# PlatyNotch UI/UX redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Present every existing feature through three destinations (Now, Agents, Library), one priority model, one visual system and Platy as the status signal, without adding features or touching the core, protocol or approval semantics.

**Architecture:** Every decision that can be pure lives in `PlatyNotchKit` with unit tests: tokens, motion presets, live ranks, one session classifier and one session-transition tracker, the Now model, pill content, approval previews, Library order and routes, notification policy, presets, first-run state, day phases, moments and the plip rule. `PlatyNotchUI` turns those into SwiftUI/AppKit views behind thin seams, checked by fit tests, render PNGs (`PLATYNOTCH_RENDER_DIR`) and the three smoke runs. The public widget and plugin API only gains members that have defaults, and every internal API a task changes keeps its old form as a wrapper.

**Tech Stack:** Swift 6, SwiftPM (`apps/mac`, macOS 15+), SwiftUI, AppKit, Core Animation, XCTest; Python (`scripts/make-sounds.py`) for the one new sound.

**Spec:** `docs/specs/2026-10-25-ui-redesign-design.md` (every section and every **[call]** is binding). Pre-flight findings this revision applies: `.superpowers/sdd/2026-10-25-ui-redesign/preflight.md`.

## Global Constraints

- Paths contain spaces. Every command starts from `WT="/Users/vaibhaav/Library/Application Support/Claude/scratch-workspaces/c03a99fb-b5e4-421a-a233-4b0358662113/25bab691-d493-4cd2-a69e-34dd9bd79c2d/scratch-2026-10-23-104f70/platynotch/.worktrees/ui-redesign"`, always quoted (`cd "$WT/apps/mac"`). Tasks run one at a time in this one worktree on branch `feat/ui-redesign`.
- Idle CPU under 1% collapsed (`scripts/perf-idle.sh`). Continuous animation only as Core Animation layers; SwiftUI timelines tick only while `\.panelTicking` is true. No animation over 2 seconds; no repeating animation while collapsed and idle, except the budgeted agent dots and Platy pill frames while live.
- No `isolated deinit` (CI greps for it); use a plain `deinit`.
- Completion-handler APIs go through an explicit `withCheckedContinuation` (CI greps for the generated async forms).
- CI type-checks with `-warn-long-expression-type-checking=300`: typed literals and typed locals, never mix `Double` and `CGFloat` in one expression. Geometry tokens are `CGFloat`; times and colour components are `Double`.
- Swift validity: a stored property never goes in an `extension`. New stored members go in the type body; for `AppearanceSettings` that also means its `CodingKeys`, its `init(from:)` (missing key → default or migration) and its memberwise init (new parameter with a default). Members shown below as `extension X { … }` are computed properties or methods only.
- New test classes subclass `DefaultsTestCase` (Kit: `Tests/PlatyNotchKitTests/DefaultsTestCase.swift`, UI: `Tests/PlatyNotchUITests/DefaultsTestCase.swift`) and get storage from `defaults()`. UI logic sits behind seams (Kit functions or injected closures), never behind a live window. No test only re-asserts a constant: token values are checked by one golden-table test; everything else tests behaviour. No wall-clock timing assertions.
- Approval safety unchanged: `ApprovalArming.delay` 0.7 s, an approval never moves under the cursor, never hidden, Return never answers, hidden characters stay visible (`SummarySanitizer`), approvals win over every other surface. `ApprovalSafetyTests` and `ApprovalArmingControllerTests` pass **unchanged** after every task.
- Every Kit type is `public` with a `public init` (structs) and is `Sendable`.
- `NotchWidget`, `NotchPlugin`, `WidgetContext`, `PanelTab`, `LiveActivity` change only additively: new members carry defaults, new init parameters carry default values (spec 6.9). `PluginAPITests` keeps passing unchanged.
- Compatibility wrappers: when a task changes an internal API, the old form stays as a thin wrapper and its callers keep compiling: `BuiltinTab` ids and `NotchController.expand(tab: String)`, `AgentDotNSView.configure(color:pulses:)`, `PlatyMoodModel.celebrate()`, `Theme.surface(_ scheme:)`, `LiveEarFit(earWidth:hasTrailing:hasBubble:)`, `PlatyFinishWatch`, `WidgetContext.peek(id:until:)`.
- Shared logic is defined once: session classification is `AgentAttention` (Task 5); session changes come only from `SessionTransitions` (Task 5) through the app's one `AgentActivityModel` (Task 9); time-of-day bands for the greeting and the pond are `DayPhase` (Task 6).
- Fixed geometry from `PanelLayout`: expanded 560×380, peek 420×236. Hero, glances and nav fit 560×380 minus the notch inset with no scrolling.
- Text: nothing below 11 pt anywhere in `PlatyNotchUI`; `.caption`, `.caption2` and `.footnote` are 10 pt on macOS and count as below 11.
- Colour is never the only carrier of meaning: every state colour comes with an SF Symbol or a word. Light and dark themes, Reduce Motion and VoiceOver labels on every new control.
- Privacy: nothing runs and nothing is requested until enabled or clicked (album art, calendar, mail previews included). No new permission prompt paths.
- "Tab links" (spec 14) are the internal tab ids passed to `WidgetContext.openPanel(tab:)` and `NotchController.expand(tab:)`. No `platynotch://` host is added for tabs.
- Smoke recipe (referred to below as "the smoke recipe"), from `"$WT/apps/mac"`:
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
  Expected today: `SMOKE OK … sounds=2 … renders=24`, `SMOKE SETTINGS OK sections=8 onboarding=3`, `SMOKE-POWER OK widgets=6`. Each task that adds renders states the new `renders=` total (two PNGs, dark and light, per view).
- Tests: `cd "$WT/apps/mac" && swift test --filter <Target>.<Class>`; before each commit `swift test` (whole suite) passes.
- Commit rule: each task's **Files** block lists every file it creates, edits or deletes, existing test files included. From `"$WT"`, stage those paths by name, plus any existing test file the task had to update (name it in the commit body), then `git commit -m "<the message given>"`. Never `git add -A` or `git add .`.

## Review Focus

- Long titles everywhere (a 200-character project name, track title or event title) → hero, glance chips, Agents rows and the pill truncate with an ellipsis; ‹ ›, "2 of 3" and the primary control never leave the frame; Now still does not scroll (Task 9 `testHeroFitsWithLongTitle`, Task 12 `testTrailingNeverWiderThanEar`).
- A chosen glance whose widget is turned off, loses its data or whose plugin is not loaded → its chip disappears without leaving a gap or a ghost; turning it back on returns it to the same slot (Task 6 `testUnavailableGlanceKeepsItsSlot`).
- Sleep, clock changes and time-zone changes across the 10-minute windows (music paused, agent finished, failed) → after wake the expired item is gone at once, never shown with a negative or stale time (Task 5 `testWindowsExpireAcrossSleep`).
- Many sessions at once (12 sessions over four agents, one needing input) → the pill shows Platy, three dots and "+9" inside the ear; the Agents list puts the needs-you row first; Now shows one Agents hero (Task 11 `testTwelveSessions`, Task 16 `testTwelveSessionsNeedsYouFirst`).
- A plugin publishing a `LiveActivity` with an out-of-range priority (1000, −5), or peeking without a kind → it ranks in the nearest band, never outranks an approval, and its peek keeps today's behaviour (Task 5 `testPluginPriorityIsClamped`, Task 22 `testUndeclaredPluginPeekStillOpens`).

## Rulings

Decisions this plan records where the spec is silent or ambiguous; tasks implement them.

1. Tokens live in Kit (golden-table tested); UI reads them through a thin `DS` layer.
2. Light-theme variants for every state and agent colour (the spec's hexes fail 4.5:1 on the light surface); values in Task 1. The notch black is the existing `PanelPalette.darkSurface`; no second constant.
3. "Errored" comes from the core's `session-failed` notice and lasts until the session is active again or 10 minutes pass (the protocol has no error state).
4. Live items the spec does not rank: `minor` (keep-awake, low battery, mirror on, Chase in play) after music; `ambient` (shelf, charging, weather) only when nothing else is live, never the hero. Plugin priorities fall into the nearest band and never reach approval rank.
5. The hero deck has one entry per widget (its best item) plus one Agents entry. The compact "Now: …" line follows rank order, so a meeting in 8 minutes comes before music.
6. Glances never backfill; the quiet line is counts only (open loops, tasks), hidden at zero or when that count is a chosen glance. Usage is the app-provided glance `agents.usage`.
7. Glance widgets are also Library tools (their tiles stay reachable); a widget with no tile opens its settings view as its tool.
8. Notifications (spec 6.3 table, now including the [call] rows): wellbeing nudges and the AirPods peek are `reminder` (can open on, quiet during Focus); downloads and charging are `other` (can open off); a plugin peek uses its declared kind, and one with none is `pluginUndeclared` (can open on, quiet during Focus); user-triggered confirmations (clipboard "Copied", launch result, link confirm card) are not governed. Ringing with "can open" off still rings and stops from the menu bar.
9. Motion: Lively opens with the old default (0.42 / 0.78); every close is 0.35 / 1.0; no blur in any preset; Reduced is a 0.15 s ease.
10. The open panel is #0B0D0D with a pure-black band level with the camera housing; its side margin becomes 16, and `approvalSlot` uses 16 for `.expanded` and keeps 12 for `.peek(.approval)`.
11. The approval diff box has a fixed height (8 rows with one card, 4 with several) and scrolls inside itself; it starts with the first 12 diff lines and "Show all" reveals the rest inside the same box.
12. Approvals and Policy settings become Agents sub-pages; legacy settings ids map; widget ordering is drag only.
13. Pups arrive in phase 7; phase 4 rows use an agent-colour badge in the same 28 pt frame.
14. Platy's done pose reuses `justFinished`: true for 4 s after a finish, or while an agent finished in the last 10 minutes and none is working or needs you.
15. The existing-user tour card sits at the top of Now and the quiet line hides while it shows.
16. The 11 pt floor re-sizes the pill's text constants (`PlatyEarFit.overflowLabel` 18 → 22, `LiveEarFit.minTrailing` 30 → 34); the ear widths in `PanelLayout` stay, so notch placement is unchanged.
17. **[call, coordinator]** Wellbeing nudges (water, stand, eyes) and the AirPods connect peek default to "can open the notch: on" and "quiet during Focus: yes"; the downloads peek stays "Everything else" (off); plugin peeks follow their declared kind, and a plugin with no kind is "Everything else" with can-open on. Recorded in spec 6.3.

---

## Phase 1: Foundation

### Task 1: Design tokens in Kit

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Design/DesignTokens.swift`, `apps/mac/Sources/PlatyNotchKit/Design/AgentIdentity.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Appearance/PanelPalette.swift` (add `panelDark`, `keylineAlpha`)
- Test: `apps/mac/Tests/PlatyNotchKitTests/DesignTokensTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct TypeStyle: Equatable, Sendable { public enum Weight: Sendable { case regular, medium, semibold }
      public let size: CGFloat; public let weight: Weight; public let rounded: Bool; public let mono: Bool
      public init(size: CGFloat, weight: Weight, rounded: Bool = false, mono: Bool = false) }
  public enum TypeScale { public static let display, title, headline, body, caption, mono: TypeStyle; public static let all: [TypeStyle]; public static let minimum: CGFloat }
  public enum Space { public static let xs, s, m, l, xl, xxl: CGFloat; public static let scale: [CGFloat]; public static let panelMargin: CGFloat; public static let heroPadding: CGFloat }
  public enum Radius { public static let chip, card, hero: CGFloat; public static let scale: [CGFloat]; public static func inner(outer: CGFloat, padding: CGFloat) -> CGFloat }
  public enum IconSize { public static let row, tile, hero: CGFloat }
  public enum Elevation: CaseIterable, Sendable { case surface, card }
  public enum Brand { public static let teal, cream, pond: RGB }
  public enum StateTone: String, CaseIterable, Sendable { case working, needsYou, error, done, idle
      public func rgb(dark: Bool) -> RGB; public var symbol: String; public var word: String }
  public enum AgentIdentity: String, CaseIterable, Sendable { case claude, codex, cursor, gemini, other
      public init(agent: String); public func rgb(dark: Bool) -> RGB }   // from Session.agent / Approval.agent
  // PanelPalette (enum, static lets in its body): panelDark = RGB(hex: 0x0B0D0D), keylineAlpha: Double = 0.08
  ```
- Values. Type: display 34 semibold rounded, title 20 semibold, headline 15 semibold, body 13 regular, caption 11 medium, mono 12 regular mono; minimum 11. Space 4 8 12 16 24 32, panelMargin 16, heroPadding 20. Radius chip 6, card 12, hero 20; `inner` = max(0, outer − padding). Icons row 15, tile 20, hero 28. Brand teal `0x2FB8A6`, cream `0xF2E6C9`, pond `0x1C3B4A`. States (dark / light): working `0x2FB8A6`/`0x0B6B5F`, needsYou `0xF5A524`/`0x845000`, error `0xF2685B`/`0xA3352B`, done `0x4CC38A`/`0x17693F`, idle `0x9AA0A6`/`0x585D62`. Agents: claude `0xE8833A`/`0x904410`, codex `0x3DBE7A`/`0x17693F`, cursor `0x5B9BF8`/`0x1F5BB8`, gemini `0xA987F5`/`0x6A3FC4`, other = working. Symbols/words: working `arrow.triangle.2.circlepath` "Working", needsYou `hand.raised.fill` "Needs you", error `exclamationmark.triangle.fill` "Error", done `checkmark.circle.fill` "Done", idle `moon.zzz.fill` "Idle". `AgentIdentity(agent:)`: `claude-code`, `claude` → claude; `codex` → codex; `cursor`, `cursor-agent` → cursor; `gemini`, `gemini-cli` → gemini; else other.

- [ ] **Step 1: Write the failing tests**
  - `testTokenGoldenTable`: one table of every value above (type styles, space, radius, icons, brand, state and agent hexes, symbols, words) compared in a single assertion loop.
  - `testRadiusInner`: `inner(outer: 20, padding: 20) == 0`, `inner(outer: 20, padding: 8) == 12`, `inner(outer: 6, padding: 8) == 0`.
  - `testColoursMeetContrast`: every StateTone and AgentIdentity dark value ≥ 4.5 on `panelDark`, on `panelDark.under(RGB(hex: 0xFFFFFF), alpha: PanelPalette.cardOverlay)` and on `darkSurface`; every light value ≥ 4.5 on `lightSurface` and `lightSurface.under(RGB(hex: 0x000000), alpha: PanelPalette.cardOverlay)`; teal ≥ 4.5 on `panelDark`; cream and white ≥ 4.5 on pond.
  - `testAgentIdentityMapping`: `claude-code` → `.claude`, `gemini-cli` → `.gemini`, `aider` → `.other`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.DesignTokensTests` → FAIL ("cannot find 'TypeScale' in scope").
- [ ] **Step 3: Implement** the interfaces with the listed values.
- [ ] **Step 4: Run** the filter → PASS; `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(mac): design tokens for type, space, radius, icons and state colours`

---

### Task 2: Motion presets replace the spring and blur sliders

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Design/MotionPreset.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Appearance/AppearanceSettings.swift` (stored `motion` in the struct body, `CodingKeys`, `init(from:)`, memberwise init), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`modeAnimation`; remove `morphBlur`/`settleBlur`), `apps/mac/Sources/PlatyNotchUI/Settings/AppearanceSection.swift` (Motion picker replaces the three sliders and "Reset motion")
- Test: `apps/mac/Tests/PlatyNotchKitTests/MotionPresetTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SpringSpec: Equatable, Sendable { public var response: Double; public var damping: Double; public init(response: Double, damping: Double) }
  public enum MotionDirection: Sendable { case open, close; public static func between(_ old: PanelMode, _ new: PanelMode) -> MotionDirection }
  public enum MotionPreset: String, Codable, CaseIterable, Sendable { case calm, lively, reduced
      public func spring(_ d: MotionDirection) -> SpringSpec?   // nil for .reduced
      public static let crossFade: Double = 0.2; public static let reducedFade: Double = 0.15 }
  // AppearanceSettings body: public var motion: MotionPreset = .calm
  extension AppearanceSettings { public func effectiveMotion(reduceMotion: Bool) -> MotionPreset }
  ```
- Values: calm open 0.38/0.86, close 0.35/1.0; lively open 0.42/0.78, close 0.35/1.0. `between`: open when `old` is `.hidden`/`.compact` and `new` is not, or `old` is a peek and `new` is `.expanded`; close otherwise. Decoding: no `motion` key → `spring == .standard ? .calm : .lively`. `spring` stays stored but no view reads it. `effectiveMotion(reduceMotion: true)` is `.reduced`.

- [ ] **Step 1: Write the failing tests**: `testOpenUsesOpenSpring` (calm `spring(.open)` = 0.38/0.86, lively = 0.42/0.78), `testCloseNeverOvershoots` (every non-nil close spring has damping 1.0), `testReducedCrossFades` (`spring(_)` nil for both directions), `testDirection` (compact→expanded open, expanded→compact close, peek(.approval)→expanded open, peek(.notice)→compact close), `testMigratesUntouchedSpringToCalm` (`{"spring":{"response":0.42,"dampingFraction":0.78,"blur":8}}` → `.calm`), `testMigratesChangedSpringToLively` (`"response":0.6` → `.lively`), `testSavedMotionWins` (`{"motion":"reduced"}`), `testRoundTripKeepsMotion`, `testReduceMotionOverrides`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.MotionPresetTests` → FAIL ("cannot find 'MotionPreset'").
- [ ] **Step 3: Implement.** `PanelRootView.modeAnimation` uses `.spring(response:dampingFraction:)` from `effectiveMotion(reduceMotion:).spring(MotionDirection.between(previous, model.mode))`, else `.easeOut(duration: MotionPreset.reducedFade)`; the previous mode is kept in `@State`. The Appearance section shows a segmented `Picker("Motion", …)`.
- [ ] **Step 4: Run** the filter → PASS; `swift test` (incl. `AppearanceTests`) → PASS; the smoke recipe → `SMOKE OK`, `SMOKE SETTINGS OK sections=8 onboarding=3`.
- [ ] **Step 5: Commit** `feat(mac): Calm, Lively and Reduced motion presets replace spring sliders`

---

### Task 3: UI token layer and the 11 pt floor

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Design/Tokens.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/Theme.swift` (`color(_ AgentTone)`, `nsColor(_:)`, `tint(_ LiveTint)` on the new palette); `apps/mac/Sources/PlatyNotchKit/Mascot/PlatyMood.swift` (`PlatyEarFit.overflowLabel` 18 → 22); `apps/mac/Sources/PlatyNotchKit/Appearance/LiveEarFit.swift` (`minTrailing` 30 → 34); every offender the lint lists today (74 literal sizes below 11 and 58 uses of the 10 pt styles) in `Shelf/Views/ShelfTile.swift`, `Views/MemoryTab.swift`, `Views/CompactPill.swift`, `Views/MemoryGraphView.swift`, `Notes/NotesWidget.swift`, `Views/UsageBar.swift`, `Games/Views/ChaseView.swift`, `Day/Views/RemindersTile.swift`, `Views/MusicTile.swift`, `Views/LoopsList.swift`, `Views/ApprovalCard.swift`, `Launch/Views/LaunchTile.swift`, `Games/Views/TetrisView.swift`, `Files/URLRoutes.swift`, `Day/Views/MeetingTile.swift`, `Clipboard/ClipboardWidget.swift`, `Clipboard/ClipPickerPanel.swift`, `Basket/BasketWindow.swift`, `Wellbeing/Views/NudgeCard.swift`, `Views/TimeTile.swift`, `Views/SurfaceViews.swift`, `Views/AgentsTab.swift`, `System/Views/SystemTile.swift`, `Mascot/PlatyRenders.swift`, `HUD/Views/HUDView.swift`, `Games/GamesWidget.swift`, `Files/BatchRenameDialog.swift`, `Day/Views/WeatherTile.swift`, `Basket/BasketSwitcher.swift`, and the `Settings/*.swift` and `Onboarding/OnboardingWindow.swift` files using `.caption`/`.footnote` (all under `apps/mac/Sources/PlatyNotchUI/`)
- Test: `apps/mac/Tests/PlatyNotchUITests/DesignLintTests.swift`; update `apps/mac/Tests/PlatyNotchKitTests/PlatyMoodTests.swift` (`testEarFitsPlatyAndDots`, `testPlatyShowsWithManySessionsAtEveryPillWidth`) and `apps/mac/Tests/PlatyNotchKitTests/AppearanceTests.swift` (the `LiveEarFit` cases) to the new constants

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
  extension StateTone { init(_ tone: AgentTone) }   // active→working, attention→needsYou, idle→idle, off→idle
  ```
- `LiveTint` maps neutral → label colour, accent → working, warning → needsYou, critical → error. Layout is unchanged except that text below 11 pt grows to 11 (`TypeScale.caption`); the pill's "+n" and countdown fit through the re-sized ear-fit constants (Ruling 16). `PanelLayout` ear and pill widths do not change.

- [ ] **Step 1: Write the failing tests** (`DesignLintTests`, scanning `Sources/PlatyNotchUI/**/*.swift` found from `#filePath`; comment lines skipped; each failure lists file:line):
  - `testNoLiteralFontBelowEleven`: regex `\.system\(size:\s*([0-9]+(?:\.[0-9]+)?)` with a value < 11.
  - `testNoTenPointTextStyles`: regexes `\.font\(\s*\.(caption2?|footnote)\b` and `\.system\(\s*\.(caption2?|footnote)\b` only (so `DS.font(TypeScale.caption)` never matches).
  - Both use `static let allowlist: [String: String]` (path → reason); it starts empty and an entry needs a reason string.
  - `testStateToneMapping`: all four `AgentTone` cases map as listed.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.DesignLintTests` → FAIL listing today's offenders.
- [ ] **Step 3: Implement** `DS`, replace each offender with `DS.font(TypeScale.caption)` (or the scale step for its role), re-size the two ear-fit constants and update the listed tests' expected widths.
- [ ] **Step 4: Run** the filter → PASS; `swift test` → PASS; the smoke recipe → `renders=24`; check the PNGs for clipped text.
- [ ] **Step 5: Commit** `feat(mac): UI token layer, new state palette, nothing below 11 pt`

---

### Task 4: One card style, the radius scale and the panel surface

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Design/CardStyle.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Appearance/AppearanceSettings.swift` (stored `surface` in the body, `CodingKeys`, decoder, memberwise init), `apps/mac/Sources/PlatyNotchKit/PanelLayout.swift` (`notchBand`), `apps/mac/Sources/PlatyNotchUI/Views/Theme.swift` (new `surface(_:mode:hasNotch:style:)` overload; `surface(_ scheme:)` stays), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (surface + band), `apps/mac/Sources/PlatyNotchUI/Settings/AppearanceSection.swift` (Surface picker), `apps/mac/Sources/PlatyNotchUI/Day/Views/MeetingTile.swift` (bar radius `height / 2`), and the tile containers using `RoundedRectangle(cornerRadius:` / `.cornerRadius(` literals in `Views/`, `Day/Views/`, `Shelf/Views/`, `System/Views/`, `Launch/Views/`, `Wellbeing/Views/`, `Clipboard/ClipboardWidget.swift`, `Notes/NotesWidget.swift`, `Views/ApprovalCard.swift` (under `apps/mac/Sources/PlatyNotchUI/`)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PanelSurfaceStyleTests.swift`; extend `apps/mac/Tests/PlatyNotchUITests/DesignLintTests.swift` and `apps/mac/Tests/PlatyNotchKitTests/AppearanceTests.swift` (palette contrast against `panelDark`)

**Interfaces:**
- Produces:
  ```swift
  // AppearanceSettings body: public enum SurfaceStyle: String, Codable, CaseIterable, Sendable { case opaque, glass }; public var surface: SurfaceStyle = .opaque
  extension AppearanceSettings { public func effectiveSurface(glassAvailable: Bool) -> SurfaceStyle }
  extension PanelLayout { public func notchBand(for mode: PanelMode) -> CGRect? }   // window-local, top-left origin
  // UI
  extension View { func dsCard(radius: CGFloat = Radius.card, keyline: Color? = nil) -> some View }
  ```
- Card: surface +1 step (`PanelPalette.cardOverlay` white over dark, black over light), 1 px inner keyline at `keylineAlpha` (white in dark, black in light) or the given tint, radius from the scale only. Plain list rows get no container.
- Surface: compact and hidden stay `PanelPalette.darkSurface` (#000, no gradient, glow or shadow). The open panel and peeks are `panelDark` in dark and `lightSurface` in light; with `.glass` on macOS 26 the system glass effect, otherwise opaque. `notchBand` is the top `anchor.height` of the content rect on a notched display for every mode except `.hidden`/`.compact` (nil without a notch), painted `darkSurface`.

- [ ] **Step 1: Write the failing tests**: `testGlassFallsBackWhenUnavailable`, `testMissingSurfaceKeyDecodesOpaque`, `testNotchBandOnNotch` (expanded on a notched 1512×982 sample: height == anchor.height, width == content width), `testNoNotchBandWithoutNotch`, `testNoNotchBandWhenCompact`; `AppearanceTests.testPaletteOnPanelDark` (`warningDark`, systemGreen allow tint ≥ 4.5 on `panelDark` and its card); lint `testTileContainersUseRadiusScale`: in the six tile directories, only `RoundedRectangle(cornerRadius: <literal>` and `.cornerRadius(<literal>)` are checked (not `Path(roundedRect:)`), the literal must be in {6, 12, 20}, with an allowlist (path:line → reason) for non-container shapes such as progress tracks.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PanelSurfaceStyleTests` and `--filter PlatyNotchUITests.DesignLintTests` → FAIL.
- [ ] **Step 3: Implement**: the Kit members, `dsCard`, the surface and band in `PanelRootView` (callers of `Theme.surface(_ scheme:)` in `ThemeRenders`, `GameRenders`, `GamesTab`, `MemoryGraphView` keep working unchanged), and move each tile container onto `dsCard`.
- [ ] **Step 4: Run** both filters → PASS; `swift test` → PASS; the smoke recipe → `renders=24`; only radius, keyline and surface differ in the renders.
- [ ] **Step 5: Commit** `feat(mac): one card style, radius scale, #0B0D0D panel with black notch band, optional glass`

---

## Phase 2: Priority model and Now

### Task 5: Live ranks, session classification and transitions

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Live/LiveRank.swift`, `apps/mac/Sources/PlatyNotchKit/Live/PriorityModel.swift`, `apps/mac/Sources/PlatyNotchKit/Live/AgentsLive.swift`, `apps/mac/Sources/PlatyNotchKit/Live/SessionTransitions.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Widgets/LiveActivity.swift` (stored `title`, `subtitle`, `startedAt` in the struct body, init parameters defaulting to nil; new `LivePriority` constants; stale "AgentsLive was removed" comments rewritten), `apps/mac/Sources/PlatyNotchKit/PanelFormat.swift` (`PillDots` ranks through `AgentAttention`), `apps/mac/Sources/PlatyNotchKit/Mascot/PlatyMood.swift` (`PlatyMoodResolver` reads needs-you/working through `AgentAttention`; `PlatyFinishWatch` becomes a wrapper over `SessionTransitions`; comment at line 94 updated)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PriorityModelTests.swift`, `apps/mac/Tests/PlatyNotchKitTests/SessionTransitionsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum LiveRank: Int, Comparable, CaseIterable, Sendable {   // spec 6.3 numbering; approvals are never a LiveItem
      case ringing = 2, meetingImminent, agentNeedsYou, agentFinished, timerRunning, meetingSoon, fileAction, agentsWorking, music, minor, ambient
      public init(activity: LiveActivity, now: Date); public var notificationKind: NotificationKind }
  public enum NotificationKind: String, Codable, CaseIterable, Sendable { case approval, agentNeedsYou, agentFinished, ringing, meetingStarting, reminder, other, pluginUndeclared }
  public enum AgentAttention: Int, Comparable, Sendable { case needsYou, errored, working, finished, idle, exited
      public init(state: SessionState)                                        // blocked/waitingInput → needsYou, active → working, idle → idle, exited → exited
      public static func of(_ s: Session, log: AgentFinishLog, now: Date) -> AgentAttention   // adds errored/finished from the log
      public var tone: StateTone }
  public enum AgentRowAction: Sendable { case answer, openTerminal; public init(_ a: AgentAttention); public var title: String }   // needsYou, errored → "Answer"; else "Open terminal"
  public struct SessionChanges: Equatable, Sendable { public let finished: [String]; public let enteredNeedsYou: [String]; public let allFinished: Bool
      public init(finished: [String], enteredNeedsYou: [String], allFinished: Bool) }
  public struct SessionTransitions: Sendable { public init()
      public mutating func update(_ sessions: [Session]) -> SessionChanges }   // first call only looks; finished = active → idle/exited (removal is not a finish); allFinished = something finished and nothing is working or needs you
  public struct AgentFinishLog: Equatable, Sendable { public static let window: TimeInterval = 600; public init()
      public mutating func record(_ c: SessionChanges, now: Date); public mutating func noteFailure(sessionKey: String, at: Date)
      public mutating func clearFailure(sessionKey: String)   // the session is active again
      public func lastFinish(now: Date) -> Date?; public func failed(_ key: String, now: Date) -> Bool; public func finished(_ key: String, now: Date) -> Bool }
  public enum LiveSource: Equatable, Sendable { case agents(AgentsLive), activity(LiveActivity) }
  public struct LiveItem: Identifiable, Equatable, Sendable { public let id: String; public let rank: LiveRank; public let source: LiveSource
      public let title: String; public let subtitle: String?; public let startedAt: Date?; public let countdownTo: Date?
      public init(id: String, rank: LiveRank, source: LiveSource, title: String, subtitle: String?, startedAt: Date?, countdownTo: Date?) }
  public enum PriorityModel { public static func rank(_ activities: [LiveActivity], agents: AgentsLive?, now: Date) -> [LiveItem] }
  public struct AgentsLive: Equatable, Sendable { public let rank: LiveRank; public let title: String; public let subtitle: String?; public let startedAt: Date
      public let needsYou: Int; public let working: Int; public let total: Int
      public init(rank: LiveRank, title: String, subtitle: String?, startedAt: Date, needsYou: Int, working: Int, total: Int)
      public static func make(sessions: [Session], log: AgentFinishLog, now: Date) -> AgentsLive? }
  // LivePriority additions: fileAction = 26, panelActivity = 23
  ```
- Bands for `LiveRank(activity:now:)` (plugin priorities are clamped into them): ≥ 90 → ringing; 80…89 → agentNeedsYou; 70…79 → meetingImminent when `countdownTo` is at most 120 s away, else meetingSoon; 50…69 → timerRunning; 40…49 → music; 30…39 → agentsWorking; 25…29 → fileAction; 11…24 → minor; ≤ 10 → ambient. Expired activities are dropped.
- `notificationKind`: ringing → `.ringing`; meetingImminent, meetingSoon → `.meetingStarting`; agentNeedsYou → `.agentNeedsYou`; agentFinished → `.agentFinished`; the rest → `.other`.
- `AgentsLive.make` uses `AgentAttention.of` for every session: rank agentNeedsYou when any is needsYou or errored; else agentsWorking when any is working; else agentFinished while `log.lastFinish` is within 600 s; else nil. Title "\(agentName) · \(project)" of the most urgent session (oldest `startedAt` in that class); `total` counts non-exited sessions.
- `rank`: sorted by rank; ties keep the earlier `startedAt` when both have one, else input order. `title` = `activity.title ?? accessibilityLabel ?? widgetID`.

- [ ] **Step 1: Write the failing tests**
  - `PriorityModelTests`: `testSpecOrder` (one item per rank 2–10, the agents one through `agents:`, shuffled in → spec order out), `testMeetingSplitsAtTwoMinutes` (119 s → meetingImminent, 181 s → meetingSoon), `testTiesGoToEarlierStart`, `testExpiredDropped`, `testPluginPriorityIsClamped` (1000 → `.ringing`, −5 → `.ambient`), `testAgentsRanks` (waitingInput → agentNeedsYou, active → agentsWorking, finished 5 min ago → agentFinished, 11 min ago → nil), `testFailureMeansNeedsYou` (`noteFailure` → agentNeedsYou until `clearFailure` or 600 s), `testWindowsExpireAcrossSleep` (finish at t, `now = t + 7200` → nil), `testExistingConstantsKeepTheirBands` (`download` → fileAction, `keepAwake` → minor, `shelfItems` → ambient, `musicPlaying` → music), `testRowActions` (each `AgentAttention` → its action).
  - `SessionTransitionsTests`: `testFirstCallOnlyLooks`, `testActiveToIdleIsFinished`, `testRemovalIsNotFinished`, `testEnteredNeedsYou` (active → waitingInput listed once, not again while it stays), `testAllFinishedOnlyWhenLastEnds` (two active → one idle: false; both idle: true).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PriorityModelTests` and `--filter PlatyNotchKitTests.SessionTransitionsTests` → FAIL.
- [ ] **Step 3: Implement.** `PillDots`, `PlatyMoodResolver` and `PlatyFinishWatch` keep their public signatures and behaviour and use `AgentAttention` / `SessionTransitions` inside. `LiveArbiter` stays for plugins.
- [ ] **Step 4: Run** both filters → PASS; `swift test` (incl. `LiveArbiterTests`, `PlatyMoodTests`, `PanelFormatTests` unchanged) → PASS.
- [ ] **Step 5: Commit** `feat(mac): one priority model, one session classifier, one transition tracker`

---

### Task 6: The Now model

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Widgets/WidgetKind.swift`, `apps/mac/Sources/PlatyNotchKit/Now/GlanceSlots.swift`, `apps/mac/Sources/PlatyNotchKit/Now/HeroDeck.swift`, `apps/mac/Sources/PlatyNotchKit/Now/NowModel.swift`, `apps/mac/Sources/PlatyNotchKit/Now/DayPhase.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/NowModelTests.swift`

**Interfaces:**
- Consumes: `LiveItem`, `LiveRank` (Task 5); `PanelLayout`.
- Produces:
  ```swift
  public struct WidgetKind: OptionSet, Hashable, Sendable { public let rawValue: Int; public init(rawValue: Int); public static let live, glance, tool: WidgetKind }
  public struct GlanceSlots: Codable, Equatable, Sendable { public static let key = "now.glances"; public static let limit = 4; public static let usageID = "agents.usage"
      public private(set) var ids: [String]; public init(ids: [String] = [])
      public static func defaults(glanceCapable: [String]) -> GlanceSlots   // first four, in order
      public mutating func set(_ ids: [String])                             // de-duplicated, at most 4
      public func shown(available: Set<String>) -> [String]                 // chosen ids with content, in slot order
      public static func load(from: UserDefaults, glanceCapable: [String]) -> GlanceSlots; public func save(to: UserDefaults) }
  public struct HeroDeck: Equatable, Sendable { public init(); public private(set) var selectedID: String?
      public static func items(_ ranked: [LiveItem]) -> [LiveItem]           // drops .ambient; one entry per widget (its best item) plus Agents
      public func current(in deck: [LiveItem]) -> Int?                      // selected if still present, else 0
      public mutating func step(_ delta: Int, in deck: [LiveItem])          // wraps
      public mutating func panelOpened()
      public static func position(_ index: Int, of count: Int) -> String? } // "2 of 3"; nil when count < 2
  public enum NowMode: Equatable, Sendable { case approvalsPending(line: String?), live, summary
      public static func resolve(approvals: Int, deck: [LiveItem], now: Date) -> NowMode }
  public enum NowSummaryLine { public static func text(_ deck: [LiveItem], now: Date) -> String? }   // top two in deck (rank) order
  public struct QuietLineItem: Equatable, Sendable { public let id: String; public let text: String; public init(id: String, text: String) }
  public enum QuietLine { public static func items(openLoops: Int, tasks: Int, glanceIDs: [String]) -> [QuietLineItem] }
  public enum DayPhase: String, CaseIterable, Sendable { case morning, day, evening, night
      public static func at(hour: Int) -> DayPhase; public var greeting: String }
  public enum NowMetrics { public static let nav: CGFloat = 32, hero: CGFloat = 160, glance: CGFloat = 64, quietLine: CGFloat = 20, tourCard: CGFloat = 44, gap: CGFloat = 8
      public static func required(tourCard: Bool) -> CGFloat; public static func available(in layout: PanelLayout) -> CGFloat }   // content height − inset − 10
  ```
- `DayPhase`: morning 5..<11, day 11..<17, evening 17..<21, night otherwise; greetings "Good morning", "Good afternoon", "Good evening", "Hello". `NowSummaryLine`: "Now: " + the two titles joined by " · "; an item whose `countdownTo` is within 60 min gets " in N min" (N rounded up); nil for an empty deck. `QuietLine` texts "Open loops (2)", "Tasks (3)" with ids `loops`, `reminders`; zero, or already a chosen glance, is left out. `required(tourCard: true)` swaps the quiet line for the card.

- [ ] **Step 1: Write the failing tests**: `testDefaultGlancesAreFirstFour`, `testSetCapsAndDedupes`, `testUnavailableGlanceKeepsItsSlot` (ids `[a,b,c,d]`, available `{a,c,d}` → `[a,c,d]`, then all → `[a,b,c,d]`), `testLoadWithoutSavedKeyUsesDefaults`, `testDeckDropsAmbient`, `testOneEntryPerWidget` (two running timers → one Time entry, the higher ranked), `testSelectionSurvivesReorder`, `testSelectionFallsBackWhenItemEnds`, `testPanelOpenedResets`, `testPosition`, `testApprovalsPendingLineFollowsRank` (music + meeting in 8 min → `.approvalsPending(line: "Now: Design in 8 min · Music")`), `testQuietLineHidesZeroAndChips`, `testDayPhaseBandsAndGreeting` (hours 4, 5, 11, 17, 21 → night, morning, day, evening, night; 21 → "Hello"), `testNowFitsTheExpandedPanel` (`required(tourCard:)` for both values ≤ `available(in:)` for a notched 1512×982 screen with notch height 38 and for a screen without a notch).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.NowModelTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mac): Now model: widget kinds, glance slots, hero deck, quiet line, day phases`

---

### Task 7: Widget API additions and registry queries

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchUI/Widgets/NotchWidget.swift`, `apps/mac/Sources/PlatyNotchUI/Widgets/WidgetRegistry.swift` (stored `openSettingsHandler` in the class body, `@ObservationIgnored`), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (`buildViews(of:)` lays out the new views; sets `openSettingsHandler`)
- Test: `apps/mac/Tests/PlatyNotchUITests/WidgetKindAPITests.swift`

**Interfaces:**
- Consumes: `WidgetKind`, `LiveItem`, `PriorityModel`, `AgentsLive` (Tasks 5–6).
- Produces (public; each is a protocol requirement with its default in the existing `extension NotchWidget`):
  ```swift
  public enum WidgetSetupAction { case openSettings; case run(@MainActor () -> Void) }
  // NotchWidget requirements:
  var kind: WidgetKind { get }            // default .tool
  var hasContent: Bool { get }            // default true
  func heroView() -> AnyView?             // default nil
  func glanceView() -> AnyView?           // default nil
  func libraryTile() -> AnyView?          // default nil
  func toolView() -> AnyView              // default: hasTile ? tileView() : (settingsView() ?? tileView())
  var setupAction: WidgetSetupAction { get }   // default .openSettings
  // WidgetRegistry:
  public var toolWidgets: [any NotchWidget]     // enabled, kind ⊇ .tool, user order
  public var glanceWidgets: [any NotchWidget]   // enabled, running, kind ⊇ .glance, hasContent
  public var glanceCapableIDs: [String]         // enabled, kind ⊇ .glance, user order
  public func rankedLive(agents: AgentsLive?, now: Date) -> [LiveItem]
  public var openSettingsHandler: (@MainActor (String) -> Void)?   // stored, "widgets/<id>"
  public func runSetup(_ id: String)
  ```
- `tileView()` stays a requirement (doc comment: deprecated in favour of `toolView()`); `hasTile` and `tileWidgets` stay. Until Task 24 the app's handler opens the Widgets section and ignores the detail.

- [ ] **Step 1: Write the failing tests**: `testTileOnlyWidgetIsATool` (fake with only the required members and `tileView()` → kind `.tool`, in `toolWidgets`, not in `glanceWidgets`, `hasContent`), `testToolViewDefaultsToTile`, `testHeadlessToolViewIsSettings`, `testGlanceWidgetsNeedContentAndRunning`, `testRunSetupDefaultOpensSettings` (handler receives `"widgets/fake"`), `testRunSetupCustomAction`, `testRankedLiveUsesRunningWidgetsOnly`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.WidgetKindAPITests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` incl. `PluginAPITests` (unchanged) → PASS; the smoke recipe → `SMOKE OK`, `SMOKE-POWER OK widgets=6`.
- [ ] **Step 5: Commit** `feat(mac): additive widget API for kinds, content, hero, glance, library and setup`

---

### Task 8: Built-in widget kinds, content and glances

**Files:**
- Modify (under `apps/mac/Sources/PlatyNotchUI/`): `Widgets/BuiltIn/MusicWidget.swift`, `Widgets/BuiltIn/FocusWidget.swift`, `Widgets/BuiltIn/LoopsWidget.swift`, `Widgets/TimeWidget.swift`, `Day/MeetingWidget.swift`, `Day/WeatherWidget.swift`, `Day/RemindersWidget.swift`, `System/SystemWidget.swift`, `Wellbeing/WellbeingWidget.swift`, `Integrations/MailWidget.swift`, `Shelf/ShelfWidget.swift`, `Camera/MirrorWidget.swift`, `Games/GamesWidget.swift`, `Files/FileActionsWidget.swift`, `Windows/WindowSnapWidget.swift`
- Create: `apps/mac/Sources/PlatyNotchUI/Now/GlanceChip.swift` (icon `IconSize.row`, value in rounded headline, caption label)
- Test: `apps/mac/Tests/PlatyNotchUITests/BuiltInKindsTests.swift`

**Interfaces:**
- Consumes: Task 7 API; `LivePriority.fileAction` / `.panelActivity`, `LiveActivity.title/subtitle/startedAt` (Task 5).
- Kinds: music `[.live, .tool]`; meeting `[.glance, .live, .tool]`; focus, time `[.live, .tool]`; loops, reminders, weather, wellbeing, mail `[.glance, .tool]`; system `[.glance, .live, .tool]`; shelf, mirror, games `[.live, .tool]`; the rest keep `.tool`.
- `hasContent` and glance: meeting — calendar access and an event within `UpcomingMeeting.horizon` → "10:30 Design"; weather — a forecast loaded → "24° Clear"; system — the Mac has a battery → "Battery 82%"; wellbeing — water tracking on → "Water 5/8"; mail — unread > 0 → "Mail 4"; loops — open loops > 0 → "Open loops 2"; reminders — reminders access and tasks due today > 0 → "Tasks 3".
- New activities: music `music:paused` (glyph `.symbol("pause.fill")`, priority `musicPlaying`, `expiresAt` pause + 600 s, title "Music"); shelf `shelf:action` at `fileAction` with `.ring(progress:)` while a file action runs; mirror `mirror:on` and games `games:chase` at `panelActivity` while running. Built-in activities set `title`/`subtitle`/`startedAt` (meeting title = event title, subtitle = start time).

- [ ] **Step 1: Write the failing tests** (inert widgets): `testKindsTable` (the table above per id), `testNoDataMeansNoContent` (meeting without access, weather without a forecast, mail at 0), `testMusicPausedStaysTenMinutes` (paused at t → present at t+599, absent at t+601), `testShelfActionIsFileActionRank`, `testGlanceViewsExistForGlanceKinds`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.BuiltInKindsTests` → FAIL.
- [ ] **Step 3: Implement** per widget.
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE OK`, `SMOKE-POWER OK widgets=6`.
- [ ] **Step 5: Commit** `feat(mac): built-in widgets declare kinds, content and glances`

---

### Task 9: The Now destination

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Now/NowView.swift`, `Now/HeroFrame.swift`, `Now/GenericHero.swift`, `Now/TodaySummaryHero.swift`, `Now/GlanceRow.swift`, `Now/QuietLineView.swift`, `Now/AgentActivityModel.swift` (all under `apps/mac/Sources/PlatyNotchUI/`)
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/ExpandedPanel.swift` (`BuiltinTab.now = "now"`, first tab; 32 pt nav, headline labels; side padding `Space.panelMargin`), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`selectedTab` default `BuiltinTab.now`; `HeroDeck.panelOpened()` on each open; expanded padding 16), `apps/mac/Sources/PlatyNotchUI/Views/TodayTab.swift` (`TodayServices.agentActivity`), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (feeds `agentActivity` from store sessions and notices), `apps/mac/Sources/PlatyNotchKit/PanelLayout.swift` (`approvalSlot`: inset 16 for `.expanded`, 12 for `.peek(.approval)`), `apps/mac/Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/NowViewTests.swift`; extend `apps/mac/Tests/PlatyNotchKitTests/PanelSurfaceTests.swift`

**Interfaces:**
- Consumes: Tasks 5–8.
- Produces:
  ```swift
  @MainActor @Observable final class AgentActivityModel {   // the app's one session tracker
      private(set) var log: AgentFinishLog
      func sessionsChanged(_ sessions: [Session], now: Date)   // SessionTransitions → log.record; clearFailure for sessions active again
      func notice(_ n: Notice, now: Date)                      // "session-failed" → noteFailure
      func observe(_ handler: @escaping @MainActor (SessionChanges) -> Void) }
  struct NowView: View { init(store: AppStore, widgets: WidgetRegistry, today: TodayServices, deck: Binding<HeroDeck>,
      onOpenTool: @escaping (String) -> Void, onOpenAgents: @escaping () -> Void, onOpenTerminal: @escaping (Session) -> Void) }
  struct HeroFrame<Content: View>: View { init(keyline: Color?, position: String?, onStep: ((Int) -> Void)?, @ViewBuilder content: () -> Content) }
  ```
- `HeroFrame`: 160 pt, radius `Radius.hero`, padding `Space.heroPadding`, ‹ › with VoiceOver labels "Previous live item"/"Next live item", horizontal swipe calls `onStep`; keyline = `DS` colour of the activity's `LiveTint` (nil for neutral). Layout by `NowMode`: `.live` → hero (`heroView()` of the item's widget, else `GenericHero`; the Agents item gets a Platy 96 hero refined in Task 10) + glance row + quiet line; `.summary` → `TodaySummaryHero` (`DayPhase.greeting`, date, time in `TypeScale.display` updated each minute only while ticking, next event, Platy 96 idle) + glance row + quiet line; `.approvalsPending(line)` → one `body` line. No `ScrollView` in Now. Glance chips equal width, 64 pt, `dsCard`; a tap opens the widget's tool, the usage chip opens Agents. The other tabs stay until Task 21.
- Renders added: `now-summary`, `now-live-generic`, `now-approvals-line` → `renders=30`.

- [ ] **Step 1: Write the failing tests**: `testNowFitsWithEverythingOn` (all built-ins enabled with inert models, four glances, three live items: `fittingSize.height <= NowMetrics.available(in:)` for a notched layout), `testHeroFitsWithLongTitle` (200-character title and subtitle → hero ≤ 528×160 with ‹ › inside it), `testDefaultTabIsNow`, `testAgentActivityRecordsFinishAndFailure` (sessions active → idle → `log.lastFinish` set; a `session-failed` notice → `log.failed`), `testNoScrollViewInNow` (lint over `Sources/PlatyNotchUI/Now/`); Kit `PanelSurfaceTests.testApprovalSlotMatchesPanelMargin` (expanded slot x = content minX + 16, width = content width − 32; peek slot keeps 12).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.NowViewTests` and `--filter PlatyNotchKitTests.PanelSurfaceTests` → FAIL.
- [ ] **Step 3: Implement** the views, the model and the three renders.
- [ ] **Step 4: Run** → PASS; `swift test` (incl. `BasketTests` slot checks) → PASS; the smoke recipe → `renders=30`.
- [ ] **Step 5: Commit** `feat(mac): Now: one hero, four glances, a quiet line, no scrolling`

---

### Task 10: Hero views per live kind

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Now/AgentsHero.swift`, `apps/mac/Sources/PlatyNotchKit/Now/HeroPrimary.swift`
- Modify (`heroView()`, under `apps/mac/Sources/PlatyNotchUI/`): `Widgets/BuiltIn/MusicWidget.swift`, `Widgets/TimeWidget.swift`, `Day/MeetingWidget.swift`, `Widgets/BuiltIn/FocusWidget.swift`, `System/SystemWidget.swift`, `Shelf/ShelfWidget.swift`, `Camera/MirrorWidget.swift`, `Games/GamesWidget.swift`; `Now/NowView.swift` (uses `AgentsHero`); `Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/HeroViewsTests.swift`, `apps/mac/Tests/PlatyNotchKitTests/HeroPrimaryTests.swift`

**Interfaces:**
- Consumes: `HeroFrame` (Task 9); `AgentsLive`, `AgentRowAction` (Task 5).
- Produces: `struct AgentsHero: View { init(agents: AgentsLive, action: AgentRowAction, mood: PlatyMood?, onPrimary: @escaping () -> Void) }`; `public enum HeroPrimary { public static func title(rank: LiveRank, playing: Bool, hasLink: Bool) -> String? }` (ringing "Stop", timerRunning "Pause", music "Pause"/"Play", meetingImminent and meetingSoon "Join" with a link else nil, else nil).
- One primary control at most: music Play/Pause (keyline = `NowPlaying.artworkTint`); timer/stopwatch/focus Pause, ringing Stop; meeting Join (with a `MeetingLinks` URL); agents from `AgentRowAction`; downloads, file action, mirror and Chase none. Counts and times use `.contentTransition(.numericText())`; countdowns tick only while `panelTicking`.
- Renders added: `hero-music`, `hero-timer`, `hero-meeting`, `hero-agents` → `renders=38`.

- [ ] **Step 1: Write the failing tests**: Kit `testPrimaryTitles` (the table above); UI `testEveryLiveBuiltInHasAHero` (each inert widget with a seeded activity returns a hero that fits 528×160), `testAgentsHeroUsesRowAction` (needs-you → "Answer", working → "Open terminal").
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.HeroPrimaryTests` and `--filter PlatyNotchUITests.HeroViewsTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=38`.
- [ ] **Step 5: Commit** `feat(mac): hero layouts for music, timers, meetings, focus, files, mirror, Chase and agents`

---

## Phase 3: Pill, live activities and the morph

### Task 11: Pill content model

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Pill/PillContent.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/PanelFormat.swift` (`PillDots.Dot` gains stored `agent` and `style` in its body), `apps/mac/Sources/PlatyNotchKit/Appearance/LiveEarFit.swift` (new init and stored `indicatorsShown` in the body; the `hasBubble` init stays as a wrapper)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PillContentTests.swift`

**Interfaces:**
- Consumes: `PriorityModel`, `NotificationKind`, `AgentAttention` (Task 5); `AgentIdentity` (Task 1).
- Produces:
  ```swift
  public enum AgentDotStyle: Sendable, Equatable { case pulse, solid, hollow; public init(_ a: AgentAttention) }   // working → pulse, needsYou/errored → solid, else hollow
  // PillDots.Dot: public var agent: AgentIdentity; public var style: AgentDotStyle
  public struct PillContent: Equatable, Sendable {
      public static let indicatorLimit = 2
      public let dots: PillDots; public let approvalCount: Int
      public let trailing: LiveActivity?          // top non-agent item whose kind shows in the pill
      public let indicators: [LiveActivity]       // next ones, ≤ 2; ambient never beside a non-ambient trailing item
      public init(activities: [LiveActivity], sessions: [Session], approvals: Int, hiddenKinds: Set<NotificationKind>, now: Date)
      public var keepsMinimalUp: Bool }           // approvals, or anything non-ambient live
  // LiveEarFit: public init(earWidth: CGFloat, hasTrailing: Bool, indicators: Int); public let indicatorsShown: Int; public static let indicator: CGFloat = 6
  ```
- Indicators cost `LiveEarFit.indicator` + `spacing` each and are dropped before the trailing text.

- [ ] **Step 1: Write the failing tests**: `testTrailingIsTopNonAgent` (timer + music → trailing timer, indicators [music]), `testAtMostTwoIndicators`, `testAmbientNeverBesideLive`, `testHiddenKindLeavesThePill` (`hiddenKinds: [.other]` drops music), `testDotStyles` (active → pulse, waitingInput → solid, idle → hollow; agent from `Session.agent`), `testTwelveSessions` (12 sessions over claude/codex/cursor/gemini, one waitingInput → 3 dots with it first, overflow 9), `testEarFitDropsIndicatorsFirst`, `testBubbleInitStillWorks`, `testKeepsMinimalUp`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PillContentTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` (incl. `AppearanceTests`) → PASS.
- [ ] **Step 5: Commit** `feat(mac): pill content from the priority model with two indicator dots`

---

### Task 12: Redraw the compact pill

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/CompactPill.swift`, `apps/mac/Sources/PlatyNotchUI/Views/Theme.swift` (`AgentDotNSView.configure(color:style:)`; `configure(color:pulses:)` stays as a wrapper: true → `.pulse`, false → `.solid`), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (builds `PillContent`), `apps/mac/Sources/PlatyNotchUI/NotchController.swift` (`setLive` from `PillContent.keepsMinimalUp`), `apps/mac/Sources/PlatyNotchKit/PanelSupport.swift` (doc comment: `hasLive` is the plugin-compatible form), `apps/mac/Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/CompactPillTests.swift`

**Interfaces:**
- Consumes: `PillContent`, `LiveEarFit(earWidth:hasTrailing:indicators:)` (Task 11); `DS.agent` (Task 3).
- Produces: `CompactPill(content: PillContent, connection: ConnectionState, hasNotch: Bool, notchWidth: CGFloat, liveSide: LiveSide, earWidth: CGFloat, platy: PlatyMood?)`. Leading ear: Platy, dots coloured by `DS.agent` with their style (a `.pulse` dot animates only while ticking and Reduce Motion is off, otherwise it draws solid), "+n" at `TypeScale.caption`. Trailing ear: connection glyph, else the approval badge, else trailing glyph + text, then up to two 6 pt indicator dots tinted by each item's tint. `liveSide` still swaps the ears. `hiddenKinds` is empty until Task 22.
- Renders added: `pill-platy-idle`, `pill-agents-music`, `pill-indicators` → `renders=44`.

- [ ] **Step 1: Write the failing tests**: `testTrailingNeverWiderThanEar` (200-character trailing text at each `PillWidth` → trailing frame within `earWidth`), `testHollowDotNeverAnimates` (`configure(color:style: .hollow)` → `isPulsing == false`; `.pulse` → true), `testOldConfigureStillWorks` (`configure(color:pulses: true)` → pulsing; `false` → not), `testAccessibilitySummaryNamesIndicators`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.CompactPillTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` (incl. `PlatyTests` unchanged) → PASS; the smoke recipe → `renders=44`; manual with `scripts/fake-events.sh`: two sessions and music → Platy, two coloured dots, music bars.
- [ ] **Step 5: Commit** `feat(mac): pill shows Platy and agents, the top live item and two indicators`

---

### Task 13: Platy state poses

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchKit/Mascot/PlatyMood.swift` (waiting: period 2, wave once), `apps/mac/Sources/PlatyNotchKit/Mascot/PlatyPoseValues.swift` (stored `flag` in the body), `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyArt.swift` (the flag), `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyView.swift` (play-once loop), `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyMoodModel.swift` (takes changes from `AgentActivityModel` instead of its own `PlatyFinishWatch`; feeds `justFinished`), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`platyMood` passes the activity log)
- Test: rewrite in `apps/mac/Tests/PlatyNotchKitTests/PlatyMoodTests.swift`: `testWaitingSkipsItsStillHalf` → `testWaitingWavesOnceThenHolds`, the waiting rows of `testLoopKeyframes`, the waiting tail-tap check in `testRestFramesKeepTheMoodCues`; extend `apps/mac/Tests/PlatyNotchUITests/PlatyTests.swift`

**Interfaces:**
- Produces: `PlatyPoseValues.flag: Bool`; `PlatyMood.playsOnce: Bool` (true for `.waiting` and `.done`); `PlatyLayerNSView` plays a `playsOnce` loop with `repeatCount = 1`, then holds `rest(mood)`; leaving and re-entering waiting plays the wave again.
- Done reuses the existing `justFinished` input (no new resolver parameter): `PlatyMoodModel` passes `flags.justFinished(at: now) || (log.lastFinish(now:) != nil && no session is working or needs you)`.
- Poses: waiting = amber flag raised, one 2 s wave, then still with the flag up; done = check, once; working = paddle; workingToMusic = headphones; sleepy at night (existing).

- [ ] **Step 1: Write the failing tests**: Kit `testWaitingWavesOnceThenHolds` (`PlatyPoseValues.at(.waiting, time: 2.5) == PlatyPoseValues.rest(.waiting)` and the pose moves between 0 and 2), `testWaitingRestHasFlag`, `testDoneHoldsAfterOneLoop`, `testRecentFinishShowsDoneOnlyWhenNothingWorks` (log finish 5 min ago, no active session → `.done`; with an active session → `.working`); UI `testPlaysOnceLoopEndsStill` (`PlatyLayerNSView` with `.waiting` → animation `repeatCount == 1`).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PlatyMoodTests` and `--filter PlatyNotchUITests.PlatyTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; `.build/debug/PlatyNotch --platy-gallery /tmp/pn-gallery` → the waiting frames show the flag.
- [ ] **Step 5: Commit** `feat(mac): Platy raises an amber flag once when you are needed`

---

### Task 14: Morph-in-place open and close

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Design/Morph.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`@Namespace`, `\.morphNamespace` environment), `apps/mac/Sources/PlatyNotchUI/Views/CompactPill.swift`, `apps/mac/Sources/PlatyNotchUI/Now/NowView.swift`, `apps/mac/Sources/PlatyNotchUI/Now/HeroFrame.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/MorphTests.swift`

**Interfaces:**
- Consumes: `MotionPreset`, `MotionDirection` (Task 2); `PillContent` (Task 11); `HeroDeck` (Task 6).
- Produces: `public enum MorphID { public static let platy = "morph.platy"; public static func live(_ id: String) -> String }`; `public enum Morph { public static func matches(pillTrailingID: String?, heroTopID: String?, motion: MotionPreset) -> Bool }` (same id and motion ≠ `.reduced`).
- Platy in the pill and in the hero share `matchedGeometryEffect(id: MorphID.platy)`; the pill's trailing glyph and the hero's glyph share `MorphID.live(id)` when `Morph.matches`. Under `.reduced`, cross-fades only. Close lands exactly on `contentRect(.compact)`. Other content changes cross-fade in `MotionPreset.crossFade`. `MorphTests` guard the decision only; the morph itself is accepted by the manual check in Step 4.

- [ ] **Step 1: Write the failing tests**: `testMatchesSameItem`, `testNoMatchForDifferentItems`, `testReducedNeverMorphs`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.MorphTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE OK`; acceptance gate on a notched Mac: open and close ten times with music playing (no jump, no overshoot on close, no seam), `scripts/perf-idle.sh` and `scripts/perf-idle.sh --state music` → PASS.
- [ ] **Step 5: Commit** `feat(mac): open grows the pill into the hero in place`

---

### Task 15: Peek on hover, open on click

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchKit/Appearance/AppearanceSettings.swift` (`OpenTrigger.peekOnHover`), `apps/mac/Sources/PlatyNotchKit/PanelState.swift` (`PeekReason.hover`, stored `hoverPeek` in `PanelSurfaceState`, `peekOnHover` in `PanelStateMachine`, precedence), `apps/mac/Sources/PlatyNotchKit/PanelLayout.swift` (`hoverPeekHeight`), `apps/mac/Sources/PlatyNotchKit/PanelSupport.swift` and `apps/mac/Sources/PlatyNotchKit/PanelFormat.swift` (switches), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (draws the hero only), `apps/mac/Sources/PlatyNotchUI/NotchController.swift`, `apps/mac/Sources/PlatyNotchUI/Settings/AppearanceSection.swift` (third "Open on" choice), `apps/mac/Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Test: extend `apps/mac/Tests/PlatyNotchKitTests/PanelStateTests.swift`, `apps/mac/Tests/PlatyNotchKitTests/PanelLayoutTests.swift`

**Interfaces:**
- Produces: `PeekReason.hover`; `PanelStateMachine.peekOnHover: Bool`; `PanelLayout.hoverPeekHeight: CGFloat = 176` (content rect: `peekSize.width` × notch height + 176); `ApprovalPlacement(mode: .peek(.hover), …) == nil`; `.peek(.hover).canBecomeKey == false`.
- Precedence: approval > open > drop > ringing > hover peek > HUD > notice > widget peek > idle. Hover enter from idle shows it; hover exit ends it; click opens the panel. The default trigger stays `.hover`.
- Render added: `peek-hover` → `renders=46`.

- [ ] **Step 1: Write the failing tests**: `testHoverPeekThenClickOpens`, `testHoverPeekExitCloses`, `testApprovalBeatsHoverPeek`, `testRingingBeatsHoverPeek`, `testHoverPeekNeverKey`, `testNoApprovalCardsInHoverPeek`; `PanelLayoutTests.testHoverPeekRect` (width 420, height notch + 176).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PanelStateTests` and `--filter PlatyNotchKitTests.PanelLayoutTests` → FAIL.
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
- Consumes: `AgentAttention`, `AgentFinishLog` (Task 5).
- Produces:
  ```swift
  public enum AgentsOrder { public static func sorted(_ sessions: [Session], log: AgentFinishLog, now: Date) -> [Session] }   // by AgentAttention.of, then newest updatedAt
  public enum SessionStatusLine { public static func text(_ s: Session, attention: AgentAttention, now: Date) -> String
      public static func lastAction(_ s: Session) -> String? }
  public struct AgentsVisibility: Codable, Equatable, Sendable { public static let key = "agents.visibility"
      public var everConnected: Bool; public var forcedOn: Bool; public init(everConnected: Bool = false, forcedOn: Bool = false)
      public var isVisible: Bool; public mutating func noteSessions(count: Int) -> Bool   // true only the first time
      public static func load(from: UserDefaults) -> AgentsVisibility; public func save(to: UserDefaults) }
  public enum PanelDestination: String, CaseIterable, Sendable { case now, agents, library
      public static func shown(agentsVisible: Bool) -> [PanelDestination] }
  ```
- Status text: needsYou "Waiting for approval" (blocked) / "Needs your input" (waitingInput); errored "Stopped with an error"; working "\(title ?? tool ?? "Working") · \(minutes since startedAt) m"; finished "Finished · \(minutes ago) m ago"; idle "Idle"; exited "Ended". `lastAction` = `message ?? tool` through `SummarySanitizer.visible(_, singleLine: true)`.

- [ ] **Step 1: Write the failing tests**: `testAttentionOrder`, `testTwelveSessionsNeedsYouFirst`, `testStatusLines` (exact strings with fixed dates), `testLastActionHidesNothing` (zero-width space → `⟨U+200B⟩`), `testVisibilityFirstConnectNotifiesOnce`, `testForcedOn`, `testDestinationsFollowVisibility`.
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
  public struct DiffLine: Equatable, Sendable { public enum Kind: Sendable { case hunk, context, added, removed }; public let kind: Kind; public let text: String; public init(kind: Kind, text: String) }
  public enum LineDiff { public static let maxCells = 250_000
      public static func usesFallback(oldLines: Int, newLines: Int) -> Bool     // oldLines × newLines > maxCells
      public static func unified(old: String, new: String, context: Int = 3) -> [DiffLine] }   // LCS; fallback: every old line removed, every new line added, one hunk
  public struct ApprovalPreview: Equatable, Sendable { public static let collapsedLines = 12
      public let command: String?; public let path: String?; public let diff: [DiffLine]; public let hadHidden: Bool
      public init(approval: Approval)
      public func lines(expanded: Bool) -> [DiffLine]; public var hasMore: Bool
      public static func boxLines(diffCount: Int, cards: Int) -> Int }   // min(diffCount, cards == 1 ? 8 : 4)
  ```
- Sources in `approval.input`: `command` (Bash); `file_path` / `notebook_path` / `path`; Edit `old_string`/`new_string`; MultiEdit `edits[]` (one hunk group per edit); Write `content` (all added); NotebookEdit `new_source` (all added). Every string passes through `SummarySanitizer.visible` (newlines kept). Hunk header `@@ -a,b +c,d @@`; line counts include the hunk line.

- [ ] **Step 1: Write the failing tests**: `testEditMakesUnifiedDiff` (old "a\nb\nc", new "a\nB\nc" → `[hunk "@@ -1,3 +1,3 @@", context "a", removed "b", added "B", context "c"]`), `testCollapsedToTwelve` (40-line Write → 12 collapsed, `hasMore`, 41 expanded), `testMultiEdit`, `testBashHasCommandNoDiff`, `testHiddenCharactersStayVisible`, `testHugeInputUsesFallback` (2000 × 2000 changed lines → `usesFallback` true and the result is one hunk with 4001 lines), `testBoxLines`, `testNoInputMeansSummaryOnly`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.ApprovalPreviewTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mac): approval previews with command, path and a unified diff`

---

### Task 18: The Agents destination

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Agents/AgentsView.swift`, `Agents/AgentRow.swift`, `Agents/UsageRings.swift`, `Agents/AgentBadge.swift` (under `apps/mac/Sources/PlatyNotchUI/`)
- Delete: `apps/mac/Sources/PlatyNotchUI/Views/AgentsTab.swift`, `apps/mac/Sources/PlatyNotchUI/Views/SessionRow.swift` (`RowButtonStyle` moves to `AgentRow.swift`); `UsageSection` in `apps/mac/Sources/PlatyNotchUI/Views/UsageBar.swift` (and `UsageBar` if nothing else uses it)
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/ExpandedPanel.swift` (Agents tab → `AgentsView`; tabs filtered by `PanelDestination.shown(agentsVisible:)`), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (feeds `noteSessions`; posts the one-time notice "Agents is in your notch now"), `apps/mac/Sources/PlatyNotchKit/AppStore.swift` (`package func postLocalNotice(_ n: Notice)`), `apps/mac/Sources/PlatyNotchUI/Settings/AgentsSection.swift` (toggle "Show Agents before an agent connects" → `forcedOn`), `apps/mac/Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/AgentsViewTests.swift`

**Interfaces:**
- Consumes: Task 16; `AgentAttention`, `AgentRowAction` (Task 5); `DS.agent`, `StateTone`.
- Produces: `struct AgentsView: View { init(sessions: [Session], usage: Usage, log: AgentFinishLog, onOpenTerminal: @escaping (Session) -> Void, onConnect: @escaping () -> Void) }`; `struct UsageRings: View { init(usage: Usage, hint: String?) }` (Claude 5 h and weekly, Codex 5 h else weekly; `hint` = `PanelFormat.claudeLimitsHint`, shown only as `.help` while limits are unavailable); `struct AgentBadge: View { init(agent: AgentIdentity, tone: StateTone) }` (agent-colour disc with the tone's symbol, 28 pt; Task 29 swaps in the pup).
- Row: agent icon, badge, project in `TypeScale.headline`, status line in `body`, last action in `TypeScale.caption` with the monospaced design (11 pt, spec 6.5), one trailing button from `AgentRowAction`. Empty state: Platy 96, "No agents running", "Connect an agent" → Settings › Agents. No permanent limits hint row.
- Renders added: `agents-list`, `agents-empty` → `renders=50`.

- [ ] **Step 1: Write the failing tests**: `testRowsFollowAttentionOrder`, `testLimitsHintOnlyAsTooltip` (`UsageRings` with limits unavailable has `hint` non-nil; `AgentsView` with the same usage lays out no text row containing the hint string), `testAgentsTabHiddenUntilConnected` (`ExpandedPanel` built with a fresh `AgentsVisibility` has no Agents tab; with `everConnected` it does), `testEmptyStateConnectCallsSettings`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.AgentsViewTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=50`.
- [ ] **Step 5: Commit** `feat(mac): Agents sorted by attention with usage rings and one action per row`

---

### Task 19: Richer approval cards and "Show changes"

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Views/ApprovalDiffBox.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/ApprovalCard.swift` (`preview`, `cards` parameters with defaults), `apps/mac/Sources/PlatyNotchUI/Views/ExpandedPanel.swift` (`ApprovalList` passes previews), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`ApprovalPeek`: "Show changes" link), `apps/mac/Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/ApprovalPreviewCardTests.swift`

**Interfaces:**
- Consumes: `ApprovalPreview` (Task 17).
- Produces: `ApprovalCard(…, preview: ApprovalPreview? = nil, cards: Int = 1)`; `struct ApprovalDiffBox: View { init(preview: ApprovalPreview, cards: Int) }`: full command, path, then a box exactly `boxLines × Theme.monoLineHeight` tall that scrolls inside itself (Ruling 11); "Show all" reveals the rest inside the same box. Added lines start with `+` in done colour, removed with `−` in error colour. The 420×236 peek keeps today's summary plus a "Show changes" link (when the diff is not empty) that calls `onExpand`; peek size and arming are unchanged.
- Render added: `approval-card-diff` → `renders=52`.

- [ ] **Step 1: Write the failing tests**: `testShowAllNeverChangesCardHeight` (300-line diff: collapsed height == expanded height == 12-line-diff height), `testNoPreviewInPeek`, `testShowChangesOnlyWithDiff`, `testDiffSignsNotColourOnly`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.ApprovalPreviewCardTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` incl. `ApprovalSafetyTests`, `ApprovalArmingControllerTests`, `ApprovalResponderTests` (unchanged) → PASS; the smoke recipe → `renders=52`; the approval-peek block in `scripts/verify-panel.md` → `SMOKE OK panels=1 mode=peek(approval)`.
- [ ] **Step 5: Commit** `feat(mac): approval cards show the full command, path and a diff that never moves`

---

## Phase 5: Library, tools and moving the tabs

### Task 20: Library model and panel routes

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Library/LibraryModel.swift`, `apps/mac/Sources/PlatyNotchKit/Library/PanelRoute.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/LibraryModelTests.swift`

**Interfaces:**
- Consumes: `PanelDestination` (Task 16).
- Produces:
  ```swift
  public struct LibraryItem: Identifiable, Equatable, Sendable { public let id: String; public let title: String; public let systemImage: String
      public let liveLine: String?; public let isSetUp: Bool
      public init(id: String, title: String, systemImage: String, liveLine: String?, isSetUp: Bool) }
  public struct LibraryRecents: Codable, Equatable, Sendable { public static let key = "library.recents"; public init()
      public mutating func noteOpened(_ id: String, at: Date); public static func load(from: UserDefaults) -> LibraryRecents; public func save(to: UserDefaults) }
  public enum LibraryOrder { public static func sorted(_ items: [LibraryItem], recents: LibraryRecents) -> [LibraryItem] }
  public enum LibraryTools { public static let memory = "memory"; public static let chase = "games.chase"; public static func plugin(_ tabID: String) -> String }   // "plugin:<id>"
  public struct PanelRoute: Equatable, Sendable { public var destination: PanelDestination; public var tool: String?; public init(destination: PanelDestination, tool: String? = nil)
      public static func legacy(tab: String, tools: Set<String>) -> PanelRoute   // today→now, agents→agents, focus/memory/games→library tool, a known tool or plugin:<id>→library tool, else now
      public func normalized(agentsVisible: Bool) -> PanelRoute
      public func back() -> PanelRoute }
  ```
- Input order (built in Task 21): widget tools in the user's order, "Platy Chase" right after Games, then Memory, then plugin tabs. Sorted: used most recently first; never used keep input order after them.

- [ ] **Step 1: Write the failing tests**: `testRecentlyUsedFirst`, `testNeverUsedKeepOrder`, `testRecentsPersist`, `testLegacyTabs`, `testPluginTabRoutes`, `testUnknownTabGoesToNow`, `testHiddenAgentsRouteFallsBack`, `testBackReturnsToGrid`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.LibraryModelTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mac): Library order and panel routes for internal tab ids`

---

### Task 21: Library grid, full-panel tools and three destinations

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Library/LibraryView.swift`, `Library/LibraryTile.swift`, `Library/ToolHost.swift`, `Now/TodayServices.swift` (moved out of `Views/TodayTab.swift`) (under `apps/mac/Sources/PlatyNotchUI/`)
- Delete: `apps/mac/Sources/PlatyNotchUI/Views/TodayTab.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Views/ExpandedPanel.swift` (nav from `PanelDestination.shown`; `selectedTab: Binding<String>` → `route: Binding<PanelRoute>`; `BuiltinTab` constants all stay as legacy ids), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`PanelViewModel.route`), `apps/mac/Sources/PlatyNotchUI/NotchController.swift` (`expand(tab: String)` keeps its signature and maps through `PanelRoute.legacy`), `apps/mac/Sources/PlatyNotchUI/Games/GamesWidget.swift` (`openTab` → library tool), `apps/mac/Sources/PlatyNotchUI/Games/Views/GamesTab.swift` (`selectPanelTab` → route), `apps/mac/Sources/PlatyNotchUI/Views/FocusTab.swift`, `apps/mac/Sources/PlatyNotchUI/Views/MemoryTab.swift` (hosted as tools), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (plugin `panelTabs()` → Library tools), `apps/mac/Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchUITests/LibraryViewTests.swift`; update `apps/mac/Tests/PlatyNotchUITests/FeedbackFixesTests.swift` (builds `ExpandedPanel(route:)`), `apps/mac/Tests/PlatyNotchUITests/WidgetCategoryRegistryTests.swift` (the `TodayTab` empty-message test becomes `testHeadlessPowerFeatureIsALibraryTool`), `apps/mac/Tests/PlatyNotchUITests/NowViewTests.swift` (`testDefaultTabIsNow` → `testDefaultRouteIsNow`), `apps/mac/Tests/PlatyNotchUITests/AgentsViewTests.swift` (`testAgentsTabHiddenUntilConnected` reads destinations). `ApprovalArmingControllerTests` stays untouched (`expand(tab: BuiltinTab.today)` keeps working).

**Interfaces:**
- Consumes: Task 20; Task 7 (`toolWidgets`, `libraryTile()`, `toolView()`, `runSetup`).
- Produces: `struct LibraryView: View { init(items: [LibraryItem], tile: @escaping (String) -> AnyView?, onOpen: @escaping (String) -> Void, onSetUp: @escaping (String) -> Void) }` — 4-column grid, tile width (528 − 3×8)/4, `dsCard`, icon `IconSize.tile`, name, live line; a tool with `hasContent == false` is dimmed with one "Set up" button; disabled widgets are not listed. `struct ToolHost: View { init(title: String, onBack: @escaping () -> Void, content: AnyView) }` — back chevron (VoiceOver "Back to Library"). Opening a tool calls `LibraryRecents.noteOpened`. Live line: `libraryTile()` when present, else the widget's top activity title. `static func ExpandedPanel.destinations(agentsVisible: Bool) -> [PanelDestination]` forwards to `PanelDestination.shown`.
- Renders added: `library-grid`, `library-tool-focus` → `renders=56`.

- [ ] **Step 1: Write the failing tests**: `testNavHasThreeDestinations`, `testEveryOldTabHasAHome` (Focus, Memory, Games, Platy Chase and a fake plugin tab appear as Library items), `testLegacyExpandRoutes` (`expand(tab: "memory")` → `.library` tool `memory`; `expand(tab: BuiltinTab.today)` → `.now`), `testDimmedTileOffersSetUp`, `testGridIsFourColumns`, `testDisabledWidgetsNotListed`; update the four listed test files.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.LibraryViewTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` (incl. `GamesWidgetTests`, the four updated files, `ApprovalArmingControllerTests` unchanged) → PASS; the smoke recipe → `renders=56`, `games=` unchanged; `checkGameViews` still fits `GameLayout.tabSize` inside `ToolHost`.
- [ ] **Step 5: Commit** `feat(mac): Library grid with full-panel tools; Focus, Memory and Games move in`

---

## Phase 6: Settings, first run, migration and notifications

### Task 22: Notification policy and its gates

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Notifications/NotificationPolicy.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/PanelFeed.swift` (`allowNotice`), `apps/mac/Sources/PlatyNotchUI/Widgets/NotchWidget.swift` (`WidgetContext.peek(id:until:as:)`; `peek(id:until:)` forwards with `.pluginUndeclared`), `apps/mac/Sources/PlatyNotchUI/Widgets/PanelSurfaces.swift` (`peek(id:until:kind:)` with `kind: NotificationKind? = nil`; gates peeks and rings), `apps/mac/Sources/PlatyNotchUI/NotchController.swift` (notice gate), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`hiddenKinds`), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (needs-input notice from `AgentActivityModel.observe`; the URL-route peek stays ungoverned), and every built-in peek caller: `Day/MeetingWidget.swift` (`.meetingStarting`), `Wellbeing/WellbeingWidget.swift` (`.reminder`), `System/SystemWidget.swift` (headphones `.reminder`, download and power `.other`), `Clipboard/ClipboardWidget.swift` and `Launch/LaunchWidget.swift` (`as: nil`, user-triggered confirmations) (under `apps/mac/Sources/PlatyNotchUI/`)
- Test: `apps/mac/Tests/PlatyNotchKitTests/NotificationPolicyTests.swift`, `apps/mac/Tests/PlatyNotchUITests/NotificationGateTests.swift`

**Interfaces:**
- Consumes: `NotificationKind`, `SessionChanges` (Task 5); `PillContent` (Task 11); `AgentActivityModel` (Task 9); `AppStore.postLocalNotice` (Task 18).
- Produces:
  ```swift
  public enum NotificationField: Sendable { case showInPill, canOpen, quietDuringFocus }
  public struct NotificationRule: Codable, Equatable, Sendable { public var showInPill: Bool; public var canOpen: Bool; public var quietDuringFocus: Bool
      public init(showInPill: Bool, canOpen: Bool, quietDuringFocus: Bool) }
  public struct NotificationPolicy: Codable, Equatable, Sendable { public static let key = "notifications.policy"; public init()
      public subscript(kind: NotificationKind) -> NotificationRule { get set }     // set leaves locked cells as they are
      public static func isLocked(_ kind: NotificationKind, _ field: NotificationField) -> Bool
      public func mayOpen(_ kind: NotificationKind, focusActive: Bool) -> Bool  // canOpen && !(quietDuringFocus && focusActive)
      public var hiddenInPill: Set<NotificationKind>
      public static func kind(noticeKind: String) -> NotificationKind?          // session-done → agentFinished; session-failed, approval-timeout, needs-input → agentNeedsYou; else nil
      public static func load(from: UserDefaults) -> NotificationPolicy; public func save(to: UserDefaults) }
  // PanelFeed: update(approvalCount:noticeSequence:holdNotices:allowNotice: Bool = true)
  // WidgetContext: @discardableResult func peek(id: String, until: Date, as kind: NotificationKind?) -> Bool   // nil = user-triggered confirmation, not governed
  ```
- Defaults (show in pill / can open / quiet during Focus), spec 6.3: approval on/on/no (all locked); agentNeedsYou on/on/no; agentFinished on/on/yes; ringing on/on/no; meetingStarting on/on/yes; reminder on/on/yes; other on/off/yes; pluginUndeclared on/on/yes.
- Gates: store notices peek only when `mayOpen(kind(noticeKind))`; `info` notices keep today's focus hold. A governed peek with `!mayOpen` is dropped (returns false). A ring with `!mayOpen(.ringing)` still rings (sound, menu bar "Stop") but sends no `.ringStarted`, so the pill and hero show it. Approvals are never gated. `SessionChanges.enteredNeedsYou` for a `.waitingInput` session posts a local notice of kind `needs-input` ("\(agentName) needs your input", body = project).

- [ ] **Step 1: Write the failing tests**: Kit `testDefaultsTable` (all eight rows), `testApprovalCellsLocked`, `testQuietDuringFocus` (`mayOpen(.agentFinished, focusActive: true) == false`, `mayOpen(.agentNeedsYou, focusActive: true) == true`, `mayOpen(.reminder, focusActive: true) == false`), `testNoticeKinds`, `testRoundTrip`, `testFeedDropsDisallowedNotice`; UI `testDownloadPeekOffByDefault`, `testWellbeingNudgeStillPeeks`, `testUndeclaredPluginPeekStillOpens` (a fake plugin widget calling `peek(id:until:)` shows), `testConfirmationsNotGoverned` (clipboard "Copied" with every kind turned off still shows), `testRingWithoutOpenStillRings`, `testNeedsInputPostsNotice`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.NotificationPolicyTests` and `--filter PlatyNotchUITests.NotificationGateTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` incl. `PanelSurfacesTests`, `PanelFeedTests`, `WellbeingWidgetTests`, `SystemWidgetTests`, `ClipboardWidgetTests` → PASS; the smoke recipe → `SMOKE OK`.
- [ ] **Step 5: Commit** `feat(mac): per-kind notification policy: show in pill, can open, quiet during Focus`

---

### Task 23: Presets, first-run state and the upgrade

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Setup/SetupPreset.swift`, `apps/mac/Sources/PlatyNotchKit/Setup/FirstRun.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (runs `UpgradeMigration.run` once at launch before widgets start)
- Test: `apps/mac/Tests/PlatyNotchKitTests/SetupPresetTests.swift`

**Interfaces:**
- Consumes: `GlanceSlots` (Task 6), `AgentsVisibility` (Task 16), `AppearanceSettings`.
- Produces:
  ```swift
  public enum SetupPreset: String, CaseIterable, Codable, Sendable { case everyday, developer, minimal
      public var turnsOn: [String]; public var turnsOff: [String]; public var glances: [String]; public var mode: AppearanceSettings.Mode; public var showsAgents: Bool }
  public struct PresetChange: Equatable, Sendable { public let turnOn: [String]; public let turnOff: [String]; public var needsConfirmation: Bool
      public init(turnOn: [String], turnOff: [String])
      public static func plan(_ p: SetupPreset, enabled: Set<String>) -> PresetChange }
  public enum FirstRunState: Equatable, Sendable { case firstRun, offerTour, settled
      public static let tourOfferedKey = "tour.offered"
      public static func resolve(onboardingDone: Bool, hasSavedLayout: Bool, tourOffered: Bool) -> FirstRunState }
  public struct OnboardingFlow: Equatable, Sendable { public enum Page: Int, CaseIterable, Sendable { case meetPlaty, pickSetup, permissions, tryIt }
      public let pages: [Page]; public init(pages: [Page]); public static let firstRun: OnboardingFlow; public static let tour: OnboardingFlow }   // tour = meetPlaty, permissions, tryIt
  public enum UpgradeMigration { public static let key = "ui.redesign.migrated"
      public static func run(defaults: UserDefaults, existingUser: Bool, glanceCapable: [String]) }   // idempotent
  ```
- Presets: everyday on `music, meeting, time, weather, shelf, clipboard`, off `fileActions, snap`, glances `meeting, weather, system, loops`, `.alwaysOn`, agents not forced; developer on everyday's + `fileActions, snap`, off none, glances `meeting, agents.usage, weather, system`, `.alwaysOn`, agents shown; minimal on `music`, off every other built-in id (`meeting, focus, loops, time, hud, shelf, clipboard, reminders, weather, wellbeing, system, games, launch, baskets, fileActions, mail, notes, mirror, snap`), glances `agents.usage`, `.minimal`, agents shown. Plugin widgets are never touched.
- Existing user: `widgets.layout` untouched; `AgentsVisibility.everConnected = true`; default glance slots saved when none are; appearance kept. New users: nothing written.

- [ ] **Step 1: Write the failing tests**: `testPresetGoldenTable` (the three presets in one table), `testPlanOnlyChanges`, `testMinimalNeedsConfirmation`, `testPresetsNeverTouchPlugins`, `testFirstRunStates`, `testTourSkipsPresets`, `testExistingUserKeepsWidgets` (layout data byte-identical), `testExistingUserKeepsAgents`, `testMigrationIdempotent`, `testNewUserWritesNothing`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.SetupPresetTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(mac): setup presets, first-run state and a non-destructive upgrade`

---

### Task 24: Settings sidebar, routes, General and Notch pages

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Setup/SettingsRoute.swift`, `apps/mac/Sources/PlatyNotchUI/Settings/GeneralSection.swift`, `Settings/NotchSection.swift`, `Settings/NotchPreview.swift`, `Settings/InfoButton.swift`
- Delete: `apps/mac/Sources/PlatyNotchUI/Settings/AppearanceSection.swift` (its Motion, Surface and Open-on pickers move to `NotchSection`)
- Modify: `apps/mac/Sources/PlatyNotchUI/Settings/SettingsWindow.swift` (sidebar, `show(section:)` via `SettingsTarget.resolve`), `apps/mac/Sources/PlatyNotchUI/Settings/AgentsSection.swift` (Approvals and Policy as sub-pages), `apps/mac/Sources/PlatyNotchKit/SettingsLogic.swift` (`AppURL.settings` keeps the whole path), `apps/mac/Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/SettingsRouteTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SettingsPage: String, CaseIterable, Sendable { case general, notch, now, notifications, widgets, agents, memory, privacy, about; public var title: String; public var systemImage: String }
  public struct SettingsTarget: Equatable, Sendable { public var section: String; public var detail: String?; public init(section: String, detail: String? = nil)
      public static func resolve(_ id: String?) -> SettingsTarget }   // appearance→notch, permissions→privacy, approvals→agents/approvals, policy→agents/policy, "widgets/<id>"→widgets/<id>, unknown passes through
  struct InfoButton: View { init(_ text: String) }
  struct NotchPreview: View { init(appearance: AppearanceSettings) }
  ```
- The sidebar uses an explicit list (not `allCases`): General, Notch, Widgets, Agents, Memory, Privacy & Permissions, About, then plugin sections under "Extensions"; Now and Notifications join in Task 25. General: launch at login, updates, "Take the tour again" (replays the full first run). Notch: live preview, then Minimal vs Always on, Open on, hover delay, pill width, live side, displays, hide in full screen, theme, surface (Glass disabled before macOS 26 with an ⓘ), Show Platy, Motion. Controls first; explanations in `InfoButton`s. Privacy & Permissions hosts today's `PermissionsSection` until Task 26.
- Render added: `settings-notch-preview` → `renders=58`.

- [ ] **Step 1: Write the failing tests**: `testLegacySections`, `testWidgetDetail`, `testPluginSectionPassesThrough`, `testAppURLKeepsPath` (`platynotch://settings/widgets/music` → `.settings(section: "widgets/music")`; `platynotch://settings` → `.settings(section: nil)`).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.SettingsRouteTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=58`, `SMOKE SETTINGS OK sections=7 onboarding=3`, config.json unchanged.
- [ ] **Step 5: Commit** `feat(mac): Settings sidebar with General and Notch pages and a live preview`

---

### Task 25: Now and Notifications settings pages

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Settings/NowSection.swift`, `apps/mac/Sources/PlatyNotchUI/Settings/NotificationsSection.swift`, `apps/mac/Sources/PlatyNotchKit/Now/NowSettings.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Settings/SettingsWindow.swift` (adds Now and Notifications to the sidebar list), `apps/mac/Sources/PlatyNotchUI/Now/NowView.swift` (`cycling: Bool` parameter from `NowSettings`)
- Test: `apps/mac/Tests/PlatyNotchUITests/NowNotificationsSettingsTests.swift`, `apps/mac/Tests/PlatyNotchKitTests/NowSettingsTests.swift`

**Interfaces:**
- Consumes: `GlanceSlots` (Task 6), `NotificationPolicy` (Task 22).
- Produces: `public struct NowSettings: Codable, Equatable, Sendable { public static let key = "now.settings"; public var heroCycling: Bool; public init(heroCycling: Bool = true); public static func load(from: UserDefaults) -> NowSettings; public func save(to: UserDefaults) }`; `NowView(…, cycling: Bool = true)` (false: only the top item, `HeroFrame.onStep == nil`).
- Now page: four slot pickers (glance-capable widgets with their status, plus "Claude/Codex usage"), ordered by drag handle only, hero cycling toggle. Notifications page: one row per `NotificationKind` (titles "Approvals", "Agent needs you or stopped", "Agent finished", "Alarms and timers", "Meeting starting", "Reminders you asked for", "Everything else", "Plug-ins without a kind") with three toggles; locked cells disabled with "Always" / "Never" and an ⓘ.

- [ ] **Step 1: Write the failing tests**: Kit `testNowSettingsMissingKeyCycles`, `testNowSettingsRoundTrip`; UI `testSlotPickerWritesSlots`, `testLockedApprovalToggles`, `testCyclingOffHidesArrows`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.NowSettingsTests` and `--filter PlatyNotchUITests.NowNotificationsSettingsTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE SETTINGS OK sections=9 onboarding=3`.
- [ ] **Step 5: Commit** `feat(mac): Settings › Now and Settings › Notifications`

---

### Task 26: Widgets grid, detail pages and the permission table

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Setup/PermissionTable.swift`, `apps/mac/Sources/PlatyNotchUI/Settings/WidgetCard.swift`, `Settings/WidgetDetail.swift`, `Settings/PermissionTableView.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Settings/WidgetsSection.swift` (grid with All / Everyday / Power filters; drag to reorder; chevrons removed), `apps/mac/Sources/PlatyNotchUI/Settings/PermissionsSection.swift` (the table on top, today's rows as detail), `apps/mac/Sources/PlatyNotchUI/Settings/SettingsWindow.swift` (`widgets/<id>` opens the detail), `apps/mac/Sources/PlatyNotchUI/Views/MemoryTab.swift` and `apps/mac/Sources/PlatyNotchUI/Views/LoopsList.swift` (empty states get one button to their settings page)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PermissionTableTests.swift`, `apps/mac/Tests/PlatyNotchUITests/WidgetsSettingsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum PermissionID: String, CaseIterable, Sendable { case accessibility, calendars, reminders, automation, camera, notifications, bluetooth }
  public enum PermissionAction: Equatable, Sendable { case request, openOwner(settingsSection: String), openSystemSettings }
  public struct PermissionRow: Identifiable, Equatable, Sendable { public let id: PermissionID; public let title: String; public let powers: String; public let withoutIt: String; public let action: PermissionAction
      public init(id: PermissionID, title: String, powers: String, withoutIt: String, action: PermissionAction) }
  public enum PermissionTable { public static let rows: [PermissionRow] }
  ```
- Actions: accessibility, calendars, reminders, notifications → `.request` (the existing `Permissions` request functions, on click only); camera → `.openOwner(settingsSection: "widgets/mirror")`; bluetooth → `.openOwner(settingsSection: "widgets/system")` (its prompt comes only from that widget's own setting); automation → `.openSystemSettings` (`Permissions.open(.automation)`). Rows show the current status; no new request path is created. Copy is one plain sentence each from `Permissions.swift`'s explanations (e.g. calendars: powers "Next meeting, Join buttons and meeting reminders", without it "No meetings in Now or the pill").
- Widget card: icon, title, on/off switch, "Power" tag for `.power`; click opens `WidgetDetail` (the widget's `settingsView()` with a back button).

- [ ] **Step 1: Write the failing tests**: Kit `testEveryPermissionHasARow`, `testNoNewRequestPaths` (camera and bluetooth rows are `.openOwner`, automation `.openSystemSettings`); UI `testFiltersSplitCategories`, `testDetailDeepLink`, `testDragIsTheOnlyOrdering` (the Widgets view model exposes `move(from:to:)` and no up/down actions).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PermissionTableTests` and `--filter PlatyNotchUITests.WidgetsSettingsTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE SETTINGS OK sections=9 onboarding=3`, config.json unchanged.
- [ ] **Step 5: Commit** `feat(mac): Widgets as a grid with detail pages; Privacy & Permissions table`

---

### Task 27: First run and the tour

**Files:**
- Modify: `apps/mac/Sources/PlatyNotchUI/Onboarding/OnboardingWindow.swift` (four pages from `OnboardingFlow`; `pageCount` 4; tour mode), `apps/mac/Sources/PlatyNotchUI/Settings/SettingsWindow.swift` (`SettingsServices.applyPreset`, `demoNotch`, `armTryIt`), `apps/mac/Sources/PlatyNotchUI/NotchController.swift` (`onExpanded`), `apps/mac/Sources/PlatyNotchUI/PanelRootView.swift` (`PanelViewModel.tourSample: LiveActivity?`), `apps/mac/Sources/PlatyNotchUI/Now/NowView.swift` (tour card at the top; quiet line hidden while it shows), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (no forced first run for existing users)
- Test: `apps/mac/Tests/PlatyNotchUITests/OnboardingFlowTests.swift`; extend `apps/mac/Tests/PlatyNotchUITests/NowViewTests.swift`

**Interfaces:**
- Consumes: `OnboardingFlow`, `FirstRunState`, `SetupPreset`, `PresetChange` (Task 23); `PermissionTable` (Task 26); `PlatyMoodModel.celebrate()`; `NowMetrics.tourCard` (Task 6).
- Produces: `SettingsServices.applyPreset(_ p: SetupPreset)` (`WidgetRegistry.setEnabled` for `plan(_:enabled:)`, saves `GlanceSlots(ids: p.glances)`, sets `AppearanceSettings.mode`, sets `AgentsVisibility.forcedOn` when `showsAgents`); `demoNotch()`; `armTryIt(onDone: @escaping () -> Void)`.
- Pages: Meet Platy (Platy 120 waving; `demoNotch()` once: expand, collapse after 1.2 s); Pick your setup (three cards; first run applies directly; Settings asks when `needsConfirmation`); Permissions (the table); Try it (`armTryIt` sets `tourSample` titled "This is Now" and waits for `onExpanded`, then `celebrate()` and Done). Every page has Skip. Existing users get a 44 pt card at the top of Now, "Take the 30-second tour" with Dismiss, until taken or dismissed (`tour.offered`); the quiet line hides while it shows.
- `SMOKE SETTINGS` onboarding becomes 4.

- [ ] **Step 1: Write the failing tests**: `testFirstRunHasFourPages`, `testTourHasThreePages`, `testExistingUserNotForced`, `testTryItCompletesOnExpand`, `testSampleIgnoredDuringApproval`; `NowViewTests.testTourCardFitsWithoutScrolling` (everything on, four glances, three live items, tour card shown: `fittingSize.height <= NowMetrics.available(in:)` on a 38 pt notch, and no quiet line).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.OnboardingFlowTests` and `--filter PlatyNotchUITests.NowViewTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `SMOKE SETTINGS OK sections=9 onboarding=4`; manual: a fresh `PLATYNOTCH_HOME` reaches "Try it" in under 60 s.
- [ ] **Step 5: Commit** `feat(mac): four-screen first run and a 30-second tour for existing users`

---

## Phase 7: Platy, moments, sound and showcase

### Task 28: Pond scene for Now's idle hero

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Mascot/PondScene.swift`, `apps/mac/Sources/PlatyNotchUI/Now/PondSceneView.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Now/TodaySummaryHero.swift`, `apps/mac/Sources/PlatyNotchUI/Smoke/ThemeRenders.swift`
- Test: `apps/mac/Tests/PlatyNotchKitTests/PondSceneTests.swift`, `apps/mac/Tests/PlatyNotchUITests/PondSceneViewTests.swift`

**Interfaces:**
- Consumes: `DayPhase` (Task 6), `Brand` (Task 1).
- Produces: `public struct PondPalette: Equatable, Sendable { public let skyTop: RGB; public let skyBottom: RGB; public let water: RGB; public let stars: Bool; public init(skyTop: RGB, skyBottom: RGB, water: RGB, stars: Bool); public static func of(_ phase: DayPhase) -> PondPalette }` with morning `0x3E6A7A`/`0x44686A`/`0x1C3B4A`, day `0x2E5E73`/`0x3F6670`/`0x1C3B4A`, evening `0x3A2F4F`/`0x5A4048`/`0x18303D` (sky top / sky bottom / water; every one ≥ 4.5 with white and cream), night `0x0D1626`/`0x1C3B4A`/`0x0F2230`, stars at night only; `final class PondSceneNSView: NSView { func configure(phase: DayPhase, animates: Bool); var isAnimating: Bool }` — CAGradientLayer sky, water layer, star layers at night, one 4 s ripple only while `animates` (`panelTicking && mode == .expanded && !reduceMotion`).
- Renders added: `now-pond-morning`, `now-pond-evening`, `now-pond-night` → `renders=64`.

- [ ] **Step 1: Write the failing tests**: Kit `testStarsOnlyAtNight`, `testGreetingReadableOnPond` (white and cream ≥ 4.5 on every phase's water and sky bottom); UI `testStillWhenCollapsed`, `testStillUnderReduceMotion`, `testAnimatesWhenOpen`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.PondSceneTests` and `--filter PlatyNotchUITests.PondSceneViewTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=64`; `scripts/perf-idle.sh` → PASS.
- [ ] **Step 5: Commit** `feat(mac): Platy's pond follows the time of day in Now`

---

### Task 29: Agent pups

**Files:**
- Create: `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyPup.swift`
- Modify: `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyArt.swift` (bandana), `apps/mac/Sources/PlatyNotchUI/Agents/AgentRow.swift` (pup replaces `AgentBadge` in the same 28 pt frame), `apps/mac/Sources/PlatyNotchUI/Agents/AgentBadge.swift` (deleted if unused), `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyRenders.swift` (gallery adds `pup-<agent>.png`)
- Test: extend `apps/mac/Tests/PlatyNotchUITests/PlatyTests.swift`

**Interfaces:**
- Consumes: `AgentIdentity.rgb(dark:)`, `StateTone` (Task 1).
- Produces: `struct PlatyPupView: View { init(agent: AgentIdentity, tone: StateTone, size: CGFloat) }` — small Platy with a bandana in the agent colour and a state ring with the tone's symbol; a still image cached per (agent, tone, size, scale), never animated.

- [ ] **Step 1: Write the failing tests**: `testPupForEveryAgentAndTone` (25 images, non-nil), `testPupsAreCached` (same `CGImage` instance on the second render), `testGalleryIncludesPups` (`writeGallery` count rises by 5).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchUITests.PlatyTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the smoke recipe → `renders=64`; `--platy-gallery /tmp/pn-gallery` → five pup PNGs.
- [ ] **Step 5: Commit** `feat(mac): a Platy pup in each agent's colour`

---

### Task 30: Moments

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Mascot/Moments.swift`
- Modify: `apps/mac/Sources/PlatyNotchKit/Mascot/PlatyMood.swift` (`PlatyMoodFlags.celebrationLength` 4 → 2), `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyMoodModel.swift` (`celebrate(_ event: MomentEvent, approvalsPending: Int)`; `celebrate()` stays, ungated), `apps/mac/Sources/PlatyNotchUI/Widgets/BuiltIn/LoopsWidget.swift` (games `onNewBest` → the gated form), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (builds `TodayServices` with `FocusModel(defaults: .standard, onFinish:)` that plays the existing sound and sends `.focusComplete`; `AgentActivityModel.observe` sends `.allAgentsFinished` when `allFinished`)
- Test: `apps/mac/Tests/PlatyNotchKitTests/MomentsTests.swift`; update `apps/mac/Tests/PlatyNotchKitTests/PlatyMoodTests.swift` (`testCelebrationLastsAFewSeconds` to 2 s)

**Interfaces:**
- Consumes: `SessionChanges.allFinished` (Task 5) through `AgentActivityModel` (Task 9); `FocusModel`'s existing `onFinish`.
- Produces: `public enum MomentEvent: Hashable, Sendable { case allAgentsFinished(at: Date), newBest(game: String, score: Int), focusComplete(endedAt: Date) }`; `public struct MomentGate: Sendable { public init(); public mutating func admit(_ e: MomentEvent, approvalsPending: Int) -> Bool }` (each event at most once; never while an approval is pending: dropped, not queued).

- [ ] **Step 1: Write the failing tests**: `testOncePerEvent`, `testNeverDuringApproval`, `testCelebrationEndsWithinTwoSeconds` (`PlatyMoodFlags.celebrate(at: t)` → celebrating at t+1.9, not at t+2.1); update `testCelebrationLastsAFewSeconds`.
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.MomentsTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift test` (incl. `PlatyMoodTests`, `PlatyTests` unchanged) → PASS.
- [ ] **Step 5: Commit** `feat(mac): two-second moments when agents finish, a best score or a focus session`

---

### Task 31: Optional "plip" when an agent needs you

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Agents/PlipPolicy.swift`, `apps/mac/Sources/PlatyNotchUI/Agents/PlipPlayer.swift`, `apps/mac/Sources/PlatyNotchUI/Resources/Sounds/plip.wav` (generated)
- Modify: `scripts/make-sounds.py` (a soft 120 ms plip), `apps/mac/Sources/PlatyNotchUI/UIResources.swift` (`CueSound.plip`), `apps/mac/Sources/PlatyNotchUI/Settings/AgentsSection.swift` (toggle, off by default), `apps/mac/Sources/PlatyNotchUI/NotchApp.swift` (plays on `SessionChanges.enteredNeedsYou`; smoke counts cue sounds)
- Test: `apps/mac/Tests/PlatyNotchKitTests/PlipPolicyTests.swift`

**Interfaces:**
- Consumes: `SessionChanges.enteredNeedsYou` through `AgentActivityModel.observe` (no new tracker); `TerminalApps`.
- Produces: `public enum PlipPolicy { public static let key = "agents.plipSound"; public static func shouldPlay(enabled: Bool, session: Session, frontmostBundleID: String?, isRunning: (String) -> Bool) -> Bool }`; UI `enum CueSound: String, CaseIterable { case plip }`.
- Muted when the session's terminal is frontmost: `TerminalApps.target(termProgram:isRunning:)` gives the bundle id; for `.pidAncestry`, muted when any of `TerminalApps.knownTerminalIDs` is frontmost. `--smoke` prints `sounds=3`.

- [ ] **Step 1: Write the failing tests**: `testOffByDefault` (`UserDefaults` without the key → not played), `testMutedWhenItsTerminalIsFrontmost` (iTerm session, frontmost `com.googlecode.iterm2` → false; Safari → true), `testUnknownTerminalMutedByAnyKnownTerminal`.
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
- Produces: `LaunchOptions.renderShowcaseDir: String?` (stored in the struct body); `enum ShowcaseRenders { static func write(to: URL) -> Result<Int, ThemeRenders.RenderError> }` — five scenes at 2× the full 560×380 panel including the black notch band: `now-music`, `now-agent`, `approval-diff`, `library`, `platy-idle`, each `-dark`/`-light`; prints `SHOWCASE OK renders=10`. README header: `docs/assets/showcase/now-agent-dark.png`. The recording script covers the 20-second storyboard (idle → agent starts → Platy paddles → approval peeks → Approve → done moment → music takes over) with the `scripts/fake-events.sh` commands for each beat. The website hero lives outside this repo and uses these files.

- [ ] **Step 1: Write the failing tests**: `testShowcaseFlag` (`--render-showcase /tmp/s` → `"/tmp/s"`; `--render-showcase --smoke` → nil), `testShowcaseWritesTen` (temp dir: 10 PNGs, each at least 1120×760).
- [ ] **Step 2: Run** `swift test --filter PlatyNotchKitTests.LaunchOptionsTests` and `--filter PlatyNotchUITests.ShowcaseRendersTests` → FAIL.
- [ ] **Step 3: Implement**; run `.build/debug/PlatyNotch --render-showcase "$WT/docs/assets/showcase"`.
- [ ] **Step 4: Run** → PASS; `swift test` → PASS; the full smoke recipe (`renders=64`, `sections=9 onboarding=4`, `widgets=6`, `sounds=3`); `scripts/perf-idle.sh` and `--state music` → PASS; manual on a real MacBook with everything on: Now shows at most one hero, four glances and one quiet line, nothing scrolls.
- [ ] **Step 5: Commit** `docs: showcase renders, recording script and README header`
