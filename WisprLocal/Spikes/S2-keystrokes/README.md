# S2 — keystroke synthesis over Screen Sharing

Which synthesized-input methods survive macOS Screen Sharing (Mac->Mac, Tailscale) into a remote TextEdit?

## Build
```
cd WisprLocal/Spikes/S2-keystrokes
source env.sh        # only needed because the Xcode license is unaccepted (swift via xcrun fails otherwise)
swift build
.build/debug/keytest all --delay 8
```
Unit tests: `swift build --build-tests` then run
`$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest .build/out/Products/Debug/KeyMapTests.xctest`
with `DYLD_FRAMEWORK_PATH=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks` and
`DYLD_LIBRARY_PATH=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib` (3 tests, all pass).

## Accessibility
Grant Accessibility to the **terminal app that launches keytest** (Terminal / iTerm / Ghostty / your IDE terminal):
System Settings > Privacy & Security > Accessibility > enable it, then quit and relaunch the terminal.
keytest refuses to run (and prompts) if not trusted.

## Run
1. Local baseline: open a local TextEdit (plain text, Format > Make Plain Text), click into it, run
   `.build/debug/keytest all --delay 8` from another terminal... the terminal steals focus when you press Return,
   so after pressing Return click the TextEdit window within the countdown.
2. Remote: open Screen Sharing to the remote Mac, remote TextEdit focused, **Screen Sharing window frontmost**,
   then in a terminal on the local Mac run `keytest all --delay 8` and click the Screen Sharing window during the countdown.
   (Run it from a terminal that is not covering the window, or via `ssh`/another device is NOT valid - events must be posted on the local Mac.)

Lines produced per run: `unicode:`, `keycode:`, `paste(sync 0ms):`, `paste(sync 1000ms):`, `paste(sync 2500ms):`.
Expected text after each prefix: `Hello World, it's 10:45! Email: a.b@x.com (test) £5 — café`

## Variants to try if a method fails remotely
```
keytest keycode --explicit-modifiers            # real Shift/Option keydown/up events around chars
keytest keycode --interval-ms 20                # slower pacing
keytest all --tap session --delay 8             # .cgSessionEventTap instead of .cghidEventTap
keytest paste --sync-ms 2500 --explicit-modifiers
keytest keycode --text "Test: ABC xyz"          # custom text
```
`keycode` prints UNMAPPABLE characters (those not producible on the current layout, e.g. possibly `—`).

## Results (fill in: OK / garbled (describe) / missing / nothing)
| Method | Variant | Local TextEdit | Remote via Screen Sharing | Notes |
|---|---|---|---|---|
| unicode | default | | | |
| unicode | --tap session | | | |
| keycode | default | | | |
| keycode | --explicit-modifiers | | | |
| keycode | --interval-ms 20 | | | |
| keycode | --tap session | | | |
| paste | sync 0 | | | |
| paste | sync 1000 | | | |
| paste | sync 2500 | | | |
| paste | --explicit-modifiers | | | |
