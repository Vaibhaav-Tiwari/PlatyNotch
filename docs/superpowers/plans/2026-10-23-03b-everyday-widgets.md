# Plan 3b: Widget system and everyday features

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the notch into a full everyday tool, matching what Crowny and Droppy ship: timers, stopwatch, alarms and world clocks; a richer music player with a live visualiser; volume and brightness HUDs; a file shelf you drop files onto; clipboard history; reminders, meeting countdowns and weather; wellbeing nudges; battery, AirPods and downloads; four games; pinned sites and Shortcuts; and appearance modes. All of it runs locally and is free.

**Architecture:** Every feature is a `NotchWidget`: a tile in the expanded panel, an optional live activity for the compact pill, and an optional settings view. A pure `LiveArbiter` decides which live activity owns the pill and which gets the side bubble. Logic (game engines, schedulers, parsers, stores) lives in `PlatyNotchKit` and is unit-tested; `PlatyNotchUI` only renders and talks to macOS. Plugins (Pro, later community widgets) register widgets through the same API.

**Tech Stack:** Swift 6, SwiftUI (Canvas, TimelineView), AppKit, EventKit, UserNotifications, CoreAudio (process tap for the visualiser), Accelerate (vDSP FFT), IOKit (power sources, power assertions), IOBluetooth, Carbon (`RegisterEventHotKey`), CoreLocation (optional), Open-Meteo HTTP API.

**Spec:** `docs/specs/2026-10-23-platynotch-design.md` ("Your day" section)
**Depends on:** Plan 3 Tasks 1–6 and 10 (models, client, geometry, store, panel, views, settings/plugin API). Task 1 here replaces Plan 3 Task 8's hard-coded Today tab with widgets.

## Global Constraints

- Idle cost: under 1% CPU on an M1 with the panel collapsed and no live activity (measured by `scripts/perf-idle.sh`, 60 s `top` sample). No timer or poll faster than 1 s while collapsed, except clipboard (0.5 s) and drag polling (only while the left mouse button is down).
- Network: only Open-Meteo (when the weather widget is enabled) and favicon fetches from the pinned site's own origin. Nothing else.
- Every widget can be disabled and reordered; disabled widgets do no work.
- Permissions are requested only when the user enables the widget that needs them.
- Clipboard and shelf never read from apps in `config.Memory.ExcludeApps`, never store items marked `org.nspasteboard.ConcealedType` or `TransientType`.
- Persistence: small state in `UserDefaults` suite `dev.platynotch.app`; files (shelf copies, clipboard images) in `~/Library/Application Support/PlatyNotch/{shelf,clipboard}` with mode 0700.
- Sounds: bundled, original or CC0; respect Focus and focus sessions (alarms still ring).

## Review Focus

- App quits or the Mac restarts with a timer or alarm running → it still fires (system notification scheduled as backup) and shows correctly on relaunch (Task 2).
- A file on the shelf is moved, renamed or deleted in Finder → shown as missing with Locate/Remove, never crashes a drag (Task 5).
- Password copied from a password manager → never enters clipboard history (Task 6).
- Volume keys pressed while Accessibility or Input Monitoring permission is missing → system HUD keeps working, our HUD stays off, Settings explains why (Task 4).
- Game running when the panel collapses or an approval arrives → game pauses instantly, the approval takes over, and the game resumes where it left off (Task 10).

---

### Task 1: Widget API, registry and live arbiter

**Files:**
- Create: `apps/mac/Sources/PlatyNotchKit/Widgets/LiveActivity.swift`, `LiveArbiter.swift`, `WidgetLayout.swift`
- Create: `apps/mac/Sources/PlatyNotchUI/Widgets/NotchWidget.swift`, `WidgetRegistry.swift`, `Views/TodayTab.swift` (rewrite to render widget tiles)
- Modify: `Sources/PlatyNotchUI/Plugin.swift` (add `PluginContext.register(widget:)`), Plan 3 Task 8 now-playing/meeting/focus/loops become widgets `music`, `meeting`, `focus`, `loops`
- Test: `Tests/PlatyNotchKitTests/LiveArbiterTests.swift`, `WidgetLayoutTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct LiveActivity: Identifiable, Equatable, Sendable {
      public let id: String          // "timer:3"
      public let widgetID: String
      public let priority: Int       // see table below
      public let glyph: LiveGlyph    // .symbol(String), .musicBars, .agentDots([SessionState]), .ring(progress: Double), .text(String)
      public let trailing: String?   // "4:59", "72%"
      public let tint: LiveTint      // .neutral, .accent, .warning, .critical
      public let expiresAt: Date?
  }
  public enum LiveArbiter { public static func pick(_ items: [LiveActivity], now: Date) -> (primary: LiveActivity?, bubble: LiveActivity?) } // drops expired; highest priority, ties → most recent id order given
  public struct WidgetLayout: Codable, Equatable { public var order: [String]; public var enabled: Set<String>
      public mutating func move(_ id: String, to index: Int); public func visible(available: [String]) -> [String] } // unknown ids dropped, new ids appended
  @MainActor public protocol NotchWidget: AnyObject {
      var id: String { get }; var title: String { get }; var systemImage: String { get }; var defaultEnabled: Bool { get }
      var liveActivities: [LiveActivity] { get }   // @Observable implementations; empty when nothing live
      func start(context: WidgetContext); func stop()
      func tileView() -> AnyView
      func settingsView() -> AnyView?
  }
  @MainActor public struct WidgetContext { public let store: AppStore; public let client: CoreClient; public let defaults: UserDefaults; public let notify: Notifier; public let openPanel: (String) -> Void }
  ```
- Priority table (exact): approval 100 (core, not a widget), alarm ringing 95, timer finished 90, agent blocked 80, meeting starting within 5 min 75, focus session 60, timer running 55, stopwatch 50, music playing 40, agent active 30, download in progress 25, battery ≤ 10% 20, shelf has items 10.

- [ ] **Step 1: Write failing tests**: `testHighestPriorityWins`, `testSecondBecomesBubble`, `testExpiredDropped`, `testTieKeepsInputOrder`, `testLayoutDropsUnknownAppendsNew`, `testMove`.
- [ ] **Step 2: Run** `swift test --filter "LiveArbiterTests|WidgetLayoutTests"` → FAIL.
- [ ] **Step 3: Implement**; convert the four Plan 3 features into widgets; compact pill renders `LiveArbiter.pick`; Settings gets a "Widgets" section with drag-to-reorder and toggles.
- [ ] **Step 4: Run** → PASS; manual: music playing + focus running → focus in pill, music in bubble.
- [ ] **Step 5: Commit** `feat(mac): widget system and live activity arbiter`

---

### Task 2: Timers, stopwatch, alarms, world clocks

**Files:**
- Create: `Sources/PlatyNotchKit/Time/DurationParser.swift`, `CountdownTimer.swift`, `Stopwatch.swift`, `Alarm.swift`, `WorldClock.swift`, `TimeStore.swift`
- Create: `Sources/PlatyNotchUI/Widgets/TimeWidget.swift`, `Views/TimeTile.swift`, `Views/RingingOverlay.swift`, `Resources/Sounds/` (CC0 chimes)
- Test: `Tests/PlatyNotchKitTests/TimeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum DurationParser { public static func parse(_ s: String) -> TimeInterval? } // "10" (minutes), "10m", "1h30", "1h 30m", "90s", "25:00", "1:05:00"; nil for garbage or 0; max 24 h
  public struct CountdownTimer: Codable, Identifiable, Equatable { id: UUID; label: String; duration: TimeInterval; startedAt: Date?; pausedRemaining: TimeInterval?
      func remaining(at: Date) -> TimeInterval; mutating func start(at:), pause(at:), resume(at:), reset(); func isFinished(at: Date) -> Bool }
  public struct Stopwatch: Codable, Equatable { mutating func start(at:), stop(at:), lap(at:), reset(); func elapsed(at: Date) -> TimeInterval; var laps: [TimeInterval] }
  public struct Alarm: Codable, Identifiable, Equatable { id: UUID; hour: Int; minute: Int; weekdays: Set<Int> /* 1=Sun…7=Sat, empty = once */; label: String; enabled: Bool
      func nextFire(after: Date, calendar: Calendar) -> Date? }
  public struct WorldClock: Codable, Identifiable, Equatable { id: UUID; timeZoneID: String; label: String
      func display(at: Date, relativeTo local: TimeZone) -> (time: String, dayOffset: Int, isNight: Bool) }
  public final class TimeStore // JSON in UserDefaults key "time.v1"; up to 10 timers, 20 alarms, 12 clocks
  ```
- UI: quick-add field accepting DurationParser input (plus "pomodoro" preset 25/5), several timers at once, stopwatch with laps, alarms list with weekday chips, world clocks with day/night glyph and "+1 day". Each running timer schedules a `UNNotificationRequest` as backup and cancels it when finished in-app. Ringing: notch expands with a pulsing ring, Snooze (9 min) and Stop; sound loops until stopped, max 60 s.

- [ ] **Step 1: Write failing tests**: `testDurationParserTable` (each input above → seconds; `"abc"`, `"0"`, `"25h"` → nil), `testTimerPauseResume`, `testTimerFinishedAfterRelaunch` (startedAt in the past beyond duration → finished), `testAlarmNextFireWeekdays` (Mon/Wed 07:30, now Tue 08:00 → Wed 07:30), `testAlarmOnceDisablesAfterFire`, `testAlarmDSTGap` (02:30 on the spring-forward day in `America/New_York` → 03:30 that day), `testWorldClockDayOffset` (Tokyo vs Kolkata late evening → +1), `testStopwatchLaps`.
- [ ] **Step 2–4:** FAIL → implement → PASS; manual: quit app with a 2-minute timer running → system notification fires; relaunch shows it finished.
- [ ] **Step 5: Commit** `feat(mac): timers, stopwatch, alarms, world clocks`

---

### Task 3: Music player upgrade and live visualiser

**Files:**
- Create: `Sources/PlatyNotchKit/Music/SpectrumBands.swift`, `DominantColor.swift`, `PlaybackClock.swift`
- Create: `Sources/PlatyNotchUI/Music/AudioTap.swift`, `MusicWidget.swift` (replaces the Plan 3 `NowPlaying` view layer), `Views/MusicTile.swift`, `Views/MusicBars.swift`
- Test: `Tests/PlatyNotchKitTests/MusicTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SpectrumBands { public static func compute(samples: [Float], sampleRate: Double, bands: Int) -> [Float] } // Hann window, vDSP FFT 1024, log-spaced bands 60 Hz–12 kHz, values 0…1 with fast attack / slow release smoothing applied by caller
  public struct BarSmoother { public init(bands: Int, attack: Float = 0.6, release: Float = 0.12); public mutating func push(_ v: [Float]) -> [Float] }
  public enum DominantColor { public static func of(cgImage: CGImage) -> (r: Double, g: Double, b: Double) } // 16×16 downsample, ignore near-black/near-white, average
  public struct PlaybackClock: Equatable { elapsed: TimeInterval; duration: TimeInterval; rate: Double; at: Date
      func position(now: Date) -> TimeInterval } // clamps to duration
  ```
- Visualiser: CoreAudio process tap on system output (macOS 14.4+ `AudioHardwareCreateProcessTap`, needs `NSAudioCaptureUsageDescription` "PlatyNotch listens to what your Mac is playing, only while music plays, to move the bars. Nothing is recorded or kept."); runs only while music plays and the pill or tile is visible; if permission denied, bars use a gentle synthetic animation driven by playback state.
- Tile: artwork with glow tinted by `DominantColor`, title/artist, source app icon, scrubber (set elapsed via the adapter), previous/play-pause/next, output device name, like button for Spotify/Music via AppleScript where supported.

- [ ] **Step 1–4:** tests `testSineHitsRightBand` (1 kHz sine → peak band contains 1 kHz), `testSilenceIsZero`, `testSmootherAttackRelease`, `testDominantColorIgnoresBlack`, `testPlaybackClockClamps` → FAIL → implement → PASS; manual: Spotify, Apple Music, YouTube in Safari all show and scrub.
- [ ] **Step 5: Commit** `feat(mac): music player with live visualiser`

---

### Task 4: Volume, brightness and backlight HUDs

**Files:**
- Create: `Sources/PlatyNotchKit/HUD/MediaKey.swift`, `LevelStep.swift`
- Create: `Sources/PlatyNotchUI/HUD/MediaKeyTap.swift`, `SystemVolume.swift`, `DisplayBrightness.swift`, `KeyboardBacklight.swift`, `HUDWidget.swift`, `Views/HUDView.swift`
- Test: `Tests/PlatyNotchKitTests/HUDTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum MediaKeyKind: Equatable { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown, backlightUp, backlightDown, other }
  public struct MediaKeyEvent: Equatable { public let kind: MediaKeyKind; public let isDown: Bool; public let isRepeat: Bool
      public static func decode(subtype: Int, data1: Int) -> MediaKeyEvent? } // NX_SYSDEFINED subtype 8; keyCode = (data1 & 0xFFFF0000) >> 16; state = (data1 & 0xFF00) >> 8 (0x0A down, 0x0B up); repeat = data1 & 0x1; codes: 0 up, 1 down, 7 mute, 2/3 brightness, 21/22 backlight
  public enum LevelStep { public static func next(_ current: Float, up: Bool, fine: Bool) -> Float } // 16 steps, ⌥⇧ fine = 64 steps, clamped 0…1
  ```
- `MediaKeyTap`: `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap, mask: 1 << 14)`; on our keys, apply the change ourselves and return nil (so the system HUD does not show); re-enable on `tapDisabledByTimeout`; if creation fails (no permission) the feature stays off and Settings shows "Needs Accessibility". Volume via CoreAudio default output device `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` and mute; brightness via `DisplayServices` (`dlopen` `/System/Library/PrivateFrameworks/DisplayServices.framework`, `DisplayServicesGetBrightness/SetBrightness`), unavailable → pass the key through; backlight via `KeyboardBrightnessClient` (CoreBrightness, `dlopen`), unavailable → pass through. HUD: slim bar that grows out of the notch for 1.5 s, shows output device for volume.
- Off by default; enabled in onboarding or Settings.

- [ ] **Step 1–4:** tests `testDecodeVolumeUpDown` (data1 `0x000A0A00` → volumeUp down; `0x000A0B00` up), `testDecodeRepeat`, `testDecodeUnknown` → other, `testLevelStepClamps`, `testFineSteps` → FAIL → implement → PASS; manual: with permission our HUD shows and the system HUD does not; without permission the system HUD works.
- [ ] **Step 5: Commit** `feat(mac): volume, brightness and backlight HUDs`

---

### Task 5: File shelf with drag detection

**Files:**
- Create: `Sources/PlatyNotchKit/Shelf/ShelfStore.swift`, `DragPoller.swift`
- Create: `Sources/PlatyNotchUI/Shelf/ShelfWidget.swift`, `ShelfDropView.swift` (AppKit `NSDraggingDestination`, file promises for Photos/Mail), `Views/ShelfTile.swift`, `ShelfActions.swift`
- Test: `Tests/PlatyNotchKitTests/ShelfTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ShelfItem: Codable, Identifiable, Equatable { id: UUID; kind: Kind /* .file(URL), .text(String), .url(URL), .image(fileURL) */; addedAt: Date; pinned: Bool; ownsFile: Bool /* true for promises, text, images stored in shelf dir */ }
  public final class ShelfStore { init(directory: URL, defaults: UserDefaults); var items: [ShelfItem]
      func add(_ k: ShelfItem.Kind) -> ShelfItem   // de-duplicates the same file URL, moves it to front
      func remove(_ id: UUID)                       // deletes owned files
      func clearUnpinned()
      func isMissing(_ item: ShelfItem, fileManager: FileManager) -> Bool
      func expireOwned(olderThan: TimeInterval, now: Date) } // owned files older than 7 days removed unless pinned
  public struct DragPoller { public mutating func sample(changeCount: Int, mouseDown: Bool) -> DragEvent? } // .began when changeCount changes while mouse down, .ended on mouse up
  ```
- Behavior: dragging anything near the top edge (within 60 pt of the notch) expands the panel into a drop zone; drop adds items; drag out supports multiple items (`NSFilePromiseProvider` for owned files, URLs otherwise); context menu: Open, Quick Look (`QLPreviewPanel`), Reveal in Finder, AirDrop (`NSSharingService(named: .sendViaAirDrop)`), Share…, Copy, Copy Path, Pin, Remove; missing files show a badge with Locate/Remove. Live activity "shelf has items" shows the count.

- [ ] **Step 1–4:** tests `testDedupMovesToFront`, `testRemoveDeletesOwnedOnly`, `testMissingDetected`, `testExpireKeepsPinned`, `testDragPollerBeginEnd` → FAIL → implement → PASS; manual: drop from Finder, Safari image, Photos; drag out into Mail; AirDrop; rename a shelf file in Finder → missing badge.
- [ ] **Step 5: Commit** `feat(mac): file shelf with drop zone and AirDrop`

---

### Task 6: Clipboard history and picker

**Files:**
- Create: `Sources/PlatyNotchKit/Clipboard/ClipboardHistory.swift`, `ClipFilter.swift`
- Create: `Sources/PlatyNotchUI/Clipboard/ClipboardWatcher.swift`, `HotKey.swift` (Carbon), `ClipPickerPanel.swift`, `ClipboardWidget.swift`, `Paster.swift`
- Test: `Tests/PlatyNotchKitTests/ClipboardTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ClipItem: Codable, Identifiable, Equatable { id: UUID; kind: Kind /* .text(String), .url(URL), .image(fileURL, width, height), .files([URL]) */; sourceBundleID: String?; copiedAt: Date; pinned: Bool; hash: Int }
  public struct ClipboardHistory: Codable { public var items: [ClipItem]; public var limit = 200; public var maxAge: TimeInterval = 7 * 86400
      public mutating func record(_ i: ClipItem, now: Date)   // same hash → move to top; trims unpinned beyond limit/age
      public func search(_ q: String) -> [ClipItem] }        // case/diacritic-insensitive substring over text and URLs
  public enum ClipFilter { public static func shouldRecord(types: [String], sourceBundleID: String?, excluded: Set<String>) -> Bool } // false for org.nspasteboard.ConcealedType, TransientType, AutoGeneratedType, com.agilebits.onepassword, excluded apps
  struct HotKey { init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) } // default ⌥⇧V, rebindable in Settings
  ```
- Picker: floating panel near the cursor, search field focused, ↑/↓, ↩ pastes (writes item to the pasteboard, then posts ⌘V via `CGEvent` if Accessibility is granted, else just copies and shows "Copied, press ⌘V"), ⌘1–9 quick pick, ⌘P pin, ⌫ delete. Images saved as PNG in the clipboard dir, max 10 MB each. "Pause history" toggle in the menu bar.

- [ ] **Step 1–4:** tests `testDuplicateMovesToTop`, `testLimitKeepsPinned`, `testAgeTrim`, `testConcealedSkipped`, `testExcludedAppSkipped`, `testSearchDiacritics` ("cafe" finds "café") → FAIL → implement → PASS; manual: copy from 1Password → nothing recorded; ⌥⇧V → paste into TextEdit.
- [ ] **Step 5: Commit** `feat(mac): clipboard history with keyboard picker`

---

### Task 7: Reminders, meeting countdowns, weather

**Files:**
- Create: `Sources/PlatyNotchKit/Day/QuickAddParser.swift`, `MeetingReminderSchedule.swift`, `Weather.swift`
- Create: `Sources/PlatyNotchUI/Day/RemindersWidget.swift`, `MeetingWidget.swift` (extends Plan 3's), `WeatherWidget.swift`, `WeatherClient.swift`, `Views/…Tile.swift`
- Test: `Tests/PlatyNotchKitTests/DayTests.swift`, fixture `Tests/PlatyNotchKitTests/Fixtures/open-meteo.json`

**Interfaces:**
- Produces:
  ```swift
  public struct QuickAdd: Equatable { public let title: String; public let due: Date?; public let isEvent: Bool }
  public enum QuickAddParser { public static func parse(_ s: String, now: Date, calendar: Calendar) -> QuickAdd } // NSDataDetector for dates; "call Priya at 5pm" → title "Call Priya", due today 17:00 (tomorrow if past); "meeting with Sam tomorrow 3pm for 30 min" → isEvent true
  public enum MeetingReminderSchedule { public static func fireDates(start: Date, offsets: [Int] = [10, 5, 1], now: Date) -> [Date] } // future only
  public struct WeatherNow: Equatable { temperatureC: Double; code: Int; isDay: Bool; nextRain: Date?; hourly: [(Date, Double /*precip prob*/)] }
  public enum WeatherDecoder { public static func decode(_ data: Data) throws -> WeatherNow } // Open-Meteo forecast response
  ```
- Reminders: EventKit reminders due today and overdue; tick to complete; quick add from the Today tile (reminder or event by `isEvent`); default list chosen in Settings.
- Meetings: reminder live activity at 10, 5, 1 minutes with a countdown ring, Join button using Plan 3 `MeetingLinks`.
- Weather: city from Settings (Open-Meteo geocoding `https://geocoding-api.open-meteo.com/v1/search?name=`) or approximate location (CoreLocation, reduced accuracy, opt-in); forecast `https://api.open-meteo.com/v1/forecast?latitude&longitude&current=temperature_2m,weather_code,is_day&hourly=precipitation_probability&forecast_hours=12`; refresh every 30 min while enabled; °C/°F setting.

- [ ] **Step 1–4:** tests `testQuickAddTimeToday`, `testQuickAddPastTimeTomorrow`, `testQuickAddEvent`, `testQuickAddNoDate`, `testMeetingOffsetsFutureOnly`, `testWeatherDecodeFixture` (temperature, code, next rain hour) → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(mac): reminders, meeting countdowns and weather`

---

### Task 8: Wellbeing nudges

**Files:**
- Create: `Sources/PlatyNotchKit/Wellbeing/NudgeScheduler.swift`, `WaterLog.swift`
- Create: `Sources/PlatyNotchUI/Wellbeing/WellbeingWidget.swift`, `Views/NudgeCard.swift`
- Test: `Tests/PlatyNotchKitTests/WellbeingTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum NudgeKind: String, Codable { case water, stand, eyes }
  public struct NudgeSettings: Codable, Equatable { var water = 60, stand = 50, eyes = 20 /* minutes, 0 = off */; var quietStart = 22, quietEnd = 8 /* hours */; var dailyWaterGoal = 8 }
  public struct NudgeContext { let now: Date; let lastDone: [NudgeKind: Date]; let inFocusSession: Bool; let inMeeting: Bool; let fullScreen: Bool; let idleSeconds: TimeInterval }
  public enum NudgeScheduler { public static func due(_ s: NudgeSettings, _ c: NudgeContext, calendar: Calendar) -> NudgeKind? } // nil during focus, meetings, full screen, quiet hours, or idle ≥ 300 s; eyes beats stand beats water when several are due
  public struct WaterLog: Codable { mutating func add(at: Date); func count(on: Date, calendar: Calendar) -> Int }
  ```
- Nudge card peeks from the notch for 10 s: "Look 20 feet away for 20 seconds" with a 20 s ring; stand; water with "+1 glass" (count / goal). Idle from `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)`.

- [ ] **Step 1–4:** tests `testNoNudgeDuringFocus`, `testQuietHoursAcrossMidnight`, `testIdleResets`, `testPriorityEyesFirst`, `testWaterCountPerDay` → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(mac): water, stand and eye-break nudges`

---

### Task 9: Battery, AirPods, downloads, keep-awake

**Files:**
- Create: `Sources/PlatyNotchKit/System/DownloadDetector.swift`, `BatteryState.swift`
- Create: `Sources/PlatyNotchUI/System/PowerMonitor.swift`, `HeadphonesMonitor.swift`, `DownloadsWatcher.swift` (FSEvents), `KeepAwake.swift`, `SystemWidget.swift`, `Views/SystemTile.swift`
- Test: `Tests/PlatyNotchKitTests/SystemTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct BatteryState: Equatable { percent: Int; charging: Bool; pluggedIn: Bool; minutesRemaining: Int?
      public var isLow: Bool { percent <= 10 && !pluggedIn } }
  public enum DownloadDetector { public static func state(fileName: String) -> DownloadFileState } // .inProgress for .crdownload/.download/.part/.partial/.opdownload, .done otherwise
  ```
- Power: `IOPSCopyPowerSourcesInfo` + `IOPSNotificationCreateRunLoopSource`; plug-in / unplug peek with percent; low-battery live activity.
- Headphones: `IOBluetoothDevice.register(forConnectNotifications:)`; battery from IORegistry keys `BatteryPercentLeft`, `BatteryPercentRight`, `BatteryPercentCase`, `BatteryPercentSingle` when present; hide battery if absent (best effort); connect peek with device name.
- Downloads: FSEvents on `~/Downloads` (and Safari's download dir if different); in-progress live activity with file name; finished notice with Open and Show in Finder; "move to shelf" action.
- Keep awake: `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)` for 30 min / 1 h / 2 h / until off; live activity with remaining time.

- [ ] **Step 1–4:** tests `testDownloadSuffixes`, `testBatteryLow` (10% unplugged true, 10% plugged false) → FAIL → implement → PASS; manual: plug/unplug, AirPods connect, download a file in Safari, keep awake 30 min.
- [ ] **Step 5: Commit** `feat(mac): battery, AirPods, downloads and keep-awake`

---

### Task 10: Games: Snake, Tetris, 2048, Flappy

**Files:**
- Create: `Sources/PlatyNotchKit/Games/SeededRNG.swift`, `Snake.swift`, `Tetris.swift`, `Game2048.swift`, `Flappy.swift`, `HighScores.swift`
- Create: `Sources/PlatyNotchUI/Games/GamesWidget.swift`, `GameHost.swift` (TimelineView + Canvas, keyboard), `Views/SnakeView.swift`, `TetrisView.swift`, `Game2048View.swift`, `FlappyView.swift`
- Test: `Tests/PlatyNotchKitTests/GamesTests.swift`

**Interfaces:**
- Produces (all engines are value types, deterministic given a seed, advanced by `step`):
  ```swift
  public struct SeededRNG: RandomNumberGenerator { public init(seed: UInt64) } // SplitMix64
  public struct Snake { public init(width: Int = 24, height: Int = 8, seed: UInt64); public mutating func turn(_ d: Direction); public mutating func step(); public var body: [Point]; public var food: Point; public var isOver: Bool; public var score: Int } // no reversing into itself; wall or self hit → over
  public struct Tetris { public init(width: Int = 10, height: Int = 20, seed: UInt64); public mutating func apply(_ i: TetrisInput) /* left, right, rotate, softDrop, hardDrop */; public mutating func tick(); public var board: [[Int]]; public var linesCleared: Int; public var score: Int; public var isOver: Bool } // 7-bag randomizer, simple wall kicks (try offsets 0, -1, +1, -2, +2), scoring 100/300/500/800
  public struct Game2048 { public init(seed: UInt64); public mutating func move(_ d: Direction) -> Bool; public var grid: [[Int]]; public var score: Int; public var isOver: Bool; public var won: Bool } // spawn 2 (90%) or 4 (10%) after a move that changed the grid
  public struct Flappy { public init(seed: UInt64); public mutating func flap(); public mutating func step(dt: Double); public var birdY: Double; public var pipes: [Pipe]; public var score: Int; public var isOver: Bool }
  public struct HighScores: Codable { public mutating func record(game: String, score: Int) -> Bool /* true if new best */; public func best(_ game: String) -> Int }
  ```
- `GameHost` runs a frame loop only while the expanded panel shows a game and the window is key; pauses on collapse, on any approval or alarm, on app deactivation; resume overlay "Press Space". Notch-shaped boards sized for the expanded panel.

- [ ] **Step 1: Write failing tests**: Snake `testGrowsOnFood`, `testDiesOnWall`, `testCannotReverse`; Tetris `testLineClearScores100`, `testTetrisScores800`, `testRotateKicksOffWall`, `testSevenBagHasAllPieces`; 2048 `testMergeRowLeft` (`[2,2,2,2]` → `[4,4,0,0]`), `testNoDoubleMerge` (`[4,4,8,0]` → `[8,8,0,0]`), `testNoSpawnWhenNoChange`, `testGameOverDetection`; Flappy `testGravityAndFlap`, `testPipeCollisionEndsGame`; `testHighScoreRecord`.
- [ ] **Step 2–4:** FAIL → implement → PASS; manual: play each, approval arrives mid-game → pauses and resumes.
- [ ] **Step 5: Commit** `feat(mac): snake, tetris, 2048 and flappy in the notch`

---

### Task 11: Pinned sites and Shortcuts

**Files:**
- Create: `Sources/PlatyNotchKit/Launch/PinnedSite.swift`, `FaviconURL.swift`
- Create: `Sources/PlatyNotchUI/Launch/LaunchWidget.swift`, `FaviconCache.swift`, `ShortcutsRunner.swift`, `Views/LaunchTile.swift`
- Test: `Tests/PlatyNotchKitTests/LaunchTests.swift`

**Interfaces:**
- Produces: `public struct PinnedSite: Codable, Identifiable, Equatable { id: UUID; title: String; url: URL }`; `public enum FaviconURL { public static func candidates(for url: URL) -> [URL] }` (`<origin>/favicon.ico`, `<origin>/apple-touch-icon.png`); `struct ShortcutsRunner { func list() async -> [String]; func run(_ name: String) async -> Int32 }` using `/usr/bin/shortcuts list` and `/usr/bin/shortcuts run`.
- Tile: up to 12 pinned sites (open in default browser), up to 8 pinned Shortcuts; add current browser tab (Safari/Chrome/Arc via AppleScript `URL of active tab`); favicons cached on disk 30 days.

- [ ] **Step 1–4:** tests `testFaviconCandidatesUseOrigin` (`https://a.com/x/y?z` → `https://a.com/favicon.ico`…), `testPinnedSiteCodable` → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(mac): pinned sites and Shortcuts`

---

### Task 12: Appearance, modes and performance budget

**Files:**
- Create: `Sources/PlatyNotchKit/Appearance/AppearanceSettings.swift`, `SpringParams.swift`
- Modify: `Sources/PlatyNotchUI/NotchController.swift`, `Settings/AppearanceSection.swift`
- Create: `scripts/perf-idle.sh`
- Test: `Tests/PlatyNotchKitTests/AppearanceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct AppearanceSettings: Codable, Equatable {
      var mode: Mode = .alwaysOn          // .alwaysOn | .minimal
      var openOn: OpenTrigger = .hover    // .hover | .click
      var hoverDelay: Double = 0.15
      var pillWidth: PillWidth = .standard // .compact | .standard | .wide
      var liveSide: Side = .right
      var displays: DisplayChoice = .main // .main | .all | .withNotch
      var theme: Theme = .system          // .system | .dark | .light
      var spring: SpringParams = .init(response: 0.42, dampingFraction: 0.78, blur: 8)
      var hideInFullScreen = true
  }
  public struct SpringParams: Codable, Equatable { response: Double; dampingFraction: Double; blur: Double
      public func clamped() -> SpringParams } // response 0.2…1.0, damping 0.5…1.0, blur 0…20
  ```
- `perf-idle.sh`: launches the built app with a fake core, waits 10 s, samples `top -l 60 -s 1 -pid <pid> -stats cpu`, fails if mean > 1.0.

- [ ] **Step 1–4:** tests `testDefaults`, `testSpringClamped`, `testCodableBackwardCompatible` (decoding `{}` gives defaults) → FAIL → implement → PASS; run `scripts/perf-idle.sh` → PASS.
- [ ] **Step 5: Commit** `feat(mac): appearance modes and idle performance budget`

---

### Task 13: Platy the platypus (mascot and app icon)

The platypus is PlatyNotch's mascot, Platy: an animal that borrows a feature from every other animal, like the app borrows the best of every notch app. Platy is original art drawn in code, so it is vector, animatable, tiny, and Apache-2.0 like everything else.

**Files:**
- Create: `design/platy/platy.svg` (master: front-facing, teal-brown body, cream bill, small webbed paws, flat tail), `design/platy/README.md` (palette, proportions, do/don't)
- Create: `Sources/PlatyNotchKit/Mascot/PlatyMood.swift`; `Sources/PlatyNotchUI/Mascot/PlatyView.swift` (SwiftUI `Canvas` drawing of the master, parameterised by pose), `PlatyPose.swift`
- Create: `scripts/render-icon.swift` (renders `PlatyView` with `ImageRenderer` at 16–1024 px into `AppIcon.iconset`, then `iconutil -c icns`), `apps/mac/Resources/AppIcon.icns`
- Test: `Tests/PlatyNotchKitTests/PlatyMoodTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum PlatyMood: String, CaseIterable, Sendable { case idle, working, thinking, waiting, done, dancing, focused, sleepy, celebrating }
  public enum PlatyMoodResolver {
      public static func mood(sessions: [SessionState], approvalsPending: Int, musicPlaying: Bool, focusActive: Bool, justFinished: Bool, hour: Int) -> PlatyMood
  }
  // priority: approvalsPending > 0 or any blocked/waiting_input → .waiting; justFinished → .done; focusActive → .focused;
  // any active → .working; musicPlaying → .dancing; hour in 23…5 → .sleepy; else .idle. (.thinking is used by the voice assistant, .celebrating by game high scores.)
  public struct PlatyPose: Equatable { var eyesOpen: Double; var billAngle: Double; var tailWag: Double; var bounce: Double; var headphones: Bool; var tint: Color? }
  public extension PlatyPose { static func at(_ mood: PlatyMood, time: TimeInterval) -> PlatyPose } // looping animation per mood: working = steady paddling bounce, waiting = tail tap + amber tint, dancing = headphones + bounce on beat, sleepy = eyes closed + slow breathing
  struct PlatyView: View { init(mood: PlatyMood, size: CGFloat) } // TimelineView(.animation) only while visible; static frame when Reduce Motion is on
  ```
- Where Platy appears: the compact pill in Always-on mode (a toggle "Show Platy"; off gives the plain "professional" look), onboarding, the empty states of Agents/Today, the menu bar icon (monochrome template version of the silhouette), the app icon, README and website.
- One Platy per agent session is not needed: per-agent color is a small badge next to Platy.

- [ ] **Step 1: Write failing tests**: `testWaitingBeatsEverything`, `testDoneBeatsWorking`, `testMusicDances`, `testNightSleepy` (hour 2, nothing live → sleepy), `testPoseIsPeriodic` (`PlatyPose.at(.working, time: t) == PlatyPose.at(.working, time: t + period)`).
- [ ] **Step 2: Run** `swift test --filter PlatyMoodTests` → FAIL.
- [ ] **Step 3: Implement** mood and poses; draw `platy.svg`, then `PlatyView` matching it.
- [ ] **Step 4: Run** → PASS; run `swift scripts/render-icon.swift` → `AppIcon.icns` contains 10 sizes (`iconutil` succeeds); manual: each mood visible in a debug gallery (`swift run PlatyNotch --platy-gallery`).
- [ ] **Step 5: Commit** `feat(mac): Platy the platypus mascot and app icon`
