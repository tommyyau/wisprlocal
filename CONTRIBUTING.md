# Contributing to WisprLocal

Thanks for your interest. Bug reports, fixes, docs and ideas are all welcome.

## Before you start

- **Bugs and ideas**: open an [issue](https://github.com/tommyyau/wisprlocal/issues/new/choose) using a template.
- **Bigger changes**: please open an issue first to discuss the approach, so your time isn't wasted.
- **Security problems**: report privately, as described in [SECURITY.md](.github/SECURITY.md).

## Ground rules

1. **Offline stays offline.** Nothing in the dictation path may use the network. `OfflineGuardTests` scans the source for networking APIs and fails if one appears outside `Sources/WisprLocalCore/RemoteBridge/` and the Receiver. Don't weaken it to make a change pass.
2. **Never change the user's words.** Cleanup and formatting go through the `OutputGuard`; if you touch either, add test cases for what should accept and what should reject.
3. **Numbers need a source.** Any performance or accuracy claim in docs or UI must come from [`WisprLocal/docs/TEST_REPORT.md`](WisprLocal/docs/TEST_REPORT.md) or a results file in the repo.
4. **Be kind about other apps.** WisprLocal is an independent alternative. Compare facts, never disparage.
5. **No model weights in git.** `RepoHygieneTests` enforces it.

## Development setup

Requirements: an Apple Silicon Mac on macOS 26. Built and tested with Xcode 27 (Swift 6.4) locally and with Xcode 26.6 (Swift 6.3) in CI, both on macOS 26. The package declares swift-tools 6.2; Swift 6.2 itself is untested.

```bash
cd WisprLocal/App
scripts/fetch_models.sh          # once: downloads Parakeet v2 + Ultra + Silero VAD into .models-cache/
swift build
swift test                       # all tests (model tests skip if models are absent)
scripts/test_offline.sh          # after scripts/fetch_models.sh; network denied; socket-dependent and opt-in tests are skipped
scripts/check_warnings.sh        # zero compiler warnings in our code (release, debug, tests)
scripts/ci.sh                    # all four gates: warnings, swift test, offline, build time
scripts/check_build_time.sh      # incremental release build after touching one view stays under 180 s
```

From the repo root, enable the privacy hook once: `git config core.hooksPath WisprLocal/App/scripts/hooks`.

Run `scripts/test_inventory.sh` for the current test inventory.

The build must stay warning-free. `scripts/check_warnings.sh` rebuilds our targets in release, debug and test configurations and fails on any warning under `Sources/`, `Tests/` or `Tools/`. Warnings inside dependencies (`.build/checkouts`) are listed but never fail it, which is why the gate is a script rather than `-warnings-as-errors` in `Package.swift` (that would break users' builds over upstream warnings).

Packaged builds must retain FluidAudio's licence and notices and each shipped model's licence, source and conversion attribution. `scripts/verify_bundle.sh` checks the assembled app and receiver, including exclusion of unused native text-normalization and LuxTTS resources.

Release builds must stay fast. `scripts/check_build_time.sh` brings the release build up to date, touches one SwiftUI view (`VIEW=`, default `SettingsView.swift`), times the incremental `swift build -c release`, and fails above `BUDGET_SECONDS` (default 180). On an M-series Mac a healthy incremental build takes about 8 s, and a clean one about 80 s. The script also prints CPU utilisation: if a slow build shows low utilisation, the build was waiting (on another build, a lock or a busy machine), not compiling. If it shows high utilisation, look for a slow type-check with `-warn-long-expression-type-checking`.

To run the app with stable permissions, create a local signing identity once, then build and install:

```bash
scripts/create_signing_identity.sh   # self-signed "WisprLocal Local Signing" in your login keychain
scripts/build_app.sh
scripts/install.sh                   # -> ~/Applications/WisprLocal.app
```

Without it, builds are ad-hoc signed and macOS forgets Accessibility and Input Monitoring on every rebuild.

## Pull requests

- Keep each PR focused on one change.
- Add or update tests (Swift Testing, in `WisprLocal/App/Tests/WisprLocalCoreTests/`). Bug fixes should come with a test that failed before the fix.
- Run `scripts/ci.sh` (warnings, `swift test`, offline tests and build time) before opening the PR, and say in the description that it passes.
- For UI changes, include a screenshot.
- Update [CHANGELOG.md](CHANGELOG.md) under `## 1.0.0 — unreleased`.
- By contributing, you agree your work is released under the [MIT License](LICENSE).

## Releases (maintainer only)

WisprLocal is not distributed as a prebuilt app, and no user-facing document points at a download. `WisprLocal/App/scripts/make_release.sh` is a maintainer tool that can still package `WisprLocal-<version>.dmg`, `WisprLocalReceiver-<version>.zip` and `SHA256SUMS.txt` in `WisprLocal/App/build.noindex/release/`. It refuses to package an ad-hoc-signed build.
