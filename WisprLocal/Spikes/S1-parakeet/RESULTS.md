# S1: Parakeet TDT 0.6B v2, offline via FluidAudio

**Verdict: GO.** Parakeet v2 runs fully offline from an explicit local directory. Warm latency is about 90 ms for a 4 s utterance and RTFx is 48 to 132x, with about 145 MB peak RSS. Two things need product handling: the 27 s first-ever ANE compile, and custom-vocabulary boosting, which is **NO-GO as shipped** (details below).

Environment: Apple M5 Pro, 64 GB, macOS 26.6.2 (build 25G83). FluidAudio **v0.17.5** (latest release, 2026-10-01, commit `0b1f462`). Release build.

## How to run
```
cd WisprLocal/Spikes/S1-parakeet
swift build -c release                    # see toolchain gotcha below
.build/release/S1Parakeet download        # ONLINE, one-time -> ./Models (gitignored)
P='(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))'
/usr/bin/time -l sandbox-exec -p "$P" .build/release/S1Parakeet bench   # also: loadonly | vocab | vad
```
All OFFLINE numbers below were measured inside the `sandbox-exec` network-deny profile, with `ModelHub.offlineMode = true`. Every run succeeded, which shows that nothing needs the network at runtime.

## Model size on disk (`./Models`)
| Dir | Size | Contents |
|---|---|---|
| `parakeet-tdt-0.6b-v2/` | **451 MB** | Preprocessor, Encoder, Decoder, JointDecision `.mlmodelc`, `parakeet_vocab.json`, `config.json` |
| `parakeet-ctc-110m-coreml/` | 102 MB | only needed for vocab boosting (MelSpectrogram, AudioEncoder, tokenizer.json, vocab.json) |
| `silero-vad/` | 1 MB | `silero-vad-unified-256ms-v6.2.1.mlmodelc` |
| **Total** | 554 MB | ASR alone: 451 MB |

Note: FluidAudio's folder name is `Repo.parakeetV2.folderName` = `parakeet-tdt-0.6b-v2` (no `-coreml` suffix). The docs say otherwise; trust the code.

## Fixtures (`Fixtures/`, `say -v Samantha` -> `afconvert -d LEI16@16000 -c 1`)
`clip05` 4.35 s · `clip30` 27.98 s · `clip60` 57.09 s · `clip05_padded` 10.35 s (3 s of digital silence on each side). The source texts are in the `.txt` files.

## Results
### Load
| Scenario | Load time | Peak RSS |
|---|---|---|
| **First-ever load** (ANE compile cache empty) | **27,464 ms** | 533 MB |
| Cold process, ANE cache warm (2 runs) | **364 to 381 ms** | 48 MB |
| CTC-110M (vocab) first-ever / cached | 24,676 ms / 368 ms | |
| Silero VAD | 494 ms | |

### Transcription (warm; `first` = first call after load; median of 5 following calls)
| Clip | Audio | First | **Median 5** | Min / max | **RTFx** |
|---|---|---|---|---|---|
| clip05 | 4.35 s | 128 ms | **90.5 ms** | 88.7 / 93.4 | 48x |
| clip30 | 27.98 s | 268 ms | **284.0 ms** | 280.4 / 329.9 | 99x |
| clip60 | 57.09 s | 438 ms | **431.5 ms** | 409.0 / 442.2 | 132x |

Peak RSS for the whole bench process (load plus 18 transcriptions): **144 MB** (peak memory footprint 107 MB).

### Output text (jargon errors in bold)
- clip05: "Please open **Whisperflow**, then connect my laptop to the Tailscale network."
- clip30: "...Kubernetes version 1.30 ... two nodes lost their **tail scale** connection, so Priya restarted the **demon** ... finish the **Whisperflow** dictation prototype ... Grafana ... Postgres ..."
- clip60: everything correct (Kubernetes, Helm, Argo CD, Tailscale, Parakeet, Sarah Chen, Diego Alvarez, "15th", "1%") except "**Whisperflow**" and "global **hot**" (should be "hotkey"). The "hot" error also appears when that sentence is transcribed alone, so it is not a chunk-boundary bug. It is probably the model, or how `say` renders "hotkey".
- The output already has punctuation, capitalisation and inverse text normalisation (ITN) built in ("1.30", "20 minutes", "15th", "1%").

### Vocabulary / context boosting
TDT 0.6B v2 has no CTC head, so FluidAudio's only option for it is "Approach 2": a **separate Parakeet CTC-110M encoder** (+102 MB) runs CTC keyword spotting, and the result is used to rescore the TDT transcript (`Documentation/ASR/CustomVocabulary.md`). There is no shallow fusion into the TDT decoder itself.

| Clip | Extra latency (median 5) | Effect |
|---|---|---|
| clip05 | +246 ms (2.7x the ASR cost) | Whisperflow -> **Wispr Flow** ✅, but **deleted "open" and "the"**: "Please Wispr Flow then connect my laptop to Tailscale network." ❌ |
| clip30 | +588 ms | tail scale -> **Tailscale** ✅, Whisperflow -> **Wispr Flow** ✅, but dropped "the" ❌ |
| clip60 | +1,466 ms | Wispr Flow ✅, but **deleted "and", "by", "owns" x2** ("Sarah Chen the audio pipeline") ❌ |

**Verdict: NO-GO in its current form.** It fixes the target terms, but it consistently swallows a neighbouring word. That is worse than the original error for a dictation product, and it triples latency on short clips. Recommendation: use a cheap deterministic post-ASR replacement dictionary (e.g. `Whisperflow|Whisper Flow -> Wispr Flow`, `tail scale -> Tailscale`) and/or the LLM cleanup pass (S3). Revisit FluidAudio boosting later, possibly with `spotterRescueEnabled = false` (see the doc's "Measured effect" table) or a TDT-CTC-110M model. (The `detected=[...]` list in the harness output includes every term, so it is not a real detection signal. Ignore it.)

### Silero VAD (`clip05_padded`: speech is actually 3.000 to 7.352 s)
| Metric | Value |
|---|---|
| `segmentSpeech` latency on 10.35 s of audio | **13.9 ms** (median 5) |
| Segments | 1: **2.716 s to 7.524 s** (default `speechPadding` 0.1 s plus the 256 ms chunk grid) |
| ASR on padded vs trimmed | identical text; trimmed clip 87 ms |

The bounds are tight enough for trimming before ASR and for hands-free endpointing.

## Exact APIs used (FluidAudio v0.17.5, `Sources/FluidAudio/...`)
- `ModelHub.offlineMode = true`: `Shared/Download/ModelHub.swift:31`
- **Load from disk:** `AsrModels.load(from: <Models>/parakeet-tdt-0.6b-v2, version: .v2)`: `ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift:331`. Internally it calls `ModelHub.loadModels(...)` once per bundle (`AsrModels.swift:353, 381, 397`).
- `AsrManager(config:)` + `loadModels(_:)`: `TDT/AsrManager.swift:77, 139`. `transcribe(_ samples:[Float], decoderState:&)`: `AsrManager.swift:501`. `TdtDecoderState.make(decoderLayers:)`: `TDT/Decoder/TdtDecoderState.swift:52`
- One-time download: `AsrModels.download(to:version:)`: `AsrModels.swift:591`
- VAD (pure local, no ModelHub): `MLModel(contentsOf:)` + `VadManager(config:vadModel:)`: `VAD/VadManager.swift:103`. `segmentSpeech(_:)`: `VAD/VadManager+SpeechSegmentation.swift:12`
- Vocab: `CtcModels.load(from:variant:)`: `.../CustomVocabulary/WordSpotting/CtcModels.swift:145`. `CtcTokenizer.load(from:)`: `CtcTokenizer.swift:39`. `CtcKeywordSpotter(models:blankId:)` and `spotKeywordsWithLogProbs`: `CtcKeywordSpotter.swift:94, 110`. `VocabularyRescorer.create(...ctcModelDirectory:)`: `Rescorer/VocabularyRescorer.swift:146`. `ctcTokenRescore`: `Rescorer/VocabularyRescorer+TokenRescoring.swift:339`

## Network code paths and how to avoid them
- Every high-level loader (`AsrModels.load`, `CtcModels.load`, `VadManager(config:)`, `DiarizerModels.load(from:)`) goes through `ModelHub.loadModels` (`ModelHub.swift:85`) -> `loadModelsOnce` (`:319`). That function **downloads from HuggingFace (URLSession via `HFClient`/`FileDownloader`/`HFTreeLister`) if any required file is missing *or* the `.fluidaudio-revision` marker doesn't match the pinned revision** (`:343-363`; `ModelCache.matchesRevision`: `Shared/Download/ModelCache.swift:20`).
- The worst case without offline mode: if the first load fails for any reason other than cancellation or network, `loadModels` **deletes the model directory** (`ModelCache.purgeCorruptedCache`, `ModelHub.swift:137`) and re-downloads it. In an app that ships its models in the bundle, this could wipe them or cause a surprise 450 MB download.
- **How to avoid it:** (1) set `ModelHub.offlineMode = true` at startup. Missing or stale files then throw `DownloadError.modelMissing`/`networkDisabled`, and the delete-and-redownload fallback is skipped (`ModelHub.swift:103`). (2) Better still, for small models, skip ModelHub completely with `MLModel(contentsOf:)` + the `init(...model:)` initialisers (`VadManager(config:vadModel:)`, `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)`, `AsrModels(encoder:preprocessor:decoder:joint:...)`, public memberwise init at `AsrModels.swift:99`).
- `VocabularyBoostingSession.init` **hard-codes `CtcModels.defaultCacheDirectory`** (`~/Library/Application Support/FluidAudio/...`) for the tokenizer (`VocabularyBoostingSession.swift:50`), so it ignores your local dir. The harness avoids this by building `CtcKeywordSpotter` + `VocabularyRescorer.create(ctcModelDirectory: local)` itself and pre-tokenising the terms (`ctcTokenIds:`).
- `AsrModels.load` with `.tdtCtc110m` falls back to auto-downloading a CTC head (`AsrModels.swift:438`). That is not relevant for `.v2`.
- Proof: all offline runs passed under `sandbox-exec` with outbound IP denied.

## Gotchas
1. **Toolchain:** `DEVELOPER_DIR=/Applications/Xcode.app/...` fails with "You have not agreed to the Xcode license agreements" (fixing it needs `sudo xcodebuild -license`, which wasn't allowed). Everything was built with the **CommandLineTools Swift 6.4** toolchain instead, which works fine for SwiftPM. Accept the Xcode license before app/Xcode-project work.
2. **First-ever load = 27.5 s / 533 MB** while CoreML compiles the ANE plan. The result is cached in `~/Library/Caches/<process-or-bundle-id>/com.apple.e5rt.e5bundlecache/<OS build>/`. The path is keyed by the **OS build**, so expect it again **after every macOS update**. The app should pre-warm in the background at first launch and after OS updates, and show a "preparing model" state.
3. Every load prints a harmless `E5RT encountered an STL exception ... ios17.slice_by_index: zero shape error` to stderr. Loading and transcription are unaffected.
4. Building FluidAudio from source takes about 4 min in release and downloads an 87 MB `NemoTextProcessing.xcframework` binary target.
5. Folder names: see the size table (`parakeet-tdt-0.6b-v2`, `silero-vad`).

## Recommendation
- **GO** on Parakeet TDT 0.6B v2 + FluidAudio 0.17.5 as the offline ASR engine. Pin the exact version.
- Ship or download models to an app-controlled directory, set `ModelHub.offlineMode = true`, load with `AsrModels.load(from:version:.v2)`, and keep one `AsrManager` warm. A typical utterance costs about 90 ms.
- Pre-warm the ANE compile off the hot path (first launch and after OS updates).
- Use Silero VAD for trimming and endpointing (14 ms per 10 s).
- **Don't** use the CTC vocabulary boosting yet. Use a replacement dictionary and/or LLM cleanup for jargon like "Wispr Flow".
- Follow-up (not done here): compare `.v3` / `.ultra` / `.phonon2` (an English QAT variant) for accuracy and latency, and test on real microphone speech.
