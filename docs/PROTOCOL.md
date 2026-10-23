# PlatyNotch socket protocol

Source of truth: `core/protocol/protocol.go`. Keep this file in sync.
Golden JSON samples of the main payloads live in `core/protocol/testdata/`;
the Swift app decodes the same files.

## Transport

Unix socket (`$PLATYNOTCH_SOCKET`, default `<home>/notch.sock`), newline-delimited
JSON, one envelope per line, max 4 MiB per line. Blank lines are ignored.
Timestamps are RFC 3339 UTC.

```json
{"v":1,"type":"hook.event","id":"optional correlation id","data":{}}
```

| Field  | Meaning |
|--------|---------|
| `v`    | Protocol version (currently 1) |
| `type` | Message type, see below |
| `id`   | Correlates a request with its reply (optional) |
| `data` | Type-specific payload (optional) |

The first message on every connection is `hello`. Roles: `hook`, `ui`,
`capture`, `cli`, `ext`.

## Message types

| Type | Direction | Payload |
|------|-----------|---------|
| `hello` | client → core | `Hello` |
| `ping` | any | none |
| `pong` | any | none |
| `error` | core → client | `ErrorMsg` |
| `hook.event` | hook → core | `HookEvent` |
| `hook.ack` | core → hook | `HookAck` |
| `hook.decision` | core → hook | `HookDecision` |
| `subscribe` | ui → core | none; core replies with `snapshot`, then streams updates |
| `snapshot` | core → ui | `Snapshot` |
| `session.updated` | core → ui | `Session` |
| `session.removed` | core → ui | `SessionRemoved` |
| `approval.added` | core → ui | `Approval` |
| `approval.resolved` | core → ui | `ApprovalResolved` |
| `approval.decide` | ui → core | `ApprovalDecide` |
| `usage.updated` | core → ui | `Usage` |
| `loops.updated` | core → ui | `[]Loop` |
| `loop.set_status` | ui → core | `LoopSetStatus` |
| `notice` | core → ui | `Notice` |
| `memory.status` | core → ui | `MemoryStatus` |
| `config.reload` | ui/cli → core | none |
| `capture.text` | capture → core | `CaptureText` |
| `memory.search` | any → core | `MemorySearch` |
| `memory.results` | core → requester | `MemoryResults` |
| `ext.request` | ext/ui → core → extension handler; reply core → requester (same type and `id`) | `ExtMessage` |
| `ext.event` | extension → ui/ext subscribers | `ExtMessage` |

## Payloads

Decision behaviors: `allow`, `deny`, `none` (no answer; the agent asks in its own terminal).
Session states: `active`, `idle`, `waiting_input`, `blocked`, `exited`.

- `Hello`: `role`, `client?`, `version`
- `ErrorMsg`: `message`
- `HookEvent`: `agent` (adapter id), `event` (kebab-case, e.g. `permission-request`), `payload?` (raw agent JSON), `pid?`, `ppid?`, `tty?`, `cwd?`, `term_program?`, `want_decision?`, `at`
- `HookAck`: `wait`, `approval_id?`, `timeout_ms?`
- `HookDecision`: `behavior`, `message?`, `source?` (`notch`, `phone`, `policy`, `slack`, ...)
- `Session`: `key` (agent:session id), `agent`, `agent_name`, `session_id`, `cwd?`, `project?`, `state`, `title?`, `tool?`, `message?`, `pid?`, `tty?`, `term_program?`, `subagents?`, `started_at`, `updated_at`
- `SessionRemoved`: `key`
- `Approval`: `id`, `session_key`, `agent`, `agent_name`, `project?`, `cwd?`, `tool`, `summary` (exact command or path, never paraphrased), `input?`, `created_at`, `expires_at`
- `ApprovalDecide`: `id`, `behavior`, `message?`, `source?`
- `ApprovalResolved`: `id`, `behavior`, `source?`
- `Window`: `used_percent`, `resets_at?`
- `Limits`: `five_hour?`, `weekly?`, `extra?` (map of name to `Window`), `updated_at`
- `Usage`: `claude?`, `codex?` (each `Limits`)
- `Loop`: `id`, `title`, `details?`, `kind` (`commitment|request|followup|task`), `status` (`open|resolved|dismissed`), `source_app?`, `source_thread?`, `quote?`, `due_at?`, `detected_at`, `resolved_at?`, `evidence?`
- `LoopSetStatus`: `id`, `status`, `evidence?`
- `MemoryStatus`: `enabled`, `threads`, `versions`, `chunks`, `pending`, `embedder`, `extractor`, `last_error?`
- `CaptureText`: `app_bundle`, `app_name`, `window_title?`, `url?`, `text`, `captured_at`
- `MemorySearch`: `query`, `limit?`, `since?`, `until?`, `app?`
- `MemoryHit`: `thread_id`, `title`, `source_app`, `snippet`, `score`, `at`
- `MemoryResults`: `hits` (`[]MemoryHit`)
- `Notice`: `kind` (`session-done|session-failed|approval-timeout|info`), `title`, `body?`, `session_key?`
- `Snapshot`: `sessions`, `approvals`, `usage`, `loops`, `memory`, `edition` (`free|pro`)
- `ExtMessage`: `ext` (extension id), `kind` (extension-defined), `data?` (extension-defined). The core routes by `ext` and never interprets `kind` or `data`.

## Server behavior

- The socket is created with mode `0600`; on macOS the core also rejects peers
  whose uid (`LOCAL_PEERCRED`) differs from its own. A leftover socket is
  replaced only when nothing answers on it; otherwise `notch serve` exits with
  "already running".
- A hook connection carries exactly one `hook.event`. The core always replies
  `hook.ack` (same `id`). With `wait: true` it then sends one `hook.decision`
  (same `id`) and closes the connection. Closing the hook connection while
  waiting expires the approval (`approval.resolved` with behavior `none`,
  source `hook-gone`).
- Approvals reach deciders only when the event wants a decision, the adapter
  treats the event as a permission request and supports approvals, and
  approvals are enabled for that agent, and the event's own payload names a
  tool (an unreadable, truncated or tool-less payload gets `wait: false` and
  never reaches policy or a decider). `notch hook` itself never forwards a
  payload over 4 MiB − 64 KiB (or one that would not fit a single line once
  encoded); it sends the event without payload and without `want_decision`.
  A policy `allow`/`deny` verdict
  answers immediately (`source` is the policy's, e.g. `local`); `ask` or no
  verdict shows the approval to deciders (subscribed `ui` clients and
  extension deciders). With no decider the hook gets `wait: false`. When the
  last decider disconnects, pending approvals survive a 5 s grace period, so a
  restarting UI finds them in its `snapshot` and can still answer; if no
  decider is back by then they expire with source `no-decider`.
- An expired approval resolves with behavior `none` and a source naming the
  reason: `timeout`, `hook-gone`, `no-decider` or `shutdown`.
- `approval.decide` accepts behavior `allow` or `deny` only; anything else, an
  unknown id or an already-resolved approval gets an `error` with the same `id`.
- `memory.search` and `loop.set_status` reply `error` "memory is off" when
  memory is disabled; `capture.text` is then dropped silently.
- `config.reload` replies with a `notice` of kind `info` (same `id`) on success.
- `ext.request` is answered with an `ext.request` envelope carrying the same
  `id`, whose `ExtMessage.data` is the extension's result; an unknown
  extension or a handler error yields `error` with the same `id`.
- Each subscriber has a bounded outbound queue (256 messages); a client that
  falls further behind is disconnected.
