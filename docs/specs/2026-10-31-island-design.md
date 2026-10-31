# Island (PlatyNotch v0.4) — design

Source of truth: `docs/specs/2026-10-31-island-wireframes.html` (approved, A–F). My own calls
are marked **[call]**. Replaces Home, the header status, chips and visual rules of
`docs/specs/2026-10-31-quiet-notch-design.md`; its §3 commands, §4 Open fix, §5.4 approval card and §7 redirects hold.

## 1. Approved decisions

1. The dock has 8 slots: Timer, Note, Remind, Clipboard, Shelf, Memory, Games, Search; Focus is a mode of Timer.
2. Colour comes from content (album-art glow, weather sky); state colours stay reserved.
3. Weather location comes from macOS Location, with a manual city override.
4. Nothing playing: "Resume" plus the last-played app's recents where available, else only "Resume".

Audience 18–30: every Home slot is always filled, every tool is one click away.

## 2. Panel and header

The open panel is **640 pt** wide (was 600); Home rests near 236 pt; heights stay 160–380.

Header (Home and Agents): Platy (22 × 18), "Home", "Agents" (amber 6 pt dot while a session
needs you), flexible space, the icon toggles Keep awake, Mirror, Settings. The date and
weather text goes (weather is the Today card). The battery badge (charging, or under 20 %
unplugged) stays left of the toggles **[call: it is state]**. Keep awake on is an amber icon
and time with **no tinted circle** **[call: the mockup's circle would break the
no-tinted-icon rule; only the dock's live circle is tinted]**.

## 3. Home

Header; two equal-height cards, Now Playing : Today = 1.25 : 1, 10 pt apart; 12 pt; the dock.
A file drag swaps the cards for the drop box; approvals sit above the cards (both unchanged).

### 3.1 Now Playing card

- **Playing or paused:** 74 pt art (radius 12) with the **source-app badge**: the playing
  app's installed icon, 20 pt, radius 6, 2 pt border in the card colour, 4 pt past the art's
  bottom-right corner; no installed icon, no badge (never initials). Title 14 pt semibold;
  "Artist · Album" 12 pt secondary; both one line, tail-truncated. A 4 pt progress bar (track
  white 0.14), elapsed and `-remaining` at 11 pt tabular tertiary; previous / play-pause /
  next at 16 / 22 / 16 pt, 22 pt apart.
- **Glow:** `NowPlaying.artworkTint` (from `DominantColor`) as a soft ellipse behind the
  card's left half: a soft elliptical gradient equivalent to blur 34 (no blur filter; phase A ruling), opacity 0.45, clipped to the card. Monochrome or missing art:
  `DominantColor.fallback`. Static; it cross-fades 0.6 s on a track change **[call]**.
- **Nothing playing:** §3.5.

### 3.2 Today card

Two parts, a white 0.06 hairline between. **Sky** (top): the condition's gradient and symbol (§5), temperature in 34 pt SF Pro
  Rounded semibold, "Condition · Place" (12 pt medium; clear by day reads "Sunny" **[call]**),
  then one 11 pt line: raining now → `Umbrella till 11 PM` (end of the current run of hours at
  ≥ 50 %); rain later in the 12 h forecast → `Rain from 5 PM`; else `H 27° · L 18°` (new
  daily high/low from Open-Meteo). Data older than 45 min, or kept while a refresh fails, appends ` · updated 2 h ago`. No reading and the last try failed: "Can't get weather" (or "Offline", or "Can't find your location") with "Try again" and "Add a city" (phase A fix round 1).
- **Next** (bottom), first that applies:
  - a timed, not-declined event in progress or later today: label `Now · ends 4:30 PM`,
    `Next · in 45 min` (within 60 min) or `Next · later today` **[call]**; title 13 pt
    semibold; detail `3:44 PM · Google Meet` (provider from the join link, else time only);
  - **free:** `Free today`, or `Free tonight` from 17:00 **[call]**, over the **week strip**:
    7 days from today, weekday (11 pt tertiary) over the date (12 pt medium). The next day in
    the week with an event wears a 20 pt `count blue` circle **[call: wireframe B marks a day
    ahead, not today]**; the whole strip is one "Open Calendar" button, which opens Calendar on today (a date would need Apple Events; phase A ruling).
  - Reminders leave Home: they are the Remind badge and tool **[call]**.

### 3.3 Dock

Eight 66 pt slots spread across the panel: a 38 pt `raised` circle with a 17 pt monochrome
symbol, a 10.5 pt secondary label under it. Search is a transparent circle with a 1 pt
`stroke` ring, labelled with the global shortcut (`⌥⌘K`), or "Search" while it is off
**[call]**. A click opens the tool in place (§4). Hover lifts the circle to `stroke`
**[call]**. Slots are keyboard-focusable and read as "Remind, 3 due".

Slots (symbol; widget needed): Timer (`timer`; `time` or `focus`), Note (`note.text`;
`notes`), Remind (`checklist`; `reminders`), Clipboard (`doc.on.clipboard`; `clipboard`),
Shelf (`tray`; `shelf`), Memory (`brain`; none), Games (`gamecontroller`; `games`), Search
(`magnifyingglass`; none). Each opens its tool; Search opens the search view.
A slot whose widget is off stays, dimmed to tertiary; its tool shows one "Turn on <Tool>"
button **[call: keeps the user's switches, leaves no gap]**. Settings › Dock can add other
panel tools (Baskets, Mail, Sites & Shortcuts, File actions, plugin tabs) (§6).

### 3.4 Badges and live states (replace the chips)

- **Badge:** a 16 pt high `count blue` capsule (min width 16, padding 0 × 4), 10 pt semibold
  white digits, at the circle's top-right (2 pt above, 12 pt in from the slot's edge). 0 hides
  it; over 99 reads `99+` **[call]**. Remind: incomplete reminders overdue or due today.
  Shelf: items on the shelf. Others: none **[call]**.
- **Live:** circle filled amber at 0.18, symbol and label amber, the label is a time. Timer is
  live while focus, a timer or the stopwatch runs: focus left first, else the soonest timer,
  else stopwatch elapsed (`18:42`, `1:02:05`) **[call: order]**. Ticks only while the panel is
  open (`\.panelTicking`).

### 3.5 Empty states (no empty boxes)

| Where | When | Shows |
|---|---|---|
| Now Playing | nothing playing, a last-played track | "Nothing playing" (11 pt tertiary), chips `Resume "Green Light"` (the app's 14 pt icon) and up to 2 recents, then Platy (30 × 24) and a greeting |
| Now Playing | nothing ever played | the caption, Platy, the greeting, "Play something and it shows here." |
| Greeting **[call]** | by hour | 05–12 "Fresh morning. Platy's on it." · 12–17 "Quiet afternoon. Platy's on it." · 17–22 "Quiet evening. Platy's on it." · 22–05 "Late night. Platy's on it." |
| Sky | no place, no Location access | clouds sky, "Weather", buttons "Use my location" and "Add a city" |
| Sky | first fetch pending | clouds sky, "Loading weather…" |
| Sky | weather widget off | Next fills the card **[call]** |
| Next | Calendar off or not granted | "This week", the strip with today circled, a "Connect Calendar" link to Settings › Privacy; never a prompt |
| Next | first run's "Try it" | "This is Home" / "Every tool is one click away in the dock" **[call: was a chip]** |
| Tools | empty list | one line with Platy (§4) |

Recents: Apple Music only, its first two user playlists by name, read through the existing
Automation path only when Automation is already granted **[call: Music has no recents API;
Spotify and others get Resume only]**. Resume sends play to the last app (Music and Spotify
by AppleScript, others by the media-remote play command). `LastPlayed` (title, artist, bundle
id, time) is saved whenever a titled track plays.

## 4. Tool views

**Pattern:** a dock slot, search, the menu bar or an old link opens the tool **in place**: the
header's tabs morph into ‹ and the tool's name (14 pt semibold), the tool's controls
trailing; the body is one `card` (padding 14). ‹, Esc or ⌘[ return to Home. One spring
(response 0.35, damping 1.0) for open, close and morphs; Reduce Motion keeps the short ease.
Lists: 28 pt neutral icon wells (radius 8, `raised`), 13 pt text, 11 pt tertiary detail,
0.05 hairlines, the selected row on `raised`.

- **Timer:** modes Timer · Focus · Stopwatch as header chips (selected: white fill, black
  text). Left: the value at 54 pt SF Pro Rounded semibold, tabular; preset chips — Timer `1 min,
  5 min, 10 min, 25 min, + custom` (default 10), Focus `15, 25, 50 min` (default 25)
  **[call]**; custom is an inline field read by `DurationParser`. Right (170 pt): white
  "Start", then running items, amber dot for the soonest, tertiary for others (`Tea · 3:10
  left`). Running: the number counts, Start becomes Pause and Stop. Stopwatch: Start / Lap /
  Reset, laps on the right. Alarms and world clocks stay in the Time view (search "alarm")
  **[call]**.
- **Note:** a quick pad (↩ appends through `QuickNote`, clears, keeps focus), then the 5
  newest entries of today's note. No vault: the fallback file, as today.
- **Remind:** an add field (`QuickAddParser`), then up to 8 reminders — overdue (red
  "Overdue") first, then today, then upcoming; a circle completes one. No access: "Allow
  Reminders" (the prompt only on that click).
- **Clipboard:** a search field over the history; rows with the kind's symbol, text and age;
  ↩ copies and pastes the selection; secrets stay masked.
- **Shelf:** files as rows (the file's icon, name, size), "AirDrop all" in the header, drag out.
  Empty: the dashed drop box "Drop files here to keep them" with Platy.
- **Memory:** a search field (↩ searches), open loops (resolve, dismiss), "Open graph". No
  loops: "No open loops. Platy's keeping watch."
- **Games:** one row per `GameKind` (Snake, Tetris, 2048, Flappy, Platy Chase) with its hint
  and best score **[call: the wireframe's "five plus Platy Chase" is five in all today]**; a
  click opens the game in the panel.
- **Search** (wireframe D): full-panel, the field on top with an `esc` keycap, sections
  Tools, Commands, Also (memory last), the shipped ranking. ⌥⌘K, ⌘K and typing with no field
  focused open it. Approval keys never fire while a text field has focus.

## 5. Weather sky

Conditions come from `WeatherNow.code` and `isDay`:

| Condition | WMO codes | Day gradient | At night | Motion while open |
|---|---|---|---|---|
| Clear | 0, 1 | 160°: #3D8BF0 0, #6FB1F7 .55, #F7C56B 1 | 170°: #0D1530 → #1F2C58 | none |
| Clouds | 2, 3, unknown **[call]** | 170°: #4A5568 → #8A94A6 **[call]** | night navy **[call]** | slow drift |
| Rain | 51–67, 80–82 | 170°: #3B4B63 0, #56677F .6, #6D7D93 1 | night navy (wireframe B) | light streaks |
| Thunder | 95–99 | 170°: #1E1B26 → #3A2F55 **[call]** | same | rare soft flash |
| Snow | 71–77, 85, 86 | 170°: #4A74A8 → #8FB2DA **[call]** | same | slow flakes |
| Fog | 45, 48 | 170°: #6B7078 → #8E939B **[call]** | same | none |

Symbols: `WeatherCode.describe`'s names, 40 pt, `.symbolRenderingMode(.multicolor)`. Text on the sky is white;
each first (top-left) stop keeps ≥ 3:1 contrast with it. Motion is Core Animation only, added
when the panel opens, removed when it closes or under Reduce Motion **[call: timings]**:
drift 40 s a pass; streaks 0.8 s, a 14 × 22 pt pattern at 0.55; flash 0.25 s every 9–15 s;
flakes 6 s to fall, 3 a second.

**Location.** Settings › Home › Weather: "Use my location" (new users' default) or a city
(Open-Meteo geocoding, as today). Location is requested only when the user clicks "Use my
location" (Settings or the sky's empty state), never on open. One fix per refresh (30 min),
rounded to 2 decimals before it leaves the Mac; the place name from Apple's reverse
geocoder. Denied or revoked: the saved city, else the "Add a city" state; no re-prompt. Add
`NSLocationUsageDescription`, the `personal-information.location` entitlement and a Location
row (Weather) in Privacy.

## 6. Presets that mean something

A preset sets Home, the dock, the pill and the Agents tab, plus widget switches and the
notch mode as before. **Weather is on in all three.**

| | Everyday | Developer | Minimal |
|---|---|---|---|
| Home | Now Playing + Today | same | same |
| Dock | Timer, Note, Remind, Clipboard, Shelf, Games, Search | Games → Memory | folded: one Search slot, "All tools" **[call]** |
| Agents tab | once hooks are set up (today) **[call]** | always | once hooks are set up |
| Pill | music first | agents first | music first |
| Also | file actions, snapping off | file actions, snapping on, usage rings | notch hidden until live |

Settings › General: selecting a preset card shows a **live preview** of Home and the pill
for it (sample content, 0.6 scale) before "Apply"; Apply lists every change and asks when
something turns off, as today. **Settings › Dock** (new page after Home): the slots in order
(drag to reorder), a checkbox per available tool, an "N of 8" counter, "Fold the dock into
Search" (Minimal's switch). At most 8 slots including Search; Search moves but cannot be
removed; a ninth pick is refused with "The dock holds 8." Picking a tool whose widget is off
turns that widget on.

## 7. Closed pill (wireframe F)

Approvals always win. Then: a session needing you shows its app icon (18 pt; the name as text
with no app) and amber "Needs you" (12 pt semibold). Then by the preset's order — music
first: music, timer, working agents; agents first: working agents, timer, music.
- **Music:** mini art 20 pt (radius 6 **[call: 5 is off-scale]**), five `MusicBars` in the art's colour.
- **Timer:** Platy and the time left, 12 pt SF Pro Rounded semibold, amber.
- **Working agents:** today's agent dots. **Nothing:** Platy alone (Minimal hides the pill).

## 8. Agents polish (wireframe E)

Rows, the approval card and Open naming stay. Agent app icons are **24 pt** (radius 6) in
rows and the approval card; no app, the name as text. Header usage becomes **rings**: 14 pt,
track white 0.15, arc green, amber from 80 %, red from 95 % **[call]**, then `Claude 62%`
(12 pt secondary); one per agent, its 5-hour window **[call]**.

## 9. Visual tokens (exact)

| Token | Value |
|---|---|
| Panel | #000000, width 640, bottom radius 22 **[call: CSS 26; kept to match the pill]**, padding 30 top / 16 sides / 14 bottom |
| `card` / `raised` / `stroke` | #121214 (radius 16, padding 12) / #1C1C1F (circles, chips, wells, buttons, fields) / #2A2A2E (search ring, keycap, hover) |
| Ink | white 0.94 / 0.60 / 0.36; hairline 0.06, list rows 0.05 |
| State | green #32D74B running, amber #FFB340 needs you, red #FF6961 error |
| `count blue` | #4C8DFF: badges, the week strip's marked day, the caret **[call]** |
| Type | SF Pro 13 body, 14 semibold titles, 12 secondary, 11 captions, 10.5 dock labels, 10 semibold badges; SF Pro Rounded semibold 34 temperature, 54 timer, 12 pill time; SF Mono 12 |
| Radii | 4, 6, 8, 12, 16, 22; chips and badges are capsules |
| Sizes | art 74; source badge 20; dock circle 38, icon 17, slot 66; weather symbol 40; week day 22, marked circle 20; agent icon 24; ring 14; pill 34 high, mini art 20, pill icon 18 |
| Gaps, effects | cards 10; cards → dock 12; glow blur 34 at 0.45; live fill amber 0.18 |

SF Symbols are monochrome except the weather's. Platy: header, pill and empty states only.

## 10. Design lint

- Content colour only in the Now Playing glow, the sky view and the pill's music lead, which use no state colour.
- Big numbers only via `TypeScale.temperature` (Today card) and `TypeScale.timer` (Timer tool); no literal `.system(size:)` above 15.
- Still enforced: no tile grids (no `LazyVGrid`/`LazyHGrid` in panel views except game
  boards and two reasoned allowlist entries), no tinted icon squares except the dock's live
  circle, no monograms, no emoji, no teal, no bordered cards beyond the listed outlines.

## 11. Migration (keep users' settings)

`IslandMigration` (`ui.island.migrated`), once, for existing users:
- Widget switches and order, notifications, sounds, hotkeys, keep-awake, the notch mode and
  stored items are untouched; no preset is applied.
- No saved dock → the standard dock (§3.3); a user whose Home column was Mail gets Mail in
  place of Games **[call]** (Notes users already have Note).
- A saved `weather.place` becomes the city location (so no Location prompt).
- `home.settings` still decodes; `rightColumn` is read once for the Mail swap, then ignored.
- Old links still land: Quiet Notch §7 ids, plus `focus` → Timer in Focus mode, `time` → Timer.

## 12. Removed or replaced from Quiet Notch

Live chips (`ChipsRow`, `LiveChips`) → dock badges and live states. The Up next column
(`UpNextColumn`, `UpNext`) → the Today card's Next and week strip. The Notes / Mail column and
its Settings › Home picker → the Note tool, Mail via the dock or search. The media block and
`TwoColumns` → the Now Playing card. Header date and weather (`HeaderDate`) → the sky. The
command line under Home → the Search slot and full-panel search. "Colour only for state" and
the 15 pt ceiling → §10. Mono usage text, 16 pt agent icons, the 600 pt panel → rings, 24 pt, 640.

## 13. Constraints and build order

Unchanged: idle CPU under 1 %; Core Animation only, only while open; no `isolated deinit`;
explicit continuations; the type-check guard; no emoji; approval safety. Phases merge alone:
- **A. Home:** tokens, the sky and location, Now Playing and Today, empty states, weather in all presets.
- **B. Dock and tools:** the dock, badges and live states, seven tool views, full-panel search, chips out.
- **C. Polish:** preset layouts and preview, Settings › Dock, pill states, Agents, lint, showcase.
