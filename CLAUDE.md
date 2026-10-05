# CLAUDE.md

Guidance for Claude Code (claude.ai/code) and other contributors working in this repository.

## Project Overview

WisprLocal is a native macOS 26 dictation app (Apple Silicon). Speech recognition, cleanup, learning and history run on this Mac without network access. The only network feature is Remote Macs (Beta), which sends finished text, never audio, to a Mac you pair over Tailscale, authenticated with HMAC. Without pairing, WisprLocal types locally into a Screen Sharing window with no network use by WisprLocal. Push-to-talk on the Globe key: record, trim silence (Silero VAD), transcribe with Parakeet v2 (default) or Ultra (Core ML via the essential FluidAudio library by FluidInference, on the Apple Neural Engine), optionally clean up with Apple's on-device Foundation Models behind a word-for-word guard, then paste the text into the active app. No transcription or cleanup network access at runtime. Model weights are never committed. FluidAudio's optional native text-normalization trait is disabled; ASR and VAD do not use it.

Status: P1 (core loop), P2 (cleanup, dictionary, snippets, history, credits, rename from WisprLite) and P3 (Remote Macs: Screen Sharing insertion + the WisprLocal Receiver over Tailscale, shipped as **Beta**) are built. P4 (speaker gating) is not built. Settings was redesigned into five tabs on 2026-10-04; release builds use the hardened runtime. 911 tests in 157 suites passed on 2026-10-05 (network-denied run: 911 passed; socket-dependent and opt-in tests are skipped). `scripts/test_inventory.sh` gives the live count. The detailed manual checklist remains unchecked and the manual two-Mac remote test is still pending (see `WisprLocal/docs/TEST_REPORT.md`, sections 7, 9 and 10). Do not claim anything is tested that the test report does not show. Planned work: `WisprLocal/docs/ROADMAP.md`.

The earlier Python CLI and cloud prototype are not part of this repository.

## Repository layout

- `WisprLocal/App/` - the SwiftPM package (swift-tools 6.2, macOS 26). Targets:
  - `WisprLocalCore` (library): all logic, unit-tested.
  - `WisprLocal` (executable): SwiftUI/AppKit shell.
  - `WisprLocalReceiver` (executable): the menu-bar receiver for Remote Macs (runs on the remote Mac).
  - `wisprlocal-fetch-models` (`Tools/ModelFetcher`): dev-only online model downloader, not linked into the app.
  - `WisprLocalReplay` (`Tools/Replay`): offline replay of a troubleshooting recording.
  - `WisprLocalStatsC`: C target for the cleanup diff.
  - `WisprLocalCoreTests`: Swift Testing suite.
- `WisprLocal/App/scripts/` - `build_app.sh`, `build_receiver.sh`, `install.sh`, `make_release.sh`, `fetch_models.sh`, `models_common.sh`, `verify_models.sh`, `version_common.sh`, `create_signing_identity.sh`, `signing_common.sh`, `test_offline.sh`, `test_inventory.sh`, `make_fixtures.sh`, `verify_bundle.sh`, `ci.sh`, `check_warnings.sh`, `check_build_time.sh`, `privacy_scan.sh`, `hooks/pre-commit`.
- `WisprLocal/App/Licenses/` - licence files shipped inside the app.
- `WisprLocal/Spikes/` - experiments S1, S1b, S2, S3, S4, S5 (sources, RESULTS and selected text measurements are tracked; audio, model files and builds are git-ignored; not built by the app package). S4's legacy speaker weights are not cleared for redistribution and never ship in the app.
- `WisprLocal/docs/TEST_REPORT.md` - benchmarks, test inventory, untested gaps.
- `WisprLocal/App/Resources/` - icons and entitlements; `Sources/WisprLocal/Settings/` - Settings sections and rows.
- `WisprLocal/App/Tests/WisprLocalCoreTests/Fixtures/` - test fixtures and provenance.
- `.github/` - CI, issue templates, `pull_request_template.md` and security policy.
- `WisprLocal/docs/` - INSTALL, DESIGN, REMOTE, ROADMAP, TEST_REPORT, RELEASE_NOTES_v1.0 and the dated licence audit.
- `ACKNOWLEDGEMENTS.md` - third-party credits (also rendered in-app).

`WisprLocal/App/VERSION` is the single source of the app version. `scripts/model-manifest.sha256` defines what ships: `fetch_models.sh` verifies hashes, `build_app.sh` copies only manifest files, and `verify_bundle.sh` checks the bundle strictly.

## Module map (`WisprLocal/App/Sources/WisprLocalCore`)

| Directory | Responsibility |
|---|---|
| `Hotkey/` | `GlobeKeyMonitor` (CGEvent tap), `HotkeyStateMachine` (hold = push-to-talk, double-tap = hands-free), `MouseButtonMonitor` |
| `Audio/` | `AudioRecorder` (capture, resampling), `WarmMic`, `PreRoll`, `CaptureTail`, `AudioGating`, `MicSelfTest`, `SpectrumAnalyzer` |
| `VAD/` | `SpeechTrimmer` (Silero VAD trimming) |
| `Transcription/` | `Transcriber` (Parakeet via FluidAudio), `ModelLocator` (finds models; enforces offline mode), `ModelComparison` |
| `Cleanup/` | `RuleCleaner`, `FoundationModelsCleaner`, `OutputGuard` (word-for-word guard: equal normalised word-token sequences plus case/layout checks), `SpokenNumbers`, `LanguagePolicy`, `CleanupPolicy`, `Backtrack`, `WritingStyle` |
| `SmartDictionary/` | Correction watcher/detector, context names, learner, snapper, lexicon, phonetics |
| `Stats/` | Insights calculator, cleanup diff, app categories |
| `Conveniences/` | Escape cancel, feedback sounds, convenience settings |
| `Dictionary/` | `DictionaryStore`, `SnippetMatcher` |
| `Insertion/` | `Insertion` (pasteboard + synthesised Cmd-V, clipboard restore), `JoinPolicy` (smart join at the caret), `KeyboardLayoutMap`, `FocusProbe` (off-main AX lookup) |
| `Pipeline/` | `DictationPipeline` orchestrates hotkey -> record -> VAD -> ASR -> dictionary -> cleaner -> gates -> insert -> history; `FinalPasses`, `NoTextPolicy`, `PipelineClock`, `PipelineEnvironment`; collaborators are injected (fakes in tests) |
| `Conflicts/` | `ConflictDetector`, `WisprFlowCoexistence` (warns/gates when Wispr Flow is running) |
| `History/` | `HistoryIndex` (owns all history I/O), `HistoryPresentation` (bounded rows, day groups and cached summaries), `HistoryStore` (JSONL writer; text only for delivered dictations), `HistoryStats`, `DebugRecordings`, `ClipPlayback`, `Retranscription`, `HistoryLibrary`, `HistoryRowLayout`, `HistoryRows` |
| `Remote/`, `RemoteBridge/` | Remote Macs: `RemoteInserter` strategy chain, typing fallbacks, pairing, HMAC bridge client/server, Tailscale interface selection (the only network code) |
| `Support/` | `AppPaths`, `AppSettings`, `LicenseCatalog`, `Log`, `Permissions`, `HelpContent`, `MenuModel`, `HUDChips`, `PermissionMonitor`, `HUDPlacement`, `StyleSettings`, `SettingsSection`, `AppEnvironment`, `MicReadiness`, `SetupIssue` |

For UI files, see `ls Sources/WisprLocal` from `WisprLocal/App`; main files include `WisprLocalApp`, `AppController`, `MenuContent`, `SettingsView`, `OnboardingView`, `AboutView`, `HUD`, `WindowManager`.

## Development commands

Run from `WisprLocal/App`:

```bash
swift build                    # debug build
swift test                     # full suite (scripts/test_inventory.sh prints the inventory)
scripts/test_offline.sh        # after scripts/fetch_models.sh; the tests (socket-dependent and opt-in tests are skipped); network denied (WISPRLOCAL_REQUIRE_MODELS=1: missing models fail instead of skip)
scripts/fetch_models.sh        # populate the gitignored dev cache WisprLocal/App/.models-cache (downloads once if no local copy)
scripts/build_app.sh           # release build -> build.noindex/WisprLocal.app, models bundled (BUNDLE_MODELS="v2,ultra" default)
scripts/build_receiver.sh      # WisprLocalReceiver.app
scripts/install.sh             # copy to ~/Applications
WISPRLOCAL_FM_BENCH=1 swift test --filter FMIntegrationTests   # opt-in Foundation Models benchmark
```

Privacy guard (once per clone, from the repo root):

```bash
git config core.hooksPath WisprLocal/App/scripts/hooks   # pre-commit runs scripts/privacy_scan.sh --staged
WisprLocal/App/scripts/privacy_scan.sh                  # scan all tracked files by hand
```

`privacy_scan.sh` fails on `/Users/<name>/` paths (only `/Users/x/`), `*.local` / `*.ts.net` names, 100.64.0.0/10 addresses and e-mails outside example.com/.org/.net, x.com and noreply.github.com. Synthetic test values go in `scripts/privacy_allowlist.txt` (exact tokens). It also reads a private, never-committed denylist from `$WISPRLOCAL_PRIVATE_DENYLIST` (default `~/.config/wisprlocal/private-denylist.txt`), one case-insensitive term per line; without it only the generic checks run. `PrivacyGuardTests` runs the same checks in `swift test`.

## Rules of the codebase

- **No dictated content in logs or refused-dictation history.** `LogHygieneTests` scans every log call; `RetentionTests` checks every refusal path is outcome-only.
- **Offline is structural.** `OfflineGuardTests` scans `Sources/` and fails on networking APIs (`URLSession`, `Network`, `Process(`, FluidAudio download APIs, etc.). All model loads go through `OfflinePolicy.requireOffline`. Only `Tools/ModelFetcher` may download online; `RemoteBridge/` and the Receiver use Network.framework for the paired-Mac bridge (allow-listed in `OfflineGuardTests`).
- **Cleanup must pass the word-for-word guard.** Any Foundation Models output goes through `OutputGuard`; on reject, fall back to the rule-based text. Never insert unguarded model output.
- **No weights or large files in git.** `RepoHygieneTests` fails on tracked weights, `.mlmodelc`, `.app` or files over 50 MB.
- **No personal data in git.** `PrivacyGuardTests` and the pre-commit hook (`scripts/privacy_scan.sh`) fail on home paths, private hostnames, tailnet IPs, real e-mail addresses and private denylist terms.
- **Every bundled component ships its licence.** `LicenseTests` and `build_app.sh` enforce it; update `ACKNOWLEDGEMENTS.md` and `App/Licenses/` when adding a dependency or model.
- Environment variables use `WISPRLOCAL_` (for example `WISPRLOCAL_MODELS_DIR`, `WISPRLOCAL_REQUIRE_MODELS`); the old `WISPRLITE_` names remain fallback aliases.

## Platform notes

The app needs Microphone, Accessibility and Input Monitoring permissions. Ad-hoc signed builds change signature every build, so macOS TCC revokes the grants; re-grant them or sign with a stable Apple Development identity or the self-signed WisprLocal Local Signing identity (`scripts/create_signing_identity.sh`). Agents cannot drive the GUI or send real key events, so hotkey, mic capture and paste insertion require manual testing.
