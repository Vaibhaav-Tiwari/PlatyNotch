# Quiet Notch (PlatyNotch v0.3) — design

Source of truth: `docs/specs/2026-10-31-quiet-notch-wireframes.html` (approved, wireframes A–E).
This spec turns it into buildable rules. Anything the wireframe doc did not fix is marked
**[call]**. Context: `docs/specs/2026-10-25-ui-redesign-design.md` (what ships today).

## 1. Decisions the user approved

1. The panel is always black. No light panel. Settings still follows the system.
2. The pond scene and celebration moments are removed. Platy stays in the closed pill, the
   panel header and empty states.
3. Games leave the panel for the menu bar menu (and `play` in the command line).
4. Home's right column is "Up next" by default; Settings can swap in Notes or Mail.

## 2. Structure

Two views, **Home** and **Agents**. Agents shows only once agent hooks are set up (today's
`AgentsVisibility`). No Library, no tile grid, no ⌘3. ⌘1 is Home, ⌘2 is Agents.

The open panel is 600 pt wide. Its height follows its content between 160 and 380 pt
**[call]** (Home at rest is about 220 pt; the Agents list and command results grow it, then
scroll inside). The closed pill is unchanged: Platy left, one live thing right; several agents
show Platy, three dots and "+n"; approvals always win.

### 2.1 Header (both views)

Left to right: Platy (20×15 pt), the view switcher ("Home", "Agents" with an amber 7 pt dot
while a session needs you), flexible space, then the view's status text, then icon toggles.

- **Home status text:** date and weather as plain text, `Fri 31 · 14° Clear`. Weather shows
  only while the Weather widget is on and has a reading **[call]**; otherwise just `Fri 31`.
- **Battery:** shown only while charging (`64% charging`, green, `bolt.fill`) or below 20 %
  and not plugged in (`15%`, red, `battery.25` **[call]**). Plugged in and full: hidden. The
  existing short plug-in alert stays.
- **Keep awake** (cup icon): one click toggles. Off → on starts the last chosen duration,
  default 2 hours **[call]**; a secondary click offers 30 min / 1 h / 2 h / Until turned off
  **[call]**. While on, the icon is amber and shows the remaining time as `h:mm` (`1:20`); no
  time for "Until turned off". Works whether or not the System widget is on **[call]**.
- **Mirror** (video icon): opens Mirror inside the panel. The first click turns the Mirror
  widget on if it is off; the camera starts only after that click, as today **[call]**.
- **Settings** (gear): opens Settings.
- **Agents status text:** usage as small mono numbers, `Claude 5h 62% · 7d 31%`,
  `Codex 5h 18%`. No rings or tiles.

### 2.2 Home

Below the header, top to bottom:

1. **Live chips** (only when something is live; the row disappears when empty): focus
   (amber dot, `Focus 18:42`), each running timer (`Tea timer 3:10`, or `Timer 3:10` without a
   label), and the shelf while not empty (tray icon, `Shelf · 3`). Order: focus, timers by
   soonest end, shelf; at most four, then `+n` **[call]**. A click opens that feature inside
   the panel **[call]**.
2. **Two columns** (1.15 : 1, 22 pt gap, a hairline before the right column):
   - Left: the media block (54 pt art, title, artist, 3 pt progress bar with elapsed and
     remaining, previous / play-pause / next). Nothing playing: Platy with "Nothing playing".
   - Right: **Up next** — calendar events and reminders merged, three rows, overdue reminders
     first in red ("Overdue"), then by time. Each row: 58 pt time column, title, a quiet note
     (`in 45 m` for an event within the hour, `reminder` for a reminder) **[call]**. Empty:
     "Nothing up next" **[call]**. Settings › Home can swap this column for Notes or Mail;
     the choice is offered only while that widget is on, and falls back to Up next when the
     widget is turned off **[call]**.
3. A hairline, then the **command line** (§3).

**Shelf on drag:** while a file drag nears the notch (today's `.peek(.drop)` rules, approvals
first), the Home body becomes drop targets in one 74 pt dashed box: "Drop to keep on Shelf" and
"AirDrop" **[call: the wireframe's "Snap window" target is not built in v0.3; window
snapping stays on its shortcuts, as the feature table says]**. Shelf off: AirDrop only.

### 2.3 Agents

1. Pending approvals on top, oldest first, in the v0.2 card style (§5.4).
2. One row per session, attention order (needs you, error, working, finished, idle): the
   agent's app icon (16 pt), **project** in semibold, `· status · age` in secondary
   (`· running tests · 12 m`), a 7 pt state dot, and one button that names the app it opens
   (§4). A click anywhere on the row does the same.
3. A hairline, then one quiet line: `2 open loops · Search memory with ⌘K`; "open loops"
   opens the loops list inside the panel **[call]**. Hidden at zero loops.
4. Empty: Platy with "No agents running".

### 2.4 Features opened inside the panel **[call]**

Removing the Library leaves tools without a grid. They open inside the panel as a full-panel
view with a back chevron and Esc back to Home (today's `ToolHost`), reached from chips, the
header, the command line (`open …` suggestions), the menu bar and old tab links. This keeps
Clipboard, Sites & Shortcuts, File actions, Baskets, Time (alarms, stopwatch, world clock),
Memory search and graph, Notes, Mail, Mirror, Games and plugin tabs reachable.

## 3. Command line

Focus it with ⌘K, or start typing anywhere in the open panel when no text field has focus
(the typed character becomes the first character). Placeholder: "Add a reminder, start a timer,
search memory…" with a ⌘K keycap. Suggestions list under it (top one selected); ↑/↓ move, ↩ runs,
Esc clears then leaves. Nothing runs without ↩ or a click.

| Input | Does |
|---|---|
| `timer <duration> [label]` | Starts a timer (`DurationParser`): "Timer · 10 minutes · "tea"" |
| `focus [minutes]` | Starts a focus session, 25 by default |
| `remind <text>`, `reminder <text>` | Quick add through `QuickAddParser` and the Reminders service, exactly as the Reminders quick-add field |
| `note <text>` | Appends to today's note through the Notes widget; Notes off → "Turn on Notes in Settings" |
| `search <query>` | Memory search; up to 5 hits listed, ↩ opens Memory with the query |
| `play [game]` | Opens Games (`play chase` → Platy Chase) |
| anything else | "Search memory for "…"", "Remind me: …", and `Open <feature>` for a matching feature title **[call]** |

A blocked command says why in its row (no Reminders access → "Allow Reminders in Settings")
and never shows a permission prompt from typing.

## 4. Open terminal, fixed

**Cause:** the hook records only `TERM_PROGRAM` and the tty; sessions in the Claude app or
agent-orchestrator have neither, so the app fell back to "most recent terminal".

**Protocol:** `HookEvent` and `Session` gain optional `host_bundle_id` (string, omitted when
empty). `notch hook` fills it from its environment's `__CFBundleIdentifier`, which macOS sets
for every process an app launches (Claude sessions report `com.anthropic.claudefordesktop`).
The session store keeps the last non-empty value, like `term_program`. No version bump: the
field is optional and old readers ignore it **[call]**.

**Resolution** (pure, in Kit), first match wins:

1. `term_program` `tmux` with a valid tty → `tmux select-window` / `select-pane` on the pane
   whose `pane_tty` matches, then activate the host app **[call]**.
2. Terminal (`term_program` `Apple_Terminal`, or host `com.apple.Terminal` when `term_program`
   names no other known app) with a valid tty → select that tab (AppleScript, tty as `argv`).
3. iTerm2 (`iTerm.app`, or host `com.googlecode.iterm2` on the same condition) with a valid
   tty → select that session.
4. A known `term_program` (ghostty, WarpTerminal, vscode) beats an inherited Terminal/iTerm2
   host: a VS Code session started from Terminal says "Open Code".
5. A valid host bundle id (reverse-DNS, at most 255 bytes; invalid counts as absent) whose app
   is installed → activate it (launch it if it is not running **[call]**).
6. Otherwise, with a cwd → **Show folder**: reveal the cwd in Finder.
7. No cwd either → no button **[call]**.

It never falls back to "most recent terminal"; the tracker and pid-ancestry guessing go.
A tab that cannot be found (or Automation denied) activates the host app, once, no retry.

**Button title:** "Open <name>" with the app's localized name from NSWorkspace ("Open Claude",
"Open Ghostty", "Open Cursor"); "Show folder" for case 6. The same title appears on Agents rows
and the approval card's secondary button.

## 5. Visual rules

### 5.1 Tokens (exact)

| Token | Value |
|---|---|
| Panel background | `#000000` always; bottom radius 22 |
| Text primary / secondary / tertiary | white at 0.92 / 0.56 / 0.32 |
| Hairline | white 0.10, 1 px, 12 pt above and below |
| Fill (chips, command line, buttons, code) | white 0.07 |
| State green / amber / red | `#32D74B` running, `#FFB340` needs you, `#FF6961` error |
| Approval card | `#111111`, radius 12, padding 12 at the sides and 10 above and below; command padding 6 × 9 **[call: one card with a full diff box fits the 240 pt approvals region]** |
| Radii | 6 (buttons, code, keycap 4 **[call]**), 8 (command line, media art), 12 (approval card, drop box **[call: wireframe 10]**), 22 panel bottom; chips are capsules |
| Panel padding | 30 top (below the notch), 18 sides, 16 bottom |
| Header | 12 pt text, 14 pt gaps, 14 pt below it; icons 16 pt |
| Chip | padding 3 × 10, gap 6, 12 pt, tabular digits |
| Command line | padding 7 × 10, gap 8, 13 pt; keycap 11 pt mono, 1 px hairline border, padding 0 × 4 |
| Button | 12 pt, padding 3 × 9, radius 6; Allow is green text on green 0.12 |
| Agent row | columns 18 / flexible / auto / auto, gap 10, 7 pt vertical padding, hairline between rows |
| Up next row | 3 pt vertical padding, 58 pt time column, 10 pt gap |
| Section label | 11 pt, uppercase, 0.06 em tracking, tertiary |
| State dot | 7 pt |
| Drop box | 1.5 pt dashed tertiary, 74 pt high, 22 pt between targets |

### 5.2 Type

SF Pro 13 body, 12 secondary, 11 captions; one 13 pt semibold title per block; nothing above
15 pt, nothing below 11 pt. SF Mono 12 for commands, numbers and usage.

### 5.3 Colour, icons, shape, motion

- White at three opacities; colour only for state (green running, amber needs you, red error).
  State colour always comes with a word or symbol. Teal is gone; no accent colour **[call:
  controls use white]**.
- SF Symbols, monochrome, 14–16 pt, never on a tinted square. Agent icons come from the
  installed app at run time; with none installed the agent's name shows as text, never initials.
  No bundled third-party logos.
- No bordered cards in the panel. The only filled surfaces: the approval card, chips, the
  command line (and buttons and the code line inside them).
- One spring for open and close (response 0.35, damping 1.0) **[call]**; Reduce Motion keeps
  today's short ease. No bouncing text, ripples or celebrations.

### 5.4 Approval card (v0.2 style)

Header row: the agent's app icon (the "brand glyph"; the name as text when no app is installed
**[call: the wireframe's drawn glyph would be a bundled logo]**), agent name in semibold,
project in secondary, the tool in a small chip, the countdown right-aligned in mono. Then the
command in mono 12 on the fill: one line for a one-line command; a longer one wraps up to
`maxSummaryLines`, then scrolls, never truncated **[call]** (diffs keep today's fixed-height box). Then right-aligned
"Deny ⌘⌫" and "Allow ⌘↩" with keycaps; Allow green. Arming, ordering, sanitising and keyboard
rules are unchanged.

## 6. Where every feature goes

| Feature | Today | v0.3 |
|---|---|---|
| Music | Hero / tile | Home media block |
| Calendar, Reminders | Two tiles + glance | Home "Up next", merged; add via command line |
| Weather | Tile | Header text ("14° Clear") |
| Battery | Tile (hides Keep awake) | Header text only when charging or below 20 %, plus the plug-in alert |
| Keep awake | Inside Battery tile | Header icon, one click, shows remaining time |
| Timers, Focus | Two tiles | Command line; live chips while running |
| Shelf, AirDrop | Tile | Drop targets on file drag; chip with a count while not empty |
| Mirror | Tool | Header icon |
| Agents, approvals, usage | Agents tab + tiles | Agents view |
| Open loops, Memory | Two tiles | One line in Agents; search via command line; MCP unchanged |
| Notes, Mail | Tools | Off by default; Settings › Home can swap one into the right column |
| Water | Glance + tile | Off by default for new users; a reminder notification only |
| Games, Platy Chase | Two tiles | One "Games" menu bar item (submenu per game) and `play` |
| Library | Tab | Removed |
| Platy | Pill, pond, moments | Pill, header, empty states |
| HUD, window snapping | Contextual | Unchanged |
| Clipboard, Sites & Shortcuts, File actions, Baskets, Time tools | Library tools | Opened inside the panel (§2.4) **[call]** |

## 7. Settings and migration

- Settings › Now becomes **Settings › Home**: right column (Up next / Notes / Mail). Glance
  slots and hero cycling go. `platynotch://settings/now` and the `now` section id land on Home.
- Old links keep working: tab ids `now`, `today`, `library` → Home; `agents` → Agents; `focus`,
  `memory`, `games`, a widget id or a plugin tab id → that feature inside the panel.
- **Nothing the user turned on is lost:** widget on/off and order, notification rows, sounds,
  the Notes vault, Mail, keep-awake, hotkeys and every stored item stay. Widgets that were glances
  stay on and show through the header, chips or Up next.
- Water: `NudgeSettings.water` defaults to 0 (off) for new installs. A one-time migration
  (`ui.quietNotch.migrated`) saves today's 60-minute value for an existing user who never saved
  wellbeing settings, so their water nudge keeps running; a saved value is never changed.
- Saved `appearance.settings` still decodes: `theme` and `surface` are read and ignored
  (always black, never glass **[call: glass is not black]**), and `motion` `lively` reads as
  `calm` **[call]**.
- Library recents, glance slots, hero cycling and the pond keys are left in defaults, unread.

## 8. Removed

The Library (grid, tiles, recents, ⌘3), the pond scene (`PondScene`, `PondSceneView`), moments
(`MomentGate`, celebrations), the light panel theme, glass, the teal accent (`Brand.teal`,
`Brand.pond`), the Now hero deck and glances, monograms, the "most recent terminal" fallback.

## 9. Constraints (unchanged from v0.2)

Idle CPU under 1 % (`scripts/perf-idle.sh`), Core Animation only for animation, no
`isolated deinit`, explicit continuations, the 300 ms type-check guard, no emoji, approval
safety unchanged (`ApprovalSafetyTests`, `ApprovalArmingControllerTests` untouched).

## 10. Build order (each phase merges on its own)

1. Open-terminal fix and the header toggles (Keep awake, Mirror, battery).
2. Structure: Library out, Home, command line, chips, shelf on drag, Games to the menu bar,
   pond and moments out, Notes/Mail column, water default.
3. Visual pass: black panel, tokens, type, Agents rows, v0.2 approval card, lint, showcase.
