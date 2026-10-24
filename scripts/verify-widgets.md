# Widgets: manual verification

Checks for the widget system (Plan 3b). Automated checks cover the logic (`swift test`:
`LiveArbiterTests`, `WidgetLayoutTests`, `WidgetRegistryTests`) and the launch
(`swift run PlatyNotch --smoke` prints `widgets=<n>`, the number of enabled widgets whose
tile was built; `--smoke-settings` visits Settings › Widgets). This list covers what only
a person looking at the screen can confirm.

## Setup

Use a throwaway home so nothing touches your real PlatyNotch data:

```sh
scripts/fake-events.sh            # prints the command for terminal B
cd apps/mac && PLATYNOTCH_EXTERNAL_CORE=1 PLATYNOTCH_HOME=… PLATYNOTCH_SOCKET=… swift run PlatyNotch
```

Widget order and on/off live in `UserDefaults.standard` under `widgets.layout` (JSON).
Under `swift run` the domain is the executable name: reset with
`defaults delete PlatyNotch widgets.layout`. The live ear side, Minimal mode and the other
panel settings are in Settings › Appearance and apply at once (one JSON value,
`appearance.settings`; `defaults delete PlatyNotch appearance.settings` resets them).

Note the Mac model and macOS version next to each tick.

## Task 1a: widget API, registry, live arbiter

- [ ] **1. Today tab is widget tiles.** Expand the panel, open Today: the nine widgets that are
  on by default, in this order: Music, Meetings, Focus, Open loops, Time, Shelf, System, Games,
  Sites & Shortcuts, scrolling when they do not fit. With no
  music app open the music tile says "Nothing playing".
- [ ] **2. Music feeds the pill from launch.** Quit PlatyNotch, start music in Music or
  Spotify, launch PlatyNotch and do not open the panel. Within a few seconds the right
  ear shows the green music bars. (Bundled app: immediately, via the media adapter.
  `swift run` without the adapter: within ~6 s only if PlatyNotch already has Automation
  permission for that player; otherwise after the Today tab is opened once. No
  Automation prompt may appear at launch.) Pause the music: the bars go away.
- [ ] **3. Arbiter: focus beats music.** Music playing, then start a 25 min focus
  session from the Focus tile. The right ear shows the moon and a `24:59` countdown
  ticking once a second, with the music bars as a small bubble next to it. Stop focus:
  the music bars are the primary again, no bubble.
- [ ] **4. Approval badge always wins.** With music and focus live, trigger an approval
  (`fake-events.sh` step). While the panel is compact (after the peek, or answer from the
  expanded panel and wait), the ear shows the amber count, never the live glyphs. When the
  core is down the amber bolt shows instead.
- [ ] **5. liveSide swaps the ears.** Settings › Appearance › Live activities: Left. The live
  glyph and badge move to the left ear, the agent dots to the right, at once. Right: back to
  dots left, live right.
- [ ] **6. Minimal mode.** Settings › Appearance › Notch: Minimal, no agent sessions: the
  pill is hidden at once. Start music: the pill appears with the
  bars. Stop music: hidden again. Start focus: the pill appears. (Shelf/weather, once
  they exist, never bring it back on their own.)
- [ ] **7. Settings › Widgets.** Lists the four widgets with a switch each. Turn Music
  off: its tile leaves the Today tab and the music bars leave the pill even while music
  plays (and, under `swift run` without the adapter, Activity Monitor shows no more
  `osascript`/perl children from PlatyNotch). Turn it back on: tile and bars return.
  Drag Open loops to the top (or use the arrow buttons): the Today tab follows at once.
  Quit and relaunch: order and switches are kept.
- [ ] **8. Focus off hides the Focus tab.** Turn Focus off in Settings › Widgets: the
  panel's Focus tab disappears; a session that was running no longer holds notices.
  Turn it on again: the tab returns.
- [ ] **9. Meeting in the pill.** With calendar access granted and a meeting starting in
  under 10 minutes: the right ear shows a calendar glyph and an m:ss countdown; at the
  start time it goes away (within a second or so).
- [ ] **10. VoiceOver.** On the compact pill VoiceOver reads the session count, then
  e.g. "Focus session running, Music playing".

## Task 1b: transient surfaces (peeks, HUD, ringing, drop zone)

No widget uses these surfaces yet (Tasks 2, 4, 5, 8 and 9 do), so most checks run once
those land; until then `--smoke` drives every surface through the real panel for a moment
(`surfaces=ok`) and `PanelSurfaceTests` / `PanelSurfacesTests` cover the precedence. The
rules being checked are `PanelPrecedence` in `PlatyNotchKit/PanelState.swift`.

- [ ] **11. Pill timelines stop while hidden.** Start a focus session (pill shows the
  `m:ss` countdown) and play music. Open a full-screen app (e.g. a video in Safari, ⌃⌘F)
  so the pill is suppressed. In Instruments › Time Profiler (or Activity Monitor › CPU)
  PlatyNotch drops to idle: neither the 1 s countdown nor the 12 fps music bars render.
  Move to the top edge: the pill reveals and both tick again.
- [ ] **12. Reduce Motion stills the music bars.** System Settings › Accessibility › Display
  › Reduce motion on: with music playing the pill and the Music tile show three still
  bars. Off: they bounce again.
- [ ] **13. Ringing (Task 2).** An alarm rings while the panel is compact: the ringing card
  grows out of the notch and stays until Stop or Snooze. Escape does nothing to it and the
  frontmost app keeps keyboard focus (type in it while it rings). Over a full-screen video
  it still shows. With the panel open (or opened from the menu bar while it rings), the
  panel stays open and a small amber "Stop" chip sits at the top right (beside the camera
  on a notch, in the header strip otherwise); one click on it stops the alarm.
- [ ] **14. Approval and ringing.** While an alarm rings, trigger an approval
  (`fake-events.sh`): the approval peek shows, and the alarm stays stoppable without
  answering: the amber "Stop" chip beside the camera (or in the header strip) stops it on
  the first click, and the menu bar menu has "Stop <alarm title>" at the top. Clicking
  Stop does not move the approval card, does not change the peek's height and does not
  take the approval's keyboard shortcuts. Ring again, answer the approval instead: the
  full ringing card comes back. Escape never hides the approval. With the panel open and
  an approval listed, the same chip shows and the cards do not move when it appears or goes.
- [ ] **15. HUD (Task 4).** Press volume up: a slim bar grows out of the notch for about
  1.5 s, no keyboard focus is taken, and clicks just below the pill go to the app
  underneath. With an approval peek showing, volume keys draw only a thin line at the
  bottom of the approval card, which never moves. Over a full-screen app our HUD does not
  show (the system HUD does).
- [ ] **16. Drop zone (Task 5).** Drag a file from Finder towards the notch: within about
  60 pt of it the panel opens into the drop zone before the cursor reaches it, and the
  first hover over the zone already highlights it (the drop is accepted on the first try).
  Drag away: it closes. Release elsewhere: it closes. With an approval pending, dragging to
  the notch leaves the approval peek as it is (no drop zone) and its buttons still work
  after the drag.
- [ ] **17. Peeks (Tasks 8, 9).** A nudge or plug-in peek appears below the notch for its
  time and goes away by itself; its buttons work with one click without activating
  PlatyNotch; hovering it does not open the panel. During a full-screen app a nudge waits
  and shows after leaving full screen if it has not expired. An agent notice shows on top
  of a nudge and the nudge returns after it.
- [ ] **18. Two displays.** With Settings › Appearance › Show on: All displays, a ringing card shows on both
  panels and Stop on one clears both. The drop zone opens only on the display whose notch
  the drag approaches.
- [ ] **19. Menu bar Stop.** While anything rings, the menu bar menu starts with one
  "Stop <title>" item per alarm or timer, oldest first; choosing one stops that one.
  When nothing rings the items are gone.
- [ ] **20. After a peek, hover opens.** Let a nudge or plug-in peek end (or stop a
  ringing card) with the cursor resting on the pill: moving slightly on the pill opens
  the panel as usual. Release a drag elsewhere, then hover the notch without the button
  down: no drop zone.

## Task 2: timers, stopwatch, alarms, world clocks

Automated: `TimeTests` (parser, countdown, alarms incl. weekday repeats and DST, clocks,
laps, persistence, relaunch, backups) and `TimeWidgetTests` (backups through a fake
notifier, ringing, Stop from the menu bar, relaunch, focus sessions). `--smoke` prints
`sounds=2` when both bundled sounds are found. Time state lives in `UserDefaults.standard`
under `time.v1`: reset with `defaults delete PlatyNotch time.v1` (`swift run`) or
`defaults delete dev.platynotch.app time.v1` (bundled app). Checks 23–25 and 31 need the
bundled app (`scripts/build-app.sh`), since notifications need a bundle.

- [ ] **21. Quick add.** Today › Time › Timers: type `10`, `1h30`, `90s`, `25:00` (Return
  or Start): each starts a timer with that length; `abc` or `25h` shows the hint and adds
  nothing. Several run at once; the pill shows the soonest one's `m:ss`. Pomodoro starts a
  25-minute timer; when it ends a 5-minute "Break" starts by itself.
- [ ] **22. A timer finishes in the app.** With a `1m` timer: at zero the ringing card grows
  out of the notch (pulsing ring, "Stop", no Snooze) and the chime loops. After about 30 s
  the card goes by itself and the pill shows a "Done" check for 10 minutes; the tile says
  Done. No system banner appears as well (the backup is cancelled before it fires).
- [ ] **23. Quit with a timer running (review focus).** Bundled app: start a `2m` timer,
  quit PlatyNotch from the menu bar. About two minutes later a "2 min timer is done" system
  notification shows. Relaunch: the timer shows Done, nothing rings, and no second banner
  appears. Repeat with a restart of the Mac instead of quitting (the notification shows
  after login if the time passed while off, or on time if the Mac is up).
- [ ] **24. Quit with an alarm set.** Bundled app: add an alarm two minutes ahead (no
  weekdays), quit. At that minute (+3 s) a system notification shows. Relaunch: the alarm
  is switched off (a once alarm) and nothing rings. A weekday alarm stays on.
- [ ] **25. Alarm rings until stopped.** An alarm going off with the app running: ringing
  card with Snooze and Stop, alarm sound loops for at most 60 s, the card stays until
  Stop or Snooze. Snooze: it rings again 9 minutes later (the tile shows `zzz`).
  The menu bar's "Stop <label>" and the header chip (panel open) also stop it and the sound.
- [ ] **26. Focus.** Start a focus session, then let a timer finish: no card, no sound, the
  pill and tile show Done. An alarm during the session still rings.
- [ ] **27. Stopwatch.** Start: the pill shows the stopwatch glyph counting up (`m:ss`).
  Lap records laps (newest first, five shown); Stop, then Reset clears. Relaunch while it
  runs: it keeps counting from where it was.
- [ ] **28. World clocks.** Clocks: type `tok`, pick Tokyo; type `kolk`, pick Kolkata. Late
  evening in Europe/India, Tokyo shows "+1 day" and a moon; a daytime city shows a sun.
- [ ] **29. Permission only on use.** Fresh install (`tccutil reset All dev.platynotch.app`
  and delete `time.notificationsAsked`): launching and turning the Time widget off and on
  ask nothing; the first timer or alarm you add shows the notification prompt, once.
  Allow it: that first timer or alarm still gets its backup (quit and wait for it).
- [ ] **30. Disabled mid-ring.** While an alarm rings, turn Time off in Settings › Widgets:
  the sound stops at once and no ringing card or chip is left behind. Bundled app, with a
  timer running and an alarm set: turn Time off, wait past both times: no system
  notification shows. Turn it on again: the timer shows Done (no ring), a once alarm whose
  time passed while off is still on for its next day, and its notification is back
  (`Notification Center` shows it at that time).
- [ ] **31. Packaged sounds.** `scripts/build-app.sh` ends without error (it checks the
  sounds in `Contents/Resources/PlatyNotch_PlatyNotchUI.bundle` and verifies its
  signature); the alarm and chime are audible in the bundled app (not the system "Glass").

## Task 3: music player and live visualiser

Automated: `MusicTests` (bands, smoother, analyser privacy, dominant colour, playback
clock, adapter time fields), `MusicVisualiserTests` (tap gating with a fake tap). No test
or smoke run creates a real tap: `--smoke` / `--smoke-settings` give the visualiser
`NoAudioTap`. The visualiser setting is `music.visualiser` in the app's defaults
(`defaults delete PlatyNotch music.visualiser` under `swift run`). Check with Spotify,
Apple Music and a YouTube video in Safari, bundled app (adapter) and `swift run` without
`PLATYNOTCH_MEDIAREMOTE_DIR` (AppleScript: Spotify and Music only).

- [ ] **32. Tile.** Today › Music shows the artwork with a soft glow in its main colour
  (changes with the next track), title, artist, the app's icon and name (Safari for
  YouTube, not "WebKit") and the output device (e.g. "MacBook Pro Speakers"; switch to
  AirPods: the name follows when the tile is shown again or the track changes).
- [ ] **33. Scrub.** The position and `-remaining` labels tick once a second while
  playing and stop while paused. Drag the bar: the thumb follows, the times show the
  drag position, and on release playback jumps there (Spotify, Music, YouTube). A live
  stream with no length shows no seekable bar.
- [ ] **34. Seek reaches the player.** After a seek, the player's own UI shows the new
  position, and a second later the tile still agrees (no jump back). Adapter build and
  AppleScript fallback both.
- [ ] **35. Favourite.** With Apple Music the heart toggles the track's favourite (first
  click may ask for Automation for Music, on that click only); Music's own heart follows.
  No heart for Spotify or Safari.
- [ ] **36. Visualiser off by default, no prompt on play.** Fresh install
  (`tccutil reset All dev.platynotch.app`, `defaults delete dev.platynotch.app
  music.visualiser`): play music, open the panel, show the Today tab: no System Audio
  Recording prompt; the bars bounce on their synthetic animation (as before this task).
- [ ] **37. Prompt timing.** Settings › Widgets › Music › Live visualiser on: the System
  Audio Recording prompt appears now (first time only), even with nothing playing. Allow:
  with music playing the pill's three bars follow the music (bass left, treble right) and
  the tile shows six. Deny (or turn it off in System Settings › Privacy & Security ›
  Screen & System Audio Recording): the bars fall back to the synthetic bounce within
  ~2 s; no further prompts on later plays.
- [ ] **38. Tap stops when hidden.** Visualiser on and allowed, music playing. Watch the
  orange recording indicator / Control Centre "System audio recording" entry, or
  `log stream --predicate 'subsystem == "dev.platynotch.app" AND category == "AudioTap"'`
  ("visualiser tap started/stopped"). Stops below come about 0.8 s later (a grace so a
  pill ↔ panel switch keeps the tap; opening the panel on Today logs no stop/start pair):
  - pause the music: stopped; play: started;
  - open the panel on the Agents tab (no pill, no tile): stopped; switch to Today: started;
  - full-screen app hiding the pill: stopped; reveal the pill: started;
  - Reduce Motion on: stopped (still bars);
  - turn the toggle off, or turn the Music widget off, or quit: stopped at once (no grace).
- [ ] **39. Developer ID build.** Signed with `PlatyNotch.entitlements` (hardened
  runtime), the visualiser still gets audio after allowing the prompt. If it stays
  silent, the `com.apple.security.device.audio-input` entitlement is the suspect.
  Ad-hoc builds lose the grant on every rebuild (like Accessibility): expect the prompt
  again after an update.
- [ ] **40. CPU.** Measured headlessly: one visualiser frame (mix 512 stereo frames,
  1024-point FFT, 12 bands, smoothing) costs about 2.4 µs in a release build on this
  Mac (~0.01% CPU at 30 fps). Check by eye in Activity Monitor with music playing and
  the pill shown: visualiser off, PlatyNotch stays where it was before this task (12 fps
  synthetic bars); on, it adds no more than ~1-2% (SwiftUI redraws at ≤30 fps); with the
  pill hidden (full screen, panel on another tab) it returns to idle.

## Task 4: volume, brightness and keyboard-backlight HUDs

Automated: `HUDTests` (key decoding with the C18 vectors, 1/16 and ⌥⇧ 1/64 steps,
clamping, volume/mute rules, the swallow gate, `hudWouldShow`) and `HUDWidgetTests`
(a fake tap and fake controls: off by default, no tap or listener while off, no prompt
on enable, pass-through without Accessibility / refused tap / full screen / ringing /
no panel on the cursor's display, HUD only on the target display). No test or smoke run
creates an event tap or changes volume or brightness; `--smoke` builds the HUD views
from an inert copy of the widget. The tap needs **Accessibility** (an active
`.defaultTap` filter; `CGEvent.tapCreate` returns nil without it), not Input
Monitoring. Logs: `log stream --predicate 'subsystem == "dev.platynotch.app" AND
(category == "MediaKeyTap" OR category == "HUDWidget")'`.

Use the installed app (`scripts/build-app.sh`): Accessibility is granted to a bundle.
Reset between runs with `tccutil reset Accessibility dev.platynotch.app`. An ad-hoc
build loses the grant on every rebuild.

- [ ] **41. Off by default.** Fresh defaults: Settings › Widgets lists "Volume &
  brightness HUD" switched off. Volume keys show the system HUD; the log shows no
  "media key tap started".
- [ ] **42. Review Focus #4: no permission.** With Accessibility reset, turn the widget
  on (Settings › Widgets, or the onboarding Permissions page toggle). No system prompt
  appears. Press volume up/down, mute, brightness: the **system HUD shows and works**,
  ours never does, and nothing lags. Settings › Widgets › Volume & brightness HUD says
  "Off: needs Accessibility…" with "Allow Accessibility…" and "Open System Settings"; the
  Today tile says the same; Settings › Permissions › Accessibility mentions the HUD.
- [ ] **43. Allow.** Click "Allow Accessibility…": the system prompt appears (only now).
  Grant it in System Settings: within a second or two (no relaunch) the status reads
  "On". Volume up: our slim bar grows out of the notch for ~1.5 s with the output's name
  ("MacBook Pro Speakers"), and the **system HUD does not appear**. 16 presses go from 0
  to full; ⌥⇧ + key moves a quarter step; ⌥ alone + key opens Sound settings as usual.
  Mute: slashed speaker, empty bar; volume up unmutes. Control Centre's Sound slider
  agrees with our level (the HUD shows the level read back from the device). An output
  whose mute is per channel only (some USB interfaces): all volume keys stay with the
  system.
- [ ] **44. Revoke while running.** Remove PlatyNotch from Privacy & Security ›
  Accessibility: within a second or two the status returns to "needs Accessibility" and
  the system HUD handles every key (no key is lost or stuck).
- [ ] **45. Output changes.** Connect AirPods (or plug in headphones): the next volume
  press shows their name. Switch output to a device without volume control (HDMI /
  DisplayPort audio): the system HUD shows ("not supported"), ours does not.
- [ ] **46. Brightness.** Brightness keys on the built-in display: our HUD (sun glyph),
  the screen dims/brightens by 1/16, ⌥⇧ by 1/64; Control Centre's Display slider agrees.
  Clamshell (external display only): the system handles the keys. Note for this Mac
  whether brightness keys reach the tap at all (some Apple Silicon keyboards handle them
  below the event system; then the system HUD shows, which is acceptable).
- [ ] **47. Keyboard backlight.** On a Mac or keyboard with backlight keys: our HUD
  ("light.max"), level steps by 1/16. Without a backlit keyboard the widget's settings
  say the system HUD still shows for the keyboard backlight.
- [ ] **48. Our HUD only where it shows.** Widget on and allowed:
  - full-screen video: the **system** HUD shows (key passed through);
  - an alarm ringing: the system HUD shows;
  - approval peek up, or the panel open: the **system** HUD shows (a 2 pt indicator is
    not feedback enough to take the key); the approval card does not move;
  - brightness keys with the cursor on an external display: the system handles them;
  - two displays, Show on: Display with the menu bar, cursor on the display without the panel:
    the system HUD shows; move the cursor to the notch display: ours. With Show on: All
    displays: ours, on the display under the cursor only.
- [ ] **49. Hang.** Find the pid (`pgrep -x PlatyNotch`), `kill -STOP <pid>` (this
  stops every thread, the tap's too), press volume up a few times: after at most about a
  second the **system HUD shows and the volume changes** (the window server timed the
  tap out). `kill -CONT <pid>`: the next presses show our HUD again (the tap re-enabled
  itself) and no key was applied twice. A main-thread-only hang (tap thread alive) is
  covered by `HUDTests.testPassesThroughWhileAHandOffIsOverdue` /
  `HUDWidgetTests.testRouterPassesKeysWhileMainIsBehind`: keys go to the system once a
  hand-off has waited 250 ms.
- [ ] **49a. Click latency.** Widget on and allowed: open a heavy panel tab (Memory
  search, Agents with many sessions) and click around other apps meanwhile, including
  with a mouse that has extra buttons: clicks never feel delayed (the tap runs on its
  own thread; aux-button events leave the callback before an NSEvent is built). Hold
  volume up: steps repeat smoothly; hold mute: it toggles once.
- [ ] **50. Crash.** `kill -9 <pid>`: volume keys immediately show the system HUD.
  Relaunch: ours again (if the widget is on and allowed).
- [ ] **51. Off again.** Turn the widget off: "media key tap stopped" in the log and the
  system HUD shows at once. Quit: same.
- [ ] **52. Secure input.** Focus a password field (secure input on) and press volume
  keys: they keep working (ours or the system's), nothing sticks after leaving the field.
- [ ] **53. Idle cost.** Widget on and allowed, collapsed, no music: Activity Monitor
  shows PlatyNotch where it was before (no polling; the tap runs only on key presses).

## Task 5: file shelf and drag detection

Automated: `ShelfTests` (store, bookmarks, missing state, expiry, drag poller),
`ShelfWidgetTests` (detector through fake signals, drop zone and the panel, receiving,
missing files), `PanelSurfaceTests` (drop zone vs ringing, open panel restored). The shelf
lives in `$PLATYNOTCH_HOME/shelf.noindex` (0700; `items.json` 0600; owned copies in
`<uuid>/`). Use a throwaway `PLATYNOTCH_HOME` and check `ls -la "$PLATYNOTCH_HOME/shelf.noindex"`.

- [ ] **54. Real drag-enter after the pass-through flip (closes #16).** Drag a file from
  Finder slowly towards the notch. Within about 60 pt the drop zone opens ("Drop to keep
  on the Shelf"); keep moving onto it: the border turns solid accent on the **first**
  pass (the drag-enter reached the panel). Drop: the item is on the shelf (Today tab
  tile, pill ear shows a tray and the count when nothing else is live). If the zone
  opens but never highlights, note it: the panel's view is registered for drags at
  creation, so this would mean AppKit withholds drag-enter after `ignoresMouseEvents`
  flips mid-drag.
- [ ] **55. Drag in, several sources.** Finder (3 files at once: all three, in the
  dragged order); Safari image (an owned copy under `shelf.noindex/<uuid>/`); Safari link (a
  link card); selected text from TextEdit (a text card); a photo from Photos and an
  attachment from Mail (file promises: owned copies appear after a moment). Nothing
  prompts for any permission.
- [ ] **56. Drag out.** Drag a card into a Finder window: a copy appears (the shelf item
  stays). ⌘-click three cards, drag one: all three go (into Mail's compose window as
  attachments). Dragging a card out of the open panel never turns the panel into the
  drop zone.
- [ ] **57. Moved, renamed, deleted in Finder (Review Focus #2).** Rename a shelved file
  in Finder, reopen the panel: the card shows the new name. Move it to another folder:
  still found. Move it to the Trash (or delete it): the card shows the orange badge with
  Locate (magnifying glass) and Remove. Dragging that card does nothing but beep (no
  crash, no empty drag); in a multi-selection the other cards still drag. Locate… →
  choose a file: badge gone. Remove: the card goes and nothing on disk is deleted.
- [ ] **58. AirDrop.** Right-click a file card › AirDrop: the system AirDrop window
  opens with the file; send to a nearby device. With several selected, all go.
- [ ] **59. Quick Look.** Right-click › Quick Look: the Quick Look panel shows the file
  (several selected: arrows page through them). Note whether it opens without
  activating PlatyNotch. Close it: the panel behaves as before.
- [ ] **60. Menu.** Open, Reveal in Finder, Share… (picker next to the card), Copy (paste
  in Finder gives the file), Copy Path, Pin (pin glyph; "Clear" keeps it), Remove.
- [ ] **61. Drag while the panel is open / something rings.** Open the panel, drag a file
  to the notch: the drop zone replaces the panel; drop: the open panel comes back. Drag
  away instead: it rests compact. With an alarm ringing, drag to the notch: the drop
  zone shows (not the ringing card) with the amber Stop chip; after the drop the ringing
  card is back.
- [ ] **62. Approval pending.** With an approval peek up, drag a file to the notch: the
  approval stays, nothing is dropped on it, its buttons work after the drag.
- [ ] **63. Privacy.** Copy a password from a password manager that marks it concealed
  and drag that text to the notch: refused (nothing added). Settings › Widgets › Shelf
  says the shelf cannot honour Memory's excluded apps. Little Snitch / `nettop`: no
  network from the shelf.
- [ ] **64. Expiry.** Set an owned item's `addedAt` 8 days back in `items.json` (quit
  first), relaunch: it and its `<uuid>/` folder are gone; a pinned one stays; files you
  dropped from disk are never deleted.
- [ ] **65. Off does nothing.** Turn the shelf off: dragging files around shows no drop
  zone, and Activity Monitor shows no extra CPU while holding the mouse button down. Turn
  it on again: the items are still there.
- [ ] **66. Idle cost.** Shelf on, collapsed: no CPU while the button is up (only click
  callbacks); while holding the button down (a window drag) a 20 Hz read of two integers
  that stops at release.
- [ ] **67. Drop on release.** Drop 20 files one after another, quickly, on
  the zone: every drop is taken (none bounces back to Finder). Release on the zone with
  nothing droppable: the zone closes within about 0.3 s.
- [ ] **68. Expiry while off.** Shelf off, an owned item 8 days old in
  `items.json` (quit first): relaunch PlatyNotch; its `<uuid>/` folder and entry are gone
  although the shelf stays off. Shelf off and never used: launch creates no `shelf.noindex/` folder.
- [ ] **69. Shelf off, drag over the pill.** Turn the shelf off, drag a file over the
  pill: no drop zone and no "Drop here" placeholder; after release, Activity Monitor
  shows PlatyNotch idle (no leftover cursor polling).
- [ ] **70. Promise file modes.** After a Photos drop, `ls -l "$PLATYNOTCH_HOME/shelf.noindex"/*/`:
  note the mode the promised file got (written by Photos; the folder is 0700).
- [ ] **71. Damaged index.** Quit, put a few owned items on the shelf
  first, then write junk into `shelf.noindex/items.json` and relaunch (shelf on, and once with it
  off): the shelf starts empty, `items.json.corrupt-<date>` (0600) holds the old text,
  Console shows "shelf index unreadable; moved aside", and every `<uuid>/` folder is
  still there. Settings › Widgets › Shelf shows the damaged-index notice with "N kept",
  Show in Finder (opens the shelf folder) and Delete Kept Copies; deleting removes the
  `.corrupt-` file and every copy no shelf item lists, and the notice goes. (Deleting the
  `.corrupt-` file by hand instead: folders older than 7 days go at the next start.)
- [ ] **71a. No file checks at launch.** Put a file from ~/Downloads on the shelf, rebuild
  the app (a new ad-hoc signature), relaunch and wait: no Files & Folders prompt until you
  open the panel's Today tab and the shelf tile shows.

## Task 6: clipboard history and picker

Automated: `ClipboardTests` (Kit: filter steps, stable hash, history dedupe / limit / age /
search, store round trip, modes, image deletion, damaged index, picker search, selection
and keys), `ClipboardWidgetTests` (fake pasteboard, timer, hot key and ⌘V poster: off does
nothing, 0.5 s poll only while on, password managers and concealed items never read or
written, pause, paste with and without Accessibility), `MenuBarTests` (C23). History lives
in `$PLATYNOTCH_HOME/clipboard` (0700): `history.json` (0600) and `images/<id>.png` (0600).
Use a throwaway `PLATYNOTCH_HOME`. Turn the widget on in Settings › Widgets (it is off by
default). Settings › Widgets › Clipboard history has Pause, Keep / Up to, Shortcut, Clear
History, Clear All, and the Accessibility button.

- [ ] **72. Password managers are never recorded (Review Focus #3).** Copy a password in
  1Password (the app, and the browser extension in Safari or Chrome), in Keychain Access
  (Show password › Copy), in Passwords, and in Bitwarden if installed. Press ⌥⇧V: none of
  them is listed. `grep -r "<the password>" "$PLATYNOTCH_HOME/clipboard"` finds nothing.
  Note which managers set `org.nspasteboard.ConcealedType` (an app like Pasteboard Viewer
  shows the types) and which were caught only by the app rule.
  **Explicitly:** copy a password from the **Apple Passwords menu bar extra**
  (menu bar key icon › pick an entry › copy password) and from **1Password Quick Access**
  (⇧⌘Space › an item › copy password) while TextEdit is the frontmost app, then switch
  straight back to TextEdit. These may never become frontmost, so only ConcealedType or
  `org.nspasteboard.source` can keep them out: note for each whether it is recorded. Also
  copy in the 1Password app and immediately ⌘-Tab to Safari: not recorded (the activation
  window covers an app that hands focus back before the 0.5 s poll).
- [ ] **73. Excluded apps.** Add an app (e.g. Notes, `com.apple.Notes`) to Settings ›
  Memory › excluded apps; copy text in Notes: not recorded. Remove it again: the next copy
  is recorded. Copy something in TextEdit while Notes is frontmost through a script
  (`osascript -e 'set the clipboard to "x"'` from Terminal while Notes is in front): note
  that it is attributed to Notes (best effort, documented).
- [ ] **74. Picker and paste with Accessibility.** Allow Accessibility from Settings ›
  Widgets › Clipboard history › Allow Accessibility… (the only place that prompts). In
  TextEdit, press ⌥⇧V: the picker opens near the cursor with the search field focused
  and TextEdit stays the active app (its menu bar stays). Type "caf" for an item with
  "café"; ↑/↓ move; ↩ pastes into TextEdit at the cursor; ⌘2 pastes the second row. The
  picker closes and TextEdit has the keyboard.
- [ ] **75. Paste without Accessibility.** Remove PlatyNotch from System Settings ›
  Privacy & Security › Accessibility, relaunch. ⌥⇧V › ↩: nothing is typed, the notch peeks
  "Copied — press ⌘V", no Accessibility prompt appears; ⌘V in TextEdit pastes the item.
  The picker's footer says "↩ copy (paste needs Accessibility…)".
- [ ] **76. Picker keys.** ⌘P pins (pin glyph; the row moves to the top; Clear History
  keeps it). With an empty search, ⌫ deletes the selected row (its image file goes too);
  with text, ⌫ edits the text; holding ⌫ to clear the search never deletes rows. Esc
  closes and returns the keyboard to the previous app. Clicking outside closes it. ⌥⇧V
  again while open closes it.
- [ ] **77. Approvals are untouched.** With an approval peek up (fake-events), press ⌥⇧V:
  the approval stays where it is, is not hidden, and the picker never covers it (move the
  cursor under the notch first). In the picker press ↩, ⌘↩ and ⌘⌫: nothing happens to
  the approval (↩ picks a clip, copy-only: the notch panel had the keyboard, so no ⌘V
  is posted). After Esc the approval card still answers ⌘↩ / ⌘⌫ as before.
- [ ] **78. Pause.** Menu bar › "Pause clipboard history": copies are not recorded; the
  item now reads "Resume clipboard history"; the tile says Paused. Relaunch: still paused.
  Resume: what was copied while paused never appears. With the widget off the menu item is
  not shown at all.
- [ ] **79. Off does nothing.** Turn the widget off: ⌥⇧V does nothing (another app can use
  it), copies are not recorded, Activity Monitor shows no 0.5 s wake-ups from PlatyNotch
  (Energy tab, idle wake-ups). Turn it on: earlier history is still there.
- [ ] **80. Images and files.** Copy an image in Preview (⌘C) and a screenshot to the
  clipboard (⌃⇧⌘4): one image row each, a PNG in `clipboard.noindex/images/`; copying the same
  image again moves it to the top (no second file). An image over 10 MB is skipped.
  Copy files in Finder: one row ("name + 2 more"); ↩ pastes them in a Finder window.
  Delete an image row: its PNG is gone.
- [ ] **81. Retention.** Keep: 1 day; set an item's `copiedAt` 2 days back in
  `history.json` (quit first) and relaunch, once with the widget on and once off: it and
  its image are gone. Up to: 50: older items beyond 50 go at once; pinned ones stay.
- [ ] **82. Damaged history.** Quit, write junk into `clipboard.noindex/history.json`, relaunch:
  history starts empty, `history.json.corrupt-<date>` (0600) keeps the old text, every
  file in `images/` is still there after a second relaunch, and Settings shows "A damaged
  history file was set aside" with Delete Kept Files (which removes them).
- [ ] **83. Shortcut taken.** Pick ⌃⌥V in Settings while another app holds it (or keep
  ⌥⇧V with an app such as Alfred bound to it): Settings says it is taken. Other shortcuts
  work at once without relaunch.
- [ ] **84. Full screen and Spaces.** In a full-screen app, ⌥⇧V opens the picker on that
  Space over the app; paste works there.

## Clipboard and shelf: panel level, paste focus, backup and Spotlight

- [ ] **85. Notch panel at status-bar level.** The panel is now really at `.statusBar`
  (it used to fall back to `.floating`). Check: the pill and an approval peek stay visible
  over the Dock (also with magnification on and a Dock stack open), over other apps' floating panels (Preview's Inspector, a
  Notes floating window, Xcode's quick help), and in full screen. Menu bar items right
  next to the notch (left and right of it) still open on click, and the menu bar's extras
  still work while the pill is compact. Open a menu that drops down under the notch: note
  whether the menu draws over or under the panel.
- [ ] **86. Paste focus check.** With Accessibility on, ⌥⇧V in TextEdit › ↩ pastes. Then
  ⌥⇧V in TextEdit, quit TextEdit from the Dock (right-click › Quit) while the picker is
  open, then ↩: nothing is typed anywhere and the notch says "Copied — press ⌘V".
- [ ] **87. Backup and Spotlight.** `xattr -l "$PLATYNOTCH_HOME/clipboard.noindex"` and
  `…/shelf.noindex` show `com.apple.metadata:com_apple_backup_excludeItem`; both folders
  also contain `.metadata_never_index`; `mdfind -onlyin "$PLATYNOTCH_HOME/clipboard.noindex"
  <copied word>` finds nothing. `tmutil isexcluded "$PLATYNOTCH_HOME/clipboard.noindex"` says
  excluded. With `clipboard`, `shelf` and `favicons` folders left by an older build, the first
  launch renames them to the `.noindex` names with everything inside (history, pins and
  copies still there).

## Task 7: reminders, meeting countdowns, weather

Use the installed app (`scripts/build-app.sh`; EventKit needs the bundle's usage strings,
under `swift run` both widgets say "needs the installed app"). Reset permissions first:
`tccutil reset Calendar dev.platynotch.app; tccutil reset Reminders dev.platynotch.app`.
Watch network with Little Snitch / LuLu or `nettop -p PlatyNotch` for the weather checks.

- [ ] **88. No calendar prompt on show.** Fresh permissions, launch, open Today: the
  Meetings tile says "See your next meetings here" with "Allow Calendar Access" and no
  system prompt appears. Click it: the prompt appears once. Allow: meetings show without
  relaunch. Deny instead, then allow in System Settings › Privacy › Calendars: within 30 s
  (or on the next panel open) the tile shows meetings, without relaunching.
- [ ] **89. Meetings in the next 12 h.** Make three events today (one now, two later,
  one with a Zoom link in Location, one with a Meet link in Notes, one with a Teams link
  wrapped by Outlook Safe Links): the tile shows "In meeting · ends in N min", the next
  meeting, then the others; Join buttons only where a link exists; Join opens the right
  meeting and nothing opens by itself. Declined and all-day events are not shown.
- [ ] **90. 10 / 5 / 1-minute reminders.** An event starting in 11 min: at 10, 5 and 1
  minutes before, a peek below the notch shows the title, a countdown ring and Join (for
  ~12 s, never past the start); the pill shows the ring with m:ss for the last 10 min,
  also with the panel closed. Sleep the Mac across the 10 and 5-minute marks and wake at
  3 min: one reminder (5) shows, not two.
- [ ] **91. Quiet during focus.** Start a 25-min focus session, then an event 6 min away:
  no reminder peeks; the pill countdown still shows.
- [ ] **92. Calendar changes.** With the panel open, add/move an event in Calendar.app:
  the tile follows within a second or two (EKEventStoreChanged).
- [ ] **93. Meetings off does nothing.** Turn Meetings off in Settings › Widgets: no pill,
  no peeks; `sample PlatyNotch 5` shows no EventKit work in the following minutes.
- [ ] **94. Reminders permission on enable.** Reminders is off by default. Turn it on:
  no prompt. Click "Allow Reminders Access" in its tile or settings: one prompt; allow:
  today's and overdue reminders show (overdue time in red). Settings › Permissions has a
  Reminders row with the same state.
- [ ] **95. Tick and quick add.** Tick a reminder: it disappears here and is completed in
  Reminders.app. Type "call Priya at 5pm" (before 17:00): the preview says "Reminder ·
  Today 5:00 PM"; Return adds it to the list chosen in settings, with an alert at 17:00.
  After 17:00 the preview says Tomorrow. "meeting with Sam tomorrow 3pm for 30 min" →
  "Event · Tomorrow 3:00 PM – 3:30 PM", added to the default calendar (with Calendar
  allowed) or to Reminders with "Calendar access is off" (without). "buy milk" → a
  reminder with no date (not shown in the tile since it is not due today).
- [ ] **96. Default list.** Pick another list in Settings › Widgets › Reminders: quick add
  goes there; delete that list in Reminders.app: the picker falls back to Default list.
- [ ] **97. Weather is off and silent by default.** Fresh defaults
  (`defaults delete dev.platynotch.app weather.place`): with Weather off, no connection to
  any open-meteo.com host at launch or after an hour.
- [ ] **98. City search and forecast hosts.** Turn Weather on, type "Lisbon" › Search:
  exactly one request to `geocoding-api.open-meteo.com` (https). Choose a result: one
  request to `api.open-meteo.com`; nothing else is contacted, no cookies are stored
  (`~/Library/Cookies` has no open-meteo entry), no cache files appear under
  `~/Library/Caches/dev.platynotch.app`. The tile shows temperature, conditions, "Rain
  likely around …" or "No rain expected in the next 12 h"; °F in settings switches it at once.
- [ ] **99. Refresh, sleep, offline.** Weather refreshes about every 30 minutes. Turn
  Wi-Fi off: no further attempts while offline; after 45 min the tile shows "Offline ·
  Updated N min ago". Wi-Fi on: a refresh within ~5 s. Sleep for an hour and wake: a
  refresh ~5 s after wake, none while asleep. Block api.open-meteo.com (e.g. /etc/hosts):
  retries back off 1, 2, 4, 8, 16, 30 min and the old data stays with its age.
- [ ] **100. Weather in the pill.** With nothing else live (no music, timer, meeting),
  the pill shows the weather symbol and temperature; anything else live replaces it and
  it never shows as the side bubble.
- [ ] **101. Signed build entitlements.** On a Developer ID build (`--sign`), Calendar and
  Reminders prompts still appear and work (the calendars entitlement covers both).

## Task 8: water, stand and eye-break nudges

Automated: `WellbeingTests` (Kit: due, priority, quiet hours across midnight and DST,
idle as a break, water per day / 14 days) and `WellbeingWidgetTests` (through the real
registry, `PanelSurfaces` and a `NotchController`: off by default, no work while off,
approval precedence, full-screen hold, sleep/lock pause, spacing). Shorten intervals for
these checks in Settings › Widgets › Wellbeing (step 5 min); reset its state with
`defaults delete PlatyNotch wellbeing.progress` (`wellbeing.water`, `wellbeing.settings`).

- [ ] **102. Off by default, silent while off.** Fresh defaults: Wellbeing is off in
  Settings › Widgets; no card ever appears. `sample PlatyNotch 5` over a few minutes shows
  no wellbeing timer and no `CGEventSourceSecondsSinceLastEventType` calls.
- [ ] **103. No permission.** Turn it on: no prompt of any kind (no Accessibility, Input
  Monitoring or Calendar); Settings › Permissions is unchanged.
- [ ] **104. Eyes card.** Eyes 5 min, others off: about 5 min after turning it on (never
  within 2 min of enabling) a card below the notch says "Look 20 feet away for 20 seconds"
  with a 20 s ring counting down; it stays the 20 s. Keep typing in another app while it
  shows: your keystrokes stay in that app (the card never takes focus). Click Done once:
  it closes on that first click.
- [ ] **105. Ignored cards.** Let a card run out without answering (whether or not you
  keep typing): that nudge comes back a full interval later, never sooner (counted as
  dismissed). Ignoring every card for an hour brings no more cards than answering them.
- [ ] **106. Water card.** Water 5 min: "Time for some water", "N / 8 glasses today".
  "+1 glass" closes it and the tile's count goes up; the count survives a relaunch and
  resets at midnight. Snooze 10 min: it returns about 10 minutes later, not sooner.
- [ ] **107. Stand card and no burst.** All three at 5 min, wait 6 min: one card (eyes),
  then the others at least 5 minutes apart, never two at once.
- [ ] **108. Approval beats a nudge.** With a card due, trigger an approval
  (`scripts/fake-events.sh`): the approval shows; Escape does not hide it; the nudge card
  appears only after answering, if its 10 s have not passed.
- [ ] **109. Full screen.** Play a video full screen (or any app in full screen) across a
  due time: no card while full screen; one card shortly after leaving full screen.
- [ ] **110. Focus and meetings.** Start a focus session: no cards until it ends. With
  the Meetings widget on and Calendar allowed, during an event in progress: no cards.
  With Meetings off (or Calendar not allowed) Wellbeing never asks for Calendar access.
- [ ] **111. Idle is a break.** Eyes 20 min: 5 minutes after Done, leave the Mac untouched
  (screen on) for 10 minutes, then come back: no card for 2 minutes after sitting down,
  and the next eyes card comes about 20 minutes after your return, not 15 minutes after
  Done. Water still counts from its last glass. While you work, `sample PlatyNotch` shows
  the wellbeing wake at most every minute (normally every 5).
- [ ] **112. Sleep and lock.** Lock the screen (⌃⌘Q) for 10 minutes across a due time:
  nothing shows while locked; after unlocking no card for 2 minutes and then at most one.
  The same after closing the lid for 10 minutes and waking.
- [ ] **113. Quiet hours.** Set quiet hours to cover now (e.g. start = this hour, end = next
  hour): no cards; the tile says "Quiet hours until …". At the end, intervals start
  again from then (no burst at the hour). Same start and end turns quiet hours off.
- [ ] **114. Turning it off.** Turn Wellbeing off while a card shows: the card closes at
  once; nothing further appears; turning it on again keeps today's glass count.
- [ ] **115. Clock and time zone.** With a nudge due in ~10 min, set the clock back two
  hours (System Settings › General › Date & Time, automatic off): the nudge still comes
  within its interval, not hours later. Change the time zone: the tile's times and quiet
  hours follow at once. Restore automatic time.
- [ ] **116. Spacing across a relaunch.** Right after a card, quit and relaunch with more
  nudges due: no card for at least 5 minutes after the previous one.
- [ ] **117. Midnight.** With the panel open on Today across midnight, the glass count
  goes back to 0 / goal at 00:00 without reopening the panel.

## Task 9: battery, keep-awake, AirPods, downloads

The System widget is on by default with only battery and keep-awake (no permission).
Headphones and downloads are off until turned on from their button in Settings › Widgets ›
System; that button is the only place their prompts can appear. Automated checks:
`SystemTests` (Kit), `SystemWidgetTests` (fakes for power, assertions, Bluetooth and FSEvents).

### Battery and keep-awake

- [ ] **118. On by default, no prompt.** Fresh defaults: System is on in Settings ›
  Widgets; the Today tab shows the battery row (percent, "On battery · … left" or
  "Charging · … until full") and Keep awake. No permission prompt of any kind.
- [ ] **119. Plug in / unplug.** Plug in the charger: within a second a peek below the
  notch says "Plugged in" with the percent, for about 4 s. Unplug: "On battery" with the
  percent and time left. While a peek shows, an approval (`scripts/fake-events.sh`) still
  takes over at once.
- [ ] **120. Charging is ambient.** While charging with nothing else live, the pill's
  live ear shows ⚡ and the percent. Turn on Settings › Appearance › Minimal: the pill
  hides while charging (charging never keeps Minimal up).
- [ ] **121. Low battery.** Unplugged at 10% or less (or simulate with a nearly empty
  battery): the pill shows the battery glyph and percent in red, and in Minimal mode the
  pill stays up. Plugging in removes it.
- [ ] **122. Desktop Mac.** On a Mac mini / iMac / Studio: no battery row, no peeks,
  no battery in the pill; Keep awake still works; nothing in Console about power sources.
- [ ] **123. Keep awake 30 min.** Start → 30 minutes. `pmset -g assertions` lists
  "PlatyNotch: keep awake" (PreventUserIdleDisplaySleep). The pill shows a cup and the
  time left counting down; the tile shows "Awake · 29:… left". Set System Settings › Lock
  Screen › "Turn display off" to 1 minute: the display stays on. After 30 minutes the
  assertion is gone (`pmset -g assertions`), the pill item disappears, and the display
  sleeps normally again.
- [ ] **124. Keep awake ends with the widget.** Start "Until turned off"; then (a) Stop,
  (b) turn System off in Settings › Widgets, (c) quit PlatyNotch: each time the assertion
  is gone from `pmset -g assertions` at once. Relaunch after (c): keep-awake is off (never
  re-created on launch).
- [ ] **125. Idle cost.** With keep-awake off and the panel collapsed, `sample PlatyNotch 5`
  shows no timer for the System widget; with keep-awake on and the panel collapsed in
  Minimal mode (pill hidden), nothing ticks (one sleep to the deadline only).

### AirPods and headphones

Probe on the build Mac (macOS 26.4, nothing granted): IOBluetoothDevice answers
`batteryPercentLeft/Right/Case/Single`; no `BatteryPercent…` keys were in the I/O Registry
(no headphones connected). Battery is best effort and hidden when absent.

- [ ] **126. Off by default, no prompt.** Fresh defaults (and `tccutil reset Bluetooth
  dev.platynotch.app`): launch, open the panel and Settings: no Bluetooth prompt anywhere,
  including Settings › Permissions (it has no Bluetooth row on purpose).
- [ ] **127. The button asks.** Settings › Widgets › System › AirPods and headphones ›
  Turn On…: the Bluetooth prompt appears now (installed .app with
  `NSBluetoothAlwaysUsageDescription`; no crash). Allow: the status says "On".
- [ ] **128. Connect peek.** Take AirPods out of the case (or connect any Bluetooth
  headphones): within a few seconds a peek shows the name and "Connected · L 80% · R 75%
  · Case 40%" (or just "Connected" when macOS reports no battery). The Today tile lists
  them; reopening the panel refreshes the battery. Already-connected headphones at launch
  are listed without a peek.
- [ ] **129. Disconnect and turn off.** Put them away: the tile row goes. Turn Off: no
  further peeks on connect.
- [ ] **130. Denied.** Deny in System Settings › Privacy & Security › Bluetooth and
  relaunch: no prompt at launch; the settings say access is off with "Open System
  Settings". With access reset (not asked) and the sub-feature on: no prompt at launch;
  "Allow Bluetooth…" asks.
- [ ] **131. Widget off.** Turn System off: `sample PlatyNotch 3` shows nothing from
  IOBluetooth notifications; connecting headphones shows nothing.

### Downloads

- [ ] **132. Off by default, no prompt.** Fresh defaults (`tccutil reset SystemPolicyDownloadsFolder
  dev.platynotch.app`): no Downloads-folder prompt at launch or anywhere but the button.
  `lsof -p $(pgrep -x PlatyNotch)` shows no FSEvents use for Downloads.
- [ ] **133. The button asks.** Settings › Widgets › System › Downloads › Turn On…: the
  "access files in your Downloads folder" prompt appears now. Allow. (Don't allow: the
  settings say so with "Open System Settings"; nothing is watched.)
- [ ] **134. Chrome / Edge / Arc.** Download a large file: within a second or two the pill
  shows ↓ and the file name (not "Unconfirmed …" for more than a moment); the tile lists
  it as Downloading. When done: a notice below the notch "Downloaded <name>" with Open,
  Show in Finder and (shelf on) Add to Shelf, for about 8 s; it stays in the tile.
- [ ] **135. Safari.** The same with Safari (its `.download` bundle): one notice when it
  finishes, with the final name; no notice for the bundle's inner files.
- [ ] **136. Firefox.** The same with Firefox (`.part` plus an empty placeholder): one
  notice when it finishes, not at the start.
- [ ] **137. Buttons only.** Nothing opens, moves or is revealed until you click. Open
  opens the file; Show in Finder selects it; Add to Shelf adds it to the shelf (the file
  stays in Downloads). With the shelf widget off, there is no Add to Shelf button.
- [ ] **138. Not downloads.** Copy a file into Downloads in Finder, unzip an archive there,
  cancel a download: no notice. A paused download leaves the pill after 10 minutes.
- [ ] **139. Second folder.** Add a Folder… (e.g. ~/Incoming, a folder your browser saves
  to): downloads there show too. Remove: only ~/Downloads again. No Safari-container lookup.
  Choosing a folder on the Desktop, in Documents, in iCloud Drive, on a USB or network drive
  or in another user's home is refused with the reason under the row.
- [ ] **140. Off.** Turn Downloads off (or the System widget off): a download in progress
  leaves the pill at once; new downloads show nothing; `sample PlatyNotch 3` shows no
  FSEvents callbacks.

### Downloads permission and the charger

- [ ] **141. Quit mid-prompt.** Turn On… downloads, and quit PlatyNotch while the macOS
  prompt is up. Relaunch: downloads are off, no prompt at launch.
- [ ] **142. Rebuild or update asks again.** With downloads on, rebuild the app
  (`scripts/build-app.sh`, a new ad-hoc signature) and relaunch: no prompt and no
  file access at launch; Settings says "Turn on again (PlatyNotch was updated or
  reinstalled)" with "Turn On Again…". Pressing it asks (or not, if macOS kept the grant)
  and downloads work again.
- [ ] **143. Denied stays denied.** Turn On… and click Don't Allow: Settings says macOS did
  not allow it (with Open System Settings and Try Again), also after a relaunch, and never
  says "on".
- [ ] **144. Loose charger.** Plug and unplug the charger three times within a second or
  two: one peek, showing the last state, not three.

### Downloads: folders and the shelf

Known limit: with downloads on and a matching stamp, a TCC reset done outside PlatyNotch
(`tccutil reset SystemPolicyDownloadsFolder`, or removing it in System Settings) cannot be
seen at launch: macOS has no Files & Folders preflight API. The first download event's
`stat` may then show the prompt. Everything else that could lose the grant (an update, a
reinstall, an ad-hoc rebuild) changes the stamp and turns downloads off instead.

- [ ] **145. Second folder inside Downloads.** Add a Folder… → ~/Downloads/Browser (point a
  browser at it): downloads there show in the pill and as a notice, like ~/Downloads itself.
- [ ] **146. Old protected folder.** With a second folder in ~/Documents saved by an older
  build (or set `system.options` by hand), relaunch and Turn On Again: only ~/Downloads is
  watched; Settings shows why the folder was dropped; no Documents prompt.
- [ ] **147. Add to Shelf.** "Add to Shelf" from a download notice puts the file on the shelf
  as if dragged there. Settings › Widgets › Shelf says items from Downloads, Desktop or
  Documents may ask macOS for access when shown; that prompt (if any) comes from showing the
  shelf item the user added, which is accepted.

## Task 10: Games

Automated: `GamesTests` (engines, seams, determinism, `GameSession` pausing and keys,
`HighScores`, board sizes against the expanded panel), `GamesWidgetTests` (approval /
ringing / collapse / key loss / full screen pause the game through the real `AppStore`
and `PanelSurfaces`; resume restores the exact state; ⌘ chords are never game keys; the
tab fits `GameLayout.tabSize`), and `--smoke` (`games=4`: the tile, settings, the tab on
every game and each board laid out with an inert widget). High scores live in
`UserDefaults.standard` under `games.highScores` (`defaults delete PlatyNotch games.highScores`).

- [ ] **148. Play each.** Open the panel › Games (or the Games tile in Today). For Snake,
  Tetris, 2048 and Flappy: click the board, press Space, play with arrows and WASD (Tetris:
  ↑ rotates, ↓ drops a row, Space slams; Flappy: Space or ↑ flaps). Each board fits the
  panel with nothing clipped, on a notched and on an external display.
- [ ] **149. Click first, never hover.** Open the Games tab and press Space or arrows
  without clicking: nothing happens ("Click to play"). Hovering the board never takes
  focus. After a click, keys work.
- [ ] **150. Approval mid-game.** While Snake or Tetris plays, trigger an approval
  (`scripts/fake-events.sh`): the game freezes at once, the board gives way to "Game
  paused while an approval is waiting", and the approval card is answerable with ⌘↩ /
  ⌘⌫ (never swallowed by the game). Arrows and Space do nothing to the game while it is
  pending. After answering: "Click to play" → click → Space resumes exactly where it was.
- [ ] **151. Escape.** While playing, Escape pauses ("Paused · Press Space"); a second
  Escape closes the panel. With an approval pending, Escape never hides the approval.
- [ ] **152. Collapse and focus.** While playing, move the cursor away so the panel
  collapses: the game is paused when you come back. Click another app's window while the
  panel stays open: the game pauses (key loss).
- [ ] **153. Ringing.** Start a 5 s timer, play Flappy: when it rings the game pauses
  ("Something is ringing") and Space does not resume until Stop.
- [ ] **154. Full screen.** Reveal the panel over a full-screen app: the game shows
  "Paused" and does not run.
- [ ] **155. Idle cost.** With a game paused (or the Games tab closed), Activity Monitor
  shows PlatyNotch idle (no 60 fps redraw). 2048 never runs a frame loop.
- [ ] **156. Reduce Motion.** With System Settings › Accessibility › Display › Reduce
  motion on, games still play; Snake's food does not pulse and Flappy's bird does not tilt.
- [ ] **157. High scores.** Finish a game with a new best: "New best: N!" shows, the tile
  and Settings › Widgets › Games show it after a relaunch; Reset High Scores clears them.

## Task 11: Pinned sites and Shortcuts

Automated: `LaunchTests` (Kit: favicon candidates from the origin only, https only,
same-origin check, sanitised cache key, type / size / freshness / once-a-day policy,
http(s)-only site URLs, pin limits 12 and 8, Codable, constant per-browser scripts,
`shortcuts run -- <name>` argv) and `LaunchWidgetTests` (fakes only: a never-started
widget fetches, scripts and spawns nothing; pinning fetches only `<origin>/favicon.ico`
then `apple-touch-icon.png`; http sites get a letter with no fetch; a redirect to another
host, a non-image, SVG, over 256 KB or undecodable bodies are refused; a failure is not
retried within a day; a fresh icon is reused for 30 days; the real redirect guard refuses
other origins; the runner passes the name as one argument, reports exit codes, stops a
hang at the timeout and on Cancel). `--smoke` lays out the tile, settings and result peek
with an inert widget (no network, no Shortcuts, no Apple Events). Pins live in
`UserDefaults.standard` under `launch.pins` (`defaults delete PlatyNotch launch.pins`);
icons in `<home>/favicons` (0700).

- [ ] **158. On by default, quiet until used.** Fresh home, launch: the Today tab shows the
  "Sites & Shortcuts" tile with its hint. Little Snitch / `nettop -p PlatyNotch` shows no
  connection from it, and no Automation or Shortcuts prompt appears.
- [ ] **159. Add current tab, Safari.** Open Safari on an https page, open the panel and
  click the Add current tab button (two rectangles): macOS asks once whether PlatyNotch may
  control Safari. Allow: the site is pinned ("Pinned <host> from Safari") and its icon
  appears within a few seconds. Repeat in Chrome and Arc (each asks once).
- [ ] **160. Browser not running, never launched.** Quit all three browsers and click Add
  current tab: "Open Safari, Chrome or Arc first."; no browser starts. With Safari open but
  no window: "Safari has no open window."
- [ ] **161. Automation denied.** In System Settings › Privacy & Security › Automation turn
  PlatyNotch › Safari off, click Add current tab: the notice names Automation. Settings ›
  Permissions › Automation lists Safari/Chrome/Arc with "Asked when you click Add current
  tab" (no Allow button), or "Open System Settings" when denied.
- [ ] **162. Non-web tabs refused.** A Safari start page, a local PDF (`file://`) or
  `chrome://settings` as the front tab: "…tab is not a web page"; nothing is pinned.
  Settings › Widgets › Sites & Shortcuts: typing `javascript:alert(1)`, `file:///etc` or
  `data:text/html,x` and Pin says only http and https can be pinned.
- [ ] **163. Favicons from the origin only.** With a proxy (Proxyman / Charles) or
  `nettop`, pin `https://github.com/anthropics`: the only requests are to
  `https://github.com/favicon.ico` (and `apple-touch-icon.png` if the first fails), with no
  Cookie header. Pin `http://neverssl.com`: no request at all, a letter icon.
  `ls -le "$PLATYNOTCH_HOME/favicons"`: directory `drwx------`, files `-rw-------` named
  `https_<host>_<port>.icon`.
- [ ] **164. Open.** Click a pinned site: it opens in the default browser. Right-click:
  Move Left / Move Right / Unpin. A 13th site is refused ("12 sites pinned…").
- [ ] **165. Shortcuts.** Click the bolt-plus button: the list of your shortcuts appears
  (`shortcuts list` ran only now). Pin one, click it: it runs once, the tile and a short
  peek say "“Name” done". A shortcut that ends with an error (e.g. "Stop and output" with
  an error) says "failed (exit N)". A 9th pin is refused.
- [ ] **166. Hang and cancel.** Make a shortcut with "Wait 120 seconds", pin and run it: a
  spinner and Cancel show; Cancel says "cancelled"; left alone it says "stopped after 60 s".
  `ps aux | grep shortcuts` shows no leftover `shortcuts run`. While one runs, other
  shortcut buttons are disabled.
- [ ] **167. Odd names.** Name a shortcut `--help` or `$(say hi)`: pin and run it; it runs
  that shortcut (no help text, nothing spoken).
- [ ] **168. Disable.** Settings › Widgets: turn Sites & Shortcuts off: the tile goes, a
  running shortcut is stopped, `<home>/favicons` is deleted; pins come back when turned on
  (icons are fetched again).
- [ ] **169. Add Current Tab from Settings.** With Chrome frontmost, open PlatyNotch
  Settings › Widgets › Sites & Shortcuts and click Add Current Tab: Chrome's tab is pinned
  (the browser active before Settings, not "Open Safari, Chrome or Arc first").
- [ ] **170. Leaving Agents mid-refresh.** Open Settings › Agents and switch section at
  once: no "exit status 15" appears when you come back (notch commands are not killed when
  a view goes away).

## Task 12: Appearance and the idle budget

Automated: `AppearanceTests` (Kit: defaults with `hoverDelay` 0.12, spring and hover delay
clamping, `{}` and partial / unknown values decode to the defaults, migration from
`appearance.minimal` / `appearance.showOnAllDisplays` / `appearance.liveSide`, which
changes rebuild the panels, display choice, pill widths, click mode, full-screen hiding
never hides approvals or ringing, live-ear fit at every pill width, warning and Allow
contrast in light) and `AppearanceControllerTests` (the real
`NotchController`: approvals and ringing show over full screen with hiding on; the pill
stays with it off; mode, open trigger and hover delay applied live; a HUD for a display
without a panel is not taken).

Idle budget, on a real Mac (not CI; the panel shows for about a minute, keep the pointer
away from the notch):

```sh
scripts/perf-idle.sh                    # mediaremote-adapter from build/ when built there
scripts/perf-idle.sh --music-fallback   # AppleScript now-playing fallback
scripts/perf-idle.sh --app                    # build/PlatyNotch.app, run as a dev.platynotch.perf copy
```

Themed views in both schemes (HUD, approval card, game boards, shelf), as PNGs to look at:

```sh
cd apps/mac && swift build && PLATYNOTCH_RENDER_DIR=/tmp/pn-renders PLATYNOTCH_HOME=<temp home> \
  PLATYNOTCH_CORE_BIN=<core> .build/debug/PlatyNotch --smoke    # SMOKE OK … renders=18 theme=<current theme>
```

- [ ] **171. Idle under 1%.** On a notched M1 both runs print PASS (mean of 60 one-second
  `top` samples, the first dropped). Note the Mac, macOS and which of Music / Spotify ran.
- [ ] **172. Settings migrate.** Before updating, set Minimal, the old "Show on all displays"
  and live side left (Plan 3 keys). After: Settings › Appearance shows Minimal, "All displays",
  Live activities Left; the panels look as before.
- [ ] **173. Live changes.** In Settings › Appearance change each control with the panel in
  view: Minimal hides the resting pill at once; Theme repaints the open panel; Live
  activities swaps the ears; Spring sliders change the next open / close; Blur 0 opens
  with no blur; Width and Show on rebuild the panels (an open panel stays open, no notice
  replays). Nothing needs a restart.
- [ ] **174. Open on click.** Open on: Click. Resting the pointer on the pill does nothing;
  a click opens it; moving away closes it. Hover delay (Hover mode) at 0.6 s needs a
  clear dwell; at 0 it opens on touch.
- [ ] **175. Displays.** With an external display: "Display with the menu bar" shows one
  panel; "All displays" one per display; "Displays with a notch" only on the built-in
  screen (with the lid closed, the menu-bar display). Press a volume key with the pointer
  on a display without a panel: the system HUD shows there.
- [ ] **176. Full screen.** Play a video full screen. Hide in full screen on: the pill goes,
  the top edge reveals it, an approval (`scripts/fake-events.sh`) and a ringing alarm still
  show. Off: the pill stays over the video (volume keys still show the system HUD there).
- [ ] **177. Reduce Motion.** System Settings › Accessibility › Display › Reduce motion:
  the panel opens with a short ease and no blur.
- [ ] **178. AppleScript fallback, measured.** Needs Automation, which only you can grant:
  `scripts/build-app.sh`, then start Music or Spotify **playing** and run
  `scripts/perf-idle.sh --app --music-fallback`. During the 10 s warm-up, hover the notch
  to open the panel and click Today (idle polls never prompt; the music tile does): macOS asks
  whether PlatyNotch may control Music. Allow (it is the `dev.platynotch.perf` copy, not
  your installed app; revoke later in System Settings › Privacy & Security › Automation),
  then move the pointer away so the panel collapses. That run counts only if the prompt was
  answered before sampling began; run it again if not. It measures the 2 s reads while
  playing (the pill is live: music bars). Then pause the player and run the
  same command again: it measures the 6 s idle read of a granted player, which must PASS.
  Note both means and the player.
- [ ] **179. Light theme legible.** Theme Light (and System in light mode): the HUD bar and
  its level, the HUD line under an approval, the HUD tile icon, Snake and 2048 boards, shelf
  cards (selected and not) and the games overlay text are all visible; "Contains hidden
  characters" is a dark orange and Allow a dark green, both easy to read. Compare with the
  PNGs from `PLATYNOTCH_RENDER_DIR`.
- [ ] **180. Compact pill width.** Pill width Compact with a timer running: beside a notch
  the live ear shows only the glyph (no clipped text); Standard shows the countdown; Wide
  shows the countdown and the bubble. Nothing is drawn under the camera housing.

## Platy (Task 13)

- [ ] **181. Platy in the pill.** Settings › Appearance › Show Platy is on by default:
  Platy sits in the agents ear before the dots, about 22 pt tall, with no clipping beside
  the camera housing. Pill width Compact shows Platy, one dot and a small "+n" badge on
  Platy for the rest; Standard shows Platy, the dots that fit and "+n" for the rest (every
  session is counted). While an agent works, a blue water line sits at Platy's feet (also
  with Reduce Motion). Turn Show Platy off: only the dots stay (the plain look), and the
  Agents and Today empty states go back to text.
- [ ] **182. Moods.** With `scripts/fake-events.sh`: a working session makes Platy paddle and bob;
  an approval or a blocked session shows the amber rim and tail taps; when a session goes
  from active to idle, a green check and sparkle show for about 4 s. Play music: headphones
  and a bounce. Start a focus session: half-closed eyes, still. After 23:00 with nothing live:
  closed eyes and a "z", breathing at one frame a second. Beat your best in a game:
  paws up, sparkles and a jump for about 4 s.
- [ ] **183. Live cost.** `scripts/build-app.sh`, then `scripts/perf-idle.sh --app`, then
  the same with `--state working`, `--state waiting`, `--state approval` and `--state music`
  (a fake track; the pill shows the music bars). Add `PN_PERF_VERBOSE=1` to see every
  sample. Don't touch the Mac while it samples: hovering the notch opens a panel, and that
  shows up as a burst of seconds at 5–20%. Each mean must PASS (under 1%). Platy, the
  pulsing agent dot and the music bars are Core Animation layers, so the app does no work
  per frame. When
  you hide the panel or go full screen while an agent works, Platy stops.
- [ ] **184. Reduce Motion.** System Settings › Accessibility › Display › Reduce motion:
  Platy is a still frame in every mood, and the cue still shows (rim, headphones, check, z).
- [ ] **185. Menu bar icon.** The menu bar shows Platy in side profile (bill to the left,
  set off by a gap; low body on webbed feet; flat tail to the right; the eye a hole), black
  on a light menu bar and white on a dark one. While capture runs, a dot with a cut-out
  ring shows at the top right.
- [ ] **186. App icon.** `scripts/build-app.sh`, then look at the app in Finder, the Dock (light
  and dark), Spotlight and the ⌘-Tab switcher: the night-blue rounded square with the notch
  and Platy, sharp at every size. Compare with the gallery (`PlatyNotch --platy-gallery <dir>`).
- [ ] **187. Onboarding and empty states.** Settings › Permissions › Show onboarding: Platy
  paddles beside "Your coding agents". With no sessions, the Agents tab shows Platy above "No
  agent sessions". With every widget off, Today shows Platy above "No widgets are on."

## Updates, secrets and keyboard focus

- [ ] **188. Visualiser after an update.** Turn on Settings › Widgets › Music › Live
  visualiser (macOS asks for System Audio Recording), quit, rebuild the app
  (`scripts/build-app.sh`, a new ad-hoc signature) and relaunch. Play music with the pill
  showing: no prompt. Settings shows the toggle off with "Turned off: PlatyNotch was updated
  or reinstalled…" and Turn On Again; pressing it asks (or not, if macOS kept the grant) and
  the bars follow the sound again.
- [ ] **189. Secrets are not kept.** With clipboard history on, copy an `sk-…` key, a GitHub
  token (`ghp_` and 36 letters), a JWT and the test card `4242 4242 4242 4242` from TextEdit:
  none appears in the ⌥⇧V picker. An ordinary sentence, two dates (`2024-01-15 2024-03-02`)
  and a row of numbers copied from Numbers or Excel all do.
- [ ] **190. No keyboard focus without a click.** Open the panel, then Settings (menu bar ›
  Settings…), close Settings with ⌘W, and type: the keys go to the app you were using, not
  the notch panel (no game moves, no approval shortcut). The same after closing onboarding
  and a shelf item's Locate… panel. Click into the open panel: it takes the keyboard again.
- [ ] **191. Ringing card pulse.** Let a 5 s timer ring with the panel closed: the ring
  around the bell grows and fades smoothly; Activity Monitor shows PlatyNotch near 0% CPU
  while it rings. With Reduce Motion the ring is still.
