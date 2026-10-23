# PlatyNotch

PlatyNotch is an open-source MacBook notch app. It combines an agent hub
(approve and monitor Claude Code and other coding agents from the notch),
everyday widgets, and local memory that stays on your Mac. Its mascot is Platy
the platypus.

**Status:** early development. Expect breaking changes.

The Go core (`core/`) is the `notch` binary that speaks the socket protocol
described in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## On-screen capture (Mac app)

With memory on and Accessibility granted, the app reads the frontmost window's
text through the Accessibility API and sends it to the local core. It never
captures:

- password managers and Keychain Access (always, even if you edit
  `memory.exclude_apps`), apps listed in `memory.exclude_apps`, PlatyNotch
  itself, the login window, or System Settings' password panes;
- secure text fields, or anything while secure input is on, the screen is
  locked, or your session is not on the console;
- private or incognito browser windows. Detection is **heuristic**: it looks
  for "Incognito", "InPrivate", "Private Browsing", "Private Window" or
  "— Private" in the window title and accessibility description, and skips
  browser windows whose title cannot be read. Safari does not always mark a
  Private window, so add Safari to `memory.exclude_apps` (or pause capture)
  if that matters to you.

"Pause capture for 1 hour" is in the Memory tab.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
