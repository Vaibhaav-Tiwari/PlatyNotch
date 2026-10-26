# The 20-second recording

This is a script for a 20-second screen recording of the notch (spec section 12). It
runs against a throwaway core fed by fake Claude Code hook events, the same way
`scripts/fake-events.sh` does. Your real `~/.claude` and PlatyNotch data are never touched.

The storyboard: idle notch → an agent starts → Platy paddles → an approval peeks →
Approve → the done moment → music takes over.

## Before you record

- **Display:** a MacBook with a notch, at its default resolution. Hide the desktop icons
  and use a calm wallpaper. Close other menu bar extras if you can.
- **Settings › Notch:**
  - Theme: Dark. The light theme makes a second take.
  - Motion: Calm.
  - Open on: Hover.
- **Settings › Notifications › Sound:** off, unless you want Platy chatter on the
  approval beat.
- **Music:** queue a track in Music and leave it paused. The last beat presses Play.
- **Recorder:** QuickTime › New Screen Recording, a 900 × 360 region centred on the
  notch, at 60 fps if you can.

## Terminal 1: the core

From the repository root:

```sh
scripts/fake-events.sh
```

The script builds the core, serves it from a temporary home and prints a line that
starts the app against it. Leave it waiting at "1/5" and don't press Enter yet.

## Terminal 2: the app

Paste the line that fake-events printed. It looks like this:

```sh
cd apps/mac && PLATYNOTCH_EXTERNAL_CORE=1 PLATYNOTCH_HOME=<home> PLATYNOTCH_SOCKET=<socket> swift run PlatyNotch
```

## Terminal 3: the done beat

Use the same home and socket that fake-events printed:

```sh
export PLATYNOTCH_HOME=<home> PLATYNOTCH_SOCKET=<socket> PLATYNOTCH_USER_HOME=<home>/user
stop_fake1() { printf '{"session_id":"fake-1","hook_event_name":"Stop"}' | /tmp/pn-notch hook claude-code stop; }
```

## The beats

| Time | What the viewer sees | What you do |
|---|---|---|
| 0–3 s | The idle notch: Platy alone in the pill. | Start recording. Then hover the notch: Now opens on Platy's pond and the greeting. Move the pointer away, and it closes. |
| 3–6 s | **An agent starts.** An agent dot appears beside Platy, and Platy paddles. | Terminal 1: press Enter. Step 1/5 starts session fake-1. |
| 6–9 s | Hover to show Now's Agents hero: "Claude Code · …", "1 working". | Hover the notch, hold for 2 s, then move away. |
| 9–12 s | **An approval peeks.** The notch opens by itself with the command card. Platy raises the amber flag. | Terminal 1: press Enter. Step 2/5 sends the permission request. Don't press Enter again. |
| 12–14 s | **Approve.** The card's buttons arm after 0.7 s. Click Allow, and the card slides away. | Click **Allow** with the pointer. Return never answers, by design. |
| 14–16 s | **Done.** The session finishes. Platy celebrates for 2 s, then shows the check. | Terminal 3: run `stop_fake1`. |
| 16–20 s | **Music takes over.** The pill shows the music bars. Hover to show the music hero. | Press Play in Music (or the play key), then hover the notch for the final frame. |

Stop recording at 20 s. In Terminal 1, press Ctrl-C. This stops the core and removes the
temporary home.

## Tips

- **Retakes:** a retake starts from a fresh `scripts/fake-events.sh`. The temporary
  home is new each time, so nothing carries over between takes.
- **The celebration:** it plays once per finish and never while an approval waits. If
  you skipped Allow, answer the card first.
- **Reduce Motion:** if it is on, Platy stays still and moments are a still pose.
  Turn it off for the recording.
- **Stills:** for still images, use `PlatyNotch --render-showcase <dir>`. It writes the
  five hero scenes as PNGs. See `scripts/verify-widgets.md`.
