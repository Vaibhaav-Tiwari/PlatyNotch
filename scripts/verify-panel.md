# Notch panel: manual verification

Checks the notch panel window (Plan 3 Task 5) and its content (Task 6) on real displays. Automated checks
cover the logic (`swift test`) and the launch (`swift run PlatyNotch --smoke`);
this list covers what only a person looking at the screen can confirm.

What each mode shows:

- **Compact**: up to three agent dots on the left (green pulsing = working, amber =
  waiting or needs approval, grey = idle) and `+n` for more; on the right (the live ear)
  a count of pending approvals, an amber bolt while the core is not connected, else the
  top live activity (music, a timer). On a notch Mac the dots sit in the left ear and the
  badge in the right ear; Settings › Appearance › Live activities swaps the ears.
- **Peek (approval)**: the oldest approval card in full; with several, the next one as
  a one-line row (agent · tool · first line, "+n more", "Open"). Clicking the card
  header, "More" or "Open" opens the full panel. **Peek (notice)**: a short toast ("Claude Code finished").
- **Expanded**: tabs Agents, Today (the enabled widgets' tiles, in the order set in
  Settings › Widgets), Focus (while the focus widget is on), Memory and Games (while the
  games widget is on); pending approvals above the tab, the Agents list and Claude/Codex
  usage bars, and a chevron close button. An amber "Reconnecting…" shows in the tab bar while the core
  is down.

## Setup

Terminal A (fake core with hook events; nothing touches your real PlatyNotch data):

```sh
scripts/fake-events.sh            # Enter between steps; --auto runs them unattended
```

It prints the command for terminal B, of the form:

```sh
cd apps/mac && PLATYNOTCH_EXTERNAL_CORE=1 PLATYNOTCH_HOME=… PLATYNOTCH_SOCKET=… swift run PlatyNotch
```

Start the app, wait for `connected`, then step through the script. Approvals only
appear while the app is connected.

Minimal mode (panel hidden when nothing is live), the displays (menu-bar display, all, or
those with a notch), open on hover or click, pill width, live side, theme, motion and
"Hide in full screen" are in Settings › Appearance and apply at once, no restart. They are
one JSON value under `appearance.settings` (the domain is the executable name under
`swift run`: `defaults read PlatyNotch appearance.settings`; `defaults delete PlatyNotch
appearance.settings` resets them). The Plan 3 keys `appearance.minimal`,
`appearance.showOnAllDisplays` and `appearance.liveSide` are read once as the starting
values while `appearance.settings` does not exist, and never again.

## Cases

Tick each on the hardware you have; note the Mac model and macOS version.

- [ ] **1. MacBook with a notch, built-in display main.** Compact panel sits exactly
  over the notch, extending ~64 pt on each side, top corners square against the
  screen edge, no shadow. Hovering the notch for a moment expands the panel
  downward from the notch; moving away collapses it after ~⅓ s. Clicking the
  compact panel expands it; the chevron at the top right collapses it (clicks inside
  the open panel go to its content and do not collapse it). Clicks on the menu bar left
  and right of the panel's ears still reach the menu bar / status items. By design
  the compact ears (~64 pt each side of the notch) cover menu-bar items that sit
  right next to the notch; those items are not clickable through the panel. With the panel
  expanded, click into it then press Esc: it collapses.
- [ ] **2. Mac without a notch (or an external display as main).** A rounded pill
  appears centred just below the menu bar, not covering it. Expanded and peek
  panels also start below the menu bar. In Minimal mode with no live session the
  pill is gone; pushing the cursor to the top edge above where it would be (and
  pausing) reveals and expands it.
- [ ] **3. Full-screen app on the panel's display** (e.g. Safari or Terminal
  ⌃⌘F). The panel disappears. Pushing the cursor to the top edge over the notch /
  pill area shows it again; moving down into it keeps it; moving away hides it
  again. Leaving full screen brings the panel back within about a second. A
  full-screen app on a *different* display does not hide it.
  On a notched display macOS places full-screen windows below the camera housing;
  the panel must still hide there (a maximised, non-full-screen window must *not*
  hide it). Multi-display caveat: only the *frontmost* app is checked, so a
  full-screen app on display A that is not frontmost (you clicked an app on display
  B) leaves A's panel showing; with "Show on all displays" each display checks the
  frontmost app's windows against its own bounds.
- [ ] **4. Display changes.** Plug or unplug an external display, change which
  display is main (System Settings › Displays › arrangement, drag the menu bar), and
  change resolution ("More Space"). Each time the panel is rebuilt on the main
  display at the right place (notch or pill) within a second, with no leftover
  panel on the old display. With "Show on all displays" on, every display has one.
- [ ] **5. Spaces and Mission Control.** Switching Spaces (⌃→) keeps the panel in
  place without sliding with the Space; Mission Control and ⌘-Tab do not list it;
  clicking the panel never activates PlatyNotch or takes focus from the frontmost
  app unless the panel is expanded or showing an approval.

## Approval peek

- [ ] **6. Approval while hidden.** Turn Minimal mode on, restart the app, step
  `fake-events.sh` to "2/5 permission request". The panel peeks (`peek(approval)`)
  even though it was hidden, stays when the cursor moves over and away from it, and
  survives Esc. It also shows over a full-screen app (case 3). When the approval
  expires (100 s default) or is answered, the panel returns to compact or hidden.
- [ ] **7. Approval while expanded.** With the panel expanded by hover, step to
  "3/5": it stays expanded; moving the cursor away settles into `peek(approval)`,
  not compact.
- [ ] **8. Core restart.** Without `PLATYNOTCH_EXTERNAL_CORE` (the app supervises
  its own core; set `PLATYNOTCH_CORE_BIN=/tmp/pn-notch`), `pkill -f 'pn-notch serve'`:
  the compact pill shows the amber bolt (the open panel says "Reconnecting…"), then
  returns to normal within a few seconds.

## Approval card

Use `fake-events.sh` (step 2 adds one approval, step 3 two more: `git status` and a
long multi-line command with a Unicode path). The core default expiry is 100 s.

- [ ] **9. Card content.** The card shows the agent icon and name, the project, the
  tool tag (`Bash`) and the summary exactly as sent: monospaced, quotes and
  backslashes intact (`npm test -- --grep "panel \"peek\""`). Drag-select part of the
  summary and ⌘C: the pasted text matches. The countdown in the top right ticks down
  once a second.
- [ ] **9b. Hidden characters.** Send an approval whose command contains a bidi
  override or ANSI colors, e.g. via `fake-events.sh`'s `permission` with
  `$'echo \u202Egnp.exe \e[31mred\e[0m'`: the card shows "Contains hidden characters"
  and the summary reads `⟨U+202E⟩gnp.exe ⟨ESC⟩[31mred⟨ESC⟩[0m`.
- [ ] **10. Several approvals at once.** After step 3 the peek shows the oldest
  (fake-1) in full and a row "Claude Code · Bash · git status … +1 more  Open" with no
  Allow/Deny. "Open" opens the panel: "3 approvals
  waiting · oldest first", cards ordered fake-1, fake-2, fake-3, and the list scrolls.
  Answer the middle one: only it disappears and its hook in terminal A prints the
  decision; the others keep their own countdowns and buttons.
- [ ] **11. Long multi-line command, Unicode path.** fake-3's summary shows every line
  with the Unicode path (`/tmp/données/日本語 フォルダ/café ☕`) rendered correctly, no
  `\n` escapes, long lines wrapped. In the open panel with one approval the summary
  grows to 12 lines, then scrolls (line 13 only after scrolling); with several
  approvals, and in the peek, it scrolls after about 5 lines.
- [ ] **12. Keyboard.** With the approval peeking and the panel *not* clicked, typing
  in another app (including Return, ⌘↩, ⌘⌫) goes to that app and answers nothing.
  Click into the card (e.g. on the summary): Return does nothing; ⌘⌫ denies the
  oldest card, ⌘↩ allows it; one keystroke answers one approval.
  **Carry-over guard:** with two approvals pending, hold ⌘↩ (key repeat), or
  double-click Allow, or click Allow twice quickly: only the first approval is
  answered; the next one slides into place, and a click or ⌘↩ within ~0.7 s shows
  "Look first…" instead of answering. After 0.7 s it answers normally. A card that
  just appeared (or the panel just opened) also shows "Look first…" for the first
  0.7 s. With Full Keyboard Access on (System Settings › Keyboard), Tab reaches Deny
  but never Allow. The buttons show the
  shortcut hints. VoiceOver reads "Allow" / "Deny" with the shortcut as hint, and the
  summary text.
- [ ] **13. Sending.** Click Allow: the countdown changes to "Sending…" and both
  buttons disable until the card disappears (normally at once). With "Show on all
  displays", the other display's card shows "Sending…" too and cannot answer again. Terminal A prints
  `decision: ... allow`.
- [ ] **14. Reconnecting.** With approvals pending (app supervising its own core, as in
  case 8), kill the core: the cards stay, show "Reconnecting… m:ss" in amber and the
  buttons are disabled; "Open terminal" still works. When the core is back (its
  approvals are lost with it, so the cards disappear) nothing is stuck in "Sending…".
  A send failure shows a red message under the summary, with "Open terminal" still
  beside the buttons, and re-enables them.
- [ ] **15. Expiry.** Let an approval run out: at 0:00 the card reads "Expired —
  answer in the terminal" and the buttons disable (clicking Allow in the last second
  before the tick shows Expired immediately and sends nothing); the card goes away when the core
  resolves it, and the hook in terminal A falls back to the terminal prompt.
- [ ] **16. Open terminal.** "Open terminal" shows when the approval's session is
  known; clicking it does nothing yet (terminal focus is Task 7). Agents tab rows
  highlight on hover and are clickable the same way.
- [ ] **17. Light and dark.** With Settings › Appearance › Theme on Dark, switch System
  Settings › Appearance between Light and Dark: the panel stays black with legible text
  and colors in both. Theme Light: the open panel and peeks are light with legible text;
  System follows the system setting. In every theme the resting pill on a notch stays
  black.

## Automated equivalents

Run from `apps/mac`. Each block is a subshell that removes its temp dirs.

```sh
swift test

# Launch smoke: supervised core, temp home and socket.
(
  set -e
  (cd ../../core && go build -o /tmp/pn-notch ./cmd/notch)
  H=$(mktemp -d); S=$(mktemp -d /tmp/pn.XXXX); trap 'rm -rf "$H" "$S"' EXIT
  PLATYNOTCH_CORE_BIN=/tmp/pn-notch PLATYNOTCH_HOME=$H PLATYNOTCH_SOCKET=$S/n.sock \
    swift run PlatyNotch --smoke       # SMOKE OK panels=1 mode=compact
)

# Approval peek end to end: app first (smoke after 10 s), then the fake events.
(
  H=$(mktemp -d); S=$(mktemp -d /tmp/pn.XXXX); trap 'rm -rf "$H" "$S"' EXIT
  export PLATYNOTCH_HOME=$H PLATYNOTCH_SOCKET=$S/n.sock
  PLATYNOTCH_EXTERNAL_CORE=1 PLATYNOTCH_SMOKE_DELAY=10 swift run PlatyNotch --smoke &
  PN_FAKE_HOLD=8 ../../scripts/fake-events.sh --auto >/dev/null
  wait                                 # SMOKE OK panels=1 mode=peek(approval)
)
```
