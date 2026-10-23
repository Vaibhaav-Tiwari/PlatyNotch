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
  frontmost app keeps keyboard focus (type in it while it rings). With the panel open, the
  ringing card replaces it; Stop returns to the open panel if the cursor is still on it.
  Over a full-screen video it still shows.
- [ ] **14. Approval beats ringing.** While an alarm rings, trigger an approval
  (`fake-events.sh`): the approval peek replaces the ringing card (the sound keeps
  playing); answer it and the ringing card comes back. Escape never hides the approval.
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
