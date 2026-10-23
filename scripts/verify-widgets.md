# Widgets: manual verification

Checks for the widget system (Plan 3b). Automated checks cover the logic (`swift test`:
`LiveArbiterTests`, `WidgetLayoutTests`, `WidgetRegistryTests`) and the launch
(`swift run PlatyNotch --smoke` prints `widgets=<n>`, the number of enabled widgets whose
tile was built; `--smoke-settings` visits Settings › Widgets). This list covers what only
a person looking at the screen can confirm. Each later widget task appends its own section.

## Setup

Use a throwaway home so nothing touches your real PlatyNotch data:

```sh
scripts/fake-events.sh            # prints the command for terminal B
cd apps/mac && PLATYNOTCH_EXTERNAL_CORE=1 PLATYNOTCH_HOME=… PLATYNOTCH_SOCKET=… swift run PlatyNotch
```

Widget order and on/off live in `UserDefaults.standard` under `widgets.layout` (JSON).
Under `swift run` the domain is the executable name: reset with
`defaults delete PlatyNotch widgets.layout`. The live ear side:
`defaults write PlatyNotch appearance.liveSide left` (undo: `defaults delete PlatyNotch appearance.liveSide`).

Note the Mac model and macOS version next to each tick.

## Task 1a: widget API, registry, live arbiter

- [ ] **1. Today tab is widget tiles.** Expand the panel, open Today: Music, Next meeting,
  Focus and Open loops tiles, in that order, scrolling when they do not fit. With no
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
- [ ] **5. liveSide swaps the ears.** Set `appearance.liveSide` to `left`, restart: the live
  glyph and badge are in the left ear, the agent dots in the right. Delete the key: back to
  dots left, live right.
- [ ] **6. Minimal mode.** `defaults write PlatyNotch appearance.minimal -bool true`,
  restart, no agent sessions: the pill is hidden. Start music: the pill appears with the
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
- [ ] **18. Two displays.** With "Show on all displays" on, a ringing card shows on both
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
