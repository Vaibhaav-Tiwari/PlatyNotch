# Plan 3c: Power features (Droppy- and Crowny-only extras)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the features only one of the researched apps has: Droppy's floating basket, file actions, Quickshare, screen capture, window snapping, menu bar manager, lock-screen view and camera mirror; Crowny's notes, GitHub, Home Assistant, mail, voice assistant and mascot; plus a decision spike on mirroring notifications.

**Architecture:** Each feature is a `NotchWidget` (Plan 3b Task 1) or a standalone controller registered by the app, off by default, with logic in `PlatyNotchKit` and tests there. Features that need a token keep it in the Keychain (service `PlatyNotch`). Features that talk to an AI reuse the memory provider config (Plan 2 providers via the core socket), so there is one place to set up AI.

**Tech Stack:** Swift 6, AppKit/SwiftUI, Vision, ImageIO, AVFoundation, ScreenCaptureKit, ApplicationServices (AX), Speech, `Lakr233/SkyLightWindow` (licence to verify before use), URLSession WebSocket.

**Spec:** `docs/specs/2026-10-23-platynotch-design.md` ("Power features")
**Depends on:** Plan 3 and Plan 3b Task 1 (widget API), 3b Task 5 (shelf) for Tasks 1–3, Plan 2 for Task 10.

## Global Constraints

- Every feature in this plan is off by default and has its own toggle under Settings → Power features.
- Droppy is GPL-3.0 + Commons Clause: read its behavior, never copy its code.
- Crowny is closed source: never reuse its art, copy or prompts; the mascot is original art.
- Network only where the feature is the network (Quickshare, GitHub, Home Assistant, chosen AI provider); each shows exactly where data goes before first use.
- Same idle budget as Plan 3b (under 1% CPU collapsed); monitors (mouse, AX observers, hotkeys) exist only while their feature is on.

## Review Focus

- Shaking the mouse while selecting text or drawing in an app (not dragging files) → no basket appears (Task 1).
- Quickshare on a large or private file → size limit and "this link is public" confirmation before upload; cancel stops the upload (Task 3).
- Window snapping on an app that refuses resizing (fixed-size window) → moves it without resizing, no loop of retries (Task 5).
- Voice assistant hears "delete all my reminders" → asks for confirmation before any destructive tool runs (Task 10).
- Menu bar manager on a Mac with a notch hiding icons behind the camera → hidden section never strands icons behind the notch; turning the feature off restores every icon (Task 6).

---

### Task 1: Floating basket with shake-to-summon

**Files:**
- Create: `Sources/PlatyNotchKit/Basket/ShakeDetector.swift`, `BasketStore.swift`
- Create: `Sources/PlatyNotchUI/Basket/BasketWindow.swift`, `BasketController.swift`, `BasketSwitcher.swift`
- Test: `Tests/PlatyNotchKitTests/BasketTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ShakeDetector { public init(sensitivity: Int = 3 /* 1…5 */); public mutating func push(x: Double, at: TimeInterval) -> Bool } // true when ≥ (7 - sensitivity) horizontal direction reversals, each ≥ 30 pt, within 0.5 s
  public struct Basket: Codable, Identifiable, Equatable { id: UUID; name: String; color: BasketColor; items: [ShelfItem] }
  public final class BasketStore { var baskets: [Basket]; func create(at: CGPoint) -> Basket; func move(itemIDs: [UUID], to basketID: UUID); func close(_ id: UUID, keepItems: Bool) }
  ```
- Shake is evaluated only during a file drag (`DragPoller` from 3b Task 5). Basket: small floating panel at the cursor, accepts drops, drag out, same actions as the shelf; up to 6 baskets, color-coded; switcher on ⌃⌥B (rebindable) cycles baskets like ⌘Tab; optional "appear instantly on any file drag".

- [ ] **Step 1–4:** tests `testShakeNeedsReversals`, `testSmallJitterIgnored` (reversals of 10 pt), `testSensitivityChangesThreshold`, `testOnlyDuringDrag` (detector not fed when no drag), `testMoveItemsBetweenBaskets` → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(mac): floating baskets with shake to summon`

---

### Task 2: File actions, Finder service and URL scheme

**Files:**
- Create: `Sources/PlatyNotchKit/Files/ConversionMatrix.swift`, `RenamePattern.swift`
- Create: `Sources/PlatyNotchUI/Files/FileActions.swift` (convert, zip/unzip, OCR, remove background, rename), `FinderService.swift`, `URLRoutes.swift`
- Test: `Tests/PlatyNotchKitTests/FileActionsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ConversionMatrix { public static func targets(for uti: UTType) -> [UTType] } // images ↔ png, jpeg, heic, webp (read), tiff, pdf; video → mp4 (H.264/HEVC), mov; audio → m4a, wav; images → single pdf
  public enum RenamePattern { public static func apply(_ pattern: String, name: String, index: Int, date: Date) -> String } // tokens {name} {n} {n:3} {date:yyyy-MM-dd}
  ```
- Actions on shelf/basket items (context menu "Actions"): Convert to… (ImageIO `CGImageDestination`, AVFoundation `AVAssetExportSession` with presets), Compress video (preset choice), Zip (`/usr/bin/ditto -c -k --sequesterRsrc --keepParent`), Unzip (`ditto -x -k`), Copy text (OCR, Vision `VNRecognizeTextRequest` accurate), Remove background (Vision `VNGenerateForegroundInstanceMaskRequest`, output PNG), Batch rename. Results land back on the shelf next to the source.
- Finder: Services menu item "Add to PlatyNotch Shelf" (`NSServices` in Info.plist) and URL routes `platynotch://shelf/add?path=<percent-encoded>` (multiple `path`), `platynotch://timer/start?d=25m`, `platynotch://clipboard/open` for Alfred/Raycast users.

- [ ] **Step 1–4:** tests `testImageTargets`, `testVideoTargets`, `testRenameTokens` (`"{date:yyyy}-{name}-{n:3}"` → `"2026-photo-007"`), `testURLRouteParsing` (in Kit: `URLRoute.parse`) → FAIL → implement → PASS; manual: convert HEIC → JPEG, OCR a screenshot, remove background from a photo.
- [ ] **Step 5: Commit** `feat(mac): file actions, Finder service and URL routes`

---

### Task 3: Quickshare

**Files:**
- Create: `Sources/PlatyNotchKit/Share/ShareProvider.swift`; `Sources/PlatyNotchUI/Share/QuickshareController.swift`, `Views/QuickshareSheet.swift`
- Test: `Tests/PlatyNotchKitTests/QuickshareTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public protocol ShareProvider { var id: String { get }; var displayName: String { get }; var maxBytes: Int64 { get }; var isPublic: Bool { get }
      func upload(file: URL, progress: @Sendable (Double) -> Void) async throws -> URL }
  public struct ZeroXZeroProvider: ShareProvider // https://0x0.st multipart "file", 512 MiB, public, link expires per their policy
  public struct CustomEndpointProvider: ShareProvider { init(url: URL, fieldName: String, headers: [String: String], responseURLPath: String?) } // response body is the URL, or JSON path
  public protocol ShareProviderRegistry { func register(_ p: ShareProvider) } // Pro may add a private hosted provider later
  ```
- Flow: Share link… → provider picker (remembered) → confirmation showing size and "Anyone with the link can download this" when `isPublic` → upload with progress in the notch → link copied, history of last 20 links with "copy again".

- [ ] **Step 1–4:** tests with `URLProtocol` stubs: `testZeroXZeroMultipart`, `testCustomEndpointJSONPath` (`{"data":{"url":"…"}}` with path `data.url`), `testTooLargeRejectedBeforeUpload`, `testCancelStopsUpload` → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(mac): Quickshare links`

---

### Task 4: Screen capture and annotation

**Files:**
- Create: `Sources/PlatyNotchKit/Capture/Annotation.swift` (model + undo stack)
- Create: `Sources/PlatyNotchUI/ScreenCapture/CaptureController.swift` (ScreenCaptureKit: area, window, full screen, AX element under cursor), `AnnotationEditor.swift`
- Test: `Tests/PlatyNotchKitTests/AnnotationTests.swift`

**Interfaces:**
- Produces: `public enum AnnotationShape: Codable, Equatable { case arrow(from: CGPoint, to: CGPoint), rect(CGRect), text(String, at: CGPoint), blur(CGRect), highlight(CGRect) }`; `public struct AnnotationDocument: Codable { var shapes: [AnnotationShape]; mutating func add(_:), undo(), redo() }`.
- Hotkey ⌃⇧4 (rebindable) → area/window/element modes; result opens the editor (arrow, box, text, blur, highlight, crop); Save, Copy, Add to shelf, Quickshare. Needs Screen Recording permission, requested on first use.

- [ ] **Step 1–4:** tests `testUndoRedo`, `testDocumentCodable` → FAIL → implement → PASS; manual: capture a window and an element, blur and save.
- [ ] **Step 5: Commit** `feat(mac): screen capture with annotation`

---

### Task 5: Window snapping

**Files:**
- Create: `Sources/PlatyNotchKit/Windows/SnapLayout.swift`; `Sources/PlatyNotchUI/Windows/WindowSnapper.swift`, `SnapHotKeys.swift`
- Test: `Tests/PlatyNotchKitTests/SnapLayoutTests.swift`

**Interfaces:**
- Produces: `public enum SnapTarget: String, CaseIterable, Codable { case leftHalf, rightHalf, topHalf, bottomHalf, leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds, maximize, center, topLeft, topRight, bottomLeft, bottomRight }`; `public enum SnapLayout { public static func frame(for t: SnapTarget, in visible: CGRect, gap: CGFloat) -> CGRect }`.
- `WindowSnapper.snap(_:)`: focused window via AX (`kAXFocusedWindowAttribute`), set `kAXPositionAttribute` then `kAXSizeAttribute`, then position again (some apps clamp); if `AXUIElementIsAttributeSettable(size)` is false, only move; one attempt, no retries. Default hotkeys ⌃⌥ + arrows / U I J K / D F G / E T / ↩ / C.

- [ ] **Step 1–4:** tests `testHalves`, `testThirdsCoverWidth` (three thirds with gap tile the width exactly), `testGapApplied`, `testCoordinateFlip` (AX uses top-left origin; `SnapLayout.axFrame(from:screenHeight:)`) → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(mac): window snapping`

---

### Task 6: Menu bar manager

**Files:**
- Create: `Sources/PlatyNotchKit/MenuBar/MenuBarLayout.swift`; `Sources/PlatyNotchUI/MenuBar/MenuBarManager.swift`
- Test: `Tests/PlatyNotchKitTests/MenuBarLayoutTests.swift`

**Interfaces:**
- Produces: `public enum MenuBarLayout { public static func safeHiddenWidth(menuBarItemsWidth: CGFloat, notchRect: CGRect?, screenWidth: CGFloat) -> CGFloat }` (never pushes visible items under the notch).
- Technique: two `NSStatusItem`s, a visible chevron and a separator; hiding sets the separator's `length` to the safe hidden width so items left of it slide off; reveal on chevron click or hover over the menu bar's right side; auto-hide after 10 s. Turning the feature off removes both items, restoring every icon.

- [ ] **Step 1–4:** tests `testNoNotchUsesFullWidth`, `testNotchLimitsWidth`, `testZeroWhenNothingToHide` → FAIL → implement → PASS; manual on a notched Mac with many icons.
- [ ] **Step 5: Commit** `feat(mac): menu bar icon manager`

---

### Task 7: Lock-screen view and camera mirror

**Files:**
- Create: `Sources/PlatyNotchUI/LockScreen/LockScreenWindow.swift`, `LockStateMonitor.swift`; `Sources/PlatyNotchUI/Camera/MirrorWidget.swift`
- Create: `THIRD_PARTY.md` entry for SkyLightWindow after its licence is confirmed

**Interfaces:**
- Lock screen: listen for `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications; on lock, show a separate small window delegated to the lock-screen space through SkyLightWindow with now playing (controls), running timers and agent states (no approval buttons on the lock screen; it says "Approval waiting, unlock to answer"). The main notch window is never moved to that space. If SkyLightWindow's licence is not compatible with Apache-2.0, this task is dropped and noted in the spec.
- Mirror: `AVCaptureSession` front camera preview in the expanded panel, starts on open, stops on collapse; camera light only while visible; needs `NSCameraUsageDescription` "Show a mirror in the notch when you open it.".

- [ ] **Step 1:** Confirm SkyLightWindow's licence; record the result in `THIRD_PARTY.md`.
- [ ] **Step 2–3:** Implement; manual: lock with music playing → controls work on the lock screen; approval pending → message only.
- [ ] **Step 4: Commit** `feat(mac): lock-screen view and camera mirror`

---

### Task 8: Notes and Obsidian tasks

**Files:**
- Create: `Sources/PlatyNotchKit/Notes/MarkdownTasks.swift`; `Sources/PlatyNotchUI/Notes/NotesWidget.swift`, `VaultAccess.swift`
- Test: `Tests/PlatyNotchKitTests/MarkdownTasksTests.swift`

**Interfaces:**
- Produces: `public struct MarkdownTask: Equatable { file: String; line: Int; text: String; done: Bool; due: Date? }`; `public enum MarkdownTasks { static func parse(_ md: String, file: String) -> [MarkdownTask]; static func toggle(_ md: String, line: Int) -> String }` (handles `- [ ]`, `* [ ]`, `- [x]`, Tasks-plugin `📅 2026-10-30`).
- Vault chosen via `NSOpenPanel` (security bookmark kept); watches the folder (FSEvents); shows open tasks from the last 30 days of edited files; tick writes back atomically. Quick note: text field appends `- HH:mm text` to today's daily note (`Daily/YYYY-MM-DD.md`, folder configurable) or to a plain `~/Library/Application Support/PlatyNotch/notes.md` when no vault.

- [ ] **Step 1–4:** tests `testParsesVariants`, `testToggleOnlyThatLine`, `testDueDateEmoji`, `testIgnoresCodeBlocks` → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(mac): notes and Obsidian tasks`

---

### Task 9: GitHub, Home Assistant, Apple Mail

**Files:**
- Create: `Sources/PlatyNotchKit/Integrations/ContributionGrid.swift`, `HAState.swift`
- Create: `Sources/PlatyNotchUI/Integrations/GitHubWidget.swift`, `GitHubClient.swift`, `HomeWidget.swift`, `HomeAssistantClient.swift`, `MailWidget.swift`, `AppleMail.swift`
- Test: `Tests/PlatyNotchKitTests/IntegrationsTests.swift` (+ fixtures)

**Interfaces:**
- GitHub: token (fine-grained, read-only) in Keychain; GraphQL `viewer { contributionsCollection { contributionCalendar { weeks { contributionDays { date contributionCount } } } } }`; REST search `is:pr is:open review-requested:@me` and `author:@me`; refresh every 10 min. `ContributionGrid.levels(counts: [Int]) -> [Int]` (0–4 quartiles).
- Home Assistant: base URL + long-lived token; WebSocket `/api/websocket` (`auth`, `subscribe_events state_changed`, `call_service`); user picks up to 8 entities; tiles toggle lights/switches, show sensors. `HAState.decode` for `light`, `switch`, `sensor`, `climate` basics.
- Apple Mail: AppleScript unread count and the 5 newest unread in Inbox (sender, subject); open message; no Gmail in this plan.

- [ ] **Step 1–4:** tests `testContributionLevels`, `testHAStateDecode` (fixture), `testHAAuthFlowMessages` (sequence auth_required → auth → auth_ok with a fake socket) → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(mac): GitHub, Home Assistant and Apple Mail widgets`

---

### Task 10: Voice dictation and assistant

**Files:**
- Create: `core/assistant/assistant.go`, `core/assistant/tools.go`, `core/assistant/assistant_test.go` (Go: chat loop over the configured extractor provider with tools); add protocol types `assistant.ask` / `assistant.reply` / `assistant.confirm` to `core/protocol` and `docs/PROTOCOL.md`
- Create: `Sources/PlatyNotchUI/Voice/SpeechListener.swift`, `VoiceController.swift`, `Views/VoiceOverlay.swift`

**Interfaces:**
- Go produces: `type Tool struct { Name, Description string; Schema json.RawMessage; Destructive bool; Run func(ctx context.Context, args json.RawMessage) (string, error) }`; `func New(p provider.Chat, tools []Tool) *Assistant`; `func (a *Assistant) Ask(ctx context.Context, text string, confirm func(Tool, json.RawMessage) bool) (string, error)`; requires a chat-capable provider: add `provider.Chat` interface (`Chat(ctx, messages []Message, tools []ToolSpec) (Message, error)`) implemented by the Plan 2 Ollama and OpenAI providers.
- Tools: `search_memory`, `list_open_loops`, `add_reminder` (forwarded to the app via `ext`-style UI request), `start_timer`, `what_is_running` (sessions + focus + music), `resolve_loop` (Destructive false), `delete_reminder` (Destructive true). Destructive tools call `confirm`, which round-trips `assistant.confirm` to the UI.
- Swift: hold-to-talk hotkey ⌥Space (rebindable); `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`; dictation mode inserts text into the focused field (pasteboard + ⌘V via Accessibility); assistant mode sends `assistant.ask` and speaks or shows the reply in the notch.

- [ ] **Step 1: Write failing Go tests**: `TestToolCallLoop` (fake chat returns a tool call then text), `TestDestructiveNeedsConfirm` (confirm false → tool not run, reply says it was cancelled), `TestNoProviderError` ("Set up an AI provider in Settings → Memory").
- [ ] **Step 2–4:** FAIL → implement → PASS (`go test ./assistant`); manual: "start a 10 minute timer", "what did I promise Priya?".
- [ ] **Step 5: Commit** `feat: voice dictation and assistant with confirmable tools`

---

### Task 11: (moved) Platy the platypus mascot

Moved to Plan 3b Task 13 so the mascot ships in v0.1. Nothing to do here.

---

### Task 12: Notification mirroring (decision spike)

**Files:**
- Create: `docs/research/notification-mirroring.md`

**Interfaces:**
- Output is a decision, not code: evaluate (a) observing Notification Center banners through Accessibility, (b) reading the notification database (requires Full Disk Access, private format), (c) not shipping it. For each: permissions, reliability across macOS 15/26, privacy impact, maintenance cost. Recommend one; if (a) or (b), append a task to this plan with interfaces and tests.

- [ ] **Step 1:** Prototype (a) for 2 hours on macOS 26; record what works.
- [ ] **Step 2:** Write the decision doc with the recommendation.
- [ ] **Step 3: Commit** `docs: notification mirroring decision`
