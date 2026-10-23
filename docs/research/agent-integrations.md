# Agent integrations for the notch app

Source: OrchestratorInc/agent-orchestrator ("AO"), Apache-2.0, cloned 2026-10-23 (HEAD: "fix(send): fail on unconfirmed delivery…").
Paths below are inside `backend/internal/`. Apache-2.0 lets us copy and adapt code into PlatyNotch (also Apache-2.0) as long as we keep the licence text and a NOTICE crediting AO.

## How AO does it

- One hook binary for every agent: `ao hooks <agent> <event>` (e.g. `ao hooks claude-code permission-request`). It reads the hook payload from stdin and POSTs it to the local daemon at `/api/v1/sessions/{id}/activity` (`cli/hooks.go:51`).
- **Observe only.** "`ao hooks` writes nothing to stdout" (`adapters/agent/claudecode/hooks.go:39`). AO never answers a permission prompt through the hook. It owns the terminal (tmux/pty) and types into it instead.
  → For approve-from-the-notch we must add the decision output ourselves (Claude/Codex/Qwen `PermissionRequest`, Cursor `beforeShellExecution`).
- **Per-workspace install.** Hooks go into the worktree's own config (e.g. `.claude/settings.local.json`) and only act when `AO_SESSION_ID` is set; otherwise exit 0 (`cli/hooks.go:580-615`).
  → We watch sessions the user starts themselves, so we install into the **user-level** config instead and key sessions by the payload's `session_id` + `cwd`.
- **Never break the agent.** A non-AO session, an event with no meaning, or an unreachable daemon all exit 0 (`cli/hooks.go:584`). The installer keeps user hooks and unrelated settings (`claudecode/hooks.go:76`). Copy both rules.
- **Five states** (`domain/activity.go:21`): `active`, `idle`, `waiting_input`, `blocked`, `exited`.

## Claude Code event → state (AO's tested mapping, `claudecode/activity.go`)

| Event | State | Edge case AO learned |
|---|---|---|
| UserPromptSubmit | active | |
| PreToolUse / PostToolUse / PostToolUseFailure | active | Never clears `blocked`, **except** the PostToolUse of the exact tool that was blocked (answering a dialog fires no hook of its own; parallel subagents would otherwise clear a live block) |
| PermissionRequest | blocked | Earlier and richer than Notification(permission_prompt); its payload names the tool |
| Stop / StopFailure | idle | StopFailure = API error (rate/usage limit, expired login). Esc-interrupt fires no Stop; read it from the transcript (`turn_interrupts.go`) |
| Notification `idle_prompt`, `agent_completed` | idle | |
| Notification `agent_needs_input` | waiting_input | Not blocked: there is no tool to correlate the unblock with |
| Notification `permission_prompt` | blocked | Duplicate of PermissionRequest |
| SessionEnd | exited (`clear`/`resume` reasons excepted) | |

Nested processes: an interactive `claude` launched from inside a session runs the same hooks and would overwrite its parent's state. AO pins each session to one Claude process via `CLAUDE_PID`, which the hook forwards (`service/hookprocess/gate.go`). Port this.

## Integration matrix (50 adapters in `adapters/agent/`)

**Can approve** = the agent has a blocking hook whose output can allow or deny. The output formats are not in AO; check each agent's docs.

### A. Command hooks with a permission event (approvals possible)

| Agent | AO config file (workspace) | Events AO installs |
|---|---|---|
| Claude Code | `.claude/settings.local.json` | SessionStart, UserPromptSubmit, Pre/PostToolUse, PostToolUseFailure, **PermissionRequest**, Stop, StopFailure, Notification, SubagentStart/Stop, SessionEnd |
| Codex | `.codex/hooks.json` | SessionStart, UserPromptSubmit, PostToolUse, **PermissionRequest**, Stop, SubagentStart/Stop |
| Qwen Code | `.qwen/settings.json` | SessionStart, UserPromptSubmit, **PermissionRequest**, Stop |
| Autohand | `.autohand/config.json` | session-start, pre-prompt, **permission-request**, stop |
| Cursor | `.cursor/hooks.json` | sessionStart, beforeSubmitPrompt, **beforeShellExecution**, **beforeMCPExecution**, after*, postToolUse(Failure), stop |

### B. Command hooks, status only

| Agent | Config | Events |
|---|---|---|
| Gemini CLI | `.gemini/settings.json` | SessionStart, BeforeAgent, AfterAgent, AfterTool, Notification |
| Copilot CLI | `.github/hooks/ao.json`-style (`ao.json`) | sessionStart, userPromptSubmitted, preToolUse, agentStop |
| Factory Droid | `.factory/hooks.json` | SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd |
| Kiro | `.kiro/…/ao.json` | agentSpawn, userPromptSubmit, preToolUse, stop |
| Kimchi | `.kimchi/hooks.local.json` | full Claude-style set incl. Notification |
| Auggie | `.augment/settings.local.json` | SessionStart, Pre/PostToolUse, Stop, SessionEnd |
| Cline | `.clinerules/hooks` (sh/ps1) | TaskStart, UserPromptSubmit, PreToolUse, TaskComplete, TaskCancel |
| Devin | `.devin/config.local.json` | SessionStart, UserPromptSubmit, Stop, SessionEnd |
| Goose / Agy | `.agents/hooks.json` | SessionStart, UserPromptSubmit, Stop |
| OpenHands | `.openhands/hooks.json` | SessionStart, UserPromptSubmit, Stop |
| Command Code | `.commandcode/settings.json` | SessionStart, Pre/PostToolUse, Stop |
| Memcode | `.memcode/hooks.json` | session_start, pre/post_tool_use |
| Kimi | `.kimi/config.toml` | (TOML hooks) |
| Vibe | `.vibe/hooks.toml` | (TOML hooks) |

### C. JS/TS plugin instead of a command hook

AO drops a plugin file (`ao-activity.ts`) into the agent's plugin directory, and the plugin calls `ao hooks <agent>`.
OpenCode (v1 and v2, `.opencode/`), Kilo Code (`.kilocode/`), OMP (`.omp/`), Pi (`.pi/`), Mimocode, PrimeAgent, Amp (`.amp/ao-system-prompt.ts`).
Templates are in each adapter's `assets/` folder.

### D. No hooks: read the terminal screen

Aider, Continue, Grok, Hermes, CodeWhale/DeepSeek, Crush (config only).
AO reads the terminal screen to infer state (`*/terminal_activity.go`). We don't own the terminal, so for these, show "running" while the process is alive and nothing more, unless the agent writes a transcript we can watch.

## What this changes in the architecture

1. `notch-hook <agent> <event>`, the same shape as `ao hooks`. A table maps each agent to its config file and event list (port `hooksjson/`, `hookutil/`, `nativeconfig/` for safe merging).
2. Stdout stays empty for every event **except** permission events from groups A agents, where we print the decision. Any failure: print nothing, exit 0, so the agent asks in its terminal as usual.
3. Port AO's state mapping and the blocked-clear rule as-is (cite the file in a comment and keep the Apache NOTICE).
4. Launch scope: Claude Code, Codex, Gemini, Cursor, OpenCode. These cover all three integration styles (A, B, C). Add the rest from the matrix afterwards.
