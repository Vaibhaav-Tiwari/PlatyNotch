# PlatyNotch UI/UX redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Present every existing feature through three destinations (Now, Agents, Library), one priority model, one visual system and Platy as the status signal, without adding features or touching the core, protocol or approval semantics.

**Architecture:** Every decision that can be pure lives in `PlatyNotchKit` with unit tests: tokens, motion presets, live ranks, the Now model (hero deck, glance slots, quiet line), pill content, agent ordering, approval previews, Library order and routes, notification policy, presets, first-run state, pond phases, moments and the plip rule. `PlatyNotchUI` turns those into SwiftUI/AppKit views behind thin seams, checked by fit tests, render PNGs (`PLATYNOTCH_RENDER_DIR`) and the three smoke runs. The public widget and plugin API only gains members that have defaults.

**Tech Stack:** Swift 6, SwiftPM (`apps/mac`, macOS 15+), SwiftUI, AppKit, Core Animation, XCTest; Python (`scripts/make-sounds.py`) for the one new sound.

**Spec:** `docs/specs/2026-10-25-ui-redesign-design.md` (every section and every **[call]** is binding)

## Global Constraints

- Paths contain spaces. Every command starts from `WT="/Users/vaibhaav/Library/Application Support/Claude/scratch-workspaces/c03a99fb-b5e4-421a-a233-4b0358662113/25bab691-d493-4cd2-a69e-34dd9bd79c2d/scratch-2026-10-23-104f70/platynotch/.worktrees/ui-design"`, always quoted (`cd "$WT/apps/mac"`). Tasks run one at a time in this one worktree on branch `docs/ui-redesign`.
- Idle CPU under 1% collapsed (`scripts/perf-idle.sh`). Continuous animation only as Core Animation layers; SwiftUI timelines tick only while `\.panelTicking` is true. No animation over 2 seconds; no repeating animation while collapsed and idle, except the budgeted agent dots and Platy pill frames while live.
- No `isolated deinit` (CI greps for it); use a plain `deinit`.
- Completion-handler APIs go through an explicit `withCheckedContinuation` (CI greps for the generated async forms).
- CI type-checks with `-warn-long-expression-type-checking=300`: typed literals and typed locals, never mix `Double` and `CGFloat` in one expression. Geometry tokens are `CGFloat`; times and colour components are `Double`.
- New test classes subclass `DefaultsTestCase` (Kit: `Tests/PlatyNotchKitTests/DefaultsTestCase.swift`, UI: `Tests/PlatyNotchUITests/DefaultsTestCase.swift`) and get storage from `defaults()`. UI logic sits behind seams (Kit functions or injected closures), never behind a live window.
- Approval safety unchanged: `ApprovalArming.delay` 0.7 s, an approval never moves under the cursor, never hidden, Return never answers, hidden characters stay visible (`SummarySanitizer`), approvals win over every other surface. `ApprovalSafetyTests` and `ApprovalArmingControllerTests` pass unchanged after every task.
- Every Kit type is `public` with a `public init` (structs) and is `Sendable`.
- `NotchWidget`, `NotchPlugin`, `WidgetContext`, `PanelTab`, `LiveActivity` change only additively: new members carry defaults, new init parameters carry default values (spec 6.9). `PluginAPITests` keeps passing unchanged.
- Fixed geometry from `PanelLayout`: expanded 560×380, peek 420×236. Hero, glances and nav fit 560×380 minus the notch inset with no scrolling.
- Text: nothing below 11 pt anywhere in `PlatyNotchUI`; `.caption`, `.caption2` and `.footnote` are 10 pt on macOS and count as below 11.
- Colour is never the only carrier of meaning: every state colour comes with an SF Symbol or a word. Light and dark themes, Reduce Motion and VoiceOver labels on every new control.
- Privacy: nothing runs until enabled or clicked (album art, calendar, mail previews included).
- Smoke recipe (referred to below as "the smoke recipe"), from `apps/mac`:
  ```sh
  (cd ../../core && go build -o /tmp/pn-notch ./cmd/notch)
  H=$(mktemp -d); S=$(mktemp -d /tmp/pn.XXXX)
  export PLATYNOTCH_CORE_BIN=/tmp/pn-notch PLATYNOTCH_HOME="$H" PLATYNOTCH_SOCKET="$S/n.sock"
  swift build
  PLATYNOTCH_RENDER_DIR=/tmp/pn-renders .build/debug/PlatyNotch --smoke
  .build/debug/PlatyNotch --smoke-settings
  .build/debug/PlatyNotch --smoke-power
  rm -rf "$H" "$S"
  ```
  Expected today: `SMOKE OK … renders=24`, `SMOKE SETTINGS OK sections=8 onboarding=3`, `SMOKE-POWER OK widgets=6`. Each task that adds renders states the new `renders=` total (two PNGs, dark and light, per view).
- Tests: `cd "$WT/apps/mac" && swift test --filter <Target>.<Class>`; before each commit also `swift test` (whole suite) passes.
- Commit step: from `"$WT"`, `git add` exactly the paths in the task's **Files** block (plus generated renders only when the task names them), then `git commit -m "<the message given>"`.

## Review Focus

- Long titles everywhere (a 200-character project name, track title or event title) → hero, glance chips, Agents rows and the pill truncate with an ellipsis; ‹ ›, "2 of 3" and the primary control never leave the frame; Now still does not scroll (Task 9 `testHeroFitsWithLongTitle`, Task 12 `testTrailingNeverWiderThanEar`).
- A chosen glance whose widget is turned off, loses its data or whose plugin is not loaded → its chip disappears without leaving a gap or a ghost; turning it back on returns it to the same slot (Task 6 `testUnavailableGlanceKeepsItsSlot`).
- Sleep, clock changes and time-zone changes across the 10-minute windows (music paused, agent finished, failed) → after wake the expired item is gone at once, never shown with a negative or stale time (Task 5 `testWindowsExpireAcrossSleep`).
- Many sessions at once (12 sessions over four agents, one needing input) → the pill shows Platy, three dots and "+9" inside the ear; the Agents list puts the needs-you row first; Now shows one Agents hero (Task 11 `testTwelveSessions`, Task 16 `testTwelveSessionsNeedsYouFirst`).
- A plugin publishing a `LiveActivity` with an out-of-range priority (1000, −5) → it ranks in the nearest band, can never outrank an approval and never auto-opens the notch by itself (Task 5 `testPluginPriorityIsClamped`).

---

## Phase 1: Foundation

### Task 1: Design tokens in Kit

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Design/DesignTokens.swift`, `apps/mac/Sources/PlatyNotchKit/Design/AgentIdentity.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Appearance/PanelPalette.swift` (add `panelDark`)
- Test: `apps/mac/Tests/PlatyNotchKitTests/DesignTokensTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct TypeStyle: Equatable, Sendable { public enum Weight: Sendable { case regular, medium, semibold }
      public let size: CGFloat; public let weight: Weight; public let rounded: Bool; public let mono: Bool; public init(size:weight:rounded:mono:) }
  public enum TypeScale { public static let display, title, headline, body, caption, mono: TypeStyle; public static let all: [TypeStyle]; public static let minimum: CGFloat /* 11 */ }
  public enum Space { public static let xs, s, m, l, xl, xxl: CGFloat /* 4 8 12 16 24 32 */; public static let scale: [CGFloat]; public static let panelMargin: CGFloat /* 16 */; public static let heroPadding: CGFloat /* 20 */ }
  public enum Radius { public static let chip, card, hero: CGFloat /* 6 12 20 */; public static let scale: [CGFloat]; public static func inner(outer: CGFloat, padding: CGFloat) -> CGFloat /* max(0, outer − padding) */ }
  public enum IconSize { public static let row, tile, hero: CGFloat /* 15 20 28 */ }
  public enum Elevation: CaseIterable, Sendable { case surface, card }
  public enum Brand { public static let teal, cream, pond: RGB /* 0x2FB8A6 0xF2E6C9 0x1C3B4A */ }
  public enum StateTone: String, CaseIterable, Sendable { case working, needsYou, error, done, idle
      public func rgb(dark: Bool) -> RGB; public var symbol: String; public var word: String }
  public enum AgentIdentity: String, CaseIterable, Sendable { case claude, codex, cursor, gemini, other
      public init(agentID: String); public func rgb(dark: Bool) -> RGB }
  extension PanelPalette { public static let panelDark: RGB /* 0x0B0D0D */; public static let pill: RGB /* 0x000000 */; public static let keylineAlpha: Double /* 0.08 */ }
  ```
- Values (dark / light): working `0x2FB8A6`/`0x0B6B5F`, needsYou `0xF5A524`/`0x845000`, error `0xF2685B`/`0xA3352B`, done `0x4CC38A`/`0x17693F`, idle `0x9AA0A6`/`0x585D62`; agents claude `0xE8833A`/`0x904410`, codex `0x3DBE7A`/`0x17693F`, cursor `0x5B9BF8`/`0x1F5BB8`, gemini `0xA987F5`/`0x6A3FC4`, other = working. Symbols/words: working `arrow.triangle.2.circlepath` "Working", needsYou `hand.raised.fill` "Needs you", error `exclamationmark.triangle.fill` "Error", done `checkmark.circle.fill` "Done", idle `moon.zzz.fill` "Idle". `AgentIdentity(agentID:)`: `claude-code`, `claude` → claude; `codex` → codex; `cursor`, `cursor-agent` → cursor; `gemini`, `gemini-cli` → gemini; anything else → other.
- Type scale: display 34 semibold rounded, title 20 semibold, headline 15 semibold, body 13 regular, caption 11 medium, mono 12 regular mono.

- [ ] **Step 1: Write the failing tests**

```swift
final class DesignTokensTests: DefaultsTestCase {
    func testTypeScaleValues() { XCTAssertEqual(TypeScale.display, TypeStyle(size: 34, weight: .semibold, rounded: true, mono: false))
        XCTAssertEqual(TypeScale.caption.size, 11); XCTAssertEqual(TypeScale.caption.weight, .medium)
        XCTAssertTrue(TypeScale.all.allSatisfy { $0.size >= TypeScale.minimum }) }
    func testSpaceRadiusIconScales() { XCTAssertEqual(Space.scale, [4, 8, 12, 16, 24, 32]); XCTAssertEqual(Radius.scale, [6, 12, 20])
        XCTAssertEqual(Radius.inner(outer: 20, padding: 20), 0); XCTAssertEqual(Radius.inner(outer: 20, padding: 8), 12)
        XCTAssertEqual([IconSize.row, IconSize.tile, IconSize.hero], [15, 20, 28]); XCTAssertEqual(Elevation.allCases.count, 2) }
    func testStateTonesMeetContrastOnBothSurfaces() // every StateTone and AgentIdentity: dark value ≥ 4.5 on panelDark, on panelDark.under(white, 0.08) and on pill; light value ≥ 4.5 on lightSurface and lightSurface.under(black, 0.08)
    func testBrandPairs() // teal dark ≥ 4.5 on panelDark; cream and white ≥ 4.5 on pond
    func testEveryToneHasSymbolAndWord() // non-empty, distinct symbols
    func testAgentIdentityMapping() { XCTAssertEqual(AgentIdentity(agentID: "claude-code"), .claude); XCTAssertEqual(AgentIdentity(agentID: "gemini-cli"), .gemini); XCTAssertEqual(AgentIdentity(agentID: "aider"), .other) }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd "$WT/apps/mac" && swift test --filter PlatyNotchKitTests.DesignTokensTests`
Expected: build error "cannot find 'TypeScale' in scope".

- [ ] **Step 3: Implement the interfaces above with the listed values** (tokens live in Kit so they are unit-tested; `RGB.contrast` and `RGB.under` already exist in `PanelPalette.swift`).

- [ ] **Step 4: Run to verify it passes**

Run: `cd "$WT/apps/mac" && swift test --filter PlatyNotchKitTests.DesignTokensTests` → PASS; then `swift test` → PASS.

- [ ] **Step 5: Commit**

```bash
cd "$WT" && git add apps/mac/Sources/PlatyNotchKit/Design apps/mac/Sources/PlatyNotchKit/Appearance/PanelPalette.swift apps/mac/Tests/PlatyNotchKitTests/DesignTokensTests.swift
git commit -m "feat(mac): design tokens for type, space, radius, icons and state colours"
```

---

### Task 2: Motion presets replace the spring and blur sliders

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Design/MotionPreset.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Appearance/AppearanceSettings.swift` (add `motion`), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`modeAnimation`, remove `morphBlur`/`settleBlur`), `apps/mac/Sources/PlatyNotchUI/Settings/AppearanceSection.swift` (Motion picker replaces the three sliders and "Reset motion")
- Test: `apps/mac/Tests/PlatyNotchKitTests/MotionPresetTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SpringSpec: Equatable, Sendable { public var response: Double; public var damping: Double; public init(response:damping:) }
  public enum MotionDirection: Sendable { case open, close; public static func between(_ old: PanelMode, _ new: PanelMode) -> MotionDirection }
  public enum MotionPreset: String, Codable, CaseIterable, Sendable { case calm, lively, reduced
      public func spring(_ d: MotionDirection) -> SpringSpec?   // nil for .reduced (cross-fade)
      public static let crossFade: Double      // 0.2, content changes
      public static let reducedFade: Double    // 0.15, every mode change under Reduced }
  extension AppearanceSettings { public var motion: MotionPreset; public func effectiveMotion(reduceMotion: Bool) -> MotionPreset }
  ```
- Values: calm open 0.38/0.86, close 0.35/1.0; lively open 0.42/0.78, close 0.35/1.0 (no overshoot on close in any preset). `between`: open when `new` is `.expanded` or a `.peek` and `old` is `.hidden`/`.compact`, or `old` is a peek and `new` is `.expanded`; close otherwise.
- Migration: when the saved JSON has no `motion` key, `motion = spring == .standard ? .calm : .lively`. `spring` stays stored (decoded and encoded) but no view reads it. `effectiveMotion(reduceMotion: true)` is always `.reduced`.

- [ ] **Step 1: Write the failing tests**: `testCalmValues`, `testLivelyValues`, `testReducedHasNoSpring`, `testCloseNeverOvershoots` (`allCases.compactMap { $0.spring(.close) }.allSatisfy { $0.damping == 1.0 }`), `testDirection` (compact→expanded open, expanded→compact close, peek(.approval)→expanded open), `testMigratesUntouchedSpringToCalm` (decode `{"spring":{"response":0.42,"dampingFraction":0.78,"blur":8}}` → `.calm`), `testMigratesChangedSpringToLively` (`"response":0.6` → `.lively`), `testSavedMotionWins` (`{"motion":"reduced"}` → `.reduced`), `testReduceMotionOverrides`, `testHoverDelaysUnchanged` (`HoverDebouncer.defaultEnterDelay == 0.12`, `defaultExitDelay == 0.35`).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.MotionPresetTests` → FAIL ("cannot find 'MotionPreset'").
- [ ] **Step 3: Implement** the Kit types; `PanelRootView.modeAnimation` becomes `.spring(response:dampingFraction:)` from `effectiveMotion(reduceMotion:).spring(MotionDirection.between(old, new))`, else `.easeOut(duration: MotionPreset.reducedFade)`. Track the previous mode in `@State` to get the direction. Delete the blur settle. The Appearance section shows a segmented `Picker("Motion", …)` with Calm, Lively, Reduced.
- [ ] **Step 4: Run** the filter → PASS; `swift test` → PASS; the smoke recipe → `SMOKE OK`, `SMOKE SETTINGS OK sections=8 onboarding=3`.
- [ ] **Step 5: Commit** `feat(mac): Calm, Lively and Reduced motion presets replace spring sliders`

---

### Task 3: UI token layer and the 11 pt floor

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Design/Tokens.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/Theme.swift` (`color(_ AgentTone)`, `nsColor(_:)`, `tint(_ LiveTint)` on the new palette), and every file found by the lint (74 literal sizes below 11 and 58 uses of `.caption`/`.caption2`/`.footnote` today, in `Shelf/`, `Views/`, `Notes/`, `Games/`, `Day/`, `Clipboard/`, `Basket/`, `Launch/`, `Settings/`, `Files/`, `HUD/`, `System/`, `Wellbeing/`, `Mascot/PlatyRenders.swift`)
- Test: `apps/mac/Tests/PlatyNotchUITests/DesignLintTests.swift`

**Interfaces:**
- Consumes: Task 1 tokens.
- Produces (internal to UI):
  ```swift
  enum DS {
      static func font(_ t: TypeStyle) -> Font
      static func color(_ tone: StateTone, _ scheme: ColorScheme) -> Color
      static func nsColor(_ tone: StateTone, dark: Bool) -> NSColor
      static func agent(_ a: AgentIdentity, _ scheme: ColorScheme) -> Color
      static let teal: Color; static let cream: Color; static let pond: Color
      static func icon(_ systemName: String, size: CGFloat) -> some View   // hierarchical rendering, medium weight; size is an IconSize token
  }
  extension StateTone { init(_ tone: AgentTone) }   // active→working, attention→needsYou, idle→idle, off→idle (drawn at 35%)
  ```
- `LiveTint` maps neutral → label colour, accent → working, warning → needsYou, critical → error. Layout is unchanged: only sizes under 11 grow to 11 (`TypeScale.caption`), weights follow the scale.

- [ ] **Step 1: Write the failing tests**

```swift
final class DesignLintTests: DefaultsTestCase {
    /// Every `.system(size: N` with a literal N < 11 under Sources/PlatyNotchUI (file:line listed on failure).
    func testNoFontBelowElevenPoints()
    /// No `.caption`, `.caption2` or `.footnote` text style under Sources/PlatyNotchUI (10 pt on macOS).
    func testNoTenPointTextStyles()
    func testStateToneMapping() { XCTAssertEqual(StateTone(AgentTone.active), .working); XCTAssertEqual(StateTone(AgentTone.attention), .needsYou) }
}
```
  Sources are found from `#filePath` (`../../Sources/PlatyNotchUI`); comment lines are skipped.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.DesignLintTests` → FAIL listing the current offenders.
- [ ] **Step 3: Implement** `DS` and replace each offender with `DS.font(TypeScale.caption)` (or the scale step that matches its role); Settings' `.font(.caption)` becomes `DS.font(TypeScale.caption)`.
- [ ] **Step 4: Run** the filter → PASS; `swift test` → PASS; the smoke recipe → `renders=24`; open `/tmp/pn-renders/*.png` and check nothing clips at 11 pt.
- [ ] **Step 5: Commit** `feat(mac): UI token layer, new state palette, nothing below 11 pt`

---

### Task 4: One card style, the radius scale and the panel surface

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Design/CardStyle.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Appearance/AppearanceSettings.swift` (`surface`), `apps/mac/Sources/PlatyNotchKit/PanelLayout.swift` (`notchBand`), `apps/mac/Sources/PlatyNotchUI/Views/Theme.swift` (`surface(_:mode:hasNotch:style:)`), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (surface + notch band), `apps/mac/Sources/PlatyNotchUI/Settings/AppearanceSection.swift` (Surface picker), and the panel tiles using `RoundedRectangle(cornerRadius:` / `.cornerRadius(` (44 rounded rectangles today: `Views/`, `Day/Views/`, `Shelf/Views/`, `System/Views/`, `Launch/Views/`, `Wellbeing/Views/`, `Clipboard/ClipboardWidget.swift`, `Notes/NotesWidget.swift`, `Views/ApprovalCard.swift`)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PanelSurfaceStyleTests.swift`, extend `apps/mac/Tests/PlatyNotchUITests/DesignLintTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension AppearanceSettings { public enum SurfaceStyle: String, Codable, CaseIterable, Sendable { case opaque, glass }
      public var surface: SurfaceStyle /* .opaque */; public func effectiveSurface(glassAvailable: Bool) -> SurfaceStyle }
  extension PanelLayout { public func notchBand(for mode: PanelMode) -> CGRect? }   // window-local, top-left origin
  // UI
  extension View { func dsCard(radius: CGFloat = Radius.card, keyline: Color? = nil) -> some View }
  ```
- Card: surface +1 step (`PanelPalette.cardOverlay` white over dark, black over light), 1 px inner keyline at `keylineAlpha` (white in dark, black in light) or the given tint, radius from the scale only. Plain list rows get no container.
- Surface: compact and hidden stay `PanelPalette.pill` (#000, no gradient, glow or shadow). The open panel and peeks are `panelDark` (#0B0D0D) in dark, `lightSurface` in light; with `.glass` on macOS 26 the system glass effect (`glassEffect`) behind the content, otherwise opaque. `notchBand` is the top `anchor.height` of the content rect on a notched display for every non-compact mode (nil without a notch, nil for `.hidden`/`.compact`), always painted `pill` black so nothing next to the camera housing differs from it.

- [ ] **Step 1: Write the failing tests**: `testSurfaceDefaultsOpaque`, `testGlassFallsBackWhenUnavailable`, `testMissingSurfaceKeyDecodes` (`{}` → `.opaque`), `testNotchBandOnNotch` (expanded on a notched 1512×982 sample screen: height == anchor.height, width == content width), `testNoNotchBandWithoutNotch`, `testNoNotchBandWhenCompact`; lint `testPanelViewsUseRadiusScale` (in `Views/`, `Day/Views/`, `Shelf/Views/`, `System/Views/`, `Launch/Views/`, `Wellbeing/Views/`: any literal `cornerRadius:` value not in {6, 12, 20} fails; the dot and progress-bar radii computed from size are not literals).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PanelSurfaceStyleTests` and `--filter PlatyNotchUITests.DesignLintTests` → FAIL.
- [ ] **Step 3: Implement**: the Kit members, `dsCard`, the surface and band in `PanelRootView`, and move each tile container onto `dsCard` (nine radii → 6/12/20; three container styles → one). No layout changes beyond the radii.
- [ ] **Step 4: Run** both filters → PASS; `swift test` → PASS; the smoke recipe → `renders=24`; compare the approval card, shelf and HUD renders with the previous ones (only radius, keyline and surface differ).
- [ ] **Step 5: Commit** `feat(mac): one card style, radius scale, #0B0D0D panel with black notch band, optional glass`

---

## Phase 2: Priority model and Now

### Task 5: Live ranks and the priority model

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Live/LiveRank.swift`, `apps/mac/Sources/PlatyNotchKit/Live/PriorityModel.swift`, `apps/mac/Sources/PlatyNotchKit/Live/AgentsLive.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Widgets/LiveActivity.swift` (additive fields and constants)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PriorityModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum LiveRank: Int, Comparable, CaseIterable, Sendable {   // lower = more urgent (spec 6.3)
      case approval = 1, ringing, meetingImminent, agentNeedsYou, agentFinished, timerRunning, meetingSoon, fileAction, agentsWorking, music, minor, ambient
      public init(activity: LiveActivity, now: Date)
      public var notificationKind: NotificationKind }
  public enum NotificationKind: String, Codable, CaseIterable, Sendable { case approval, agentNeedsYou, agentFinished, ringing, meetingStarting, other }
  public enum LiveSource: Equatable, Sendable { case agents(AgentsLive), activity(LiveActivity) }
  public struct LiveItem: Identifiable, Equatable, Sendable { public let id: String; public let rank: LiveRank; public let source: LiveSource
      public let title: String; public let subtitle: String?; public let startedAt: Date?
      public init(id: String, rank: LiveRank, source: LiveSource, title: String, subtitle: String?, startedAt: Date?) }
  public enum PriorityModel { public static func rank(_ activities: [LiveActivity], agents: AgentsLive?, now: Date) -> [LiveItem] }
  public struct AgentFinishLog: Equatable, Sendable { public static let window: TimeInterval /* 600 */; public init()
      public mutating func update(_ sessions: [Session], now: Date); public mutating func noteFailure(sessionKey: String, at: Date)
      public func lastFinish(now: Date) -> Date?; public func failed(_ key: String, now: Date) -> Bool; public func finished(_ key: String, now: Date) -> Bool }
  public struct AgentsLive: Equatable, Sendable { public let rank: LiveRank; public let title: String; public let subtitle: String?; public let startedAt: Date
      public let needsYou: Int; public let working: Int; public let total: Int
      public static func make(sessions: [Session], log: AgentFinishLog, now: Date) -> AgentsLive? }
  // LiveActivity, additive (init params default nil):
  public let title: String?; public let subtitle: String?; public let startedAt: Date?
  extension LivePriority { public static let fileAction = 26; public static let panelActivity = 23 }
  ```
- Bands for `LiveRank(activity:now:)` (a plugin's priority is clamped into them): ≥ 90 → ringing (an activity can never be `.approval`); 80…89 → agentNeedsYou; 70…79 → meetingImminent when `countdownTo` is at most 120 s away, else meetingSoon; 50…69 → timerRunning; 40…49 → music; 30…39 → agentsWorking; 25…29 → fileAction; 11…24 → minor; ≤ 10 → ambient. Expired activities are dropped.
- `notificationKind`: approval → `.approval`; ringing → `.ringing`; meetingImminent, meetingSoon → `.meetingStarting`; agentNeedsYou → `.agentNeedsYou`; agentFinished → `.agentFinished`; the rest → `.other`.
- `AgentsLive.make`: rank agentNeedsYou when a session is `.blocked`/`.waitingInput` or `log.failed`; else agentsWorking when one is `.active`; else agentFinished while `log.lastFinish` is within 600 s; else nil. Title "\(agentName) · \(project)" of the most urgent session (oldest `startedAt` in that state), `total` counts non-exited sessions.
- `rank`: ties keep the earlier `startedAt` when both have one, else input order. `title` = `activity.title ?? accessibilityLabel ?? widgetID`.

- [ ] **Step 1: Write the failing tests**: `testSpecOrder` (one item per rank 2–10 shuffled → sorted in spec order), `testMeetingSplitsAtTwoMinutes` (countdown 119 s → meetingImminent, 181 s → meetingSoon), `testTiesGoToEarlierStart`, `testExpiredDropped`, `testPluginPriorityIsClamped` (priority 1000 → `.ringing`, −5 → `.ambient`, never `.approval`), `testAgentsRanks` (waitingInput → 4, active → 9, finished 5 min ago → 5, finished 11 min ago → nil), `testFailureNoticeMeansNeedsYou` (`noteFailure` → 4 until the session is `.active` again or 600 s pass), `testWindowsExpireAcrossSleep` (finish at t, then `now = t + 7200` → nil), `testNotificationKinds`, `testExistingConstantsKeepTheirBands` (`LivePriority.download` → fileAction, `.keepAwake` → minor, `.shelfItems` → ambient, `.musicPlaying` → music).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PriorityModelTests` → FAIL ("cannot find 'LiveRank'").
- [ ] **Step 3: Implement** the interfaces; keep `LiveArbiter` and its tests untouched (plugins may call it).
- [ ] **Step 4: Run** → PASS; `swift test` (incl. `LiveArbiterTests`) → PASS.
- [ ] **Step 5: Commit** `feat(mac): one priority model for pill, Now hero and auto-open`

---

### Task 6: The Now model

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Widgets/WidgetKind.swift`, `apps/mac/Sources/PlatyNotchKit/Now/GlanceSlots.swift`, `apps/mac/Sources/PlatyNotchKit/Now/HeroDeck.swift`, `apps/mac/Sources/PlatyNotchKit/Now/NowModel.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/NowModelTests.swift`

**Interfaces:**
- Consumes: `LiveItem`, `LiveRank` (Task 5); `PanelLayout` (existing).
- Produces:
  ```swift
  public struct WidgetKind: OptionSet, Hashable, Sendable { public let rawValue: Int; public init(rawValue: Int); public static let live, glance, tool: WidgetKind }
  public struct GlanceSlots: Codable, Equatable, Sendable { public static let key = "now.glances"; public static let limit = 4; public static let usageID = "agents.usage"
      public private(set) var ids: [String]; public init(ids: [String] = [])
      public static func defaults(glanceCapable: [String]) -> GlanceSlots   // first four, in order
      public mutating func set(_ ids: [String])                             // de-duplicated, at most 4
      public func shown(available: Set<String>) -> [String]                 // chosen ids that have content, in slot order
      public static func load(from: UserDefaults, glanceCapable: [String]) -> GlanceSlots; public func save(to: UserDefaults) }
  public struct HeroDeck: Equatable, Sendable { public init(); public private(set) var selectedID: String?
      public static func items(_ ranked: [LiveItem]) -> [LiveItem]           // drops .approval and .ambient; one entry per widget (its best item) plus Agents
      public func current(in deck: [LiveItem]) -> Int?                      // selected if still present, else 0
      public mutating func step(_ delta: Int, in deck: [LiveItem])          // wraps
      public mutating func panelOpened()                                    // back to the top item
      public static func position(_ index: Int, of count: Int) -> String? } // "2 of 3"; nil when count < 2
  public enum NowMode: Equatable, Sendable { case approvalsPending(line: String?), live, summary
      public static func resolve(approvals: Int, deck: [LiveItem], now: Date) -> NowMode }
  public enum NowSummaryLine { public static func text(_ deck: [LiveItem], now: Date) -> String? }   // "Now: Music · Design in 8 min" (top two)
  public struct QuietLineItem: Equatable, Sendable { public let id: String; public let text: String; public init(id:text:) }
  public enum QuietLine { public static func items(openLoops: Int, tasks: Int, glanceIDs: [String]) -> [QuietLineItem] }   // "Open loops (2)", "Tasks (3)"; zero or already a chip → left out
  public enum TodayGreeting { public static func text(hour: Int) -> String }   // 5–11 "Good morning", 12–17 "Good afternoon", 18–22 "Good evening", else "Hello"
  public enum NowMetrics { public static let nav: CGFloat = 32, hero: CGFloat = 160, glance: CGFloat = 64, quietLine: CGFloat = 20, gap: CGFloat = 8
      public static var required: CGFloat; public static func available(in layout: PanelLayout) -> CGFloat }   // content height − inset − 10 bottom
  ```
- `NowSummaryLine`: an item with `countdownTo` within 60 min gets " in N min" (N rounded up); nil for an empty deck.
- Quiet line ids: `loops` and `reminders` (the widget ids they link to).

- [ ] **Step 1: Write the failing tests**: `testWidgetKindIsAnOptionSet`, `testDefaultGlancesAreFirstFour` (`["meeting","weather","system","wellbeing","mail"]` → first four), `testSetCapsAndDedupes`, `testUnavailableGlanceKeepsItsSlot` (ids `[a,b,c,d]`, available `{a,c,d}` → `[a,c,d]`; available again `{a,b,c,d}` → `[a,b,c,d]`), `testLoadWithoutSavedKeyUsesDefaults`, `testDeckDropsApprovalAndAmbient`, `testOneEntryPerWidget` (two running timers → one Time entry, the higher ranked), `testSelectionSurvivesReorder` (select item 2, the deck re-ranks → same id), `testSelectionFallsBackWhenItemEnds`, `testPanelOpenedResets`, `testPosition` (`position(1, of: 3) == "2 of 3"`, `position(0, of: 1) == nil`), `testApprovalsPendingMode` (`NowMode.resolve(approvals: 1, …)` → `.approvalsPending(line: "Now: Music · Design in 8 min")`), `testQuietLineHidesZeroAndChips`, `testGreeting`, `testNowFitsTheExpandedPanel` (`NowMetrics.required <= NowMetrics.available(in:)` for a notched 1512×982 screen with notch height 38 and for a screen without a notch).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.NowModelTests` → FAIL.
- [ ] **Step 3: Implement** the interfaces.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mac): Now model: widget kinds, glance slots, hero deck, quiet line`

---

### Task 7: Widget API additions and registry queries

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchUI/Widgets/NotchWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Widgets/WidgetRegistry.swift`, `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (`buildViews(of:)` also lays out the new views; set `openSettingsHandler`)
- Test: `apps/mac/Tests/PlatyNotchUITests/WidgetKindAPITests.swift`

**Interfaces:**
- Consumes: `WidgetKind`, `LiveItem`, `PriorityModel`, `AgentsLive` (Tasks 5–6).
- Produces (public; each new member is a protocol requirement with its default in the existing `extension NotchWidget`):
  ```swift
  public enum WidgetSetupAction { case openSettings; case run(@MainActor () -> Void) }
  protocol NotchWidget {   // added requirements
      var kind: WidgetKind { get }            // default .tool
      var hasContent: Bool { get }            // default true
      func heroView() -> AnyView?             // default nil
      func glanceView() -> AnyView?           // default nil
      func libraryTile() -> AnyView?          // default nil
      func toolView() -> AnyView              // default: hasTile ? tileView() : (settingsView() ?? tileView())
      var setupAction: WidgetSetupAction { get } } // default .openSettings
  extension WidgetRegistry {
      public var toolWidgets: [any NotchWidget]     // enabled, kind ⊇ .tool, user order
      public var glanceWidgets: [any NotchWidget]   // enabled, running, kind ⊇ .glance, hasContent
      public var glanceCapableIDs: [String]         // enabled, kind ⊇ .glance, user order (GlanceSlots.defaults)
      public func rankedLive(agents: AgentsLive?, now: Date) -> [LiveItem]
      public var openSettingsHandler: (@MainActor (String) -> Void)?   // "widgets/<id>"
      public func runSetup(_ id: String) }
  ```
- `tileView()` stays a requirement (its doc comment says it is deprecated in favour of `toolView()`); `hasTile` and `tileWidgets` stay. Until Task 24 the app's `openSettingsHandler` opens the Widgets section and ignores the detail.

- [ ] **Step 1: Write the failing tests**: `testTileOnlyWidgetIsATool` (a fake implementing only `id`, `title`, `systemImage`, `defaultEnabled`, `tileView()` → `kind == .tool`, in `toolWidgets`, not in `glanceWidgets`, `hasContent`), `testToolViewDefaultsToTile`, `testHeadlessToolViewIsSettings` (`hasTile == false` with a settings view → `toolView()` hosts the settings view), `testGlanceWidgetsNeedContentAndRunning`, `testRunSetupDefaultOpensSettings` (handler receives `"widgets/fake"`), `testRunSetupCustomAction`, `testRankedLiveUsesRunningWidgetsOnly`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.WidgetKindAPITests` → FAIL.
- [ ] **Step 3: Implement**; `buildViews(of:)` lays out `toolView()`, `glanceView()`, `heroView()` and `libraryTile()` when present.
- [ ] **Step 4: Run** → PASS; `swift test` incl. `PluginAPITests` → PASS (unchanged); the smoke recipe → `SMOKE OK`, `SMOKE-POWER OK widgets=6`.
- [ ] **Step 5: Commit** `feat(mac): additive widget API for kinds, content, hero, glance, library and setup`

---

### Task 8: Built-in widget kinds, content and glances

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchUI/Widgets/BuiltIn/MusicWidget.swift`, `FocusWidget.swift`, `LoopsWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Widgets/TimeWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Day/MeetingWidget.swift`, `Day/WeatherWidget.swift`, `Day/RemindersWidget.swift`, `apps/mac/Sources/PlatyNotchUI/System/SystemWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Wellbeing/WellbeingWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Integrations/MailWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Shelf/ShelfWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Camera/MirrorWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Games/GamesWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Files/FileActionsWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Windows/WindowSnapWidget.swift`
- Create: `apps/mac/Sources/PlatyNotchUI/Now/GlanceChip.swift` (shared chip layout: icon 15, value in rounded headline, caption label)
- Test: `apps/mac/Tests/PlatyNotchUITests/BuiltInKindsTests.swift`

**Interfaces:**
- Consumes: Task 7 API, `LivePriority.fileAction` / `.panelActivity` (Task 5).
- Kinds: music `[.live, .tool]`; meeting `[.glance, .live, .tool]`; focus, time `[.live, .tool]`; loops, reminders, weather, wellbeing, mail `[.glance, .tool]`; system `[.glance, .live, .tool]`; shelf, mirror, games `[.live, .tool]`; everything else keeps `.tool`.
- `hasContent` and glance (exact rule each): meeting — calendar access and an event within `UpcomingMeeting.horizon` → "10:30 Design"; weather — a forecast loaded → "24° Clear"; system — the Mac has a battery → "Battery 82%"; wellbeing — water tracking on → "Water 5/8"; mail — unread count > 0 → "Mail 4"; loops — open loops > 0 → "Open loops 2"; reminders — reminders access and tasks due today > 0 → "Tasks 3". Widgets without data keep `hasContent == false` and appear nowhere in Now.
- New activities: music adds `music:paused` (glyph `.symbol("pause.fill")`, priority `musicPlaying`, `expiresAt` pause + 600 s, title "Music"); shelf publishes `shelf:action` at `LivePriority.fileAction` with `.ring(progress:)` while a file action runs; mirror publishes `mirror:on` and games `games:chase` at `LivePriority.panelActivity` while running. Every built-in activity gets `title`/`subtitle`/`startedAt` (meeting title = event title, subtitle = start time).
- `FileActionsWidget` and `WindowSnapWidget` keep `hasTile == false`; their `toolView()` is their settings view (Task 7 default).

- [ ] **Step 1: Write the failing tests** (inert widgets, `persist: false`): `testKindsTable` (the table above, asserted per id), `testNoDataMeansNoContent` (meeting without access, weather without a forecast, mail at 0 → `hasContent == false`), `testMusicPausedStaysTenMinutes` (paused at t → activity present at t+599, absent at t+601), `testShelfActionIsFileActionRank`, `testGlanceViewsExistForGlanceKinds`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.BuiltInKindsTests` → FAIL.
- [ ] **Step 3: Implement** per widget.
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE OK`, `SMOKE-POWER OK widgets=6`.
- [ ] **Step 5: Commit** `feat(mac): built-in widgets declare kinds, content and glances`

---

### Task 9: The Now destination

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Now/NowView.swift`, `Now/HeroFrame.swift`, `Now/GenericHero.swift`, `Now/TodaySummaryHero.swift`, `Now/GlanceRow.swift`, `Now/QuietLineView.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/ExpandedPanel.swift` (`BuiltinTab.now = "now"`, first tab; 32 pt nav with headline labels), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`selectedTab` default `BuiltinTab.now`; `HeroDeck.panelOpened()` on each open), `apps/mac/Sources/PlatyNotchUI/Views/TodayTab.swift` (`TodayServices` gains `agentActivity`), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (feeds `agentActivity`), `apps/mac/Sources/PlatyNotchKit/PanelLayout.swift` (`approvalSlot` insets 12 → `Space.panelMargin`), `apps/mac/Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Create: `apps/mac/Sources/PlatyNotchUI/Now/AgentActivityModel.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/NowViewTests.swift`

**Interfaces:**
- Consumes: Tasks 5–8.
- Produces: `@MainActor @Observable final class AgentActivityModel { private(set) var log: AgentFinishLog; func sessionsChanged(_ s: [Session], now: Date); func notice(_ n: Notice, now: Date) }` (a `session-failed` notice calls `noteFailure`), held as `TodayServices.agentActivity`; `struct NowView: View { init(store: AppStore, widgets: WidgetRegistry, today: TodayServices, deck: Binding<HeroDeck>, onOpenTool: (String) -> Void, onOpenAgents: () -> Void, onOpenTerminal: (Session) -> Void) }`; `struct HeroFrame<Content: View>: View { init(keyline: Color?, position: String?, onStep: ((Int) -> Void)?, @ViewBuilder content: () -> Content) }` (160 pt tall, radius `Radius.hero`, padding `Space.heroPadding`, ‹ › buttons with VoiceOver labels "Previous live item"/"Next live item", horizontal swipe calls `onStep`).
- Layout by `NowMode`: `.live` → hero (`heroView()` of the item's widget, else `GenericHero`; Agents item → a Platy 96 hero, refined in Task 10) + glance row + quiet line; `.summary` → `TodaySummaryHero` (greeting, date, time in `TypeScale.display` updated each minute only while ticking, next event, Platy 96 idle) + glance row + quiet line; `.approvalsPending(line)` → one `body` line only. No `ScrollView` anywhere in Now. The open panel's side padding becomes `Space.panelMargin` (16) and `approvalSlot` moves with it, so it stays exactly where cards are drawn (the peek keeps 12). Hero keyline: `DS` colour of the activity's `LiveTint`, nil for neutral. Glance chips are equal width, 64 pt, `dsCard(radius: Radius.card)`; tapping opens the widget's tool (`onOpenTool(id)`), the usage chip opens Agents. The Today, Agents, Focus, Memory and Games tabs stay until Task 21.
- Renders added: `now-summary`, `now-live-generic`, `now-approvals-line` → `renders=30`.

- [ ] **Step 1: Write the failing tests**: `testNowFitsWithEverythingOn` (all built-ins enabled with inert models, four glances, three live items: hosted `NowView` at 528 wide has `fittingSize.height <= NowMetrics.available(in:)` for a notched layout), `testHeroFitsWithLongTitle` (200-character title and subtitle → hero `fittingSize` ≤ 528×160 and the ‹ › buttons are still laid out inside it), `testDefaultTabIsNow` (`PanelViewModel().selectedTab == "now"`), `testNoScrollViewInNow` (lint over `Sources/PlatyNotchUI/Now/`: no `ScrollView`); Kit `PanelSurfaceTests.testApprovalSlotMatchesPanelMargin` (slot x = content minX + 16, width = content width − 32).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.NowViewTests` → FAIL.
- [ ] **Step 3: Implement** the views and the three renders.
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=30`; look at the three PNGs in both schemes.
- [ ] **Step 5: Commit** `feat(mac): Now: one hero, four glances, a quiet line, no scrolling`

---

### Task 10: Hero views per live kind

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Now/AgentsHero.swift`
- Modify: `heroView()` in `Widgets/BuiltIn/MusicWidget.swift`, `Widgets/TimeWidget.swift`, `Day/MeetingWidget.swift`, `Widgets/BuiltIn/FocusWidget.swift`, `System/SystemWidget.swift`, `Shelf/ShelfWidget.swift`, `Camera/MirrorWidget.swift`, `Games/GamesWidget.swift`; `Now/NowView.swift` (uses `AgentsHero`); `Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/HeroViewsTests.swift`, `apps/mac/Tests/PlatyNotchKitTests/HeroPrimaryTests.swift`

**Interfaces:**
- Consumes: `HeroFrame` (Task 9), `AgentsLive` (Task 5).
- Produces: `struct AgentsHero: View { init(agents: AgentsLive, mood: PlatyMood?, onPrimary: () -> Void) }`; Kit `apps/mac/Sources/PlatyNotchKit/Now/HeroPrimary.swift`: `public enum HeroPrimary { public static func title(rank: LiveRank, playing: Bool, hasLink: Bool) -> String? }` (ringing "Stop", timerRunning "Pause", music "Pause"/"Play", meetingImminent and meetingSoon "Join" with a link else nil, everything else nil; the agents hero uses `AgentRowAction`).
- One primary control each, at most: music Play/Pause (keyline = album art tint, `NowPlaying.artworkTint`); timer Pause, stopwatch Pause, ringing Stop; meeting Join (only with a `MeetingLinks` URL); focus Pause; downloads/file action none; mirror none; Chase none; agents "Answer" when needs-you, else "Open terminal". Counts and times use `.contentTransition(.numericText())`; countdowns tick only while `panelTicking`.
- Renders added: `hero-music`, `hero-timer`, `hero-meeting`, `hero-agents` → `renders=38`.

- [ ] **Step 1: Write the failing tests**: `testEveryLiveBuiltInHasAHero` (each inert widget with a seeded activity returns a non-nil `heroView()` that fits 528×160), Kit `testPrimaryTitles` (the table above), `testAgentsHeroAction` (needs-you → "Answer", working → "Open terminal").
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.HeroViewsTests` and `--filter PlatyNotchKitTests.HeroPrimaryTests` → FAIL.
- [ ] **Step 3: Implement** the hero views and renders.
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=38`.
- [ ] **Step 5: Commit** `feat(mac): hero layouts for music, timers, meetings, focus, files, mirror, Chase and agents`

---

## Phase 3: Pill, live activities and the morph

### Task 11: Pill content model

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Pill/PillContent.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/PanelFormat.swift` (`PillDots.Dot` gains `agent` and `style`), `apps/mac/Sources/PlatyNotchKit/Appearance/LiveEarFit.swift` (indicators)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PillContentTests.swift`

**Interfaces:**
- Consumes: `PriorityModel`, `NotificationKind` (Task 5), `AgentIdentity` (Task 1).
- Produces:
  ```swift
  public enum AgentDotStyle: Sendable, Equatable { case pulse, solid, hollow }   // working, waiting (needs you), idle
  extension PillDots.Dot { public var agent: AgentIdentity; public var style: AgentDotStyle }
  public struct PillContent: Equatable, Sendable {
      public static let indicatorLimit = 2
      public let dots: PillDots; public let approvalCount: Int
      public let trailing: LiveActivity?          // top non-agent item whose kind shows in the pill
      public let indicators: [LiveActivity]       // next ones, ≤ 2; ambient never beside a non-ambient trailing item
      public init(activities: [LiveActivity], sessions: [Session], approvals: Int, hiddenKinds: Set<NotificationKind>, now: Date)
      public var keepsMinimalUp: Bool }           // anything non-ambient live, approvals included
  extension LiveEarFit { public init(earWidth: CGFloat, hasTrailing: Bool, indicators: Int); public let indicatorsShown: Int }
  ```
- `LiveEarFit.indicator: CGFloat = 6` plus 3 pt spacing each; the old `hasBubble` init stays and maps to one indicator.

- [ ] **Step 1: Write the failing tests**: `testTrailingIsTopNonAgent` (timer + music → trailing timer, indicators [music]), `testAtMostTwoIndicators`, `testAmbientNeverBesideLive`, `testHiddenKindLeavesThePill` (`hiddenKinds: [.other]` drops music), `testDotStyles` (active → pulse, waitingInput → solid, idle → hollow; agent from `agentID`), `testTwelveSessions` (12 sessions over claude/codex/cursor/gemini, one `waitingInput` → 3 dots with the waiting one first, overflow 9), `testEarFitDropsIndicatorsFirst` (narrow ear: trailing kept, indicators 0), `testKeepsMinimalUp`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PillContentTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(mac): pill content from the priority model with two indicator dots`

---

### Task 12: Redraw the compact pill

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/CompactPill.swift`, `apps/mac/Sources/PlatyNotchUI/Views/Theme.swift` (`AgentDotNSView.configure(color:style:)`: hollow is a 1.5 pt ring, solid a filled dot, pulse the existing CA animation), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (builds `PillContent`; Minimal uses `keepsMinimalUp`), `apps/mac/Sources/PlatyNotchUI/NotchController.swift` (`setLive` from `PillContent.keepsMinimalUp`), `Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/CompactPillTests.swift`

**Interfaces:**
- Consumes: `PillContent`, `LiveEarFit(earWidth:hasTrailing:indicators:)` (Task 11); `DS.agent` (Task 3).
- Produces: `CompactPill(content: PillContent, connection: ConnectionState, hasNotch: Bool, notchWidth: CGFloat, liveSide: LiveSide, earWidth: CGFloat, platy: PlatyMood?)`. Leading ear: Platy, then dots coloured by `DS.agent` with their style, then "+n" at `TypeScale.caption`. Trailing ear: connection glyph, else the approval badge, else trailing glyph + text, then up to two 6 pt indicator dots tinted by each item's tint. `liveSide` still swaps the ears. `hiddenKinds` is empty until Task 22.
- Renders added: `pill-platy-idle`, `pill-agents-music`, `pill-indicators` → `renders=44`.

- [ ] **Step 1: Write the failing tests**: `testTrailingNeverWiderThanEar` (hosted pill with a 200-character trailing text at each `PillWidth` → trailing frame within `earWidth`), `testHollowDotDoesNotAnimate` (`AgentDotNSView` configured `.hollow` → `isPulsing == false`; `.pulse` with ticking → true), `testAccessibilitySummaryNamesIndicators`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.CompactPillTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=44`; manual: `scripts/fake-events.sh` with two sessions and music → pill shows Platy, two coloured dots, music bars.
- [ ] **Step 5: Commit** `feat(mac): pill shows Platy and agents, the top live item and two indicators`

---

### Task 13: Platy state poses

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchKit/Mascot/PlatyMood.swift`, `apps/mac/Sources/PlatyNotchKit/Mascot/PlatyPoseValues.swift`, `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyArt.swift` (the flag), `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyView.swift` (play once), `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyMoodModel.swift`
- Test: extend `apps/mac/Tests/PlatyNotchKitTests/PlatyMoodTests.swift`, `apps/mac/Tests/PlatyNotchUITests/PlatyTests.swift`

**Interfaces:**
- Produces: `PlatyPoseValues.flag: Bool`; `PlatyMood.playsOnce: Bool` (waiting, done); `PlatyMood.waiting.period == 2`; `PlatyMoodResolver.mood(…, finishedRecently: Bool = false)` (after working, before dancing: `.done`); `PlatyLayerNSView` plays a `playsOnce` loop with `repeatCount = 1` and then holds `rest(mood)`; a new needs-you event (mood leaves and re-enters waiting) plays the wave again.
- Pose: waiting = amber flag raised with one wave over 2 s, then still with the flag up; done = check; working = paddle; workingToMusic = headphones; sleepy = night idle (existing).

- [ ] **Step 1: Write the failing tests**: Kit `testWaitingWavesOnceForTwoSeconds` (`period == 2`, `playsOnce`), `testWaitingRestHasFlag`, `testDonePlaysOnce`, `testFinishedRecentlyIsDone` (no active session, `finishedRecently: true` → `.done`; with an active session → `.working`); UI `testPlaysOnceLoopEndsStill` (`PlatyLayerNSView` with waiting → animation `repeatCount == 1`).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PlatyMoodTests` and `--filter PlatyNotchUITests.PlatyTests` → FAIL.
- [ ] **Step 3: Implement**; `PlatyMoodModel.mood` passes `finishedRecently` from `today.agentActivity.log.lastFinish(now:) != nil`.
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; `.build/debug/PlatyNotch --platy-gallery /tmp/pn-gallery` → the waiting frames show the flag.
- [ ] **Step 5: Commit** `feat(mac): Platy raises an amber flag once when you are needed`

---

### Task 14: Morph-in-place open and close

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Design/Morph.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`@Namespace`, `\.morphNamespace` environment), `Views/CompactPill.swift`, `Now/NowView.swift`, `Now/HeroFrame.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/MorphTests.swift`

**Interfaces:**
- Consumes: `MotionPreset`, `MotionDirection` (Task 2), `PillContent` (Task 11), `HeroDeck` (Task 6).
- Produces:
  ```swift
  public enum MorphID { public static let platy = "morph.platy"; public static func live(_ id: String) -> String }
  public enum Morph { public static func matches(pillTrailingID: String?, heroTopID: String?, motion: MotionPreset) -> Bool }   // same id and motion != .reduced
  ```
- Platy in the pill and Platy in the hero share `matchedGeometryEffect(id: MorphID.platy)`; the pill's trailing glyph and the hero's glyph share `MorphID.live(id)` when `Morph.matches`. With `.reduced`, cross-fades only. Close lands exactly on the notch outline (content frame equals `contentRect(.compact)` at the end). Other content changes cross-fade in `MotionPreset.crossFade`.

- [ ] **Step 1: Write the failing tests**: `testMatchesSameItem`, `testNoMatchForDifferentItems`, `testReducedNeverMorphs`, `testLiveIDsDiffer`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.MorphTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE OK`; manual on a notched Mac: open and close ten times with music playing (no jump, no overshoot on close, no seam); `scripts/perf-idle.sh` and `scripts/perf-idle.sh --state music` → PASS.
- [ ] **Step 5: Commit** `feat(mac): open grows the pill into the hero in place`

---

### Task 15: Peek on hover, open on click

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchKit/Appearance/AppearanceSettings.swift` (`OpenTrigger.peekOnHover`), `apps/mac/Sources/PlatyNotchKit/PanelState.swift` (`PeekReason.hover`, `PanelSurfaceState.hoverPeek`, precedence), `apps/mac/Sources/PlatyNotchKit/PanelLayout.swift` (`hoverPeekHeight`), `apps/mac/Sources/PlatyNotchKit/PanelSupport.swift` and `PanelFormat.swift` (switches), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (draws the hero only), `apps/mac/Sources/PlatyNotchUI/NotchController.swift`, `Settings/AppearanceSection.swift` (third "Open on" choice), `Smoke/ThemeRenders.swift`
- Test: extend `apps/mac/Tests/PlatyNotchKitTests/PanelStateTests.swift`, `PanelLayoutTests.swift`

**Interfaces:**
- Produces: `PeekReason.hover`; `PanelStateMachine.peekOnHover: Bool`; `PanelLayout.hoverPeekHeight: CGFloat = 176` (content rect: `peekSize.width` × notch height + 176); `ApprovalPlacement(mode: .peek(.hover), …) == nil`; `.peek(.hover).canBecomeKey == false`.
- Precedence: approval > open > drop > ringing > hover peek > HUD > notice > widget peek > idle. Hover enter from idle shows the hover peek; hover exit ends it; click opens the panel; the default trigger stays `.hover` (open on hover, as today).
- Render added: `peek-hover` → `renders=46`.

- [ ] **Step 1: Write the failing tests**: `testHoverPeekThenClickOpens`, `testHoverPeekExitCloses`, `testApprovalBeatsHoverPeek`, `testRingingBeatsHoverPeek`, `testHoverPeekNeverKey`, `testNoApprovalCardsInHoverPeek`, `testHoverPeekRect` (width 420, height notch + 176), `testDefaultTriggerUnchanged`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PanelStateTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=46`.
- [ ] **Step 5: Commit** `feat(mac): optional peek on hover, open on click`

---

## Phase 4: Agents

### Task 16: Agent ordering, status lines and visibility

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Agents/AgentsOrder.swift`, `apps/mac/Sources/PlatyNotchKit/Agents/AgentsVisibility.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/AgentsOrderTests.swift`

**Interfaces:**
- Consumes: `AgentFinishLog` (Task 5), `StateTone` (Task 1).
- Produces:
  ```swift
  public enum AgentAttention: Int, Comparable, Sendable { case needsYou, errored, working, finished, idle, exited; public var tone: StateTone }
  public enum AgentsOrder { public static func attention(_ s: Session, log: AgentFinishLog, now: Date) -> AgentAttention
      public static func sorted(_ sessions: [Session], log: AgentFinishLog, now: Date) -> [Session] }   // by attention, then newest updatedAt
  public enum SessionStatusLine { public static func text(_ s: Session, attention: AgentAttention, now: Date) -> String
      public static func lastAction(_ s: Session) -> String? }
  public enum AgentRowAction: Sendable { case answer, openTerminal; public static func `for`(_ a: AgentAttention) -> AgentRowAction; public var title: String }
  public struct AgentsVisibility: Codable, Equatable, Sendable { public static let key = "agents.visibility"
      public var everConnected: Bool; public var forcedOn: Bool; public init(everConnected: Bool = false, forcedOn: Bool = false)
      public var isVisible: Bool; public mutating func noteSessions(count: Int) -> Bool   // true only the first time (one-time notice)
      public static func load(from: UserDefaults) -> AgentsVisibility; public func save(to: UserDefaults) }
  ```
- Attention: blocked / waitingInput → needsYou; `log.failed` → errored; active → working; `log.finished` within 600 s → finished; idle → idle; exited → exited. Status text: needsYou "Waiting for approval" (blocked) / "Needs your input" (waitingInput); errored "Stopped with an error"; working "\(title ?? tool ?? "Working") · \(minutes since startedAt) m"; finished "Finished · \(minutes ago) m ago"; idle "Idle"; exited "Ended". `lastAction` = `message ?? tool`, through `SummarySanitizer.visible(_, singleLine: true)`. `AgentRowAction`: needsYou, errored → answer ("Answer"); else openTerminal ("Open terminal").

- [ ] **Step 1: Write the failing tests**: `testAttentionOrder`, `testTwelveSessionsNeedsYouFirst`, `testStatusLines` (exact strings above with fixed dates), `testLastActionHidesNothing` (zero-width space → `⟨U+200B⟩`), `testRowActions`, `testVisibilityFirstConnectNotifiesOnce`, `testForcedOn`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.AgentsOrderTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mac): agent attention order, status lines and Agents visibility`

---

### Task 17: Approval previews

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Agents/ApprovalPreview.swift`, `apps/mac/Sources/PlatyNotchKit/Agents/LineDiff.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/ApprovalPreviewTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct DiffLine: Equatable, Sendable { public enum Kind: Sendable { case hunk, context, added, removed }; public let kind: Kind; public let text: String; public init(kind:text:) }
  public enum LineDiff { public static let maxCells = 250_000
      public static func unified(old: String, new: String, context: Int = 3) -> [DiffLine] }   // LCS over lines; above maxCells: every old line removed, every new line added, one hunk
  public struct ApprovalPreview: Equatable, Sendable { public static let collapsedLines = 12
      public let command: String?; public let path: String?; public let diff: [DiffLine]; public let hadHidden: Bool
      public init(approval: Approval)
      public func lines(expanded: Bool) -> [DiffLine]; public var hasMore: Bool
      public static func boxLines(diffCount: Int, cards: Int) -> Int }   // min(diffCount, cards == 1 ? 8 : 4)
  ```
- Sources in `approval.input` (only what the hook payload carries): `command` (Bash); `file_path` / `notebook_path` / `path`; Edit `old_string`/`new_string`; MultiEdit `edits[]` (one hunk group per edit); Write `content` (all added); NotebookEdit `new_source` (all added). Every string passes through `SummarySanitizer.visible` (newlines kept); `hadHidden` is true when any did. Hunk header `@@ -a,b +c,d @@`.

- [ ] **Step 1: Write the failing tests**: `testEditMakesUnifiedDiff` (old "a\nb\nc", new "a\nB\nc" → `[hunk "@@ -1,3 +1,3 @@", context "a", removed "b", added "B", context "c"]`), `testCollapsedToTwelve` (40-line Write → `lines(expanded: false).count == 12`, `hasMore`, expanded count 41 incl. hunk), `testMultiEdit`, `testBashHasCommandNoDiff`, `testHiddenCharactersStayVisible`, `testHugeInputFallsBack` (2000×2000 changed lines → one hunk, 4000 lines, finishes under 0.5 s), `testBoxLines`, `testNoInputMeansSummaryOnly`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.ApprovalPreviewTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mac): approval previews with command, path and a unified diff`

---

### Task 18: The Agents destination

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Agents/AgentsView.swift`, `Agents/AgentRow.swift`, `Agents/UsageRings.swift`, `Agents/AgentBadge.swift`
- Delete: `apps/mac/Sources/PlatyNotchUI/Views/AgentsTab.swift`, `apps/mac/Sources/PlatyNotchUI/Views/SessionRow.swift` (`RowButtonStyle` moves to `AgentRow.swift`)
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/ExpandedPanel.swift` (Agents tab → `AgentsView`; hidden unless `AgentsVisibility.isVisible`), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (feeds `noteSessions`, posts the one-time notice "Agents is in your notch now" via `AppStore.postLocalNotice`), `apps/mac/Sources/PlatyNotchKit/AppStore.swift` (`package func postLocalNotice(_ n: Notice)`), `Settings/AgentsSection.swift` (toggle "Show Agents before an agent connects" → `forcedOn`), `Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/AgentsViewTests.swift`

**Interfaces:**
- Consumes: Task 16 and `DS.agent`, `StateTone`.
- Produces: `struct AgentsView: View { init(sessions: [Session], usage: Usage, log: AgentFinishLog, onOpenTerminal: (Session) -> Void, onConnect: () -> Void) }`; `struct UsageRings: View { init(usage: Usage, hint: String?) }` (Claude 5 h and weekly, Codex 5 h, else weekly; compact, right-aligned in the header; `hint` from `PanelFormat.claudeLimitsHint` only as `.help` tooltip while limits are unavailable); `struct AgentBadge: View { init(agent: AgentIdentity, tone: StateTone) }` (agent-colour disc with the tone's symbol; Task 29 swaps in the pup at the same 28 pt frame).
- Row: agent icon, badge, project in `TypeScale.headline`, status line in `body`, last action in `TypeScale.caption` with the monospaced design (11 pt, spec 6.5), one trailing button from `AgentRowAction`. `ExpandedPanel.tabIDs(widgets: WidgetRegistry, agentsVisible: Bool) -> [String]` (static) decides the tabs. Empty state: Platy 96, "No agents running", button "Connect an agent" → Settings › Agents. The permanent limits hint line is removed.
- Renders added: `agents-list`, `agents-empty` → `renders=50`.

- [ ] **Step 1: Write the failing tests**: `testRowsFollowAttentionOrder` (hosted view's row ids equal `AgentsOrder.sorted`), `testNoLimitsHintLine` (lint: `AgentsView.swift` has no `claudeLimitsHint` outside `UsageRings`), `testAgentsHiddenUntilConnected` (`ExpandedPanel.tabIDs` has no `agents` for a fresh `AgentsVisibility`; with `everConnected` it does), `testEmptyStateConnectCallsSettings`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.AgentsViewTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=50`.
- [ ] **Step 5: Commit** `feat(mac): Agents sorted by attention with usage rings and one action per row`

---

### Task 19: Richer approval cards and "Show changes"

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Views/ApprovalDiffBox.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/ApprovalCard.swift` (`preview` parameter), `apps/mac/Sources/PlatyNotchUI/Views/ExpandedPanel.swift` (`ApprovalList` passes previews), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`ApprovalPeek`: "Show changes" link), `Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/ApprovalPreviewCardTests.swift`

**Interfaces:**
- Consumes: `ApprovalPreview` (Task 17).
- Produces: `ApprovalCard(…, preview: ApprovalPreview? = nil, cards: Int = 1)`; `struct ApprovalDiffBox: View { init(preview: ApprovalPreview, cards: Int) }`: full command, path, then a box exactly `boxLines × Theme.monoLineHeight` tall that scrolls inside itself; first the 12 collapsed lines, "Show all" reveals the rest inside the same box (the box and the card never change height). Added lines `+` in done colour, removed `−` in error colour, both with the sign. The 420×236 peek keeps today's summary and shows a "Show changes" link (when `diff` is not empty) that calls `onExpand`; peek size and arming are unchanged.
- Render added: `approval-card-diff` → `renders=52`.

- [ ] **Step 1: Write the failing tests**: `testShowAllNeverChangesCardHeight` (hosted card with a 300-line diff: `fittingSize.height` collapsed == expanded == with a 12-line diff), `testNoPreviewInPeek` (`ApprovalPeek` builds its card without `preview`), `testShowChangesOnlyWithDiff`, `testDiffSignsNotColourOnly` (rendered line texts start with "+" / "−").
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.ApprovalPreviewCardTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` incl. `ApprovalSafetyTests`, `ApprovalArmingControllerTests`, `ApprovalResponderTests` → PASS; the smoke recipe → `renders=52`; the approval peek end-to-end block in `scripts/verify-panel.md` → `SMOKE OK panels=1 mode=peek(approval)`.
- [ ] **Step 5: Commit** `feat(mac): approval cards show the full command, path and a diff that never moves`

---

## Phase 5: Library, tools and moving the tabs

### Task 20: Library model and panel routes

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Library/LibraryModel.swift`, `apps/mac/Sources/PlatyNotchKit/Library/PanelRoute.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/LibraryModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct LibraryItem: Identifiable, Equatable, Sendable { public let id: String; public let title: String; public let systemImage: String
      public let liveLine: String?; public let isSetUp: Bool
      public init(id: String, title: String, systemImage: String, liveLine: String?, isSetUp: Bool) }
  public struct LibraryRecents: Codable, Equatable, Sendable { public static let key = "library.recents"; public init()
      public mutating func noteOpened(_ id: String, at: Date); public static func load(from: UserDefaults) -> LibraryRecents; public func save(to: UserDefaults) }
  public enum LibraryOrder { public static func sorted(_ items: [LibraryItem], recents: LibraryRecents) -> [LibraryItem] }   // used most recently first; never used keep input order after them
  public enum LibraryTools { public static let memory = "memory"; public static let chase = "games.chase"; public static func plugin(_ tabID: String) -> String /* "plugin:<id>" */ }
  public enum PanelDestination: String, CaseIterable, Sendable { case now, agents, library }
  public struct PanelRoute: Equatable, Sendable { public var destination: PanelDestination; public var tool: String?; public init(destination:tool:)
      public static func legacy(tab: String, tools: Set<String>) -> PanelRoute   // today→now, agents→agents, focus/memory/games→library tool, known tool or plugin:<id>→library tool, else now
      public func normalized(agentsVisible: Bool) -> PanelRoute                // agents → now while hidden
      public func back() -> PanelRoute }                                       // tool → grid
  ```
- Input order (built by the UI, Task 21): widget tools in the user's widget order, "Platy Chase" right after Games, then Memory, then plugin tabs in plugin order.

- [ ] **Step 1: Write the failing tests**: `testRecentlyUsedFirst`, `testNeverUsedKeepOrder`, `testRecentsPersist`, `testLegacyTabs` (`today` → `.now`; `agents` → `.agents`; `focus`, `memory`, `games` → `.library` with that tool), `testPluginTabRoutes` (`legacy(tab: "pro.stats", tools: ["plugin:pro.stats"])` → tool `plugin:pro.stats`), `testUnknownTabGoesToNow`, `testHiddenAgentsRouteFallsBack`, `testBackReturnsToGrid`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.LibraryModelTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mac): Library order and panel routes with legacy tab links`

---

### Task 21: Library grid, full-panel tools and three destinations

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Library/LibraryView.swift`, `Library/LibraryTile.swift`, `Library/ToolHost.swift`
- Delete: `apps/mac/Sources/PlatyNotchUI/Views/TodayTab.swift`'s `TodayTab` view (keep `TodayServices`, moved to `apps/mac/Sources/PlatyNotchUI/Now/TodayServices.swift`)
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/ExpandedPanel.swift` (nav: Now, Agents (when visible), Library; `selectedTab: String` → `route: PanelRoute`), `PanelRootView.swift` (`PanelViewModel.route`), `NotchController.swift` (`expand(tab:)` maps through `PanelRoute.legacy`), `Games/GamesWidget.swift` (`openTab` → library tool), `Games/Views/GamesTab.swift` (`selectPanelTab` → route), `Views/FocusTab.swift`, `Views/MemoryTab.swift` (hosted as tools), `NotchApp.swift` (plugin `panelTabs()` → Library tools), `Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/LibraryViewTests.swift`

**Interfaces:**
- Consumes: Task 20, Task 7 (`toolWidgets`, `libraryTile()`, `toolView()`, `runSetup`).
- Produces: `struct LibraryView: View { init(items: [LibraryItem], tile: (String) -> AnyView?, onOpen: (String) -> Void, onSetUp: (String) -> Void) }` — a 4-column grid (tile width (528 − 3×8)/4, `dsCard`, icon `IconSize.tile`, name, live line); a not-set-up tool (`hasContent == false`) shows dimmed with one "Set up" button; disabled widgets are not listed. `struct ToolHost: View { init(title: String, onBack: () -> Void, content: AnyView) }` — back chevron (VoiceOver "Back to Library"), full panel. Opening a tool calls `LibraryRecents.noteOpened`. Live line: `libraryTile()` when present, else the widget's top activity title. "Power" tags appear only in Settings.
- Renders added: `library-grid`, `library-tool-focus` → `renders=56`.

- [ ] **Step 1: Write the failing tests**: `testNavHasThreeDestinations` (`ExpandedPanel.destinations(agentsVisible:)`, replacing `tabIDs`: visible → now, agents, library; hidden → now, library), `testEveryOldTabHasAHome` (Focus, Memory, Games, Platy Chase and a fake plugin tab appear as Library items), `testLegacyExpandRoutes` (`expand(tab: "memory")` → route `.library` tool `memory`), `testDimmedTileOffersSetUp`, `testGridIsFourColumns`, `testDisabledWidgetsNotListed`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.LibraryViewTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` incl. `GamesWidgetTests` → PASS; the smoke recipe → `renders=56`, `games=` unchanged; `checkGameViews` still fits `GameLayout.tabSize` inside `ToolHost`.
- [ ] **Step 5: Commit** `feat(mac): Library grid with full-panel tools; Focus, Memory and Games move in`

---

## Phase 6: Settings, first run, migration and notifications

### Task 22: Notification policy and its gates

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Notifications/NotificationPolicy.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/PanelFeed.swift` (`allowNotice`), `apps/mac/Sources/PlatyNotchUI/Widgets/NotchWidget.swift` (`WidgetContext.peek(id:until:as:)`), `apps/mac/Sources/PlatyNotchUI/Widgets/PanelSurfaces.swift` (gate peeks and rings), `apps/mac/Sources/PlatyNotchUI/NotchController.swift` (notice gate), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`hiddenKinds` into `PillContent`), `Day/MeetingWidget.swift` (`as: .meetingStarting`), `System/SystemWidget.swift` (download peek `as: .other`), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (needs-input notice)
- Test: `apps/mac/Tests/PlatyNotchKitTests/NotificationPolicyTests.swift`, `apps/mac/Tests/PlatyNotchUITests/NotificationGateTests.swift`

**Interfaces:**
- Consumes: `NotificationKind` (Task 5), `PillContent` (Task 11).
- Produces:
  ```swift
  public enum NotificationField: Sendable { case showInPill, canOpen, quietDuringFocus }
  public struct NotificationRule: Codable, Equatable, Sendable { public var showInPill: Bool; public var canOpen: Bool; public var quietDuringFocus: Bool
      public init(showInPill: Bool, canOpen: Bool, quietDuringFocus: Bool) }
  public struct NotificationPolicy: Codable, Equatable, Sendable { public static let key = "notifications.policy"; public static let standard: NotificationPolicy; public init()
      public subscript(kind: NotificationKind) -> NotificationRule { get set }     // set leaves locked cells as they are
      public static func isLocked(_ kind: NotificationKind, _ field: NotificationField) -> Bool
      public func mayOpen(_ kind: NotificationKind, focusActive: Bool) -> Bool  // canOpen && !(quietDuringFocus && focusActive)
      public var hiddenInPill: Set<NotificationKind>
      public static func kind(noticeKind: String) -> NotificationKind?          // session-done → agentFinished; session-failed, approval-timeout, needs-input → agentNeedsYou; else nil
      public static func load(from: UserDefaults) -> NotificationPolicy; public func save(to: UserDefaults) }
  // PanelFeed: update(approvalCount:noticeSequence:holdNotices:allowNotice: Bool = true)
  // WidgetContext: @discardableResult func peek(id: String, until: Date, as kind: NotificationKind?) -> Bool   // nil = not governed (today's behaviour)
  ```
- Defaults (show in pill / can open / quiet during Focus): approval on/on/no, all three locked; agentNeedsYou on/on/no; agentFinished on/on/yes; ringing on/on/no; meetingStarting on/on/yes; other on/off/yes.
- Gates: store notices peek only when `mayOpen(kind(noticeKind))` (ungoverned `info` notices keep today's focus hold); a governed widget peek is dropped when `!mayOpen`; a ring with `!mayOpen(.ringing)` still rings (sound, menu bar "Stop") but sends no `.ringStarted` to panels, so the pill and the hero show it; approvals are never gated. When a session enters `.waitingInput`, the app posts a local notice of kind `needs-input` ("\(agentName) needs your input", body = project).

- [ ] **Step 1: Write the failing tests**: Kit `testDefaultsTable` (all six rows), `testApprovalCellsLocked` (setting `policy[.approval] = NotificationRule(showInPill: false, canOpen: false, quietDuringFocus: true)` leaves on/on/no), `testQuietDuringFocus` (`mayOpen(.agentFinished, focusActive: true) == false`, `mayOpen(.agentNeedsYou, focusActive: true) == true`), `testNoticeKinds`, `testRoundTrip`, `testFeedDropsDisallowedNotice` (`allowNotice: false` → no `.notice` event, sequence consumed); UI `testDownloadPeekOffByDefault` (download peek → false, nothing shown), `testMeetingReminderPeeks`, `testRingWithoutOpenStillRings` (`PanelSurfaces.ringing` contains the id, no sink got `.ring`), `testNeedsInputPostsNotice`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.NotificationPolicyTests` and `--filter PlatyNotchUITests.NotificationGateTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` incl. `PanelSurfacesTests`, `PanelFeedTests` → PASS; the smoke recipe → `SMOKE OK`.
- [ ] **Step 5: Commit** `feat(mac): per-kind notification policy: show in pill, can open, quiet during Focus`

---

### Task 23: Presets, first-run state and the upgrade

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Setup/SetupPreset.swift`, `apps/mac/Sources/PlatyNotchKit/Setup/FirstRun.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (runs `UpgradeMigration.run` once at launch before widgets start)
- Test: `apps/mac/Tests/PlatyNotchKitTests/SetupPresetTests.swift`

**Interfaces:**
- Consumes: `GlanceSlots` (Task 6), `AgentsVisibility` (Task 16), `AppearanceSettings` (Task 2).
- Produces:
  ```swift
  public enum SetupPreset: String, CaseIterable, Codable, Sendable { case everyday, developer, minimal
      public var turnsOn: [String]; public var turnsOff: [String]; public var glances: [String]; public var mode: AppearanceSettings.Mode; public var showsAgents: Bool }
  public struct PresetChange: Equatable, Sendable { public let turnOn: [String]; public let turnOff: [String]; public var needsConfirmation: Bool; public init(turnOn:turnOff:)
      public static func plan(_ p: SetupPreset, enabled: Set<String>) -> PresetChange }   // only ids that change
  public enum FirstRunState: Equatable, Sendable { case firstRun, offerTour, settled
      public static let tourOfferedKey = "tour.offered"
      public static func resolve(onboardingDone: Bool, hasSavedLayout: Bool, tourOffered: Bool) -> FirstRunState }
  public struct OnboardingFlow: Equatable, Sendable { public enum Page: Int, CaseIterable, Sendable { case meetPlaty, pickSetup, permissions, tryIt }
      public let pages: [Page]; public init(pages:); public static let firstRun: OnboardingFlow; public static let tour: OnboardingFlow }   // tour = meetPlaty, permissions, tryIt
  public enum UpgradeMigration { public static let key = "ui.redesign.migrated"
      public static func run(defaults: UserDefaults, existingUser: Bool, glanceCapable: [String]) }   // idempotent
  ```
- Presets: everyday on `music, meeting, time, weather, shelf, clipboard`, off `fileActions, snap`, glances `meeting, weather, system, loops`, mode `.alwaysOn`, agents not forced; developer on everyday's + `fileActions, snap`, off none, glances `meeting, agents.usage, weather, system`, `.alwaysOn`, agents shown; minimal on `music`, off every other built-in id (`meeting, focus, loops, time, hud, shelf, clipboard, reminders, weather, wellbeing, system, games, launch, baskets, fileActions, mail, notes, mirror, snap`), glances `agents.usage`, mode `.minimal`, agents shown. Plugin widgets are never touched.
- `FirstRunState`: `.firstRun` when neither onboarding is done nor a widget layout is saved; `.offerTour` for an existing user until `tour.offered`; else `.settled`.
- Migration for an existing user: `widgets.layout` untouched; `AgentsVisibility.everConnected = true`; `GlanceSlots.defaults(glanceCapable:)` saved when no slots are saved; appearance kept (motion mapped by Task 2's decoder). New users: nothing written.

- [ ] **Step 1: Write the failing tests**: `testPresetContents` (the three lists exactly), `testPlanOnlyChanges`, `testMinimalNeedsConfirmation`, `testPresetsNeverTouchPlugins`, `testFirstRunStates`, `testTourSkipsPresets`, `testExistingUserKeepsWidgets` (layout data byte-identical), `testExistingUserKeepsAgents`, `testMigrationIdempotent`, `testNewUserWritesNothing`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.SetupPresetTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(mac): setup presets, first-run state and a non-destructive upgrade`

---

### Task 24: Settings sidebar, routes, General and Notch pages

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Setup/SettingsRoute.swift`, `apps/mac/Sources/PlatyNotchUI/Settings/GeneralSection.swift`, `Settings/NotchSection.swift` (replaces `AppearanceSection.swift`), `Settings/NotchPreview.swift`, `Settings/InfoButton.swift`
- Delete: `apps/mac/Sources/PlatyNotchUI/Settings/AppearanceSection.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Settings/SettingsWindow.swift` (sidebar, `show(section:)` via `SettingsTarget.resolve`), `Settings/AgentsSection.swift` (Approvals and Policy as sub-pages), `apps/mac/Sources/PlatyNotchKit/SettingsLogic.swift` (`AppURL.settings` keeps the whole path, "widgets/music"), `Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/SettingsRouteTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SettingsPage: String, CaseIterable, Sendable { case general, notch, now, notifications, widgets, agents, memory, privacy, about; public var title: String; public var systemImage: String }
  public struct SettingsTarget: Equatable, Sendable { public var section: String; public var detail: String?; public init(section:detail:)
      public static func resolve(_ id: String?) -> SettingsTarget }   // appearance→notch, permissions→privacy, approvals→agents/approvals, policy→agents/policy, "widgets/<id>"→widgets/<id>, unknown (plugin) passes through
  // UI
  struct InfoButton: View { init(_ text: String) }   // ⓘ with a popover
  struct NotchPreview: View { init(appearance: AppearanceSettings) }   // live pill + scaled Now with sample data
  ```
- Sidebar (titles): General, Notch, Widgets, Agents, Memory, Privacy & Permissions, About, then plugin sections under "Extensions"; Now and Notifications join in Task 25. General: launch at login (moved from Appearance), updates, "Take the tour again". Notch: live preview on top, then Minimal vs Always on, Open on (hover / click / peek on hover), hover delay, pill width, live side, displays, hide in full screen, theme, surface (Glass disabled before macOS 26 with an ⓘ saying so), Show Platy, Motion. Controls first; explanations move into `InfoButton`s. Privacy & Permissions hosts today's `PermissionsSection` until Task 26.
- Render added: `settings-notch-preview` → `renders=58`.

- [ ] **Step 1: Write the failing tests**: `testLegacySections` (each mapping above), `testWidgetDetail`, `testPluginSectionPassesThrough`, `testAppURLKeepsPath` (`platynotch://settings/widgets/music` → `.settings(section: "widgets/music")`, `platynotch://settings` → `.settings(section: nil)`).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.SettingsRouteTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=58`, `SMOKE SETTINGS OK sections=7 onboarding=3` and config.json unchanged.
- [ ] **Step 5: Commit** `feat(mac): Settings sidebar with General and Notch pages and a live preview`

---

### Task 25: Now and Notifications settings pages

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Settings/NowSection.swift`, `Settings/NotificationsSection.swift`
- Modify: `Settings/SettingsWindow.swift`, `apps/mac/Sources/PlatyNotchKit/Now/HeroDeck.swift` (`NowSettings`)
- Test: `apps/mac/Tests/PlatyNotchUITests/NowNotificationsSettingsTests.swift`

**Interfaces:**
- Consumes: `GlanceSlots` (Task 6), `NotificationPolicy` (Task 22).
- Produces: `public struct NowSettings: Codable, Equatable, Sendable { public static let key = "now.settings"; public var heroCycling: Bool /* true */; public init(heroCycling:) }` (off: the hero shows only the top item, no ‹ ›). Now page: four slot pickers (glance-capable widgets with their status, plus "Claude/Codex usage"), ordered by drag handle only, hero cycling toggle. Notifications page: one row per `NotificationKind` (titles "Approvals", "Agent needs you or stopped", "Agent finished", "Alarms and timers", "Meeting starting", "Everything else") with three toggles; locked cells are disabled and show "Always" / "Never" with an ⓘ "Approvals always show and can always open the notch".
- `SMOKE SETTINGS` sections become 9.

- [ ] **Step 1: Write the failing tests**: `testSlotPickerWritesSlots` (choosing four ids saves `GlanceSlots` in that order), `testLockedApprovalToggles` (the view model refuses to change approval cells), `testHeroCyclingOffHidesArrows` (NowView with `heroCycling: false` builds `HeroFrame` with `onStep == nil`).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.NowNotificationsSettingsTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE SETTINGS OK sections=9 onboarding=3`.
- [ ] **Step 5: Commit** `feat(mac): Settings › Now and Settings › Notifications`

---

### Task 26: Widgets grid, detail pages and the permission table

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Setup/PermissionTable.swift`, `apps/mac/Sources/PlatyNotchUI/Settings/WidgetCard.swift`, `Settings/WidgetDetail.swift`, `Settings/PermissionTableView.swift`
- Modify: `Settings/WidgetsSection.swift` (grid with All / Everyday / Power filters; drag to reorder, chevrons removed), `Settings/PermissionsSection.swift` (the table on top, today's rows as detail), `Settings/SettingsWindow.swift` (`widgets/<id>` opens the detail)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PermissionTableTests.swift`, `apps/mac/Tests/PlatyNotchUITests/WidgetsSettingsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum PermissionID: String, CaseIterable, Sendable { case accessibility, calendars, reminders, automation, camera, notifications, bluetooth }
  public struct PermissionRow: Identifiable, Equatable, Sendable { public let id: PermissionID; public let title: String; public let powers: String; public let withoutIt: String
      public init(id: PermissionID, title: String, powers: String, withoutIt: String) }
  public enum PermissionTable { public static let rows: [PermissionRow] }   // one row per PermissionID, in that order, all three strings non-empty
  ```
- Copy is one plain sentence each, naming the features from `Permissions.swift`'s current explanations (e.g. calendars: powers "Next meeting, Join buttons and meeting reminders", without it "No meetings in Now or the pill"). Each row has one "Allow" button that calls the existing `Permissions` request for it; nothing is asked without a click.
- Empty states elsewhere deep-link here with one button: `MemoryTab` ("Set up memory" → `memory`), `LoopsList` (→ `memory`), the Library's dimmed tiles (→ `widgets/<id>`), Agents' empty state (→ `agents`).
- Widget card: icon, title, on/off switch, a "Power" tag for `.power`; click opens `WidgetDetail` (the widget's `settingsView()` as a page with a back button), not a stacked GroupBox.

- [ ] **Step 1: Write the failing tests**: Kit `testEveryPermissionHasARow`, `testCopyNotEmpty`; UI `testFiltersSplitCategories`, `testDetailDeepLink` (`show(section: "widgets/music")` selects widgets with detail "music"), `testNoChevronControls` (lint: `WidgetsSection.swift` has no `chevron.up`/`chevron.down`).
- [ ] **Step 2: Run** both filters → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE SETTINGS OK sections=9 onboarding=3`, config.json unchanged.
- [ ] **Step 5: Commit** `feat(mac): Widgets as a grid with detail pages; Privacy & Permissions table`

---

### Task 27: First run and the tour

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchUI/Onboarding/OnboardingWindow.swift` (four pages from `OnboardingFlow`; `pageCount` 4; tour mode), `apps/mac/Sources/PlatyNotchUI/Settings/SettingsWindow.swift` (`SettingsServices.demoNotch`, `armTryIt`, `applyPreset`), `apps/mac/Sources/PlatyNotchUI/NotchController.swift` (`onExpanded` callback), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`PanelViewModel.tourSample: LiveActivity?`), `apps/mac/Sources/PlatyNotchUI/Now/NowView.swift` (tour card in the quiet line's place), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (no forced first run for existing users)
- Test: `apps/mac/Tests/PlatyNotchUITests/OnboardingFlowTests.swift`

**Interfaces:**
- Consumes: `OnboardingFlow`, `FirstRunState`, `SetupPreset`, `PresetChange` (Task 23); `PermissionTable` (Task 26); `PlatyMoodModel.celebrate()`.
- Produces: `SettingsServices.applyPreset(_ p: SetupPreset)` (calls `WidgetRegistry.setEnabled` for `plan(_:enabled:)`, saves `GlanceSlots(ids: p.glances)`, sets `AppearanceSettings.mode`, sets `AgentsVisibility.forcedOn` when `showsAgents`); `demoNotch()`; `armTryIt(onDone: @escaping () -> Void)`. Settings › General "Take the tour again" replays the full first run (four pages).
- Pages: Meet Platy (Platy 120 waving; calls `demoNotch()` once: expand, then collapse after 1.2 s); Pick your setup (three cards; first run applies the preset directly; the tour never shows this page; from Settings a preset with `needsConfirmation` lists what turns off and asks); Permissions (the table, every row optional); Try it ("Move your pointer to the notch": `armTryIt` sets `tourSample` to a sample hero titled "This is Now" and waits for `onExpanded`, then Platy celebrates and Done appears). Every page has Skip. Existing users get a one-time card in Now, "Take the 30-second tour" with Dismiss, 44 pt in the quiet line's place, until taken or dismissed (`tour.offered`).
- `SMOKE SETTINGS` onboarding becomes 4.

- [ ] **Step 1: Write the failing tests**: `testFirstRunHasFourPages`, `testTourHasThreePages`, `testExistingUserNotForced` (launch decision with the onboarding marker present → no window, tour card shown), `testTryItCompletesOnExpand` (fake controller fires `onExpanded` → `tourSample == nil`, finished), `testSamplesNeverDuringApproval` (`tourSample` is ignored by `NowMode` while approvals are pending).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.OnboardingFlowTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE SETTINGS OK sections=9 onboarding=4`; manual: a fresh `PLATYNOTCH_HOME` reaches "Try it" in under 60 s.
- [ ] **Step 5: Commit** `feat(mac): four-screen first run and a 30-second tour for existing users`

---

## Phase 7: Platy, moments, sound and showcase

### Task 28: Pond scene for Now's idle hero

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Mascot/PondScene.swift`, `apps/mac/Sources/PlatyNotchUI/Now/PondSceneView.swift`
- Modify: `Now/TodaySummaryHero.swift`, `Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/PondSceneTests.swift`, `apps/mac/Tests/PlatyNotchUITests/PondSceneViewTests.swift`

**Interfaces:**
- Produces: `public enum PondPhase: String, CaseIterable, Sendable { case morning, day, evening, night; public static func at(hour: Int) -> PondPhase; public var sky: (top: RGB, bottom: RGB); public var water: RGB; public var stars: Bool }` (morning 5..<11, day 11..<17, evening 17..<21, night otherwise; base tint `Brand.pond`, cream glow on the idle hero); `final class PondSceneNSView: NSView { func configure(phase: PondPhase, animates: Bool); var isAnimating: Bool }` — CAGradientLayer sky, water layer, star layers at night, one 4 s ripple animation only while `animates` (`panelTicking && mode == .expanded && !reduceMotion`), otherwise still.
- Renders added: `now-pond-morning`, `now-pond-evening`, `now-pond-night` → `renders=64`.

- [ ] **Step 1: Write the failing tests**: Kit `testPhaseBands` (4 → night, 5 → morning, 11 → day, 17 → evening, 21 → night), `testStarsOnlyAtNight`, `testGreetingReadableOnPond` (white and cream ≥ 4.5 on every phase's water and sky bottom); UI `testStillWhenCollapsed`, `testStillUnderReduceMotion`, `testAnimatesWhenOpen`.
- [ ] **Step 2: Run** both filters → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=64`; `scripts/perf-idle.sh` → PASS.
- [ ] **Step 5: Commit** `feat(mac): Platy's pond follows the time of day in Now`

---

### Task 29: Agent pups

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyPup.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyArt.swift` (bandana), `apps/mac/Sources/PlatyNotchUI/Agents/AgentRow.swift` (pup replaces `AgentBadge` in the same 28 pt frame), `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyRenders.swift` (gallery adds `pup-<agent>.png`)
- Test: extend `apps/mac/Tests/PlatyNotchUITests/PlatyTests.swift`

**Interfaces:**
- Consumes: `AgentIdentity.rgb(dark:)` (Task 1), `StateTone` (Task 1).
- Produces: `struct PlatyPupView: View { init(agent: AgentIdentity, tone: StateTone, size: CGFloat) }` — a small Platy with a bandana in the agent colour and a state ring with the tone's symbol; a still image cached per (agent, tone, size, scale), never animated.

- [ ] **Step 1: Write the failing tests**: `testPupForEveryAgentAndTone` (25 images render, non-nil), `testPupsAreCached` (second render returns the same `CGImage` instance), `testGalleryIncludesPups` (`writeGallery` count rises by 5).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.PlatyTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=64` (agents-list now shows pups); `--platy-gallery /tmp/pn-gallery` → five pup PNGs.
- [ ] **Step 5: Commit** `feat(mac): a Platy pup in each agent's colour`

---

### Task 30: Moments

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Mascot/Moments.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Mascot/PlatyMood.swift` (`PlatyMoodFlags.celebrationLength` 4 → 2), `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyMoodModel.swift` (`celebrate(_ event: MomentEvent, approvalsPending: Int)`), `apps/mac/Sources/PlatyNotchUI/FocusModel.swift` (`onComplete`), `apps/mac/Sources/PlatyNotchUI/Widgets/BuiltIn/LoopsWidget.swift` (games `onNewBest` and focus `onComplete` wiring), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (all-finished watch)
- Test: `apps/mac/Tests/PlatyNotchKitTests/MomentsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum MomentEvent: Hashable, Sendable { case allAgentsFinished(at: Date), newBest(game: String, score: Int), focusComplete(endedAt: Date) }
  public struct MomentGate: Sendable { public static let maxDuration: TimeInterval /* 2 */; public init()
      public mutating func admit(_ e: MomentEvent, approvalsPending: Int) -> Bool }   // each event at most once; never while an approval is pending (dropped, not queued)
  public struct AllFinishedWatch: Sendable { public init(); public mutating func update(_ sessions: [Session]) -> Bool }   // true when the last working session finishes and none works or needs you
  ```

- [ ] **Step 1: Write the failing tests**: `testOncePerEvent`, `testNeverDuringApproval`, `testCelebrationIsTwoSeconds` (`PlatyMoodFlags.celebrationLength == 2`, `MomentGate.maxDuration == 2`), `testAllFinishedOnlyWhenLastOneEnds` (two active → one idle: false; both idle: true; first call: false).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.MomentsTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` incl. `PlatyMoodTests` → PASS.
- [ ] **Step 5: Commit** `feat(mac): two-second moments when agents finish, a best score or a focus session`

---

### Task 31: Optional "plip" when an agent needs you

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Agents/PlipPolicy.swift`, `apps/mac/Sources/PlatyNotchUI/Agents/PlipPlayer.swift`, `apps/mac/Sources/PlatyNotchUI/Resources/Sounds/plip.wav` (generated)
- Modify: `scripts/make-sounds.py` (a soft 120 ms plip), `apps/mac/Sources/PlatyNotchUI/UIResources.swift` (`CueSound.plip`), `apps/mac/Sources/PlatyNotchUI/Settings/AgentsSection.swift` (toggle, off by default), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (smoke counts cue sounds)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PlipPolicyTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum PlipPolicy { public static let key = "agents.plipSound"   // Bool, default false
      public static func shouldPlay(enabled: Bool, session: Session, frontmostBundleID: String?, isRunning: (String) -> Bool) -> Bool }
  public struct NeedsYouWatch: Sendable { public init(); public mutating func update(_ sessions: [Session]) -> [String] }   // keys that just entered blocked / waitingInput; first call returns []
  // UI: enum CueSound: String, CaseIterable { case plip }
  ```
- Muted when the session's terminal is frontmost: `TerminalApps.target(termProgram:isRunning:)` gives the bundle id (Apple Terminal, iTerm, `activate(id)`); for `.pidAncestry` it is muted when any of `TerminalApps.knownTerminalIDs` is frontmost.
- `--smoke` prints `sounds=3`.

- [ ] **Step 1: Write the failing tests**: `testOffByDefault`, `testMutedWhenItsTerminalIsFrontmost` (iTerm session, frontmost `com.googlecode.iterm2` → false; frontmost Safari → true), `testUnknownTerminalMutedByAnyKnownTerminal`, `testNeedsYouWatchFiresOnEntry`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PlipPolicyTests` → FAIL.
- [ ] **Step 3: Implement**; `python3 scripts/make-sounds.py` writes `plip.wav`.
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `sounds=3`.
- [ ] **Step 5: Commit** `feat(mac): optional soft sound when an agent needs you`

---

### Task 32: Showcase renders, recording script and README header

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Smoke/ShowcaseRenders.swift`, `docs/showcase/recording-script.md`, `docs/assets/showcase/*.png` (10 files)
- Modify: `apps/mac/Sources/PlatyNotchKit/LaunchOptions.swift` (`renderShowcaseDir` from `--render-showcase <dir>`), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (report and exit like `--platy-gallery`), `README.md` (header image), `scripts/verify-widgets.md` (how to regenerate)
- Test: extend `apps/mac/Tests/PlatyNotchKitTests/LaunchOptionsTests.swift`; add `apps/mac/Tests/PlatyNotchUITests/ShowcaseRendersTests.swift`

**Interfaces:**
- Consumes: every view above with inert models.
- Produces: `LaunchOptions.renderShowcaseDir: String?`; `enum ShowcaseRenders { static func write(to: URL) -> Result<Int, ThemeRenders.RenderError> }` — five scenes at 2× the full 560×380 panel including the black notch band: `now-music`, `now-agent`, `approval-diff`, `library`, `platy-idle`, each `-dark`/`-light`; prints `SHOWCASE OK renders=10`. The README header is `docs/assets/showcase/now-agent-dark.png`. The recording script covers the 20-second storyboard (notch idle → agent starts → Platy paddles → approval peeks → Approve → done moment → music takes over) with the `scripts/fake-events.sh` commands that drive each beat. The website hero uses these files; it lives outside this repo.

- [ ] **Step 1: Write the failing tests**: `testShowcaseFlag` (`--render-showcase /tmp/s` → `"/tmp/s"`; `--render-showcase --smoke` → nil), `testShowcaseWritesTen` (to a temp dir: 10 PNGs, each 1120×760 or larger).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.ShowcaseRendersTests` → FAIL.
- [ ] **Step 3: Implement**; run `.build/debug/PlatyNotch --render-showcase "$WT/docs/assets/showcase"`.
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the full smoke recipe (`renders=64`, `sections=9 onboarding=4`, `widgets=6`, `sounds=3`); `scripts/perf-idle.sh` and `--state music` → PASS; manual on a real MacBook with everything on: Now shows at most one hero, four glances and one quiet line, nothing scrolls.
- [ ] **Step 5: Commit** `docs: showcase renders, recording script and README header`
