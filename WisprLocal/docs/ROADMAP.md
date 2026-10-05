# Roadmap

## v1.1 (from the independent pre-release review)

Items the v1.0 release review scheduled for after release. IDs refer to that review's findings. The review's "Before release" items were fixed for v1.0.

### Correctness and robustness
- [ ] Restored history rows reappear in search only after searching again.
- [ ] Clear All during the first seconds of history loading can also clear a dictation that lands during that wait.
- [ ] **CC-8** User-visible notice when the microphone fails to start or the device is lost (not just `status = .error`).
- [ ] **CC-11** History write failures logged and surfaced once (no more silent `try?`); same for VAD fallback and history delete/clear.
- [ ] **CC-13** Rate-limited "No speech detected" notice; ignore Caps Lock while holding 🌐.
- [ ] **CC-9** `Transcriber.reset()` cancels and awaits an in-flight load (no two concurrent Parakeet loads).
- [ ] **CC-10** Sheets instead of `runModal` while the event tap is live; async prepare in `AudioRecorder.start()`.
- [x] **CC-10 (AX lookup)** Insertion focus snapshot off-main via `FocusProbe`/`AXQueue`.
- [ ] **CC-10 (HUD)** HUD target-screen lookup (`HUD.swift` `focusedWindowFrame`) still calls AX on the main actor.
- [ ] **CC-12** Explicit `userFormattingEnabled` instead of `!(cleaner is RuleCleaner)`.
- [ ] **CC-14** Keep the prewarmed FM session across taps.
- [x] **CC-14 (timeout)** Cancel the timeout sleeper when the operation wins in `PipelineEnvironment`.
- [ ] **CC-1** Confirm the paste was consumed before restoring the clipboard (or extend/skip and notify).
- [ ] **CC-3** Add an entry-count retention cap; stream stats.
- [x] **CC-3 (retention controls)** Settings supports forever, 30 days, 7 days or 24 hours; expiry runs at launch and hourly.
- [ ] **CC-5** Hoist the per-call `NSRegularExpression` in `SpokenNumbers` to a static.

### Performance
- [ ] **PERF-4** Delete the unread `pipeline.level` / `lastEntry` and the per-buffer main-actor Tasks (parity 100 %).
- [ ] **PERF-5** Incremental history append from `onEntry` and tail-read for `readRecent`.
- [x] **PERF-5 (stats)** Cached incremental stats in `InsightsCalculator`.
- [ ] **PERF-6** `OutputGuard.check(preCleanedRaw:)` so the RuleCleaner pre-pass runs once.
- [ ] **PERF-7** Per-10 ms RMS ring for the adaptive-tail threshold instead of a key-up scan of the whole buffer.
- [ ] **PERF-1** Overlap ASR with the capture tail (measure first; Parakeet is non-streaming).
- [ ] **PERF-2** (= CC-5) and **PERF-3** whitelist-only pasteboard snapshot.

### Security and privacy
- [ ] **SEC-5** Protocol v2: AEAD-sealed text (ChaChaPoly) and MAC'd acks; unauthenticated ack = unconfirmed.
- [ ] **SEC-8** Per-peer connection cap, 1 s header timeout, ~4 s budget, `.busy` receipt in the menu.
- [ ] **SEC-17** Replay verifier owned by the receiver app (survives listener restarts).
- [ ] **SEC-18** Stricter receiver routing: default only when unambiguous; ≥4-char word-boundary tokens; show the chosen receiver in the HUD.
- [x] **SEC-20 (Receiver signing)** Receiver `--options runtime` in `build_receiver.sh`.
- [ ] **SEC-20** Bridge NITs: drop `allowLocalEndpointReuse`, listener under the mutex, serialized `deliver`, port 0 refused, `kSecUseDataProtectionKeychain`, receiver SHA-256, receipts for over-capacity drops.
- [x] **SEC-7** Focus-changed clipboard write uses Concealed + Transient + current-host-only markers.
- [ ] **SEC-9** Don't restore Concealed/Transient items; skip file promises and large items.
- [ ] **SEC-10** Split the event tap: listen-only `keyDown`, active tap only for `flagsChanged`; state the capability in SECURITY.md.
- [ ] **SEC-11** Developer ID + notarisation; until then publish the signing leaf hash / signed tag as an out-of-band anchor.
- [x] **SEC-12** `scripts/model-manifest.sha256` pins every shipped model file; fetch, build and bundle verification check SHA-256. The app does not re-hash at runtime.
- [ ] **SEC-13** AX secure-field detection for insertion and retention, including fields that do not enable macOS secure input.
- [ ] **SEC-14 (rest)** Retention cap and `isExcludedFromBackup` for DebugRecordings (0600/0700 permissions shipped in v1.0).
- [ ] **SEC-15** Extend the offline ban list (`dlopen`, BSD sockets, `CFSocket`, non-file `Data(contentsOf:)`, …); run the built app once under the sandbox profile; re-assert `requireOffline()` in `transcribe()`.
- [ ] **SEC-16** `security import -x`, passphrase via env/file, key-theft note, SHA-1 identity pin for releases.
- [ ] **SEC-21** Neutral fixture names for the public repo (optional).
- [ ] **SEC-22** `WAV.decode` guard for a short `fmt ` chunk.
- [ ] OutputGuard residual (review §1, LOW): reject ASCII symbols absent from raw outside a punctuation whitelist; terminals only at the end when raw has none; `clean(clean(x)) == clean(x)` property test.

### Architecture
- [ ] **ARCH-1** Split `WisprLocalCore` into `WisprLocalKit` (pure) and `WisprLocalSystem` (AppKit/CoreGraphics/AVFoundation/Network adapters).
- [ ] **ARCH-2** Split `HUD.swift` into controller / animator / views / model files.
- [ ] **ARCH-3** Extract the gates from `DictationPipeline.process()` (`applyGates` → `GateOutcome`).
- [ ] **ARCH-4** `KeyboardLayoutMap.pasteKeyCode` via `KeyStrokeMap` (one UCKeyTranslate map).
- [x] **ARCH-5 (index)** `Spikes/README.md` documents the frozen experiments.
- [ ] **ARCH-5 (rest)** Drop superseded S3 sources and fix stale RESULTS lines.
- [x] **ARCH-6** Rename residue reviewed: queue labels use `wisprlocal.*`; `WISPRLOCAL_*` variables retain intentional `WISPRLITE_*` fallback aliases.

### Tests
- [ ] **TS-2** CI-safe timing assertions (gate wall-clock budgets behind `WISPRLOCAL_PERF=1` or widen on CI).
- [ ] **TS-3** Security negative tests: over-the-wire oversize/zero/truncated frames, malformed JSON and identical-frame replay, nonce/MAC length, 9th-connection drop, mismatched-nonce ack, rogue `ok` server, golden MAC vectors, `PairingCode` limits.
- [ ] **TS-4** Coverage: `AudioRecorder` lifecycle, HUD/`HUDController`, `PasteboardSnapshot.restore` with concealed/promised items.
- [ ] **TS-5** Second sandbox profile allowing 127.0.0.1 only, so the loopback suites also run network-denied.
- [ ] **TS-8** Label/gate environment-dependent tests.
- [x] **TS-8 (Clock)** Clock injected into the pipeline, `PasteInserter` and timeout environment.

### Release and docs
- [x] **REL-6** Verify Xcode 26 / Swift 6.2 or state the toolchain precisely (built and tested with Xcode 27 / Swift 6.4 locally and Xcode 26.6 / Swift 6.3 in CI); say macOS 26 is needed to build.
- [x] **REL-8** GitHub Actions workflow on `macos-26` (`swift build` + non-model tests) and bug-report / feature-request issue templates.
- [ ] **REL-8 (rest)** PR template done. Enable private vulnerability reporting on the public repo.
- [x] **REL-9** Single `VERSION` file.
- [ ] **REL-9 (rest)** `dsymutil` + `strip -S` before codesign; keep the dSYM.
- [ ] **REL-11** Factual nits: first-compile time, "25 languages" source, ANE cache path, ACKNOWLEDGEMENTS NOTICE line, S1b RESULTS range, `.gitignore` Python/Node sections, CHANGELOG date on tag day.
- [ ] **REL-12** Intel FAQ line: document Apple Silicon-only support.
- [ ] **REL-13** Keep "independent alternative" framing consistent; drop comparative pricing lines.
- [ ] **REL-14** Keep fixture provenance current: `clip05.wav` now uses eSpeak NG; see `App/Tests/WisprLocalCoreTests/Fixtures/README.md`. Historical spike audio used macOS `say`.

### Before Remote Macs leaves Beta
- [ ] Run the two-Mac test (REMOTE.md › Setup › Test) and the S2 keystroke comparison; record results in TEST_REPORT §7.
- [ ] Verify the sender's utun path check and the receiver's utun bind on real Tailscale (Network.framework interface naming).
- [ ] Manually verify the lost-Fn-up poll (hold 🌐 5+ s; the recording must continue).

## Known limitations

- [ ] Per-window and per-field insertion targeting within the same app.
- [ ] Automatic paste retry can in rare cases double-paste in slow apps.
