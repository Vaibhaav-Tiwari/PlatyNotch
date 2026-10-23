// Copyright 2026 Untrivial
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported from agent-orchestrator (https://github.com/OrchestratorInc/agent-orchestrator,
// Apache-2.0, commit 60202ba): backend/internal/adapters/agent/opencode/assets/ao-activity.ts.
//
// Modified for PlatyNotch: shells `notch hook opencode <event>` (binary path injected at install); fire-and-forget with a short timeout; AO env/launch id removed.
//
// platynotch: managed opencode activity plugin (do not edit)
//
// Maps opencode lifecycle events onto PlatyNotch hook events:
//   session.created                          -> session-start
//   message.updated / message.part.updated   -> user-prompt-submit
//   tool.execute.before / tool.execute.after -> active
//   session.status (idle)                    -> stop (carries final assistant text)
//   permission.asked / question.asked        -> permission-blocked
//   permission/question reply or rejection   -> active
//
// The event payload is piped to the hook as JSON on stdin. Every call is
// best-effort: it never throws and never waits long, so a failure here can
// never break opencode.
import type { Plugin } from "@opencode-ai/plugin"

const NOTCH_BIN: string = __NOTCH_BIN__
const HOOK_TIMEOUT_MS = 2_000

export const platynotch: Plugin = async ({ directory }) => {
  const promptReports = new Map<string, boolean>()
  let currentSessionID: string | null = null
  let currentModel: string | null = null
  const messageStore = new Map<string, any>()
  const assistantMessages = new Set<string>()
  let lastAssistantText = ""

  // Synchronous on purpose (as in AO): spawnSync keeps events strictly in
  // dispatch order (an async session-start could otherwise land after the
  // prompt), and `opencode run` exits on the idle event, so an async stop
  // would be killed before it is delivered. The hook never waits for a
  // decision and the timeout is short, so this is cheap. Never throws.
  function callHook(hookName: string, payload: Record<string, unknown>) {
    try {
      const body = JSON.stringify({ ...payload, cwd: directory }) + "\n"
      Bun.spawnSync([NOTCH_BIN, "hook", "opencode", hookName], {
        cwd: directory,
        stdin: new TextEncoder().encode(body),
        stdout: "ignore",
        stderr: "ignore",
        timeout: HOOK_TIMEOUT_MS,
      })
    } catch {
      // Missing binary or spawn failure: never propagate.
    }
  }

  function switchedSession(sessionID: string): boolean {
    if (currentSessionID === sessionID) return false
    promptReports.clear()
    messageStore.clear()
    assistantMessages.clear()
    lastAssistantText = ""
    currentModel = null
    currentSessionID = sessionID
    return true
  }

  // Prefer the report that carries the prompt text; an empty report fires at
  // most once, a text report fires once and is terminal.
  function reportUserPrompt(sessionID: string, messageID: string, prompt: string) {
    const hasText = prompt.length > 0
    const reportedWithText = promptReports.get(messageID)
    if (reportedWithText) return
    if (reportedWithText === false && !hasText) return
    promptReports.set(messageID, hasText)
    callHook("user-prompt-submit", { session_id: sessionID, prompt, model: currentModel ?? "" })
  }

  return {
    event: async ({ event }) => {
      try {
        switch (event.type) {
          case "session.created": {
            const session = (event as any).properties?.info
            if (!session?.id) break
            if (switchedSession(session.id)) callHook("session-start", { session_id: session.id })
            break
          }

          case "message.updated": {
            const msg = (event as any).properties?.info
            if (!msg) break
            if (msg.sessionID && switchedSession(msg.sessionID)) {
              callHook("session-start", { session_id: msg.sessionID })
            }
            if (msg.role === "assistant" && msg.modelID) currentModel = msg.modelID
            if (msg.role === "assistant" && msg.id) assistantMessages.add(msg.id)
            if (msg.role === "user") {
              messageStore.set(msg.id, msg)
              const sessionID = msg.sessionID ?? currentSessionID
              if (sessionID) reportUserPrompt(sessionID, msg.id, "")
            }
            break
          }

          case "message.part.updated": {
            const part = (event as any).properties?.part
            if (!part?.messageID) break
            const msg = messageStore.get(part.messageID)
            if (msg?.role === "user" && part.type === "text") {
              const sessionID = msg.sessionID ?? currentSessionID
              const prompt = part.text ?? ""
              if (sessionID) reportUserPrompt(sessionID, msg.id, prompt)
              if (prompt.length > 0) messageStore.delete(part.messageID)
            } else if (assistantMessages.has(part.messageID) && part.type === "text" && !part.synthetic && !part.ignored &&
              typeof part.text === "string" && part.text.trim().length > 0) {
              lastAssistantText = part.text
            }
            break
          }

          case "session.status": {
            const props = (event as any).properties
            if (props?.status?.type !== "idle") break
            const sessionID = props?.sessionID ?? currentSessionID
            if (!sessionID) break
            callHook("stop", { session_id: sessionID, model: currentModel ?? "", last_assistant_message: lastAssistantText })
            assistantMessages.clear()
            lastAssistantText = ""
            break
          }

          case "permission.asked":
          case "question.asked": {
            const sessionID = (event as any).properties?.sessionID ?? currentSessionID
            if (!sessionID) break
            callHook("permission-blocked", { session_id: sessionID, model: currentModel ?? "" })
            break
          }

          case "permission.replied":
          case "question.replied":
          case "question.rejected": {
            const sessionID = (event as any).properties?.sessionID ?? currentSessionID
            if (!sessionID) break
            callHook("active", { session_id: sessionID, model: currentModel ?? "" })
            break
          }
        }
      } catch {
        // A malformed event must never crash opencode.
      }
    },
    "tool.execute.before": async (input) => {
      try { callHook("active", { session_id: input.sessionID, model: currentModel ?? "" }) } catch {}
    },
    "tool.execute.after": async (input) => {
      try { callHook("active", { session_id: input.sessionID, model: currentModel ?? "" }) } catch {}
    },
  }
}
