<!-- Release notes for v1.0.0 (source only: there is no prebuilt download or GitHub release). -->

**Dictation for your Mac. Hold 🌐, speak, done. On-device recognition.**

WisprLocal is a free, MIT-licensed, push-to-talk dictation app for macOS 26 on Apple Silicon. It runs NVIDIA's Parakeet v2 speech model on the Apple Neural Engine (via FluidAudio), with Moondream's new Parakeet Ultra one click away for noisy rooms and other languages, so there's no account, no subscription, and your voice never leaves your Mac.

Speech recognition, cleanup, learning and history run on this Mac without network access. The only network feature is Remote Macs (Beta), which sends finished text, never audio, to a Mac you pair over Tailscale, authenticated with HMAC. Without pairing, WisprLocal types locally into a Screen Sharing window with no network use by WisprLocal.

> WisprLocal is an independent alternative to Wispr Flow. Not affiliated with or endorsed by Wispr AI.

## Install

WisprLocal is installed by building it from source; there is no prebuilt download. It requires macOS 26+, Apple Silicon, Xcode, and about 5 GB of disk while building (about 1.1 GB for the finished app).

```bash
git clone https://github.com/tommyyau/wisprlocal.git && cd wisprlocal/WisprLocal/App
scripts/fetch_models.sh
scripts/create_signing_identity.sh   # recommended, once: privacy permissions survive rebuilds
scripts/build_app.sh
scripts/install.sh
open ~/Applications/WisprLocal.app
```

Grant Microphone, Input Monitoring and Accessibility when asked, then hold 🌐 and speak. Source build only, not notarised. Use a stable signing identity to preserve privacy permissions across rebuilds; changing identity requires granting them again. The recommended local identity is self-signed. Gatekeeper will warn if the app is quarantined, for example after transfer; a build on your own Mac is normally not quarantined. The full guide, Xcode setup and troubleshooting: [INSTALL.md](https://github.com/tommyyau/wisprlocal/blob/main/WisprLocal/docs/INSTALL.md). The optional **Beta** receiver for Remote Macs is built with `scripts/build_receiver.sh` ([REMOTE.md](https://github.com/tommyyau/wisprlocal/blob/main/WisprLocal/docs/REMOTE.md)).

The single `WisprLocal/App/VERSION` file supplies the app version. `scripts/model-manifest.sha256` defines and verifies the bundled model files. Release builds use the hardened runtime; the main app carries the `com.apple.security.device.audio-input` entitlement.

## What's in 1.0

- Hold 🌐 to talk, double-tap for hands-free
- Two on-device speech models, one loaded at a time: **English (Parakeet v2)** by default, and **Noisy room / other languages (Parakeet Ultra)** for a TV or people talking nearby, or other languages (25 European languages supported by the model, not yet tested by us)
- Clearly non-English text (at least three words, confidently recognised) is typed as heard, plus dictionary replacements; short or uncertain text gets English cleanup
- Five Settings tabs: General, Microphone, Writing, Privacy and Remote Macs, with a setup banner
- ⓘ help next to every non-obvious setting, and Help & FAQ in the menu bar
- "scratch that", "new line", "new paragraph"
- Snippets and a personal dictionary
- Optional on-device AI formatting (Apple Foundation Models), checked by a word-for-word guard requiring equal normalised word-token sequences plus case/layout checks
- Local history, movable recording indicator, noise reduction
- Remote Mac support via Screen Sharing or the paired WisprLocal Receiver (**Beta**: not yet tested end to end on two real Macs)
- Holds off automatically while Wispr Flow is running
- Paste fixes: adaptive clipboard restore is active, copies between dictations are preserved, and secure input, the frontmost app and Wispr Flow are checked again immediately before every paste.
- Guard fix: AI formatting preserves currency, percentage and math symbols, including $, %, +, −, =, <, > and #.

## Numbers (from the [test report](https://github.com/tommyyau/wisprlocal/blob/main/WisprLocal/docs/TEST_REPORT.md))

- Word error rate, clean speech: v2 6.12 %, Ultra 6.63 % (a tie on this small set)
- With TV speech in the background (-6 dB): Ultra 7.55 %, v2 19.03 %. Measured by feeding audio straight to the models, without the app's voice processing; real-world gaps may differ.
- 28 s of speech transcribed in 211 ms (v2) / 153-383 ms (Ultra), warm, on an M5 Pro
- Switching models takes 0.15-0.19 s once each has been prepared
- 9,004 calls in a 15-minute soak: 0 hangs, 0 errors
- 911 tests in 157 suites passed on 2026-10-05 (network-denied run: 911 passed; socket-dependent and opt-in tests are skipped). See `scripts/test_inventory.sh` for the live count.
- The maintainer confirmed build 202610050022; build 202610050038 was then rebuilt from the same sources (only docs and a verifier script changed) and installed. The detailed manual checklist remains unchecked.

Measured with synthetic voices on one machine. Real-voice and M1-class results aren't measured yet, so your numbers will differ.

## Known limitations

- Tested in English only. Ultra's other languages are supported by the model, not yet tested by us.
- Remote Macs is Beta: built and tested in software, but not yet end to end on two real Macs.
- Preparing a speech model for the first time — on first launch, after each macOS update, or the first time you switch to the other model — took 7–12 s in the latest measurement and 18–23 s in the original spike; after that it loads in well under a second.
- Not notarised, and not distributed as a prebuilt app: you build it yourself.

## Thanks

FluidAudio by FluidInference is the essential Swift library that runs our speech recognition and speech detection (Apache-2.0). Models: Parakeet TDT 0.6B v2 (NVIDIA; Core ML by FluidInference; CC-BY-4.0), Parakeet Ultra (Moondream, from NVIDIA's Parakeet TDT 0.6B v3; Core ML by FluidInference; CC-BY-4.0), Silero VAD (Silero Team, MIT). Full credits, pinned revisions, licences and conversion notes: [ACKNOWLEDGEMENTS.md](https://github.com/tommyyau/wisprlocal/blob/main/ACKNOWLEDGEMENTS.md).

Found a bug? [Open an issue](https://github.com/tommyyau/wisprlocal/issues/new/choose). Security issue? See [SECURITY.md](https://github.com/tommyyau/wisprlocal/blob/main/.github/SECURITY.md).

Full changelog: [CHANGELOG.md](https://github.com/tommyyau/wisprlocal/blob/main/CHANGELOG.md)
