# Security policy

## Supported versions

| Version | Supported |
|---|---|
| the latest commit on `main` until the first tagged release | Yes |
| Pre-release builds (WisprLite, 0.x) | No |

## Reporting a vulnerability

Please **don't open a public issue** for a security problem.

Report it privately through GitHub: on [tommyyau/wisprlocal](https://github.com/tommyyau/wisprlocal), go to **Security › Report a vulnerability** (private vulnerability reporting). Include:

- what you found and its impact;
- steps to reproduce, or a proof of concept;
- the WisprLocal version and your macOS version.

You can expect an acknowledgement within 7 days. This is a one-person, spare-time project, so fixes are best effort, but security reports come first. Once a fix ships you'll be credited in the release notes unless you'd rather not be.

## Scope

In scope:

- **The WisprLocal app**: anything that sends audio, transcripts, history or dictionary contents off the Mac; inserts text somewhere the user didn't intend; or lets another process abuse WisprLocal's Microphone, Accessibility or Input Monitoring permissions.
- **The remote bridge and WisprLocal Receiver**: authentication or replay bypasses, listening on a non-Tailscale address, accepting unpaired senders, or anything that lets a third party inject keystrokes or text.
- **Build integrity**: the build scripts, signing, and the pinned model downloads.

Out of scope:

- The fact that v1 isn't notarised or distributed as a prebuilt app. You build it from source; this is a known, documented decision.
- Attacks that need an attacker who already runs code as your user, or has your password or physical access to an unlocked Mac.
- Bugs in macOS, Apple Foundation Models, Tailscale, or the bundled models and libraries (please report those upstream; tell us too if WisprLocal needs a mitigation).
- Misrecognitions and formatting mistakes, unless they're a security bypass.

## Threat model summary

**What WisprLocal protects:** your speech and what it becomes. Audio, history and your dictionary stay on your Mac. Recognition, cleanup and learning run locally; the optional paired-Mac bridge sends finished text over Tailscale.

- **Local recognition, cleanup, learning and history.** Speech recognition, voice detection and optional AI formatting all run on-device. There's no account, telemetry or analytics. A source-scan regression guard (`OfflineGuardTests`) fails if networking APIs appear outside the remote bridge, and the tests (socket-dependent and opt-in tests are skipped) also run with the network denied (`scripts/test_offline.sh`).
- **Installed apps load models from their bundle** (developer builds and tools honour `WISPRLOCAL_MODELS_DIR`), with the library's offline mode forced on; there's no download path in the app. `scripts/model-manifest.sha256` pins SHA-256 for every shipped model file; `fetch_models.sh`, `build_app.sh` and `verify_bundle.sh` verify against it. The app does not re-hash at runtime.
- **Remote bridge (opt-in, Beta).** Sends finished text (never audio) only to Tailscale address literals, and only over a `utun` tunnel path. The receiver binds only to an address on Tailscale's `utun` interface (never a CGNAT address on Wi-Fi/Ethernet), and each message is authenticated with HMAC-SHA256 using a key shared at pairing, with nonce and timestamp checks against replay. The receiver refuses while macOS secure input is enabled on *its* Mac; text reached it but is not inserted or kept, and fields that do not enable that signal are not detected. The sender does not fall back to typing after this refusal. Neither side logs the text. Acknowledgements are not authenticated and the bridge relies on WireGuard for confidentiality (see REMOTE.md).
- **The pairing code is the receiver's permanent key.** Whoever holds it and can reach the receiver on your tailnet can paste arbitrary text (including a command plus newline into a focused Terminal) on that Mac at any time, with or without a Screen Sharing session. Revoke with the receiver's **Generate New Key…**; see "What a leaked pairing code allows" in [REMOTE.md](../WisprLocal/docs/REMOTE.md).
- **Clipboard writes.** Automatic dictated-text clipboard writes (paste, focus-changed copy and failed-insert copy) use Concealed + Transient markers and are current-host-only. The two Screen Sharing writes (clipboard-delay fallback and pairing code) keep the markers but are not current-host-only. Copy buttons you click write ordinary clipboard text.
- **Insertion safety.** At insertion, WisprLocal checks the frontmost process and bundle against the app you started in; an app change copies text to the clipboard. It does not detect a window or field change within the same app. When macOS secure input is enabled, nothing is inserted; no text or audio is kept; History shows only the time, the outcome and the app; fields that do not enable it are not detected. A dictation refused by any of these checks is recorded in history **without its words** and with no troubleshooting audio (only the time, outcome and app). Browser password fields that don't turn on secure input are not detected yet. The previous clipboard is restored after pasting.
- **Microphone capture.** Capture runs while 🌐 or the chosen mouse button is held, during double-tap hands-free until Done/a tap/10 minutes, during the three-second mic test, and with Microphone readiness set to Ready for 60 s after dictating (on by default) or Always on. Warm audio stays in memory; the last ~0.3 s becomes dictation pre-roll and part of its recording if enabled. Unused warm audio is never saved.
- **Screen Sharing fallback.** Without pairing, WisprLocal types locally into the viewer window and uses no network for that fallback.
- **Logs.** WisprLocal's unified-log messages carry outcome kinds, counts, timings and error descriptions only, never dictated words (`LogHygieneTests` is a source-scan regression guard, not proof that every runtime path is content-free).
- **Local data.** History, dictionary and troubleshooting recordings (last 20, on by default; turn off in Settings › Privacy) are stored unencrypted in `~/Library/Application Support/WisprLocal/` with owner-only permissions (files 0600, folders 0700), protected by your macOS account and FileVault. Anyone with access to your user account can read them. Clear them in the app at any time. When a dictation is blocked by macOS secure input, blocked while WisprLocal is holding off for Wispr Flow, or cancelled, no text or audio is kept; History shows only the time, the outcome and the app. After an app switch or a failed paste, the text is not saved in History or recordings; the text is copied to the clipboard so you can paste it, and kept in memory until you quit for ⌃⌥⌘V. Failed dictations (no speech heard, transcription failed, the app refused the text) keep audio if Keep last 20 recordings is on, but never text.
- **Distribution.** There is no prebuilt download: you build WisprLocal from source and sign it with a stable certificate you create on your own Mac (`scripts/create_signing_identity.sh`). Read the code you build, and clone only from this repository.
