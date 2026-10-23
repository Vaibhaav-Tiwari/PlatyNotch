# Plan 1: Go core and agent hub

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `notch` binary that installs hooks into five coding agents, tracks every session's state, shows permission requests to a connected UI and returns the decision to Claude Code, and reports Claude/Codex usage limits.

**Architecture:** One Go module (`core/`). `notch serve` owns a Unix socket; `notch hook <agent> <event>` is a short-lived client that agents run. Adapters are ported from agent-orchestrator (AO) and registered in a package registry. All state lives in the server process; UIs subscribe and receive a snapshot then deltas.

**Tech Stack:** Go 1.27, stdlib, `golang.org/x/sys/unix` (peer credentials). No cgo.

**Spec:** `docs/specs/2026-10-23-platynotch-design.md`, `docs/research/agent-integrations.md`

## Global Constraints

- Module path `github.com/platynotch/platynotch/core`; Go 1.27.
- Data dir `~/Library/Application Support/PlatyNotch`, overridable with `PLATYNOTCH_HOME`; user home overridable with `PLATYNOTCH_USER_HOME`; socket with `PLATYNOTCH_SOCKET` (all tests set these to temp dirs).
- Socket file mode 0600; reject peers whose uid ≠ `os.Getuid()`.
- `notch hook` always exits 0; prints to stdout only a decision for a permission event that got an allow/deny.
- Approval wait default 100 s (`config.Approvals.TimeoutSeconds`); permission hook entries are installed with `timeout: 120`.
- Hook command written into configs: the stable binary path, double-quoted, e.g. `"/Users/a/Library/Application Support/PlatyNotch/bin/notch" hook claude-code permission-request`.
- Files ported from AO keep AO's Apache-2.0 header plus `// Modified for PlatyNotch: <what>`; `third_party/agent-orchestrator/LICENSE` and `NOTICE` ship in the repo.
- Five states only: `active`, `idle`, `waiting_input`, `blocked`, `exited`.
- AO source of truth for ports: commit in `third_party/agent-orchestrator/UPSTREAM_COMMIT`, files under `backend/internal/adapters/agent/`.

## Review Focus

- Core not running, or a stale socket file left behind → `notch hook` prints nothing, exits 0 within 500 ms (Task 9).
- Agent config file is missing, has user hooks, or is invalid JSON → user hooks kept, invalid file left untouched with an error (Task 2).
- Data path contains spaces (`Application Support`) → hook command is quoted and runs (Task 2).
- Phone and notch answer the same approval at once → first wins, second gets `ErrResolved` (Task 7, used by Pro).
- A nested `claude` started inside a session sends hooks with a different pid → parent session state is not overwritten (Task 6).

---

### Task 1: Foundation packages and protocol fixtures

`protocol/`, `wire/`, `paths/`, `config/` already exist from scaffolding. This task adds the extension message types, golden fixtures shared with the Swift app, and tests.

**Files:**
- Modify: `core/protocol/protocol.go` (add ext types)
- Create: `core/protocol/protocol_test.go`, `core/protocol/testdata/*.json`
- Create: `core/wire/wire_test.go`, `core/config/config_test.go`, `core/paths/paths_test.go`
- Create: `docs/PROTOCOL.md`, `README.md` (`LICENSE` Apache-2.0 and `NOTICE` already exist)

**Interfaces:**
- Produces: everything in `protocol` (Envelope, message type constants, payload structs), `wire.NewReader/NewWriter/Send`, `paths.*`, `config.Load/Save/Secret/Default/ApprovalsOn`.
- Adds: `TypeExtRequest = "ext.request"`, `TypeExtEvent = "ext.event"`, `type ExtMessage struct { Ext string; Kind string; Data json.RawMessage }` (json: `ext`, `kind`, `data`).

- [ ] **Step 1: Write failing tests**
  - `TestEnvelopeRoundTrip`: `MustNew(TypeApprovalAdded, "1", Approval{ID:"apr_1", Tool:"Bash", Summary:"npm test"})` → marshal → unmarshal → `Decode` gives the same struct.
  - `TestGoldenFixtures`: for each struct in {Snapshot, Session, Approval, HookEvent, HookDecision, Usage, Loop, MemoryHit, ExtMessage}, marshal a fixed sample and compare to `testdata/<name>.json`; `-update` flag rewrites them. (Swift tests decode these same files in Plan 3.)
  - `TestReaderSkipsBlankLinesAndRejectsOversize`: reader over `"\n{...}\n"` returns one envelope; a 5 MB line returns an error, not a panic.
  - `TestConfigDefaults`: missing file → `Approvals.Enabled==true`, `TimeoutSeconds==100`, `Agents["claude-code"]==true`, `Memory.Enabled==false`, `Embedder.Name=="none"`.
  - `TestConfigSaveIsOwnerOnly`: saved file mode is 0600.
  - `TestSecretEnv`: `Secret("env:X")` with X=abc → "abc"; `Secret("bogus:1")` → error.
  - `TestPathsOverride`: with `PLATYNOTCH_HOME=/tmp/x`, `Socket()=="/tmp/x/notch.sock"`, `HookBinary()=="/tmp/x/bin/notch"`.
- [ ] **Step 2: Run** `cd core && go test ./protocol ./wire ./config ./paths` → FAIL (missing ext types / fixtures).
- [ ] **Step 3: Implement** the ext types; generate fixtures with `go test ./protocol -update`; write `docs/PROTOCOL.md` listing every type, direction and payload (copy of the Go doc comments).
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(core): protocol fixtures, ext messages, foundation tests"`

---

### Task 2: Merge-safe hook config installer (`hookjson`)

Port of AO `hookutil/hookutil.go` + `hooksjson/hooksjson.go` into one package.

**Files:**
- Create: `core/hookjson/hookjson.go`, `core/hookjson/command.go`, `core/hookjson/hookjson_test.go`, `core/hookjson/testdata/`

**Interfaces:**
- Produces:
  ```go
  type Format int // FormatClaude (hooks.<Event>[]{matcher?, hooks[]{type:"command", command, timeout?}}), FormatCursor (version:1, hooks.<event>[]{command}), FormatCodex (as AO codex/hooks.go)
  type Entry struct { Event string; Matcher *string; Command string; TimeoutSec int }
  type Spec struct { Path string; Format Format; Entries []Entry }
  func Install(s Spec) (changed bool, err error)
  func Uninstall(s Spec) (changed bool, err error)
  func Installed(s Spec) (bool, error)
  func Command(bin, agent, event string) string // `"<bin>" hook <agent> <event>`
  func IsOurs(command string) bool             // contains "/PlatyNotch/bin/notch" and " hook "
  ```

- [ ] **Step 1: Write failing tests** (fixtures in `testdata/`):
  - `TestInstallPreservesUserHooks`: settings with a user `PreToolUse` hook and `"theme":"dark"` → after Install, the user hook and theme are unchanged and ours is appended.
  - `TestInstallIsIdempotent`: second Install returns `changed=false`, file bytes identical.
  - `TestUninstallRemovesOnlyOurs`: after Uninstall the file equals the original fixture (modulo formatting).
  - `TestInvalidJSONUntouched`: `{"hooks":` → Install returns error, file bytes unchanged, no backup written.
  - `TestMissingFileCreated`: nonexistent path → created with mode 0600 and parent dirs.
  - `TestBackupWrittenOnce`: first change writes `<path>.platynotch-backup` with the original bytes; second change does not overwrite it.
  - `TestCommandQuotesSpaces`: `Command("/a b/notch","claude-code","stop")` == `"\"/a b/notch\" hook claude-code stop"`; `IsOurs` of it is true when the path contains `/PlatyNotch/bin/notch`.
  - `TestTimeoutWritten`: an Entry with `TimeoutSec:120` yields `"timeout":120` in FormatClaude.
- [ ] **Step 2: Run** `go test ./hookjson` → FAIL.
- [ ] **Step 3: Implement** by porting AO's merge logic (keep its Apache header, note modifications: user-level paths, quoting, timeout, backup). Write atomically (temp file + rename), preserve key order with `json.Decoder` + `json.RawMessage` passthrough for unknown keys.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): merge-safe hook installer ported from agent-orchestrator`

---

### Task 3: Adapter contract, registry and Claude Code adapter

**Files:**
- Create: `core/agents/agents.go`, `core/agents/summarize.go`, `core/agents/agents_test.go`
- Create: `core/agents/claudecode/claudecode.go`, `activity.go` (port of AO `claudecode/activity.go`), `claudecode_test.go`, `testdata/*.json`

**Interfaces:**
- Consumes: `hookjson.Spec/Install/Command`, `protocol.State`, `protocol.HookDecision`, `paths.UserHome`.
- Produces:
  ```go
  type ApprovalSupport int // ApprovalsNone, ApprovalsExperimental, ApprovalsVerified
  type Common struct {
      SessionID, CWD, Tool, ToolUseID, Prompt, Message, NotificationType, TranscriptPath string
      ToolInput json.RawMessage
  }
  type Adapter interface {
      ID() string        // "claude-code"
      Name() string      // "Claude Code"
      Detect() bool      // config dir exists or binary on PATH
      ConfigPath() string
      InstallHooks(hookBin string) (bool, error)
      UninstallHooks() (bool, error)
      HooksInstalled() (bool, error)
      DeriveState(event string, payload []byte) (protocol.State, bool)
      ParseCommon(event string, payload []byte) Common
      Approvals() ApprovalSupport
      IsPermissionEvent(event string) bool
      FormatDecision(event string, d protocol.HookDecision) []byte // nil → print nothing
  }
  func Register(a Adapter); func Get(id string) (Adapter, bool); func All() []Adapter // sorted by ID
  func Summarize(tool string, input json.RawMessage) string
  ```
- Claude Code specifics: config `~/.claude/settings.json`; events and kebab names exactly as AO (`SessionStart`→`session-start`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` (timeout 120), `Stop`, `StopFailure`, `Notification`, `SubagentStart`, `SubagentStop`, `SessionEnd`); `Approvals()==ApprovalsVerified`.

- [ ] **Step 1: Write failing tests**
  - `TestDeriveStateTable` (table from AO, one row each): `user-prompt-submit`→active; `pre-tool-use`→active; `permission-request`→blocked; `stop`→idle; `stop-failure`→idle; `notification` with `notification_type` `idle_prompt`→idle, `agent_needs_input`→waiting_input, `permission_prompt`→blocked, `auth_success`→(_, false); `session-end` reason `clear`→(_, false), reason `logout`→exited; unknown→(_, false).
  - `TestFormatDecisionAllow`: output equals `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`.
  - `TestFormatDecisionDeny`: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from PlatyNotch."}}}` (default message when empty).
  - `TestFormatDecisionNone`: `BehaviorNone` → nil.
  - `TestParseCommon`: fixture `testdata/permission-request.json` → SessionID, CWD, Tool `Bash`, ToolInput command `npm test`.
  - `TestSummarize`: Bash `{"command":"rm -rf build"}`→`rm -rf build`; Write/Edit/MultiEdit/Read → `file_path`; WebFetch → `url`; unknown → compact JSON truncated to 500 runes with `…`.
  - `TestInstallUserLevel`: with `PLATYNOTCH_USER_HOME` temp, InstallHooks writes `~/.claude/settings.json` containing 12 events and `"timeout":120` only on PermissionRequest.
- [ ] **Step 2: Run** `go test ./agents/...` → FAIL.
- [ ] **Step 3: Implement.** Verify the PermissionRequest output shape against the current Claude Code hooks documentation before finalizing; if it differs, update the test to the documented shape and note the doc URL in a comment.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): adapter contract and Claude Code adapter`

---

### Task 4: Codex, Gemini, Qwen and Cursor adapters

**Files:**
- Create: `core/agents/{codex,gemini,qwen,cursor}/<name>.go` + `_test.go` + `testdata/`

**Interfaces:**
- Consumes: Task 3 contract.
- Produces adapters with these values:

| ID | Name | Config (user level) | Format | Approvals |
|---|---|---|---|---|
| `codex` | Codex | `~/.codex/hooks.json` | FormatCodex | None |
| `gemini` | Gemini CLI | `~/.gemini/settings.json` | FormatClaude-style per AO gemini/hooks.go | None |
| `qwen` | Qwen Code | `~/.qwen/settings.json` | as AO qwen/hooks.go | None |
| `cursor` | Cursor | `~/.cursor/hooks.json` | FormatCursor | Experimental |

Event lists and state mappings are ported from the matching AO `hooks.go` and `activity.go`. Cursor `FormatDecision` for `before-shell-execution` returns `{"permission":"allow"}` or `{"permission":"deny","user_message":"…","agent_message":"…"}`; it stays Experimental (off unless `config.Approvals.Agents["cursor"]`) until checked against Cursor's docs.

- [ ] **Step 1: Write failing tests**: per adapter, `TestDeriveStateTable` (rows from the AO file), `TestInstallUserLevel` (writes the path above, preserves a user entry), `TestApprovals` (value in the table), and for Cursor `TestFormatDecision` with the two JSON shapes above.
- [ ] **Step 2: Run** `go test ./agents/...` → FAIL.
- [ ] **Step 3: Implement** the four adapters.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): codex, gemini, qwen, cursor adapters`

---

### Task 5: OpenCode plugin adapter and `agents/all`

OpenCode has no command hooks; AO installs a TypeScript plugin. We install `~/.config/opencode/plugin/platynotch.ts` that shells out to `notch hook opencode <event>`.

**Files:**
- Create: `core/agents/opencode/opencode.go`, `opencode_test.go`, `assets/platynotch.ts` (adapted from AO `opencode/assets/ao-activity.ts`, Apache header kept), `//go:embed`
- Create: `core/agents/all/all.go` (blank-imports every adapter package)

**Interfaces:**
- Produces: adapter `opencode` (Name "OpenCode", Approvals None). Plugin template placeholder `__NOTCH_BIN__` replaced with the quoted hook binary path.

- [ ] **Step 1: Write failing tests**: `TestInstallWritesPlugin` (file exists, contains the binary path, no placeholder left), `TestUninstallRemovesOnlyOurFile` (another plugin file in the dir survives), `TestDeriveStateTable` (AO opencode mapping), `TestAllRegistersSix` (`len(agents.All())==6` with claude-code, codex, cursor, gemini, opencode, qwen in ID order).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): opencode plugin adapter and adapter registry`

---

### Task 6: Policy engine

**Files:**
- Create: `core/policy/policy.go`, `core/policy/policy_test.go`

**Interfaces:**
- Consumes: `config.Rule`.
- Produces:
  ```go
  type Verdict struct { Action, Reason, Source string } // Action: allow|deny|ask
  type Provider interface { Name() string; Evaluate(tool, summary string) (Verdict, bool) }
  func Local(rules []config.Rule) Provider          // Source "local"
  type Chain []Provider
  func (c Chain) Evaluate(tool, summary string) (Verdict, bool) // first provider that matches wins
  func Match(pattern, s string) bool                  // '*' matches any run of characters incl. spaces and '/'; '?' one char; no other metacharacters
  ```

- [ ] **Step 1: Write failing tests**: `TestMatch` rows: (`rm -rf /*`, `rm -rf /usr`)→true; (`rm -rf /*`, `rm -rf ./build`)→false; (`*git push*--force*`, `git push origin main --force`)→true; (`npm test`, `npm test`)→true; (`a?c`,`abc`)→true. `TestToolStar`: rule Tool `*` matches any tool. `TestChainFirstMatchWins`: provider A (deny) before B (allow) → deny with A's Source. `TestNoMatch` → `(_, false)`.
- [ ] **Step 2–4:** run FAIL → implement → run PASS (`go test ./policy`).
- [ ] **Step 5: Commit** `feat(core): local approval policy`

---

### Task 7: Session store and approval manager

**Files:**
- Create: `core/session/store.go`, `core/session/store_test.go`
- Create: `core/approval/manager.go`, `core/approval/manager_test.go`

**Interfaces:**
- Consumes: `agents.Adapter`, `agents.Common`, `protocol.*`.
- Produces:
  ```go
  // session
  func NewStore(now func() time.Time) *Store
  func (s *Store) Apply(ev protocol.HookEvent, a agents.Adapter) (protocol.Session, bool) // bool: state or fields changed
  func (s *Store) Resolve(key string) (protocol.Session, bool)  // approval answered: blocked → active
  func (s *Store) Upsert(sess protocol.Session)                 // from discovery; never overrides a hook-fed session
  func (s *Store) Sweep(alive func(pid int) bool) (changed, removed []protocol.Session)
  func (s *Store) List() []protocol.Session                     // newest UpdatedAt first
  func Key(agent, sessionID string, pid int) string             // agent+":"+sessionID, or agent+":pid"+pid
  // approval
  var ErrUnknown, ErrResolved error
  func NewManager(now func() time.Time) *Manager
  func (m *Manager) Open(a protocol.Approval) (protocol.Approval, <-chan protocol.HookDecision) // assigns ID "apr_"+16 hex, CreatedAt, ExpiresAt
  func (m *Manager) Decide(d protocol.ApprovalDecide) error
  func (m *Manager) Expire(id string) bool  // delivers BehaviorNone
  func (m *Manager) Pending() []protocol.Approval
  ```
- Rules (from AO `claudecode/activity.go` and `service/hookprocess/gate.go`):
  - `blocked` is only cleared by: post-tool-use/post-tool-use-failure whose `ToolUseID` equals the blocking one (or same tool name when no id), user-prompt-submit, stop, stop-failure, session-end, or `Resolve`.
  - The first pid seen for a key is pinned. Events from another pid are ignored for state while the pinned pid is alive; if it is dead, the new pid is pinned.
  - `Sweep`: a session not updated for 30 min whose pid is dead → exited; exited sessions are removed 10 min after exiting.
  - Title = last prompt, one line, max 80 runes.

- [ ] **Step 1: Write failing tests**
  - `TestBlockedSurvivesParallelToolTraffic`: permission-request(tool_use_id t1) → pre-tool-use(t2) → state still blocked → post-tool-use(t1) → active.
  - `TestNestedProcessIgnored`: events pid 100 then pid 200 (alive fn says 100 alive) → state follows only pid 100.
  - `TestRepinAfterDeath`: pinned 100 dead → event from 200 applies.
  - `TestSweep`: fake clock +31 min, pid dead → exited; +10 min more → removed.
  - `TestDecideOnce`: Open → Decide allow → channel gets allow; second Decide → `ErrResolved`; Decide unknown id → `ErrUnknown`.
  - `TestConcurrentDecide`: 50 goroutines decide the same id → exactly one nil error.
  - `TestExpireDeliversNone`.
- [ ] **Step 2: Run** `go test -race ./session ./approval` → FAIL.
- [ ] **Step 3: Implement** (mutex-guarded maps; channel buffered 1).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): session state machine and approval manager`

---

### Task 8: Server, extension host and memory interface

**Files:**
- Create: `core/ext/ext.go`, `core/memory/service.go` (interface only; implemented in Plan 2)
- Create: `core/server/server.go`, `listener_darwin.go` (peer uid), `hub.go`, `hooks.go`, `ui.go`, `server_test.go`

**Interfaces:**
- Consumes: Tasks 1–7.
- Produces:
  ```go
  // memory
  type Service interface {
      Ingest(ctx context.Context, c protocol.CaptureText) error
      Search(ctx context.Context, q protocol.MemorySearch) ([]protocol.MemoryHit, error)
      Loops(ctx context.Context, status string) ([]protocol.Loop, error)
      SetLoopStatus(ctx context.Context, s protocol.LoopSetStatus) error
      Status() protocol.MemoryStatus
      OnLoopsChanged(fn func([]protocol.Loop))
      Close() error
  }
  // ext
  type AuditEvent struct { At time.Time; Agent, Project, CWD, Tool, Summary, Decision, Source string }
  type Auditor interface { Record(AuditEvent) }
  type Host interface {
      Edition() string
      Snapshot() protocol.Snapshot
      Subscribe(fn func(protocol.Envelope)) (cancel func())
      Decide(d protocol.ApprovalDecide) error
      RegisterDecider(name string) (unregister func()) // counts as "someone can answer"
      Memory() memory.Service                           // nil when memory is off
      Config() config.Config
      AddPolicy(p policy.Provider)                      // evaluated before local rules
      AddAuditor(a Auditor)
      EmitEvent(ext, kind string, data any)             // ext.event to UIs
      Logf(format string, args ...any)
  }
  type Extension interface { Name() string; Start(ctx context.Context, h Host) error }
  type RequestHandler interface { HandleRequest(ctx context.Context, kind string, data json.RawMessage) (any, error) }
  // server
  type Options struct {
      Socket, Edition string; Config config.Config; Memory memory.Service
      Extensions []ext.Extension; Now func() time.Time; Logf func(string, ...any)
  }
  func New(o Options) (*Server, error)
  func (s *Server) Serve(ctx context.Context) error // removes a stale socket only if no process answers it
  // *Server implements ext.Host
  ```
- Hook flow (`hooks.go`): adapter lookup → `Store.Apply` → broadcast `session.updated` → if `WantDecision && adapter.IsPermissionEvent && cfg.ApprovalsOn(agent)`: summary = `agents.Summarize`; `Chain{ext policies..., Local(cfg.Policy.Rules)}`; allow/deny verdict → ack `{wait:true}` + immediate decision with Source from verdict, audited; otherwise if deciders (UI subscribers + registered) == 0 → ack `{wait:false}`; else open approval, ack `{wait:true, approval_id, timeout_ms}`, broadcast `approval.added`, wait for decision or timeout or hook disconnect (→ `Expire`), send `hook.decision`, broadcast `approval.resolved`, `Store.Resolve`, audit. Stop/stop-failure after active → `notice` "session-done".
- UI flow (`ui.go`): `subscribe` → `snapshot`; `approval.decide`; `loop.set_status`; `memory.search` → `memory.results` (error message if memory off); `capture.text` → `Memory().Ingest`; `config.reload`; `ext.request` → matching extension's `RequestHandler`, reply with same ID.

- [ ] **Step 1: Write failing tests** (server on a temp socket, clients via `wire`):
  - `TestSocketModeAndPeer`: socket file mode 0600.
  - `TestSnapshotOnSubscribe`: a hook event for session s1, then subscribe → snapshot contains s1 active.
  - `TestApprovalRoundTrip`: UI subscribed; hook client sends permission-request with `want_decision` → UI receives `approval.added` with Summary `npm test` → UI sends decide allow → hook receives `hook.decision` allow; UI receives `approval.resolved`; session back to active.
  - `TestNoDeciderNoWait`: no UI → hook gets ack `wait:false` within 100 ms.
  - `TestPolicyDenyWithoutUI`: rule deny `rm -rf /*` → decision deny, Source "local", even with no UI.
  - `TestHookDisconnectExpires`: hook closes while waiting → UI receives `approval.resolved` behavior none.
  - `TestExtensionHost`: a fake extension's `Start` gets a Host; its `AddPolicy` provider wins over local; `RegisterDecider` makes a no-UI hook wait; its `Decide` resolves the approval.
  - `TestExtRequestRouting`: `ext.request{ext:"fake",kind:"ping"}` → reply carries the same ID and the handler's data.
  - `TestStaleSocketReplaced`: a leftover socket file with no listener is removed and Serve succeeds; a live server on the same path makes the second `Serve` fail with "already running".
- [ ] **Step 2: Run** `go test -race ./server ./ext` → FAIL.
- [ ] **Step 3: Implement.** Peer check via `unix.GetsockoptXucred(fd, unix.SOL_LOCAL, unix.LOCAL_PEERCRED)`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): socket server, approval flow, extension host`

---

### Task 9: `notch hook` client

**Files:**
- Create: `core/hookcli/hookcli.go`, `procinfo_darwin.go`, `hookcli_test.go`

**Interfaces:**
- Consumes: `agents.Get`, `wire`, `protocol`, `paths.Socket`.
- Produces: `func Run(agent, event string, stdin io.Reader, stdout io.Writer, env func(string) string) int` — always returns 0.
- Behavior: read stdin up to 4 MB (excess discarded); dial with 300 ms timeout; send `hello{role:hook}` + `hook.event` (`want_decision` = adapter is permission event and `Approvals() != None`); non-waiting events finish after the write (1 s total budget); waiting events read until `hook.decision` or `timeout_ms + 2 s`; print `adapter.FormatDecision` if non-nil. Process info only for session-start, user-prompt-submit, permission-request, notification: pid = `CLAUDE_PID` env if set, else parent of `os.Getppid()` via `ps -o ppid= -p`; tty via `ps -o tty= -p <pid>` (`??` → empty); `TERM_PROGRAM` from env.

- [ ] **Step 1: Write failing tests**
  - `TestNoServerExitsQuietly`: socket path to nowhere → returns 0, stdout empty, elapsed < 500 ms.
  - `TestStaleSocketFile`: a plain file at the socket path → same as above.
  - `TestGarbageStdin`: 5 MB of non-JSON → returns 0, stdout empty.
  - `TestAllowPrinted`: fake server answering allow → stdout equals Claude allow JSON from Task 3.
  - `TestWaitFalse`: fake server ack `wait:false` → stdout empty, returns immediately.
  - `TestServerHangsUp`: fake server closes mid-wait → stdout empty, 0.
- [ ] **Step 2: Run** `go test ./hookcli` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): hook client that never blocks or breaks an agent`

---

### Task 10: Usage limits (Claude status line, Codex rollouts)

**Files:**
- Create: `core/usage/statusline.go`, `codex.go`, `watcher.go`, `install.go`, `usage_test.go`, `testdata/`

**Interfaces:**
- Produces:
  ```go
  func ParseStatusline(input []byte) (*protocol.Limits, bool)
  func RunStatusline(stdin io.Reader, stdout io.Writer, cfg config.Config) int
  func ParseCodexRollout(lines [][]byte) (*protocol.Limits, bool)
  func InstallStatusline(hookBin string) error   // saves previous statusLine.command into config.Statusline.Previous
  func UninstallStatusline() error               // restores it
  func NewWatcher(usageFile, codexSessionsDir string, onChange func(protocol.Usage)) *Watcher
  func (w *Watcher) Run(ctx context.Context)     // polls every 5 s; newest rollout file only
  ```
- Parsing is tolerant: find any object keyed `five_hour` / `seven_day` (others → `Extra`); percent from the first of `used_percentage`, `utilization`, `used_percent`, `percent` (0–1 values scaled to 0–100); reset from `resets_at` (RFC 3339 or unix seconds). Codex: last line whose JSON has `rate_limits`; `primary` → FiveHour, `secondary` → Weekly; `used_percent`; reset from `resets_at` or now + `resets_in_seconds`. `RunStatusline` writes `usage.json` atomically, then runs `Previous` via `/bin/sh -c` with the same stdin and prints its stdout; with no previous command prints `<model> · 5h <n>%`.

- [ ] **Step 1: Write failing tests** with fixtures: `TestStatuslineNestedLimits` (fixture with `rate_limits.five_hour.used_percentage: 42`, `resets_at` unix → FiveHour 42 and time), `TestStatuslineFractions` (`utilization: 0.42` → 42), `TestStatuslineNoLimits` → false, `TestRunsPreviousCommand` (previous `echo hi` → stdout `hi`), `TestCodexRollout` (fixture → FiveHour/Weekly), `TestInstallRestoresPrevious` (install then uninstall leaves `statusLine` identical).
- [ ] **Step 2–4:** FAIL → implement → PASS (`go test ./usage`).
- [ ] **Step 5: Commit** `feat(core): Claude and Codex usage limits`

---

### Task 11: Transcript discovery

Backfills sessions that started before the core.

**Files:**
- Create: `core/discover/discover.go`, `discover_test.go`, `testdata/`

**Interfaces:**
- Produces: `func Claude(projectsDir string, since time.Time) []protocol.Session`, `func Codex(sessionsDir string, since time.Time) []protocol.Session`.
- Claude: newest `*.jsonl` per session under `projectsDir/*/`, modified after `since`; SessionID = file stem; CWD from the first line with `cwd`; Title from the last `type:"user"` message text; State idle. Codex: `YYYY/MM/DD/rollout-*.jsonl`, session id and cwd from the `session_meta` line. Read only the first 64 KB and last 256 KB of each file.

- [ ] **Step 1–4:** tests `TestClaudeDiscovery` (2 fixture sessions, one older than since → 1 result with title), `TestCodexDiscovery`, `TestLargeFileReadsTail` (10 MB file completes < 200 ms) → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(core): discover running sessions from transcripts`

---

### Task 12: CLI and end-to-end test

**Files:**
- Create: `core/cli/cli.go`, `cmd_serve.go`, `cmd_hooks.go`, `cmd_status.go`, `cmd_approve.go`, `cmd_doctor.go`, `cli_test.go`
- Create: `core/cmd/notch/main.go`
- Create: `core/e2e/e2e_test.go`

**Interfaces:**
- Consumes: everything above.
- Produces:
  ```go
  type Command struct { Summary string; Run func(ctx context.Context, args []string) int }
  type Option func(*Options)
  func WithEdition(e string) Option
  func WithExtensions(e ...ext.Extension) Option
  func WithCommands(c map[string]Command) Option
  func WithMemory(open func(config.Config) (memory.Service, error)) Option // Plan 2 passes its opener
  func Run(ctx context.Context, args []string, opts ...Option) int
  ```
- Commands: `serve` (also starts usage watcher, discovery at start and every 60 s, sweep every 30 s), `hook <agent> <event>`, `statusline [install|uninstall]`, `hooks install|uninstall|status [agent|all]`, `status [--json]`, `approve <id> allow|deny [--message m]`, `doctor` (socket reachable, each adapter detected/installed, statusline installed, config valid), `version`.

- [ ] **Step 1: Write failing tests**
  - `TestHooksStatusJSON`: temp home, `hooks install claude-code` → `hooks status --json` lists claude-code installed true.
  - `TestUnknownCommand` → exit 2 and usage on stderr.
  - `TestWithCommandsAddsCommand`: extra command `pair` runs.
  - E2E `TestClaudePermissionEndToEnd`: `go build` the binary into a temp dir; start `notch serve` with temp env; subscribe a UI client; run `notch hook claude-code permission-request < testdata/permission-request.json`; UI sees approval, sends allow; process stdout equals the allow JSON; exit code 0.
- [ ] **Step 2: Run** `go test ./cli ./e2e` → FAIL. **Step 3: Implement.** **Step 4: Run** `go test -race ./...` → PASS.
- [ ] **Step 5: Commit** `feat(core): notch CLI and end-to-end approval test`
