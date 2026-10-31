# Quiet Notch (v0.3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the open panel to Home and Agents, fix Open terminal so it opens the app that really hosts each session, move the Library's long tail into a command line, chips and the menu bar, and return to the dense black v0.2 look.

**Architecture:** Pure decisions live in `PlatyNotchKit` with unit tests (open-target resolution, header text, Up next, chips, the command parser, routes, settings and migration, tokens); `PlatyNotchUI` turns them into views behind seams (closure structs, static helpers) that tests drive without live windows. The Go core gains one optional protocol field. Three phases, each merged to main on its own, each ending with the full suite and the smoke runs.

**Tech Stack:** Go 1.27 (`core/`), Swift 6 / SwiftPM (`apps/mac`, macOS 15+), SwiftUI, AppKit, Core Animation, XCTest.

**Spec:** `docs/specs/2026-10-31-quiet-notch-design.md` (from the approved `docs/specs/2026-10-31-quiet-notch-wireframes.html`). Every **[call]** in the spec is binding.

## Global Constraints

- Paths contain spaces. Every command starts from `WT="/Users/vaibhaav/Library/Application Support/Claude/scratch-workspaces/c03a99fb-b5e4-421a-a233-4b0358662113/25bab691-d493-4cd2-a69e-34dd9bd79c2d/scratch-2026-10-23-104f70/platynotch/.worktrees/quiet-notch"`, always quoted. Branch `feat/quiet-notch`; one task at a time.
- All builds use `--scratch-path /private/tmp/claude-501/pn-build-shared`, never a per-agent path. Tests: `cd "$WT/apps/mac" && swift test --scratch-path /private/tmp/claude-501/pn-build-shared [--filter <Target>.<Class>]`.
- Never use `isolated deinit`; CI greps for it. Use a plain `deinit`.
- Wrap AVFoundation and QuickLook completion APIs in `withCheckedContinuation`, never their generated async forms.
- Pass the type-check guard `-warn-long-expression-type-checking=300`: typed locals, never mix `Double` and `CGFloat` in one expression.
- Idle CPU stays under 1 % (`scripts/perf-idle.sh`); animation uses Core Animation only. Countdown text (chips, keep-awake time) ticks only while `\.panelTicking` is true.
- New test classes that touch defaults use `DefaultsTestCase` (`Tests/PlatyNotchKitTests/DefaultsTestCase.swift`, `Tests/PlatyNotchUITests/DefaultsTestCase.swift`) and get storage from `defaults()`.
- Every test or render window goes off-screen at (-10000, 10000).
- Never bundle third-party logos. App icons come at run time from installed apps only. When no app is installed, show the agent name as text, never initials.
- No emoji anywhere in the UI (`DesignLintTests.testNoEmojiInStringLiterals`). Keycap glyphs (⌘ ⌫ ↩) are not emoji.
- Layout tests must not hard-code point heights that differ between macOS 15 and 26; measure reference controls at run time.
- Showcase renders are forced to 2x.
- `ApprovalSafetyTests` and `ApprovalArmingControllerTests` stay unmodified and must pass after every task.
- Plugin API (`NotchWidget`, `NotchPlugin`, `WidgetContext`, `PanelTab`, `LiveActivity`) changes only additively; members no longer drawn (hero, glance) keep their defaults. `PluginAPITests` passes unchanged.
- Old tab ids (`NotchController.expand(tab:)`, `WidgetContext.openPanel(tab:)`) and settings ids keep working through redirects (spec 7).
- Smoke recipe ("the smoke runs"):
  ```sh
  cd "$WT/core" && go build -o /private/tmp/claude-501/pn-notch ./cmd/notch
  cd "$WT/apps/mac" && swift build --scratch-path /private/tmp/claude-501/pn-build-shared
  B=/private/tmp/claude-501/pn-build-shared/debug/PlatyNotch; R=$(mktemp -d)
  PLATYNOTCH_CORE_BIN=/private/tmp/claude-501/pn-notch PLATYNOTCH_HOME=$(mktemp -d) PLATYNOTCH_RENDER_DIR="$R" "$B" --smoke
  PLATYNOTCH_CORE_BIN=/private/tmp/claude-501/pn-notch PLATYNOTCH_HOME=$(mktemp -d) "$B" --smoke-settings
  PLATYNOTCH_HOME=$(mktemp -d) "$B" --smoke-power
  ```
  Baseline at `75fdeca`: `SMOKE OK panels=1 mode=compact menubar=true … widgets=<W> surfaces=ok sounds=<S> games=5 renders=188 theme=dark`, `SMOKE SETTINGS OK sections=<P> onboarding=<O> menubar=true`, `SMOKE-POWER OK widgets=6`. 188 = 2 × (75 `ThemeRenders` views + 19 `SettingsRenders.windows()`); if the Task 5 baseline prints another value, that value is N₀ and every later total keeps the stated deltas.
- Commits: stage the task's listed files by name (never `git add -A` / `git add .`); deleted files with `git rm`.

## Review Focus

- A session whose cwd was deleted after it started, with no known host → "Show folder" shows a short notice "Folder no longer exists" instead of opening Finder somewhere else (Task 3 `testMissingFolderShowsNotice`).
- An approval arrives while the command line has focus and text in it → ⌘↩ / ⌘⌫ answer the approval as today, Return never answers it, and the typed command does not run (Task 11 `testCommandLineNeverAnswersApprovals`).
- The Mac sleeps past a timed keep-awake → on wake the header icon is off at once, never shows `0:00` or a negative time (Task 4 `testKeepAwakeExpiredAfterSleepShowsOff`).
- 200-character track titles, event titles, labels and project names → media block, Up next, chips and Agents rows truncate with an ellipsis and the panel stays 600 pt wide (Task 10 `testLongTitlesTruncate`, Task 15 `testLongProjectTruncates`).
- Odd command input (`timer 0`, `timer 25h`, `remind` alone, `play pong`, leading spaces, mixed case) → nothing runs, the row explains (Task 7 `testInvalidInputExplains`).

---

## Phase 1: Open terminal and the header toggles

### Task 1: The hook records the host app

**Files:**
- Modify: `core/protocol/protocol.go` (HookEvent, Session)
- Modify: `core/hookcli/hookcli.go:64-71`
- Modify: `core/session/store.go:126-128`
- Modify: `core/protocol/protocol_test.go` (fixture values), `core/protocol/testdata/{hook_event,session,snapshot}.json` (regenerated)
- Test: `core/hookcli/hookcli_test.go`, `core/session/store_test.go`
- Modify: `docs/PROTOCOL.md:67,70`

**Interfaces:**
- Produces: `HookEvent.HostBundleID string \`json:"host_bundle_id,omitempty"\``, `Session.HostBundleID string \`json:"host_bundle_id,omitempty"\``. `protocol.Version` stays 1.

- [ ] **Step 1: Write the failing tests**

```go
// hookcli_test.go — env returns the socket and __CFBundleIdentifier
func TestHostBundleIDRecorded(t *testing.T) // fakeServer decodes the hook.event; want ev.HostBundleID == "com.anthropic.claudefordesktop"
func TestHostBundleIDOmittedWhenUnset(t *testing.T) // raw hook.event JSON has no "host_bundle_id" key
// store_test.go
func TestHostBundleIDKeptAcrossEvents(t *testing.T) // first event sets "com.anthropic.claudefordesktop"; a later event with "" keeps it; a later "com.mitchellh.ghostty" replaces it
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd "$WT/core" && go test ./hookcli ./session -run 'HostBundleID'`
Expected: FAIL, `ev.HostBundleID undefined`.

- [ ] **Step 3: Implement.** Add the two fields after `TermProgram`; in `Run` set `HostBundleID: env("__CFBundleIdentifier")`; in the store copy it when non-empty (as `TermProgram`). In `TestGoldenFixtures` set `HostBundleID: "com.apple.Terminal"` on `session` and `hookEvent`, then regenerate: `go test ./protocol -run TestGoldenFixtures -update`. Document `host_bundle_id?` after `term_program?` in both PROTOCOL.md lines.

- [ ] **Step 4: Run to verify they pass**

Run: `cd "$WT/core" && go test ./... && go vet ./...`
Expected: `ok` for every package, no vet output.

- [ ] **Step 5: Commit** — `git commit -m "feat(core): hooks record the host app's bundle id (host_bundle_id)"`

### Task 2: Resolve where "Open" goes

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchKit/Models.swift` (HookEvent, Session)
- Create: `apps/mac/Sources/PlatyNotchKit/Agents/OpenTarget.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Agents/PlipPolicy.swift:25-37`
- Test: Create `apps/mac/Tests/PlatyNotchKitTests/OpenResolverTests.swift`; Modify `Tests/PlatyNotchKitTests/ModelsTests.swift`, `Tests/PlatyNotchKitTests/PlipPolicyTests.swift`

**Interfaces:**
- Consumes: Task 1's `host_bundle_id`.
- Produces:
  - `Session.hostBundleID: String?` (key `host_bundle_id`; init parameter `hostBundleID: String? = nil` after `termProgram`); same on `HookEvent`.
  - `public enum OpenTarget: Equatable, Sendable { case terminalTab(tty: String), iTermSession(tty: String), tmuxPane(tty: String, hostBundleID: String), activate(bundleID: String), showFolder(path: String) }` with `public var appBundleID: String?` (Terminal, iTerm2, the tmux host, the activated id; nil for `showFolder`).
  - `public struct OpenAction: Equatable, Sendable { public let target: OpenTarget; public let title: String }`
  - `public enum OpenResolver { public static func resolve(_ s: Session, appName: (String) -> String?) -> OpenAction? }` — `appName` returns the installed app's localized name, nil when not installed. Rules in spec §4 order; empty strings count as nil; ttys go through `TTY.normalize`; the tmux and host rules need `appName(host) != nil`. Title `"Open \(name)"`, or `"Show folder"`.
  - `public enum TmuxPanes { public static func target(forTTY tty: String, listing: String) -> String? }` — `listing` is `tmux list-panes -a -F '#{pane_tty} #{session_name}:#{window_index}.#{pane_index}'` output; returns `"main:1.0"` for the line whose tty matches.

- [ ] **Step 1: Write the failing tests** (names → `appName` stub `["com.anthropic.claudefordesktop": "Claude", "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm", "com.mitchellh.ghostty": "Ghostty"]`)

```swift
func testClaudeAppSessionOpensClaude()      // host claudefordesktop, cwd "/w/p" → OpenAction(target: .activate(bundleID: "com.anthropic.claudefordesktop"), title: "Open Claude")
func testTerminalTab()                      // term "Apple_Terminal", tty "ttys004" → .terminalTab(tty: "/dev/ttys004"), "Open Terminal"
func testITermSession()                     // term "iTerm.app", tty "/dev/ttys007" → .iTermSession(tty: "/dev/ttys007"), "Open iTerm"
func testTmuxSelectsPaneInHost()            // term "tmux", tty "ttys009", host ghostty → .tmuxPane(tty: "/dev/ttys009", hostBundleID: "com.mitchellh.ghostty"), "Open Ghostty"
func testTmuxWithoutKnownHostShowsFolder()  // term "tmux", no host, cwd "/w/p" → .showFolder(path: "/w/p"), "Show folder"
func testUnknownHostShowsFolder()           // host "com.example.gone" (no name), cwd "/w/p" → "Show folder"
func testNothingRecordedShowsFolder()       // no host, no term, cwd "/w/p" → "Show folder"
func testNoCwdNoButton()                    // nothing known, cwd nil → nil
func testLegacyTermProgramStillMaps()       // term "ghostty", no host → .activate(bundleID: "com.mitchellh.ghostty"), "Open Ghostty"
func testBadTTYActivatesTerminal()          // term "Apple_Terminal", tty "../x" → .activate(bundleID: "com.apple.Terminal")
func testEmptyHostIsIgnored()               // host "", term "iTerm.app", tty "ttys001" → .iTermSession
func testTmuxListingMatch()                 // TmuxPanes.target(forTTY: "/dev/ttys009", listing: "/dev/ttys008 a:0.0\n/dev/ttys009 main:1.2\n") == "main:1.2"; unknown tty → nil
// ModelsTests.testFixtureValues: XCTAssertEqual(s.hostBundleID, "com.apple.Terminal")
// PlipPolicyTests
func testHostAppFrontmostMutes()            // session host claudefordesktop, front claudefordesktop → shouldPlay false; front Finder → true
```

- [ ] **Step 2: Run to verify they fail** — `swift test --scratch-path /private/tmp/claude-501/pn-build-shared --filter 'PlatyNotchKitTests.(OpenResolverTests|ModelsTests|PlipPolicyTests)'` → FAIL, `cannot find 'OpenResolver'`.
- [ ] **Step 3: Implement** the model fields, `OpenTarget.swift`, and in `PlipPolicy.shouldPlay` return `front != host` first when the session has a host. `TerminalApps` stays (Plip's mute rule and resolver rule 5 use it).
- [ ] **Step 4: Run to verify they pass** — same command → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): resolve each session's host app; Show folder when unknown"`

### Task 3: Open the resolved app; buttons name it

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchUI/TerminalFocus.swift` (rewrite around `OpenAction`; delete `startTracking`, `lastActive`, `activateByAncestry`, `activateMostRecentTerminal`, `parentPID`)
- Create: `apps/mac/Sources/PlatyNotchUI/Agents/HostAppName.swift`
- Modify: `Sources/PlatyNotchUI/NotchApp.swift:191,514`, `Sources/PlatyNotchUI/Agents/AgentRow.swift`, `Sources/PlatyNotchUI/Now/AgentsHero.swift`, `Sources/PlatyNotchUI/Views/ApprovalCard.swift:130`
- Test: Create `apps/mac/Tests/PlatyNotchUITests/TerminalFocusTests.swift`; Modify `Tests/PlatyNotchUITests/AgentsViewTests.swift`

**Interfaces:**
- Consumes: `OpenResolver.resolve`, `OpenTarget`, `TmuxPanes.target` (Task 2).
- Produces:
  - `@MainActor enum HostAppName { static var lookup: (String) -> String? }` — default: `NSRunningApplication.localizedName` when running, else `FileManager.default.displayName(atPath:)` of `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` without `.app`; cached, cache cleared on `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification`.
  - `struct OpenEffects { var selectTab: (OpenTarget, @escaping @MainActor (Bool) -> Void) -> Void; var isRunning: (String) -> Bool; var activate: (String) -> Void; var launch: (String) -> Void; var folderExists: (String) -> Bool; var reveal: (String) -> Void; var notice: (String) -> Void; static var live: OpenEffects }`
  - `@MainActor enum TerminalFocus { static func open(_ session: Session); static func perform(_ action: OpenAction, effects: OpenEffects); static func title(for session: Session) -> String? }`
  - `AgentRowAction.title` is no longer drawn; rows and the approval card's secondary button use `TerminalFocus.title(for:)` (hidden when nil).

- [ ] **Step 1: Write the failing tests** (a spy `OpenEffects` records calls in order)

```swift
func testTabFoundActivatesNothingElse()      // .terminalTab, selectTab reports true → calls == ["selectTab"]
func testTabMissActivatesHostOnce()          // .iTermSession, selectTab false → ["selectTab", "activate:com.googlecode.iterm2"]
func testTmuxSelectsPaneThenActivatesHost()  // .tmuxPane → ["selectTab", "activate:com.mitchellh.ghostty"]
func testLaunchesHostWhenNotRunning()        // .activate, isRunning false → ["launch:com.anthropic.claudefordesktop"]
func testUnknownHostRevealsFolderOnly()      // .showFolder("/w/p") → ["reveal:/w/p"]; no activate, no launch
func testMissingFolderShowsNotice()          // folderExists false → ["notice:Folder no longer exists"]
func testTitleUsesLocalizedName()            // HostAppName.lookup = { $0 == "com.anthropic.claudefordesktop" ? "Claude" : nil }; title(for: claude session) == "Open Claude"
// AgentsViewTests
func testRowButtonNamesTheHostApp()          // AgentRow.texts(...).last == "Open Claude"
func testUnknownHostRowSaysShowFolder()      // .last == "Show folder"
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotchUITests.(TerminalFocusTests|AgentsViewTests)'` → FAIL.
- [ ] **Step 3: Implement.** `selectTab` live: Terminal / iTerm2 AppleScripts as today (tty as `argv`, off-main queue, −1743 logged once); tmux runs `tmux list-panes …` then `tmux select-window -t <t>` and `select-pane -t <t>` through `ProcessRunner` off-main. `reveal` is `NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:)])`; `launch` is `NSWorkspace.shared.openApplication(at:configuration:completionHandler:)`. Remove `TerminalFocus.startTracking()` from `NotchApp`.
- [ ] **Step 4: Run to verify they pass** — same filter → PASS; then the whole suite → PASS.
- [ ] **Step 5: Commit** — `git commit -m "fix(mac): Open names and opens the session's host app; never the most recent terminal"`

### Task 4: Header toggles: Keep awake, Mirror, battery

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Home/HeaderStatus.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/System/KeepAwakeTimer.swift` (preferred duration)
- Create: `apps/mac/Sources/PlatyNotchUI/Home/HeaderServices.swift`, `apps/mac/Sources/PlatyNotchUI/Home/HeaderToggles.swift`
- Modify: `Sources/PlatyNotchUI/System/SystemWidget.swift:179-190` (takes the shared `KeepAwake`), `Sources/PlatyNotchUI/Views/ExpandedPanel.swift` (`controls`), `Sources/PlatyNotchUI/NotchApp.swift` (owns `HeaderServices`)
- Test: Create `Tests/PlatyNotchKitTests/HeaderStatusTests.swift`, `Tests/PlatyNotchUITests/HeaderTogglesTests.swift`

**Interfaces:**
- Produces:
  - `public struct HeaderBadge: Equatable, Sendable { public let text: String; public let symbol: String; public let tone: StateTone }`
  - `public enum HeaderBattery { public static let lowBelow = 20; public static func badge(_ b: BatteryState?) -> HeaderBadge? }` — charging → `"\(p)% charging"`, `bolt.fill`, `.working`; `percent < 20 && !pluggedIn` → `"\(p)%"`, `battery.25`, `.error`; else nil.
  - `public enum KeepAwakeLabel { public static func remaining(_ s: KeepAwakeSession?, now: Date) -> String? }` — `h:mm`, minutes rounded up; nil when off, expired or until-off.
  - `public enum HeaderDate { public static func text(now: Date, weather: String?, calendar: Calendar, locale: Locale) -> String }` — `"Fri 31 · 14° Clear"`, `"Fri 31"` without weather.
  - `extension KeepAwakeDuration { public static let preferenceKey = "keepAwake.duration"; public static func preferred(in d: UserDefaults) -> KeepAwakeDuration /* .twoHours */; public func savePreferred(to d: UserDefaults) }`
  - `@MainActor @Observable final class HeaderServices { let keepAwake: KeepAwake; private(set) var battery: BatteryState?; init(keepAwake: KeepAwake, power: PowerSourceReading, defaults: UserDefaults); func toggleKeepAwake(); func startKeepAwake(_ d: KeepAwakeDuration) }`
  - `struct HeaderToggles: View` (keep-awake `cup.and.saucer` / `.fill` amber with `KeepAwakeLabel`, context menu of the four durations; Mirror `video` → `static func openMirror(registry: WidgetRegistry, route: inout PanelRoute)`: enables `MirrorWidget.widgetID` if off, then sets the route to the Mirror tool; Settings `gearshape`; battery badge before them). Every icon 16 pt, VoiceOver labels "Keep awake", "Mirror", "Settings".

- [ ] **Step 1: Write the failing tests**

```swift
// HeaderStatusTests (Kit, DefaultsTestCase)
func testChargingShowsPercentAndWord()   // BatteryState(percent: 64, charging: true, pluggedIn: true, minutesRemaining: nil) → HeaderBadge(text: "64% charging", symbol: "bolt.fill", tone: .working)
func testLowBelowTwentyUnplugged()       // 19 unplugged → "19%", "battery.25", .error; 20 unplugged → nil
func testPluggedInNotChargingHidden()    // 100 plugged, not charging → nil; 15 plugged, not charging → nil
func testKeepAwakeRemaining()            // 80 min left → "1:20"; 59 s → "0:01"; .untilOff → nil
func testKeepAwakeExpiredAfterSleepShowsOff() // session(.thirtyMinutes, now: t); remaining(at: t + 3 h) == nil
func testDateAndWeather()                // 2026-10-31, en_US_POSIX, weather "14° Clear" → "Fri 31 · 14° Clear"; nil → "Fri 31"
func testPreferredDurationDefaultsToTwoHours() // preferred(in: defaults()) == .twoHours; .oneHour saved → .oneHour
// HeaderTogglesTests (UI, DefaultsTestCase; NoPowerAsserter, fake PowerSourceReading)
func testClickStartsPreferredDuration()  // toggleKeepAwake() → keepAwake.session?.duration == .twoHours
func testSecondClickStops()              // toggle twice → session == nil
func testMirrorClickTurnsMirrorOn()      // registry(persist: false) Mirror off → HeaderToggles.openMirror(...) → enabled contains "mirror", route.tool == MirrorWidget.widgetID
func testWorksWithSystemWidgetOff()      // System widget disabled → toggleKeepAwake() still holds the assertion
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotch(Kit|UI)Tests.(HeaderStatusTests|HeaderTogglesTests)'` → FAIL.
- [ ] **Step 3: Implement.** `SystemWidget.init` gains `keepAwake: KeepAwake? = nil` (nil builds its own, for `inert()` and tests); the app passes `HeaderServices.keepAwake`, so the System tile and the header share one assertion. The header text in this phase sits in today's nav row; Task 10 moves it into Home's header.
- [ ] **Step 4: Run to verify they pass** — same filter, then the whole suite → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): header Keep awake, Mirror and battery (only when charging or low)"`

### Task 5: Phase 1 check

**Files:**
- Modify: `scripts/verify-widgets.md` (new section "Quiet Notch phase 1": Open in the Claude app, Ghostty, Terminal tab, iTerm2 tab, tmux pane; a deleted host app → Show folder; Keep awake one click and time; battery only when charging or under 20 %)

- [ ] **Step 1:** `cd "$WT/core" && go test ./... && go vet ./...` → all `ok`.
- [ ] **Step 2:** `cd "$WT/apps/mac" && swift test --scratch-path /private/tmp/claude-501/pn-build-shared` → `Executed N tests, with 0 failures`, `ApprovalSafetyTests` and `ApprovalArmingControllerTests` among them, their files unchanged (`git diff --stat 75fdeca -- apps/mac/Tests/PlatyNotchKitTests/ApprovalSafetyTests.swift apps/mac/Tests/PlatyNotchUITests/ApprovalArmingControllerTests.swift` prints nothing).
- [ ] **Step 3:** The smoke runs → `SMOKE OK … games=5 renders=188 theme=dark` (N₀), `SMOKE SETTINGS OK …`, `SMOKE-POWER OK widgets=6`. `grep -rn "isolated deinit" "$WT/apps/mac/Sources"` → nothing.
- [ ] **Step 4: Commit** — `git commit -m "docs: Quiet Notch phase 1 hardware checks"`

---

## Phase 2: Structure

### Task 6: Library out, redirects in

**Files:**
- Modify: `Sources/PlatyNotchKit/Agents/AgentsVisibility.swift:40-46`, `Sources/PlatyNotchKit/Library/PanelRoute.swift` (move to `Sources/PlatyNotchKit/Home/PanelRoute.swift`), `Sources/PlatyNotchKit/Setup/SettingsRoute.swift`
- Delete: `Sources/PlatyNotchKit/Library/LibraryModel.swift` (keep `LibraryTools` as `PanelTools` in `Home/PanelRoute.swift`), `Sources/PlatyNotchUI/Library/LibraryView.swift`, `LibraryTile.swift`, `LibraryLines.swift`
- Modify: `Sources/PlatyNotchUI/Views/ExpandedPanel.swift`, `Sources/PlatyNotchUI/NotchController.swift:209-256`, `Sources/PlatyNotchUI/NotchPanel.swift:81-88`, `Sources/PlatyNotchUI/Library/ToolHost.swift`, `Sources/PlatyNotchUI/Settings/SettingsWindow.swift`, `Sources/PlatyNotchUI/Smoke/ThemeRenders.swift` (`LibraryRenders` → `ToolRenders`), `Sources/PlatyNotchUI/Smoke/ShowcaseRenders.swift` (scene `library` → `agents-list`)
- Test: Delete `Tests/PlatyNotchKitTests/LibraryModelTests.swift`, `Tests/PlatyNotchUITests/LibraryViewTests.swift`; Create `Tests/PlatyNotchKitTests/PanelRouteTests.swift`, `Tests/PlatyNotchUITests/PanelRoutingTests.swift`; Modify `Tests/PlatyNotchKitTests/SettingsRouteTests.swift`

**Interfaces:**
- Produces:
  - `public enum PanelDestination: String, CaseIterable, Sendable { case home, agents; public static func shown(agentsVisible: Bool) -> [PanelDestination] }`
  - `PanelRoute(destination:tool:)` unchanged in shape; `tool` is a feature open inside Home. `legacy(tab:tools:)`: `now`, `today`, `home`, `library` → `.home`; `agents` → `.agents`; `focus`, `memory`, `games`, a tool id or `plugin:<id>` → `.home` with that tool; else `.home`. `normalized(agentsVisible:)`, `back()` (tool → plain Home).
  - `public enum PanelTools { static let memory = "memory", chase = "games.chase"; static func plugin(_ id: String) -> String }`
  - `SettingsPage.home` (raw `"home"`, title `"Home"`, symbol `"house"`) replaces `.now`; `SettingsTarget.resolve("now")` and `("now/<d>")` → `home`.
  - `NotchController.commandDigit(_:)` handles 1 (Home) and 2 (Agents) only; `NotchPanel.commandDigit` accepts `1...2`.
  - `ExpandedPanel.route(forTool:) -> PanelRoute` returns `PanelRoute(destination: .home, tool: id)`; an open tool draws in `ToolHost` with its back chevron.

- [ ] **Step 1: Write the failing tests**

```swift
// PanelRouteTests (Kit)
func testOldDestinationsLandOnHome()  // for t in ["now","today","home","library"]: legacy(tab: t, tools: []) == PanelRoute(destination: .home)
func testToolTabsOpenInsideHome()     // "focus","memory","games","clipboard"(in tools) → PanelRoute(destination: .home, tool: t)
func testPluginTabOpensItsTool()      // tools ["plugin:x"]; legacy(tab: "x") == PanelRoute(destination: .home, tool: "plugin:x")
func testUnknownTabIsHome()
func testBackFromToolIsHome()         // PanelRoute(destination: .home, tool: "shelf").back() == PanelRoute(destination: .home)
func testAgentsHiddenFallsBackToHome()
func testOnlyTwoDestinations()        // PanelDestination.allCases == [.home, .agents]
// SettingsRouteTests
func testNowSectionLandsOnHome()      // resolve("now") == SettingsTarget(section: "home"); resolve("now/x").detail == "x"
// PanelRoutingTests (UI, moved from LibraryViewTests: testToolHostHasABackChevron, testGamesFitAsATool, testNonKeyPanelIgnoresCommandDigit)
func testCommandDigitThreeIsUnused()  // expanded controller: commandDigit(3) == false; commandDigit(1) → route.destination == .home
func testExpandLibraryTabOpensHome()  // controller.expand(tab: "library") → model.route == PanelRoute(destination: .home)
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotch(Kit|UI)Tests.(PanelRouteTests|SettingsRouteTests|PanelRoutingTests)'` → FAIL.
- [ ] **Step 3: Implement.** Today's Now view stays the `.home` body until Task 10. Renders: `library-grid`, `library-grid-default`, `library-setup` go; `library-tool-<id>` become `tool-<id>`.
- [ ] **Step 4: Run to verify they pass** — filter, then whole suite → PASS. Smoke `renders=` is N₀ − 6.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): remove the Library; old tabs and settings links redirect to Home"`

### Task 7: Command parser

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Home/CommandParser.swift`
- Test: Create `apps/mac/Tests/PlatyNotchKitTests/CommandParserTests.swift`

**Interfaces:**
- Consumes: `DurationParser.parse/describe`, `QuickAddParser.parse`, `QuickAddFormat.preview`, `GameKind`.
- Produces:
  - `public enum PanelCommand: Equatable, Sendable { case timer(duration: TimeInterval, label: String?), focus(minutes: Int), remind(QuickAdd), note(String), search(String), play(GameKind?), open(tool: String) }`
  - `public struct CommandSuggestion: Equatable, Sendable { public let command: PanelCommand?; public let title: String; public let detail: String? }` — nil command: an explanation row that never runs.
  - `public struct CommandTool: Equatable, Sendable { public let id: String; public let title: String }`
  - `public enum CommandParser { public static func suggestions(for text: String, tools: [CommandTool], now: Date, calendar: Calendar) -> [CommandSuggestion] }` — keyword is the first word, case-insensitive; `timer` takes the longest run of up to 3 leading tokens `DurationParser` accepts, the rest (quotes stripped) is the label; `focus` defaults to 25, accepts 1...240; `play` maps game titles case-insensitively (`chase` → `.chase`); free text gives "Search memory for "…"", "Remind me: …" and up to 3 `Open <title>` matches by title prefix.

- [ ] **Step 1: Write the failing tests**

```swift
func testTimerWithLabel()        // "timer 10m tea" → first == CommandSuggestion(command: .timer(duration: 600, label: "tea"), title: "Timer", detail: "10 min · \"tea\"")
func testTimerTwoTokenDuration() // "timer 1h 30m" → .timer(duration: 5400, label: nil)
func testFocusDefault()          // "focus" → .focus(minutes: 25); "Focus 50" → .focus(minutes: 50)
func testRemindUsesQuickAdd()    // "remind call Priya at 5pm" and "reminder call Priya at 5pm" → .remind(QuickAddParser.parse("call Priya at 5pm", now: t, calendar: cal))
func testNoteAndSearch()         // "note buy milk" → .note("buy milk"); "search budget" → .search("budget")
func testPlay()                  // "play" → .play(nil); "play chase" → .play(.chase); "play 2048" → .play(.twenty48)
func testFreeTextOffersSearchRemindOpen() // "cli", tools [CommandTool(id: "clipboard", title: "Clipboard")] → titles ["Search memory for \"cli\"", "Remind me: cli", "Open Clipboard"]
func testEmptyGivesNothing()     // "   " → []
func testInvalidInputExplains()  // "timer 0", "timer 25h", "remind", "play pong", "focus 999" → first.command == nil, detail non-nil
```

- [ ] **Step 2: Run to verify they fail** — `--filter PlatyNotchKitTests.CommandParserTests` → FAIL.
- [ ] **Step 3: Implement** `CommandParser.swift`.
- [ ] **Step 4: Run to verify they pass** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): command parser for timer, focus, remind, note, search, play and open"`

### Task 8: Home model: Up next and live chips

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Home/UpNext.swift`, `apps/mac/Sources/PlatyNotchKit/Home/LiveChips.swift`
- Test: Create `Tests/PlatyNotchKitTests/UpNextTests.swift`, `Tests/PlatyNotchKitTests/LiveChipsTests.swift`

**Interfaces:**
- Produces:
  - `public struct UpNextItem: Equatable, Sendable { public enum Kind: Sendable { case event, reminder }; public let id: String; public let title: String; public let date: Date?; public let hasTime: Bool; public let isAllDay: Bool; public let kind: Kind }`
  - `public struct UpNextRow: Equatable, Sendable { public let id: String; public let time: String; public let title: String; public let note: String?; public let overdue: Bool }`
  - `public enum UpNext { public static let limit = 3; public static func rows(_ items: [UpNextItem], now: Date, calendar: Calendar, locale: Locale) -> [UpNextRow] }` — overdue reminders first (oldest first, time "Overdue"), then by date; events that ended or are all-day are dropped, reminders without a date dropped; note `"in N m"` (rounded up) for an event within 60 min, `"now"` while it runs, `"reminder"` for reminders; a dated reminder without time shows "Today".
  - `public struct LiveChip: Equatable, Sendable { public enum Kind: Equatable, Sendable { case focus, timer(UUID), shelf }; public let kind: Kind; public let text: String; public let tone: StateTone? }`
  - `public enum LiveChips { public static let maxShown = 4; public static func chips(focus: FocusTimer?, timers: [CountdownTimer], shelfCount: Int, now: Date) -> (shown: [LiveChip], overflow: Int) }` — focus (`.needsYou` dot, `"Focus 18:42"`), running timers by soonest end (`"Tea timer 3:10"` from label "tea", else `"Timer 3:10"`; `h:mm:ss` from an hour), shelf `"Shelf · 3"`.

- [ ] **Step 1: Write the failing tests**

```swift
func testOverdueFirst()               // overdue reminder 09:00, event 15:44, reminder 17:00 at 14:59 → times ["Overdue","3:44 PM","5:00 PM"]
func testEventWithinHourSaysMinutes() // event 15:44 at 14:59 → note "in 45 m"; event 14:30–15:30 → "now"
func testDropsPastAllDayAndUndated()
func testLimitThree()                 // 6 items → 3 rows
func testReminderNote()               // note == "reminder"
// LiveChipsTests
func testOrderFocusTimersShelf()      // focus, timers ending in 5 m and 2 m, shelf 3 → texts ["Focus 18:42","Timer 2:00","Tea timer 5:00","Shelf · 3"]
func testOverflowAfterFour()          // focus + 4 timers + shelf → shown.count == 4, overflow == 2
func testPausedTimerNotShown()
func testNothingLiveIsEmpty()         // (shown: [], overflow: 0)
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotchKitTests.(UpNextTests|LiveChipsTests)'` → FAIL.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4: Run to verify they pass** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): Up next (calendar and reminders merged) and live chips"`

### Task 9: Settings › Home, water off for new users, migration

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Home/HomeSettings.swift`
- Modify: `Sources/PlatyNotchKit/Wellbeing/NudgeScheduler.swift:13-50` (`NudgeSettings`), `Sources/PlatyNotchKit/Setup/FirstRun.swift` (add `QuietNotchMigration`; drop the glance part of `UpgradeMigration`)
- Create: `Sources/PlatyNotchUI/Settings/HomeSection.swift`; Delete `Sources/PlatyNotchUI/Settings/NowSection.swift`
- Modify: `Sources/PlatyNotchUI/Settings/SettingsWindow.swift`, `Sources/PlatyNotchUI/NotchApp.swift` (runs the migration beside `UpgradeMigration.run`)
- Test: Create `Tests/PlatyNotchKitTests/HomeSettingsTests.swift`, `Tests/PlatyNotchKitTests/QuietNotchMigrationTests.swift`; Modify `Tests/PlatyNotchKitTests/WellbeingTests.swift`, `Tests/PlatyNotchUITests/NowNotificationsSettingsTests.swift`

**Interfaces:**
- Produces:
  - `public struct HomeSettings: Codable, Equatable, Sendable { public enum RightColumn: String, Codable, CaseIterable, Sendable { case upNext, notes, mail }; public static let key = "home.settings"; public var rightColumn: RightColumn; public init(rightColumn: RightColumn = .upNext); public static func load(from: UserDefaults) -> HomeSettings; public func save(to: UserDefaults); public func effectiveColumn(notesOn: Bool, mailOn: Bool) -> RightColumn }`
  - `NudgeSettings.init(water: Int = 0, …)`; `public static let legacyWaterMinutes = 60`; a saved value missing `water` decodes as 60.
  - `public enum QuietNotchMigration { public static let key = "ui.quietNotch.migrated"; public static func run(defaults: UserDefaults, existingUser: Bool) }` — existing user without `wellbeing.settings` → saves `NudgeSettings(water: 60)`; never touches a saved value; once only; nothing for a new install.
  - `HomeSection.options(notesOn: Bool, mailOn: Bool) -> [(column: HomeSettings.RightColumn, enabled: Bool)]`

- [ ] **Step 1: Write the failing tests**

```swift
// HomeSettingsTests (DefaultsTestCase)
func testDefaultIsUpNext()
func testRoundTrip()                         // .mail saved → load == .mail
func testFallsBackWhenWidgetOff()            // HomeSettings(rightColumn: .notes).effectiveColumn(notesOn: false, mailOn: true) == .upNext
func testDamagedValueLoadsDefault()
// QuietNotchMigrationTests (DefaultsTestCase)
func testNewUserWaterOff()                   // NudgeSettings().water == 0; run(existingUser: false) writes nothing
func testExistingUserKeepsSixty()            // no saved settings, run(existingUser: true) → saved water == 60
func testSavedChoiceNeverChanged()           // saved water 30 → still 30
func testRunsOnce()                          // second run after deleting wellbeing.settings writes nothing
func testSavedWithoutWaterKeyKeepsSixty()    // {"stand":50} decodes water == 60
// NowNotificationsSettingsTests
func testHomeOptionsDisableOffWidgets()      // HomeSection.options(notesOn: false, mailOn: true) == [(.upNext, true), (.notes, false), (.mail, true)]
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotch(Kit|UI)Tests.(HomeSettingsTests|QuietNotchMigrationTests|NowNotificationsSettingsTests)'` → FAIL.
- [ ] **Step 3: Implement.** `NowSettings`, `GlanceSlots` and their keys stay in defaults unread; their types go in Task 10. Settings › Wellbeing shows water 0 as "Off".
- [ ] **Step 4: Run to verify they pass** — filter, whole suite → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): Settings › Home right column; water off for new users, kept for existing ones"`

### Task 10: Home view, chips and shelf on drag

**Files:**
- Create: `Sources/PlatyNotchUI/Home/HomeView.swift`, `Home/MediaBlock.swift`, `Home/UpNextColumn.swift`, `Home/ChipsRow.swift`, `Home/DropTargetsView.swift`, `Home/PanelHeader.swift`
- Modify: `Sources/PlatyNotchKit/PanelLayout.swift` (expanded width and height), `Sources/PlatyNotchUI/Widgets/WidgetRegistry.swift` (glance defaults go), `Sources/PlatyNotchUI/Views/ExpandedPanel.swift`, `Sources/PlatyNotchUI/PanelRootView.swift`, `Sources/PlatyNotchUI/NotchController.swift` (applies the reported height), `Sources/PlatyNotchUI/Shelf/ShelfDropView.swift` (AirDrop target), `Sources/PlatyNotchUI/Smoke/ThemeRenders.swift` (`NowRenders` → `HomeRenders`)
- Delete: `Sources/PlatyNotchUI/Now/{NowView,GenericHero,AgentsHero,HeroFrame,GlanceChip,GlanceRow,QuietLineView,TodaySummaryHero}.swift`, `Sources/PlatyNotchKit/Now/{HeroDeck,HeroPrimary,GlanceSlots,NowModel,NowSettings}.swift`
- Test: Create `Tests/PlatyNotchUITests/HomeViewTests.swift`; Modify `Tests/PlatyNotchKitTests/PanelLayoutTests.swift`; Delete `Tests/PlatyNotchUITests/{NowViewTests,HeroViewsTests}.swift`, `Tests/PlatyNotchKitTests/{NowModelTests,HeroPrimaryTests,NowSettingsTests}.swift` (move `testAgentActivityRecordsFinishAndFailure`, `testWakeExpiresAtOnce`, `testAgentActivityRerankOnClockChange` into `HomeViewTests`)

**Interfaces:**
- Consumes: `HeaderDate`, `HeaderBattery`, `HeaderToggles` (Task 4), `UpNext`, `LiveChips` (Task 8), `HomeSettings` (Task 9), `PanelRoute` (Task 6).
- Produces:
  - `PanelLayout.expandedWidth: CGFloat = 600`, `PanelLayout.expandedHeights: ClosedRange<CGFloat> = 160...380`, `var expandedContentHeight: CGFloat` (clamped on set); `contentRect(for: .expanded)` and `hitRect(for: .expanded)` use it.
  - `struct HomeView: View` with `static func texts(...) -> [String]` (tests) and a `HomeHeightKey: PreferenceKey` the controller reads.
  - `struct DropTargetsView: View { static func titles(shelfOn: Bool, airDrop: Bool) -> [String] }` — `["Drop to keep on Shelf", "AirDrop"]`.
  - Chip taps route: focus → `FocusWidget.widgetID`, timer → `TimeWidget.widgetID`, shelf → `ShelfWidget.widgetID`.
  - The first run's "Try it" sample shows as a chip; the existing-user tour card is not drawn (the tour stays in Settings › General) **[spec call]**.

- [ ] **Step 1: Write the failing tests**

```swift
// PanelLayoutTests
func testExpandedIsSixHundredWide()     // layout.contentRect(for: .expanded).width == 600
func testExpandedHeightIsClamped()      // set 90 → 160; 500 → 380; hitRect height follows
// HomeViewTests (DefaultsTestCase; fit measured with NSHostingView.fittingSize, never fixed heights)
func testHomeFitsWithEverythingLive()   // music, 3 up-next rows, 4 chips + overflow: fitting height <= 380 - layout inset
func testNothingPlayingShowsPlaty()     // texts contains "Nothing playing"
func testChipsRowHiddenWhenEmpty()
func testRightColumnFollowsSetting()    // .notes with Notes on → column id "notes"; Notes turned off → "upNext"
func testDragShowsDropTargets()         // mode .peek(.drop): texts contains "Drop to keep on Shelf", "AirDrop"
func testShelfOffDropShowsAirDropOnly()
func testLongTitlesTruncate()           // 200-char track, event and timer label: fitting width <= 600, lineLimit 1
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotch(Kit|UI)Tests.(PanelLayoutTests|HomeViewTests)'` → FAIL.
- [ ] **Step 3: Implement.** Header: Platy (`PlatyView` 20 × 15), switcher, date/weather or battery text, `HeaderToggles`. Media block from `NowPlaying`; Up next from `CalendarService` + `RemindersService` (read only when their widget is on; no prompts). Drop on "AirDrop" calls `ShelfActions.airDrop(_:)` with the dropped file URLs. Renders: drop `now-summary`, `now-live-generic`, `now-approvals-line`, `hero-music`, `hero-timer`, `hero-meeting`, `hero-agents`, `now-tour-card`, `now-try-it-sample`; add `home-rest`, `home-live`, `home-nothing-playing`, `home-drop`, `home-notes-column`.
- [ ] **Step 4: Run to verify they pass** — filter, whole suite → PASS. Smoke `renders=` is N₀ − 14.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): Home — media, Up next, live chips and drop targets in a 600 pt panel"`

### Task 11: Command line in the panel

**Files:**
- Create: `Sources/PlatyNotchUI/Home/CommandLineView.swift`, `Sources/PlatyNotchUI/Home/CommandRunner.swift`
- Modify: `Sources/PlatyNotchUI/PanelRootView.swift` (`PanelViewModel.commandText`, `commandFocused`), `Sources/PlatyNotchUI/NotchPanel.swift` (⌘K and printable keys), `Sources/PlatyNotchUI/NotchController.swift`, `Sources/PlatyNotchUI/Day/RemindersWidget.swift:121-140` (extract `add`), `Sources/PlatyNotchUI/Notes/NotesWidget.swift:470` (extract `appendNote`), `Sources/PlatyNotchUI/Home/HomeView.swift`, `Sources/PlatyNotchUI/Smoke/ThemeRenders.swift` (`home-command`)
- Test: Create `Tests/PlatyNotchUITests/CommandLineTests.swift`

**Interfaces:**
- Consumes: `CommandParser`, `PanelCommand`, `CommandSuggestion` (Task 7); `PanelRoute` (Task 6).
- Produces:
  - `struct CommandActions { var startTimer: (TimeInterval, String?) -> Bool; var startFocus: (Int) -> Void; var remind: (QuickAdd) -> String?; var note: (String) -> String?; var search: (String) -> Void; var open: (PanelRoute) -> Void; var selectGame: (GameKind) -> Void }` — a String return is the row's message (nil: done).
  - `@MainActor final class CommandRunner { init(actions: CommandActions); func run(_ s: CommandSuggestion) -> String? }` — `play` opens `PanelRoute(destination: .home, tool: GamesWidget.widgetID)` (or `PanelTools.chase`); `search` sets `MemoryServices.search.query`, listing up to 5 hits, ↩ opens `PanelTools.memory`.
  - `NotchController.commandK() -> Bool` (expanded and key only) and `NotchController.typed(_ s: String) -> Bool` (expanded, key, no text field focused, printable, no ⌘/⌃).
  - `RemindersWidget.add(_ q: QuickAdd) -> String?`, `NotesWidget.appendNote(_ text: String) -> String?`.

- [ ] **Step 1: Write the failing tests** (spy `CommandActions`)

```swift
func testCommandKFocusesCommandLine()   // expanded+key: commandK() == true, model.commandFocused; compact: false
func testTypingStartsCommandLine()      // typed("t") → model.commandText == "t"; with ⌘ held → false
func testReturnRunsTopSuggestion()      // "timer 10m tea" ↩ → spy.timers == [(600, "tea")]
func testNothingRunsWithoutReturn()     // typing "focus" only → spy.focus == []
func testRemindPassesQuickAdd()         // "remind call Priya at 5pm" ↩ → spy.reminded.first?.title == "Call Priya"
func testNoteWhenNotesOffSaysWhy()      // notes off → message "Turn on Notes in Settings"
func testPlayChaseOpensChase()          // → spy.routes == [PanelRoute(destination: .home, tool: PanelTools.chase)]
func testEscClearsThenLeaves()          // Esc with text → text ""; Esc again → commandFocused false; panel still open
func testCommandLineNeverAnswersApprovals() // approval pending, text "timer 5m": Return → no decision, no timer; ⌘↩ → allow recorded, no timer
```

- [ ] **Step 2: Run to verify they fail** — `--filter PlatyNotchUITests.CommandLineTests` → FAIL.
- [ ] **Step 3: Implement.** ⌘K goes through `NotchPanel.performKeyEquivalent` beside `commandDigit`; Return in the command line is handled by the text field only, never by `ApprovalResponder`.
- [ ] **Step 4: Run to verify they pass** — filter, whole suite (including `ApprovalSafetyTests`) → PASS. Smoke `renders=` is N₀ − 12.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): command line (⌘K or type) runs timer, focus, remind, note, search and play"`

### Task 12: Games to the menu bar; pond and moments out

**Files:**
- Modify: `Sources/PlatyNotchUI/MenuBar.swift`, `Sources/PlatyNotchUI/NotchApp.swift` (menu wiring, smoke check), `Sources/PlatyNotchUI/Games/GamesWidget.swift`, `Sources/PlatyNotchUI/Games/GameHost.swift`, `Sources/PlatyNotchKit/Games/{GameSession,HighScores}.swift`, `Sources/PlatyNotchKit/Mascot/{PlatyMood,PlatyPoseValues}.swift`, `Sources/PlatyNotchUI/Mascot/PlatyMoodModel.swift`, `Sources/PlatyNotchUI/Now/{TodayServices,AgentActivityModel}.swift`, `Sources/PlatyNotchUI/Widgets/BuiltIn/LoopsWidget.swift`, `Sources/PlatyNotchUI/Onboarding/OnboardingWindow.swift`, `Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Delete: `Sources/PlatyNotchKit/Mascot/{PondScene,Moments}.swift`, `Sources/PlatyNotchKit/Now/DayPhase.swift`, `Sources/PlatyNotchUI/Now/PondSceneView.swift`
- Test: Modify `Tests/PlatyNotchUITests/MenuBarTests.swift`, `Tests/PlatyNotchKitTests/PlatyMoodTests.swift`, `Tests/PlatyNotchUITests/{PlatyTests,GamesWidgetTests,OnboardingFlowTests,PlipPlayerTests}.swift`; Delete `Tests/PlatyNotchKitTests/{MomentsTests,PondSceneTests}.swift`, `Tests/PlatyNotchUITests/PondSceneViewTests.swift`

**Interfaces:**
- Produces:
  - `MenuBar.init(…, games: GamesWidget? = nil, onOpenGame: @escaping (GameKind) -> Void = { _ in })`; a "Games" item whose submenu lists `GameKind.allCases.map(\.title)`; `static func gamesItemHidden(gamesOn: Bool) -> Bool`.
  - `PlatyMood` loses `.celebrating`; `PlatyMoodResolver.resolve(…)` loses `celebrating:`; `PlatyMoodModel.celebrate()` removed; `GamesWidget.onNewBest` removed (high scores stay).
  - The smoke run fails with `"menu bar games item missing"` when Games is on and `menuTitles` lacks "Games".

- [ ] **Step 1: Write the failing tests**

```swift
func testGamesItemListsEveryGame()    // submenu titles == ["Snake","Tetris","2048","Flappy","Platy Chase"]
func testGamesItemHiddenWhileGamesOff()
func testChoosingAGameOpensIt()       // spy onOpenGame receives .chase for "Platy Chase"
func testNoCelebratingMood()          // XCTAssertFalse(PlatyMood.allCases.map(\.rawValue).contains("celebrating"))
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotch(Kit|UI)Tests.(MenuBarTests|PlatyMoodTests)'` → FAIL.
- [ ] **Step 3: Implement.** Choosing a game calls `games.host.select(kind)` then `controller.expand(tab: GamesWidget.tabID)`. Renders: drop `now-pond-morning`, `now-pond-evening`, `now-pond-night`.
- [ ] **Step 4: Run to verify they pass** — filter, whole suite → PASS. Smoke `renders=` is N₀ − 18.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): Games in the menu bar; remove the pond scene and celebrations"`

### Task 13: Phase 2 check

**Files:**
- Modify: `scripts/verify-widgets.md` (section "Quiet Notch phase 2": ⌘1/⌘2, ⌘3 unused; command line each command; chips appear and go; drag a file → Shelf / AirDrop; Games menu; old `platynotch://settings/now` opens Home; an upgraded profile keeps water at 60 and every widget on)

- [ ] **Step 1:** Whole suite → 0 failures; approval suites unchanged (Task 5 Step 2 diff command prints nothing).
- [ ] **Step 2:** The smoke runs → `SMOKE OK … games=5 renders=170 theme=dark` (N₀ − 18), `SMOKE SETTINGS OK sections=<P> …` (same P as Task 5), `SMOKE-POWER OK widgets=6`.
- [ ] **Step 3:** `grep -rn "LibraryView\|PondScene\|MomentGate" "$WT/apps/mac/Sources"` → nothing.
- [ ] **Step 4: Commit** — `git commit -m "docs: Quiet Notch phase 2 hardware checks"`

---

## Phase 3: Visual pass

### Task 14: Black panel, tokens, type scale, one spring

**Files:**
- Modify: `Sources/PlatyNotchKit/Design/DesignTokens.swift`, `Sources/PlatyNotchKit/Appearance/{PanelPalette,AppearanceSettings}.swift`, `Sources/PlatyNotchKit/Design/MotionPreset.swift`, `Sources/PlatyNotchUI/Design/Tokens.swift`, `Sources/PlatyNotchUI/Views/Theme.swift`, `Sources/PlatyNotchUI/PanelRootView.swift` (`.environment(\.colorScheme, .dark)`), `Sources/PlatyNotchUI/Settings/NotchSection.swift` (Theme and Glass rows go), `Sources/PlatyNotchUI/Smoke/ThemeRenders.swift` (panel views dark only), `Sources/PlatyNotchUI/NotchApp.swift` (smoke drops ` theme=`), every `PlatyNotchUI` call site of removed tokens
- Delete: `Sources/PlatyNotchUI/Design/CardStyle.swift`
- Test: Modify `Tests/PlatyNotchKitTests/{DesignTokensTests,AppearanceTests,MotionPresetTests,PanelSurfaceStyleTests}.swift`, `Tests/PlatyNotchUITests/AppearanceControllerTests.swift`; Create `Tests/PlatyNotchUITests/ThemeRendersTests.swift`

**Interfaces:**
- Produces:
  - `PanelPalette.panel = RGB(hex: 0x000000)`, `.approvalCard = RGB(hex: 0x111111)`; `public enum Ink { static let primary = 0.92, secondary = 0.56, tertiary = 0.32, hairline = 0.10, fill = 0.07 }` (white alphas, `Double`).
  - `StateTone.rgb: RGB` (one value): working `0x32D74B`, needsYou `0xFFB340`, error `0xFF6961`, done = white at `Ink.secondary`, idle = white at `Ink.tertiary` (done and idle via `StateTone.alpha: Double`). `rgb(dark:)` removed.
  - `TypeScale`: `title` 13 semibold, `body` 13, `secondary` 12, `caption` 11, `mono` 12 mono, `glyph` 15 semibold (the play/pause symbol); `maximum: CGFloat = 15`, `minimum: CGFloat = 11`; `display`, `headline` removed.
  - `Radius`: `keycap 4`, `small 6`, `medium 8`, `card 12`, `panelBottom 22`; `hero` removed. `Space`: `panelTop 30`, `panelSide 18`, `panelBottom 16`, `header 14`, `columnGap 22`. `IconSize`: `symbol 14`, `header 16`.
  - `Brand.teal` and `Brand.pond` removed (`Brand.cream` stays for Platy).
  - `AppearanceSettings` drops `theme` and `surface` (old keys decode and are ignored); `MotionPreset` is `calm, reduced`; `"lively"` decodes as `.calm`; `.calm` opens and closes with `SpringSpec(response: 0.35, damping: 1.0)`.

- [ ] **Step 1: Write the failing tests**

```swift
func testTokenGoldenTable()            // every value above, exactly
func testTypeNeverAboveFifteen()       // TypeScale.all.allSatisfy { $0.size <= 15 && $0.size >= 11 }
func testOldThemeAndGlassStillDecode() // {"theme":"light","surface":"glass","motion":"lively","pillWidth":"wide"} → pillWidth .wide, motion .calm
func testOneSpringForOpenAndClose()    // MotionPreset.calm.spring(.open) == MotionPreset.calm.spring(.close) == SpringSpec(response: 0.35, damping: 1.0)
func testPanelRendersAreDarkOnly()     // ThemeRenders.write(to: tmp, only: ["pill-platy-idle"]) writes exactly ["pill-platy-idle-dark.png"]
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotch(Kit|UI)Tests.(DesignTokensTests|AppearanceTests|MotionPresetTests|ThemeRendersTests)'` → FAIL.
- [ ] **Step 3: Implement**, then repoint call sites; controls tint white (`.tint(.white)`), no accent.
- [ ] **Step 4: Run to verify they pass** — filter, whole suite → PASS. Smoke now prints `renders=<V + 2·S>` with V = `ThemeRenders` views (66) and S = settings windows (19): `renders=104`, no ` theme=`.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): always-black panel, white ink at 92/56/32, 11–15 pt type, one spring; teal and light panel go"`

### Task 15: Agents rows, usage line, v0.2 approval card

**Files:**
- Create: `Sources/PlatyNotchKit/Agents/UsageLine.swift`
- Modify: `Sources/PlatyNotchKit/Agents/AgentBrand.swift` (no monogram), `Sources/PlatyNotchUI/Agents/{AgentBadge,AgentRow,AgentsView}.swift`, `Sources/PlatyNotchUI/Views/ApprovalCard.swift` (layout only), `Sources/PlatyNotchUI/Home/PanelHeader.swift` (usage text on Agents)
- Delete: `Sources/PlatyNotchUI/Agents/UsageRings.swift`
- Test: Create `Tests/PlatyNotchKitTests/UsageLineTests.swift`, `Tests/PlatyNotchUITests/ApprovalCardStyleTests.swift`; Modify `Tests/PlatyNotchKitTests/AgentBrandTests.swift`, `Tests/PlatyNotchUITests/{AgentsViewTests,ApprovalCardBadgeTests}.swift`

**Interfaces:**
- Consumes: `TerminalFocus.title(for:)` (Task 3), tokens (Task 14).
- Produces:
  - `public enum UsageLine { public static func parts(_ u: Usage) -> [String] }` → `["Claude 5h 62% · 7d 31%", "Codex 5h 18%"]`, percents rounded, missing windows and agents left out.
  - `public enum AgentsFooter { public static func text(openLoops: Int) -> String? }` → `"2 open loops · Search memory with ⌘K"`, `"1 open loop · …"`, nil at 0.
  - `AgentBrand.displayName: String`; `monogram` and `letters` removed.
  - `AgentBadge` draws the installed app icon at 16 pt with no background, else `Text(brand.displayName)`; state is the 7 pt dot plus its word for VoiceOver.
  - `AgentRow` columns 18 / flexible / auto / auto: project (13 semibold), `" · \(status) · \(age)"` (12 secondary), dot, button (`TerminalFocus.title`). The mono last-action line goes.
  - `ApprovalCard` header: icon or name, agent name semibold, project, tool chip, countdown mono; one mono command line (diff box unchanged); right-aligned `Deny ⌘⌫` and `Allow ⌘↩` keycaps; `static let keycaps = ["⌘⌫", "⌘↩"]`. Arming, order and sanitising untouched.

- [ ] **Step 1: Write the failing tests**

```swift
func testClaudeBothWindows()            // fiveHour 62.4, weekly 31 → "Claude 5h 62% · 7d 31%"
func testCodexFiveHourOnly()            // "Codex 5h 18%"; nil usage → []
func testFooterPlural()                 // 2 → "2 open loops · Search memory with ⌘K"; 0 → nil
func testNoMonogram()                   // AgentBrand(agent: "aider", agentName: "Aider").displayName == "Aider"
func testMissingAppShowsAgentName()     // AgentsViewTests (replaces testMissingAppFallsBackToMonogram)
func testLongProjectTruncates()         // 200-char project: row fitting width <= 600 - 2 * Space.panelSide
func testKeycapsShown()                 // ApprovalCard.keycaps == ["⌘⌫", "⌘↩"]
func testCommandIsOneMonoLine()         // bash approval: command text lineLimit 1, font mono 12
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotch(Kit|UI)Tests.(UsageLineTests|AgentBrandTests|AgentsViewTests|ApprovalCardStyleTests|ApprovalCardBadgeTests)'` → FAIL.
- [ ] **Step 3: Implement.** `ApprovalCardBadgeTests` keeps measuring heights at run time against a reference button.
- [ ] **Step 4: Run to verify they pass** — filter, whole suite (approval suites untouched) → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(mac): dense Agents rows, usage as numbers, v0.2 approval card with keycaps"`

### Task 16: Design lint and showcase renders

**Files:**
- Modify: `Tests/PlatyNotchUITests/DesignLintTests.swift`, `Tests/PlatyNotchUITests/ShowcaseRendersTests.swift`, `Sources/PlatyNotchUI/Smoke/ShowcaseRenders.swift`
- Replace: `docs/assets/showcase/*.png` (old ten removed with `git rm`), `README.md:4` (`agents-dark.png`)
- Modify: `scripts/verify-widgets.md` (showcase section: new scene list)

**Interfaces:**
- Produces: `ShowcaseRenders.scenes == ["home-music", "home-live", "agents", "approval", "command-line"]`, still dark and light backdrops (the panel is black in both), 1600 × 900 px each.

- [ ] **Step 1: Write the failing lint tests** (comment lines skipped; each lists `file:line`; allowlist entries need a reason)

```swift
func testNoTeal()                    // no /\bteal\b/i in Sources/PlatyNotchUI
func testNoFontAboveFifteen()        // literal .system(size: N) with N > 15 outside Settings/, Onboarding/, Games/Views/ (game boards)
func testNoTintedIconSquares()       // no RoundedRectangle…fill((DS|Theme).(dynamicColor|color|tint)(…).opacity(…)) on a line with or after Image(systemName:
func testNoLightPanelScheme()        // no "colorScheme, .light" / "ColorScheme.light" outside Settings/, Onboarding/, Smoke/SettingsRenders.swift
func testNoMonogram()                // no "monogram" identifier in Sources
func testNoBorderedCardsInPanel()    // no .stroke( / .strokeBorder( in Home/, Agents/, Views/ except DropTargetsView.swift (dashed box) and the keycap view
func testTileContainersUseRadiusScale() // updated: radii ∈ [4, 6, 8, 12, 22]
// ShowcaseRendersTests.testShowcaseWritesTen: add XCTAssertEqual(ShowcaseRenders.scenes, ["home-music","home-live","agents","approval","command-line"])
```

- [ ] **Step 2: Run to verify they fail** — `--filter 'PlatyNotchUITests.(DesignLintTests|ShowcaseRendersTests)'` → FAIL on the offenders and the scene list.
- [ ] **Step 3: Fix every offender** the lints list; build the five scenes.
- [ ] **Step 4: Regenerate** — `cd "$WT/apps/mac" && swift build --scratch-path /private/tmp/claude-501/pn-build-shared && PLATYNOTCH_HOME=$(mktemp -d) /private/tmp/claude-501/pn-build-shared/debug/PlatyNotch --render-showcase ../../docs/assets/showcase` → `SHOWCASE OK renders=10`; `sips -g pixelWidth -g pixelHeight ../../docs/assets/showcase/agents-dark.png` → 1600 × 900. Then the filter → PASS.
- [ ] **Step 5: Commit** — `git commit -m "test(mac): lint the Quiet Notch rules; regenerate the showcase"`

### Task 17: Phase 3 check

**Files:**
- Modify: `scripts/verify-widgets.md` (section "Quiet Notch phase 3": panel black in light mode, nothing above 15 pt, Agents rows match wireframe C, approval keycaps, no icon squares, perf-idle)

- [ ] **Step 1:** Whole suite → 0 failures; approval suites unchanged (Task 5 Step 2 diff).
- [ ] **Step 2:** The smoke runs → `SMOKE OK … games=5 renders=104` (no `theme=`), `SMOKE SETTINGS OK sections=<P> …`, `SMOKE-POWER OK widgets=6`.
- [ ] **Step 3:** `scripts/perf-idle.sh` on a real Mac → PASS under 1 %. `grep -rn "isolated deinit" "$WT/apps/mac/Sources"` → nothing.
- [ ] **Step 4: Commit** — `git commit -m "docs: Quiet Notch phase 3 hardware checks"`

---

## Self-review

- **Spec coverage:** §1 decisions → Tasks 10, 12, 14, 9. §2.1 header → 4, 10, 15. §2.2 Home, chips, shelf on drag → 8, 10. §2.3 Agents → 3, 15. §2.4 features inside the panel → 6, 11. §3 command line → 7, 11. §4 open fix → 1, 2, 3. §5 tokens, type, colour, icons, approval card → 14, 15, 16. §6 mapping → 4, 6, 8–12. §7 migration → 6, 9, 14. §8 removals → 6, 10, 12, 14, 15. §9 constraints → Global Constraints, 5, 13, 17.
- **Types:** `OpenAction`/`OpenTarget`/`OpenResolver` (2) used by 3 and 15; `PanelDestination.home`, `PanelRoute(destination:tool:)`, `PanelTools` (6) used by 10–12; `PanelCommand`, `CommandSuggestion`, `CommandTool` (7) used by 11; `UpNext`, `LiveChips` (8) and `HomeSettings` (9) used by 10; `HeaderBattery`, `KeepAwakeLabel`, `HeaderDate`, `HeaderServices`, `HeaderToggles` (4) used by 10; tokens (14) used by 15, 16.
- **Renders:** N₀ = 188. Task 6 removes 3 names (−6), Task 10 removes 9 and adds 5 (−8), Task 11 adds 1 (+2), Task 12 removes 3 (−6): 170 at Task 13 from 66 views and 19 settings windows. Task 14 renders panel views dark only: 66 + 2 × 19 = 104.
