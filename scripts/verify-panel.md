# Notch panel: manual verification

Checks the notch panel window (Plan 3 Task 5) on real displays. Automated checks
cover the logic (`swift test`) and the launch (`swift run PlatyNotch --smoke`);
this list covers what only a person looking at the screen can confirm.

The panel content is still a placeholder (Task 6 replaces it): a black shape that
shows the mode (`hidden`, `compact`, `peek(approval)`, `expanded`, ...) and the core
connection (`connecting`, `connected`, `reconnecting`). On a notch Mac the compact
label sits behind the notch; you will see the green/orange connection dot on the left ear.

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

Minimal mode (panel hidden when nothing is live): `defaults write PlatyNotch appearance.minimal -bool true`
(the domain is the executable name under `swift run`; undo with `defaults delete PlatyNotch appearance.minimal`).
Show on all displays: `defaults write PlatyNotch appearance.showOnAllDisplays -bool true`.
Restart the app after changing either.

## Cases

Tick each on the hardware you have; note the Mac model and macOS version.

- [ ] **1. MacBook with a notch, built-in display main.** Compact panel sits exactly
  over the notch, extending ~64 pt on each side, top corners square against the
  screen edge, no shadow. Hovering the notch for a moment expands the panel
  downward from the notch; moving away collapses it after ~⅓ s. Clicking the
  compact panel expands it; clicking again collapses. Clicks on the menu bar left
  and right of the panel still reach the menu bar / status items. With the panel
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
  the label shows `reconnecting`, then `connected` again within a few seconds.

## Automated equivalents

```sh
cd apps/mac && swift test
(cd core && go build -o /tmp/pn-notch ./cmd/notch)
H=$(mktemp -d); S=$(mktemp -d /tmp/pn.XXXX)
PLATYNOTCH_CORE_BIN=/tmp/pn-notch PLATYNOTCH_HOME=$H PLATYNOTCH_SOCKET=$S/n.sock \
  swift run PlatyNotch --smoke          # SMOKE OK panels=1 mode=compact

# Approval peek end to end: app first (smoke after 10 s), then the fake events.
export PLATYNOTCH_HOME=$(mktemp -d) PLATYNOTCH_SOCKET=$(mktemp -d /tmp/pn.XXXX)/n.sock
(PLATYNOTCH_EXTERNAL_CORE=1 PLATYNOTCH_SMOKE_DELAY=10 swift run PlatyNotch --smoke &)
PN_FAKE_HOLD=8 ../../scripts/fake-events.sh --auto   # app prints SMOKE OK panels=1 mode=peek(approval)
```
