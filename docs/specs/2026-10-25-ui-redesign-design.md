# PlatyNotch UI/UX redesign — design

Date: 2026-10-25. Status: draft for approval.
Inputs: competitor research (11 notch apps, 8 agent-in-the-notch apps, Apple's Live
Activities guidance), an audit of the current build with renders, and the user's
complaints. Features stay as they are; this design changes how they are presented.

Calls marked **[call]** are the designer's decisions, made because the user asked for a
product-designer's judgement rather than a list of options. Everything else comes from the
user's words or the research.

---

## 1. Why

The user, with everything turned on:

> it feels like a lot of things are just thrown at me. There's no clear distinction, and
> there's too much information … the UI just doesn't give the vibe of a good product …
> we don't have anything concretely visual to demonstrate.

The audit confirms it. The Today tab is one scrolling column of 17 unrelated tiles (about
950 pt of content in a 330 pt window, about 45 controls). Ten of the 17 tiles are setup
messages, not content. Nothing is bigger or more important than anything else: the largest
text is 13–15 pt, and 123 places use 11 pt. Tiles use three different container styles and
nine different corner radii. Platy, the strongest brand asset, appears at 22 pt in the pill
and nowhere in the open panel once agents are running. The first-run experience is three
pages of forms.

The audience is developers who use coding agents, but the product opens to the general
public now. So the design must be immediately pleasant for anyone, and become indispensable
for someone running Claude Code or Codex.

## 2. What the market rewards (research summary)

Ranked on UI/UX: Alcove, Crowny, NotchNook, Vibe Island, Droppy, MediaMate, boring.notch,
DynamicLake, Atoll; PlatyNotch currently last. Full notes:
`scratchpad/ui-research/notes.md` (not committed; summarised here).

What separates the top of that list from the bottom:

1. **One thing at a time.** Apple's Dynamic Island model: one *compact* activity when one
   thing is live; a *minimal* attached item plus small detached indicators when several are;
   *expanded* grows in place. Alcove wins on polish by doing this; DynamicLake is called
   "overwhelming" for showing everything.
2. **Context, not tabs.** NotchNook switches to its file tray when you drag a file in.
   Agent apps (Chimlo, Atoll) move whatever needs you to the top.
3. **Calm motion and a seamless notch.** Alcove is the motion benchmark. boring.notch's most
   complained-about change was a bouncy spring. A visible seam where the software meets the
   hardware notch is called out as cheap-looking.
4. **A character that carries status.** Every agent-in-the-notch app people talk about
   (Notchi, Chimlo, Crowny's Mochi, Agent Notch) uses a small companion whose pose *is* the
   state: working, waiting, done. Mascots that only decorate are ignored.
5. **Let people tune interruptions.** MediaMate is praised for choosing what may pop up, for
   how long, and when to stay quiet.
6. **First run sells the product.** Crowny's setup is a short, skippable welcome with a
   permission table that says what you lose by declining. NotchNook's repeated permission
   prompts are a top complaint.
7. **Agent hub table stakes (2026):** live session state, approve/deny in the notch with a
   preview of exactly what will run or change, "answer in terminal" fallback, and plan usage
   limits. Vibe Island adds diff previews and optional 8-bit sounds.
8. **Trends:** macOS 26's Liquid Glass styling (Droppy, Crest, DynamicLake ship glass
   modes); performance as a selling point (Notchy publishes idle CPU); open source and
   signed builds as trust signals.

## 3. Positioning **[call]**

**"Your Mac's notch, with a platypus who watches your agents."**

- For everyone: a calm, beautiful notch that shows the one thing that matters now (music,
  next meeting, a timer, a file you're moving) and stays out of the way otherwise.
- For developers: the best place to watch and answer coding agents, with Platy as the
  at-a-glance signal of what they are doing.
- Brand promise: calm, friendly, trustworthy (free, open source, local, under 1% CPU).

## 4. Goals, non-goals, anti-goals

**Goals**
1. With every feature on, the open notch shows at most one hero item and four glance items
   without scrolling. Nothing else appears unless it is live or the user asks for it.
2. Every screen has a clear visual hierarchy: one thing reads first.
3. Platy becomes the product's face and its status signal.
4. One consistent visual system: tokens for type, spacing, radius, color, elevation and
   motion, used everywhere.
5. A first run that shows the product working within 60 seconds.
6. Settings anyone can navigate: power features no longer buried.
7. Screenshots and a short screen recording that make people want it (README, website,
   social).

**Non-goals**
- No new features. Every existing widget and power feature keeps working.
- No change to the Go core, the protocol, or approval semantics.
- No full Liquid Glass rewrite; glass is an optional surface style.

**Anti-goals** (failure even if it technically works)
- Bouncy or jelly motion, overshoot on close, or a visible seam at the hardware notch.
- An approval that can be hidden, moved under the cursor, or answered by accident.
- Platy as noise: animating constantly, chattering, or making sounds by default.
- Breaking the idle budget (under 1% CPU collapsed) or the "nothing runs until enabled or
  clicked" privacy promise.
- A redesign that only re-skins the 17-tile column.

## 5. Principles

1. **Earn your space.** A widget appears in the panel only when it has something to show.
   Unconfigured or empty widgets never take a row; setup lives in Settings and onboarding.
2. **Live first, ambient second, tools on demand.** Every widget is one of three kinds
   (section 6.2), and each kind has its own place.
3. **Platy tells you.** Platy's pose and colour are the fastest way to read the state of
   your agents, at 22 pt and at 120 pt.
4. **Grow in place.** Opening the notch expands what the pill was already showing; nothing
   jumps or reorders under the pointer.
5. **Quiet by default, emphatic when it matters.** Only things that need you open the notch
   by themselves: approvals, an agent that needs input or errored, a ringing timer, a
   meeting starting. Everything else waits to be looked at (defaults in 6.3).

## 6. Information architecture

### 6.1 Surfaces

| Surface | When | Content |
|---|---|---|
| **Pill** (collapsed) | Always, unless Minimal mode and nothing live | Leading: Platy (status). Trailing: the top live activity, or nothing. Up to two small indicator dots for other live activities. |
| **Peek** | An approval, a notice, a ringing timer, a meeting starting, a drop target | One card, grown from the pill. Unchanged in behaviour. |
| **Open panel** | Hover or click | Three destinations: **Now**, **Agents**, **Library**. |
| **Context modes** | Drag a file toward the notch; an approval is pending | Shelf mode (drop zone + shelf); approval cards above everything. |

### 6.2 Widget kinds **[call]**

| Kind | Meaning | Members today | Where it shows |
|---|---|---|---|
| **Live** | Has a beginning and an end | Agents (one aggregate item, see 6.8), approvals, music playing or paused in the last 10 min, running timer/stopwatch, ringing alarm, focus session, meeting within 10 min, file action in progress, camera mirror on, Platy Chase in play | Pill trailing slot (top one), Now hero, indicator dots |
| **Glance** | Small, always-true facts | Next meeting, weather, battery, water progress, Claude/Codex usage, unread mail count, open loops count, today's tasks count | Now glance row (four slots, user-chosen) |
| **Tool** | Something you open to use | Music (player, last played, source picker), timers, clipboard, shelf/baskets, notes, games, sites & shortcuts, mirror, memory search & graph, focus, file actions, window snapping settings, and every plugin panel tab | Library grid; each opens full-panel |

A widget can be more than one kind: music is Live while playing and a Tool always; the
meeting widget is a Glance ("Next: 10:30 Design") and Live within 10 minutes. **[call]**

Widgets with no data, or not set up, show nowhere in Now. In the Library they show a dimmed
tile with one "Set up" action that opens their settings.

### 6.3 Priority (one model for pill, Now hero and auto-open)

Highest first; ties go to whichever started first (Apple's relevance rule):

1. Approval pending (always visible, always auto-peeks; never part of the hero, see 6.9)
2. Ringing alarm or timer at zero
3. Meeting starting within 2 minutes
4. Agent needs input / errored
5. Agent finished in the last 10 minutes (summary, then ends)
6. Timer or focus session running
7. Meeting in 3–10 minutes
8. File action or download in progress
9. Agents working
10. Music playing (or paused in the last 10 minutes)
11. Nothing live → Platy idle (pill) / Today summary hero (Now)

The user can demote or silence any kind in Settings › Notifications (MediaMate-style):
"show in pill", "can open the notch", "quiet during Focus". **Defaults [call]:**

| Kind | Show in pill | Can open the notch | Quiet during Focus |
|---|---|---|---|
| Approval | on | on (cannot be turned off) | no (cannot be turned off) |
| Agent needs input / errored | on | on | no |
| Agent finished | on | on, as today's short notice | yes |
| Ringing alarm / timer | on | on | no |
| Meeting starting | on | on | yes |
| Everything else | on | off | yes |

### 6.4 Now (the default destination)

```
┌──────────────────────────── 560 ────────────────────────────┐
│  [Now]  Agents  Library                       ⚙︎   ⌃        │  ← 32 pt nav, 15 pt labels
│ ┌─────────────────────────── HERO ─────────────────────────┐│
│ │  (Platy 96 pt)   Claude Code · platynotch          2 of 3 ││  ← top live item, 160 pt tall
│ │                   Running tests                     ▸     ││
│ │                   ▓▓▓▓▓▓▓░░░  4 m 12 s                    ││
│ └──────────────────────────────────────────────────────────┘│
│  ┌ 10:30 Design ┐ ┌ 24° Clear ┐ ┌ Water 5/8 ┐ ┌ Claude 62% ┐  │  ← four glance chips, 64 pt
│  Up next · Open loops (2) · Tasks (3)                        │  ← one quiet line, links
└──────────────────────────────────────────────────────────────┘
```

- **Hero**: the top live item from 6.3, at large size, with at most one primary control
  (Approve, Pause, Stop, Join). Swipe or ‹ › to cycle other live items ("2 of 3"). With
  nothing live, the hero is the **Today summary**: greeting, date, big time, next event,
  and Platy idle in its pond (section 8).
- **Glance row**: four user-chosen glances, equal chips, each opens its tool.
- **Quiet line**: counts that link into tools (open loops, tasks). Hidden when zero.
- No scrolling in Now. Ever.

### 6.5 Agents

- Header: usage rings for Claude (5 h, weekly) and Codex, compact, right-aligned.
- Session list sorted by attention: needs you → errored → working → finished → idle.
- Each row: agent icon, Platy-pup badge in the session's state colour, project name (15 pt),
  state line ("Running tests · 4 m"), last action in monospaced 11 pt, and one trailing
  action (Open terminal / Answer).
- Pending approvals render above the list exactly as today (safety rules unchanged), with a
  richer preview: the full command, file path, and (when the hook payload includes it) a
  unified-diff preview limited to 12 lines with "Show all".
- Empty state: large Platy, "No agents running", one button "Connect an agent".
- The permanent Claude-limits hint is removed; it appears only in the limits ring's tooltip
  while limits are unavailable.

### 6.6 Library

A 4-column grid of tool tiles (icon, name, one live line such as "2 timers" or "5 items").
Clicking opens the tool full-panel with a back chevron. Power features are ordinary tools
here, tagged "Power" only in Settings. Order: recently used first **[call]**.

### 6.8 Agents in the pill **[call]**

All agent sessions together are **one** Live item ("Agents"), ranked by its most urgent
session (needs input → rank 4, finished → 5, working → 9). In the pill, Platy is the leading
glyph and shows the aggregate mood; the existing per-session dots stay next to Platy (up to
three plus `+n`), now coloured by each session's agent colour (8.3) with the state shown by
the dot's motion (pulse = working, solid = waiting, hollow = idle). The trailing side shows
the top non-agent Live item, plus up to two indicator dots for further live items. The
existing `liveSide` setting stays and still swaps the two sides.

When no agent has ever connected and the user did not pick the Developer preset, the
Agents destination is hidden and the panel shows Now and Library only; it appears the
first time a hook connects (with a one-time notice) or when turned on in Settings › Agents.
Platy's mood then follows the rest of the priority model (music, timers, night) as it
already can.

### 6.9 Approvals with the panel open **[call]**

Approvals keep today's behaviour and safety rules exactly: they sit in the approvals region
at the top of the open panel (up to 240 pt), above whichever destination is selected, and
never move under the cursor. While any approval is pending:
- Now hides its hero and glance row and shows one compact line instead ("Now: Music ·
  Design in 8 min"), so nothing scrolls.
- Agents and Library show their content below the approvals region as today.
- The hero never cycles to or from an approval, so nothing slides under the pointer.
The richer preview (full command, path, up to 12 diff lines with "Show all") appears in the
open panel's approval cards only. The 420×236 peek keeps today's summary and gains a "Show
changes" link that opens the panel; peek size and arming do not change.

### 6.10 Plugins **[call]**

The public Swift API (`NotchWidget`, `NotchPlugin`) changes only additively, so existing
widgets and the private Pro plugins keep compiling and working:
- New optional requirements with defaults: `kind` (default `.tool`), `hasContent` (default
  `true`), `heroView()`, `glanceView()`, `libraryTile()` (defaults `nil`), `toolView()`
  (default: the existing `tileView()`), `setupAction` (default: open its settings).
- A widget that implements only `tileView()` appears as a Library tool showing that view.
- Plugin `panelTabs()` become Library tools (one tile each); there is no fourth destination.
- `tileView()` is deprecated in docs but not removed in this redesign.

### 6.7 What happens to today's tabs

| Today | Becomes |
|---|---|
| Agents tab | Agents destination (redesigned) |
| Today tab (17 tiles) | Now (hero + glances) and Library (tools) |
| Focus tab | Focus tool in Library; a running session is a Live item |
| Memory tab | Memory tool in Library (search + graph); open-loops count in Now's quiet line |
| Games tab | Games tool in Library; Platy Chase keeps its own entry |

## 7. Visual system

All values become tokens in one place (`PlatyNotchUI/Design/Tokens.swift` or similar) and
every view uses them. The audit's nine radii, three container styles and ad-hoc font sizes
go away.

### 7.1 Surface and material
- The pill and any area touching the hardware notch: **opaque black**, no gradient, no
  glow, no shadow at the seam. Close animations land exactly on the notch outline.
- The open panel: opaque near-black (#0B0D0D) by default; optional **Glass** style on
  macOS 26 using the system glass effect, falling back to opaque. Light theme keeps the
  existing contrast-checked light surface.
- Cards inside the panel: one elevated style (surface +1 step, 1 px inner keyline at 8%
  white), used for the hero, glance chips, Library tiles and approval cards. Plain rows
  (lists) have no container.

### 7.2 Color **[call]**
- Brand: **Platy teal** `#2FB8A6` (accent, focus rings, selected nav), **bill cream**
  `#F2E6C9` (Platy's highlights, idle hero glow), **pond blue** `#1C3B4A` (Now idle hero
  background tint).
- State: working = teal, needs you = amber `#F5A524`, error = coral `#F2685B`, done = green
  `#4CC38A`, idle = grey. Always paired with an icon or word (never colour alone).
- Per-activity tint: each Live kind gets a keyline tint in the hero (music takes the album
  art's dominant colour, the way Apple's Live Activities use a tinted keyline).
- Every pairing checked to 4.5:1 on both surfaces (extend `PanelPalette` tests).

### 7.3 Type **[call]**
SF Pro (system) for UI; SF Pro Rounded for numbers in hero and glances; SF Mono for
commands.

| Token | Size / weight | Use |
|---|---|---|
| display | 34 / semibold, Rounded | Hero time, big numbers |
| title | 20 / semibold | Hero title |
| headline | 15 / semibold | Row titles, nav |
| body | 13 / regular | Default text |
| caption | 11 / medium | Secondary lines (minimum size anywhere) |
| mono | 12 / regular | Commands, paths |

Nothing below 11 pt. Secondary text uses medium weight (Apple: avoid thin small text).

### 7.4 Space, radius, elevation
- Spacing scale: 4, 8, 12, 16, 24, 32. Panel inner margin 16; hero padding 20.
- Radius scale: 6 (chips inside cards), 12 (cards, tiles), 20 (hero), panel bottom corners
  follow `Theme.panelShape`. Margins are concentric (inner radius = outer − padding).
- Elevation: two levels only (surface, card).

### 7.5 Iconography
SF Symbols, hierarchical rendering, one weight (medium) and one size per context (15 pt in
rows, 20 pt in tiles, 28 pt in hero). No mixed icon sets.

## 8. Platy

Platy moves from decoration to the status signal and the product's face. The existing art
and 10 moods are kept and extended.

1. **Pill**: Platy is the leading glyph. Its mood follows the priority model: paddling
   (working), holding up an amber flag (needs you), check (done), headphones (music + work,
   already built), sleepy (night idle). Emphatic animation only for "needs you" (a single
   2-second wave, then still with the flag up).
2. **Now idle hero**: Platy at 96 pt in a small pond scene that follows time of day
   (morning light, evening dusk, night stars), drawn with Core Animation layers and still
   unless the panel is open. Greeting text beside it.
3. **Agent pups** **[call]**: each agent session gets a small Platy variant with a coloured
   bandana (Claude orange, Codex green, Cursor blue, Gemini violet, others teal) so several
   sessions are countable at a glance in the Agents list and the pill's indicator dots.
4. **Moments**: a short celebration when all agents finish, a new game best, or a focus
   session completes. Each at most once per event, at most 2 seconds, never during an
   approval.
5. **Sound** (off by default): an optional soft "plip" when an agent needs you. Mutes when
   the agent's terminal is frontmost.
6. **Restraint**: Platy never speaks text bubbles, never covers content, and is still under
   Reduce Motion and whenever the panel is collapsed with nothing live.

## 9. Motion

- One spring for all mode changes: response 0.35 s, damping 1.0 (no overshoot) for close;
  response 0.38 s, damping 0.86 for open **[call]**. Replaces today's 0.42 / 0.78 and the
  8 pt blur settle.
- Open = morph from the pill: the pill's leading and trailing content move to their places
  in the hero (matched geometry); nothing disappears and reappears.
- Content changes: numeric text transitions for counts and times; cross-fades ≤ 0.2 s
  elsewhere.
- Hover: keep enter 0.12 s / exit 0.35 s. Add "peek on hover, open on click" as a setting
  (default: open on hover, as today).
- No animation over 2 seconds; no repeating animation while collapsed and idle, except
  Core Animation layers already budgeted (agent dots, Platy pill frames while live).
- Reduce Motion: cross-fades only, Platy still, no morph.
- Settings › Appearance replaces the raw spring and blur sliders with Motion: **Calm**
  (default), **Lively** (slightly more spring), **Reduced**.

## 10. First run **[call]**

Four short screens, all skippable, replayable from Settings:

1. **Meet Platy.** Full-width Platy waves; the real notch on the user's screen opens and
   closes once to show where PlatyNotch lives.
2. **Pick your setup.** Three presets, each a visual card:
   - *Everyday*: music, next meeting, timers, weather, shelf, clipboard.
   - *Developer*: Everyday + agents hub, Claude/Codex limits, file actions, window snapping.
   - *Minimal*: notch stays hidden until something is live; music and agents only.
   Presets only choose which widgets are on and the four glances; all are editable later.
3. **Permissions, optional.** A table: each permission, what it powers, what you lose
   without it, and an Allow button. Nothing is requested without a click (unchanged rule).
4. **Try it.** "Move your pointer to the notch." When the user does, the panel opens on
   Now with a sample hero; Platy celebrates; Done.

## 11. Settings

Sidebar: **General**, **Notch** (appearance with a live preview of the pill and panel,
Minimal vs Always on, displays, motion), **Now** (choose and order the four glances, hero
cycling), **Notifications** (per-kind: show in pill / can open the notch / quiet during
Focus), **Widgets** (a grid of cards: everyday and power features as filters at the top;
click a card to open its settings as a detail page, not a stacked GroupBox), **Agents**,
**Memory**, **Privacy & Permissions** (the table from onboarding), **About**.

- The drag handle *or* the chevrons for ordering, not both.
- Explanatory prose moves to an ⓘ popover per setting; pages show controls first.
- Every empty state elsewhere in the app offers a one-click button that deep-links here.

## 12. Showcase assets

Part of done, because "nothing visual to demonstrate" was a complaint:
- Five hero screenshots from the render harness (Now with music, Now with an agent working,
  an approval with diff preview, Library, Platy idle scene), light and dark.
- A 20-second screen recording script: notch idle → agent starts → Platy paddles → approval
  peeks → Approve → done celebration → music takes over.
- README header image and a website hero built from these.

## 13. Constraints (unchanged)

- Idle CPU under 1% collapsed (`scripts/perf-idle.sh`); continuous animation only as Core
  Animation; timelines tick only while the panel is visible.
- Fixed window geometry from `PanelLayout` (expanded 560×380, peek 420×236, etc.). Hero,
  glances and nav must fit 560×380 minus the notch inset without scrolling. Changing these
  sizes is allowed only if the perf and placement tests are updated with them.
- Approval safety: 0.7 s arming, never under the cursor, never hidden, Return never answers,
  hidden characters stay visible, approvals win over every other surface.
- Light and dark themes with contrast tests; Reduce Motion; VoiceOver labels; no colour-only
  information.
- Privacy: nothing runs until enabled or clicked (album art, calendar, mail previews
  included).
- No `isolated deinit`; explicit continuations for completion-handler APIs (CI-enforced).

## 13b. Existing users **[call]**

- No forced first run. After the update, a one-time card at the top of Now offers "Take
  the 30-second tour" (the first run's steps 1, 3 and 4; presets skipped).
- Which widgets are on is kept exactly. A preset is applied only when the user chooses one
  in the tour or Settings, and then it asks before turning anything off.
- The four glances default to the first four enabled glance-capable widgets.
- `liveSide`, displays, Minimal mode, theme and hover settings are kept.
- The spring and blur sliders map to **Calm** unless the user had changed them, then to
  **Lively**; Reduce Motion still overrides.
- `platynotch://` tab links keep working: `today` → Now, `agents` → Agents, `focus`,
  `memory`, `games` → that Library tool.

## 14. Success measures

- With every feature on: Now shows ≤ 1 hero + 4 glances + 1 quiet line; zero scrolling.
- No text below 11 pt; one radius scale; one card style (lint/test for literal values in
  views where practical).
- First run reaches the "try it" step in under 60 seconds.
- Idle CPU unchanged (under 1%).
- The user, with everything on, no longer feels things are "thrown at" them (subjective
  check on a real MacBook).

## 15. Suggested phases

1. **Foundation**: tokens (type, color, space, radius, motion), one card style, Platy
   palette; apply to existing screens without layout changes.
2. **Now and the priority model**: hero, glances, quiet line; widget kinds; empty widgets
   leave the panel.
3. **Pill and live activities**: priority-driven trailing slot, indicator dots, Platy
   state poses, morph-in-place open.
4. **Agents**: attention sorting, pups, usage rings, richer approval previews.
5. **Library and tools**: grid, full-panel tools, Focus/Memory/Games moved in.
6. **Settings and first run**: new sidebar, live preview, notifications page, presets,
   permission table, try-it step.
7. **Platy and polish**: idle pond scene, moments, optional sound; showcase assets.

## 16. Left to the builder

- Hero layout per Live kind (music, timer, meeting, agents, file action, mirror, game),
  within the hero frame and token set.

- Exact component structure and file layout; whether tokens live in Kit or UI.
- Pond scene illustration details within the existing Platy style.
- Which glances each preset picks beyond those listed.
- How the diff preview is obtained per agent (only where the hook payload already carries
  it; otherwise command and path only).
- Recording and screenshot tooling.
