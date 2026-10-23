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
| `session.removed` | core → ui | `Session` (or its key) |
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
| `ext.request` | ext/ui → core → extension handler | `ExtMessage` |
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
