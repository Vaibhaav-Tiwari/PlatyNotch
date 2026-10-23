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
