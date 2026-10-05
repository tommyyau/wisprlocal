# S1b: Phonon-2 vs Parakeet Ultra vs Parakeet TDT v2 (FluidAudio 0.17.5, offline)

> **Superseded 2026-10-03:** the app now defaults to Parakeet v2 (English) and offers Ultra behind a "Noisy room / other languages" toggle. See WisprLocal/docs/TEST_REPORT.md Section 3.9.

**Verdict: Ultra is confirmed as the primary model on macOS 26.** Phonon-2 is a usable fallback but is worse on every accuracy measure here. **No escalation condition is hit**: Ultra never failed or hung, a 28 s clip takes 0.15–0.43 s, peak RSS is about 270 MB, and Phonon-2 does not beat Ultra on accuracy.

Environment: Apple M5 Pro, 64 GB, macOS 26.6.2 (25G83). FluidAudio pinned to `exact: "0.17.5"` (commit `0b1f462`), Xcode toolchain (Swift 6.4), release build. All measurements ran **inside `sandbox-exec` with the network denied** unless stated otherwise. The machine was shared during the runs (Chrome, TV.app and another build), so latency varies by up to 2x between runs. Ranges are reported where that matters.

## How to reproduce
```
cd WisprLocal/Spikes/S1b-models
./run_bench.sh                    # full: build, download if missing, first-ever compile, cold load, latency, WER, 500-call soak, escalation check
./run_bench.sh --quick            # no first-ever compile, no soak
./run_bench.sh --with-v2          # also run the v2 baseline
./run_bench.sh --my-voice <dir>   # <dir>/*.wav (any sample rate or channel count) + transcripts.txt ("file.wav<TAB>exact text" per line) -> Ultra vs Phonon-2 WER
```
Harness: `Sources/S1bModels/main.swift` (modes `download | load [--gpu] [--hub] | bench | soak | vocab | myvoice`). Fixtures: `scripts/make_fixtures.py`. Scoring: `scripts/score.py`. Raw outputs are in `results/raw/`, and the full validation run of `run_bench.sh` is in `results/run_*/summary.txt`.

## 0. Do the models exist, and how to load them offline (FluidAudio 0.17.5, `Sources/FluidAudio/...`)
| Model | Enum | HF repo (`ModelNames.swift`) | Local folder | Min OS |
|---|---|---|---|---|
| Phonon-2 | `AsrModelVersion.phonon2` (`ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift:18`) | `FluidInference/phonon-2-coreml` (`ModelNames.swift:27`) | `phonon-2` | macOS 15 (`checkPlatformSupport`, `AsrModels.swift:165`) |
| Ultra | `.ultra` (`AsrModels.swift:14`) | `FluidInference/parakeet-ultra-coreml` (`ModelNames.swift:21`) | `parakeet-ultra` | macOS 14 |
| TDT v2 | `.v2` (`AsrModels.swift:6`) | `FluidInference/parakeet-tdt-0.6b-v2-coreml` (`ModelNames.swift:28`) | `parakeet-tdt-0.6b-v2` | macOS 14 |

The release notes confirm the versions: v0.17.3 is titled "Parakeet Ultra and Parakeet Redux" and v0.17.5 is titled "Phonon-2". Ultra and Phonon-2 are v3-family models (`isV3Family`, `AsrModels.swift:75`). They share v3's tokenizer, blank id 8192 and `JointDecisionv3`, and need `Preprocessor`, `Encoder`, `Decoder` and `JointDecisionv3.mlmodelc` plus `parakeet_vocab.json`.

**Recommended offline loader:** `AsrModels.loadLocal(from: dir, version: .ultra | .phonon2 | .v2, encoderComputeUnits: nil)` (`AsrModels.swift:263`). It calls `MLModel(contentsOf:)` for each component, with **no ModelHub, no revision marker and no download path**. Then call `AsrManager(config: .default).loadModels(models)` (`TDT/AsrManager.swift:139`) and `transcribe(samples, decoderState:&)` (`AsrManager.swift:501`). The ModelHub path also worked offline under the sandbox: `AsrModels.load(from:version:)` (`AsrModels.swift:331`) with `ModelHub.offlineMode = true` (`Shared/Download/ModelHub.swift:31`). However, `loadLocal` cannot trigger the S1 "purge and re-download" behaviour, so it is the right call for bundled weights. One-time fetch: `AsrModels.download(to:version:)` (`AsrModels.swift:591`).

## 1. Licences (blocking for bundling)
| Model | Weights licence (quoted) | Flags |
|---|---|---|
| **Ultra**: `FluidInference/parakeet-ultra-coreml` ← `moondream/parakeet-ultra` ← `nvidia/parakeet-tdt-0.6b-v3` | HF `license: cc-by-4.0`. Card: "License CC-BY-4.0, as the upstream checkpoint." Upstream card: "License is CC-BY-4.0, same as the original." | None. Attribution is required (NVIDIA + moondream + FluidInference). |
| **Phonon-2**: `FluidInference/phonon-2-coreml` ← `FermionResearch/Phonon-2` ← NVIDIA v3 | HF `license: cc-by-4.0`. Card: "distributed under CC-BY-4.0, as upstream." The `NOTICE` says the weights "are therefore distributed under CC-BY-4.0" | ⚠️ The `NOTICE` lists training data that includes **CHiME-6 (CC-BY-SA-4.0)** and **SPGISpeech, "used under Kensho's public terms"**. SPGISpeech is a gated dataset under Kensho's own terms (HF `license: other`), and those terms are generally understood to be non-commercial. Fermion still licenses the weights CC-BY-4.0. For personal use this is not a blocker, but bundling must ship the `NOTICE`. Flag for legal before any commercial use. |
| **TDT v2**: `FluidInference/parakeet-tdt-0.6b-v2-coreml` ← `nvidia/parakeet-tdt-0.6b-v2` | "GOVERNING TERMS: Use of this model is governed by the CC-BY-4.0 license." NVIDIA card: "ready for commercial/non-commercial use" | None. Attribution is required. |
| CTC-110M (vocab boosting only): `FluidInference/parakeet-ctc-110m-coreml` | HF tag `cc-by-4.0`. The card body says "released under the Apache 2.0 License" | The licence is inconsistent, but both options are permissive. |

None of the weights are non-commercial, research-only or no-redistribution. CC-BY-4.0 allows bundling inside the .app if we **ship attribution plus a licence link** (an About/Acknowledgements screen plus `LICENSE`/`NOTICE` files in Resources).

## 2. Accuracy (normalised WER: lowercase, punctuation stripped, numbers, emails and times mapped to words)
Fixtures (`Fixtures/manifest.json`, 92 clips, all 16 kHz mono):
- The 3 S1 clips (Samantha).
- 22 dictation utterances of 3.1 to 14.4 s using 10 `say` voices: Daniel, Flo, Eddy, Reed and Shelley (UK); Moira (IE); Karen (AU); Tessa (ZA); Rishi (IN); Samantha (US). They contain jargon, names, numbers and emails.
- Each utterance mixed with **TV-like speech** (4 other `say` voices, band-limited to 200 Hz–4 kHz) at **-10 dB and -6 dB relative to the target** (SNR +10 and +6 dB), and with a **synthesised chord progression plus hi-hat** at -10 dB.
- A **3.4 min** long-form clip (Daniel) to probe FluidAudio #954.

| Condition (words) | **Ultra** | Phonon-2 | v2 | Ultra jargon | Phonon-2 jargon | v2 jargon |
|---|---|---|---|---|---|---|
| clean, S1 + 22 utt (563) | **6.63 %** | 10.03 % | 6.12 % | 32/48 | 21/48 | 33/48 |
| clean, 22 utt only (307) | 7.85 % | 10.88 % | 7.55 % | 18/30 | 13/30 | 19/30 |
| TV speech -10 dB | **6.95 %** | 13.29 % | 9.97 % | 22/30 | 14/30 | 17/30 |
| TV speech -6 dB | **7.55 %** | 21.15 % | 19.03 % | 21/30 | 13/30 | 16/30 |
| music -10 dB | 8.16 % | 13.29 % | 7.25 % | 19/30 | 16/30 | 19/30 |
| long 3.4 min | 5.73 % | 7.81 % | 3.65 % | 3/4 | 2/4 | 3/4 |

Per-term hits across all conditions (Ultra / Phonon-2 / v2):
- Kubernetes: **22/23** / 9/23 / 18/23
- Tailscale: **11/20** / 3/20 / 5/20
- Grafana: 19/22 / 17/22 / 18/22
- Sarah Chen: 5/9 / 2/9 / 8/9 ("Sarachen")
- **Wispr Flow: 0/20 for all three** ("Whisperflow", "Whisper Flow", "Wispflow")
- accounts@example.org: 0/4 for all three ("example, organ")

Full tables are in `results/wer_tables.md`.

Note (2026-10-03): the TV-speech and music conditions were measured by feeding audio straight to the models, without the app's voice processing; real-world gaps may differ.

Reading:
- **Ultra ≥ Phonon-2 everywhere.** Phonon-2 is about 3–4 points worse on clean speech and collapses under TV babble (21 % vs 7.6 %). It also produces real-word errors ("build→bill", "bugs→boats", "Kubernetes→Cuba Needs"). This matches the vendor ranking (LibriSpeech clean: Ultra 2.13 %, Phonon-2 2.47 %).
- **Ultra vs v2 is a wash on clean speech** (6.6 vs 6.1 %, which is about 3 words on this small set). Ultra is clearly more robust to background TV speech (7.6 vs 19 % at -6 dB), and that is the realistic noise case for home dictation. (Measured by feeding audio straight to the models, without the app's voice processing; real-world gaps may differ.) v2 is slightly better on music and long-form. **These sets are small** (one error = 0.2–0.3 points on the clean set) and use TTS voices, not real speech.
- **FluidAudio #954 (duplicated words at window merges):** reproduced **once** in Ultra on the 3.4 min clip ("half past three three tomorrow"). Phonon-2 and v2 had none. It only matters for dictations over 15 s, which use multiple windows. A cheap fix is an adjacent-duplicate guard in post-processing, or keeping dictations under one window.
- #971 (word end-time truncation) affects timestamps only, not text, so it is irrelevant here.

## 3. Latency, memory, disk
| | **Ultra** | Phonon-2 | v2 |
|---|---|---|---|
| **Disk (exact bytes)** | **632,314,500 B (632.3 MB; `du` 618 MiB)**, encoder 583 MiB | **357,726,026 B (357.7 MB; `du` 341 MiB)**, encoder 306 MiB | 464,413,250 B (464.4 MB) |
| Both bundled | **990.0 MB** | | |
| **First-ever ANE compile** (empty e5rt cache) | **18.0 s** (2 runs: 18.0 / 18.0 s) | **89–96 s** | 22.7 s |
| Cold load, ANE cache warm (fresh process) | **120–270 ms** | 125–233 ms | 147–510 ms |
| First transcribe after load (4.3 s clip) | 59–139 ms | 54–115 ms | 50–277 ms |
| Warm median of 5: 3.1 s clip | 41–64 ms | 44–95 ms | 107 ms |
| Warm median of 5: 14.4 s clip | 78–124 ms | 110–202 ms | 132 ms |
| **Warm median of 5: 28.0 s clip** | **153–383 ms** (RTFx 73–183x) | 213–373 ms | 211 ms |
| Warm median of 5: 57.1 s clip | 199–538 ms (RTFx 106–287x) | 412–774 ms | 336 ms |
| Peak RSS: bench process (load + 116 calls) | **231–259 MB** (peak footprint 122–160 MB) | 244–268 MB | 172 MB |
| Peak RSS: 15 min soak | 266 MB | 269 MB | n/a |
| Max RSS during first-ever compile | 642 MB (footprint 47 MB, mostly file-mapped weights) | 375 MB | 500 MB |

Latency ranges cover 3–4 separate runs on the busy shared machine. The lowest values are from the quietest run. Contrary to the vendor docs, **Phonon-2 was not faster than Ultra here** on clips of 14 s or longer.

**GPU encoder path (`encoderComputeUnits: .cpuAndGPU`): never use it.**
- Phonon-2 on GPU: first launch took **212 s** to load and peaked at **3.06 GB RSS**. The second launch loaded in 234 ms but still used **2.4 GB RSS**. The result is cached (contrary to the "every launch" claim in the docs), but it leaves about 1.8 GB in `~/Library/Caches/<process>`.
- Ultra on GPU: 0.2–0.7 s load, then a **2.8–5.7 s first transcribe** and 1.2 GB RSS.
- The ANE default is much better on every axis.

The first-ever compile cache lives in `~/Library/Caches/<process-or-bundle-id>/com.apple.e5rt.e5bundlecache/<OS build>/` (about 36 MB per model). Because it is keyed by OS build, **the compile happens again after every macOS update**. The app needs a background "preparing model" pre-warm. Phonon-2's 90 s compile is a UX cost as a fallback, so pre-warm it only when it is actually needed.

## 4. Stability (10 s per-call watchdog, RSS sampled every 50 calls, network denied)
| Run | Calls | Hangs | Crashes / errors | Non-deterministic outputs | p50 / p99 / max latency | Footprint first → max → last | Same-clip latency drift (last ¼ vs first ¼) |
|---|---|---|---|---|---|---|---|
| **Ultra, 500 calls** (×2 runs) | 500 | 0 | 0 | 0 | 80 / 395 / 532 ms | 88 → 173 → 147 MB | n/a |
| **Ultra, 15 min** | **9,004** | **0** | **0** | **0** | 81 / 392 / 1,648 ms | 88 → 165 → 149 MB | **0.86x (no drift)** |
| Phonon-2, 500 calls (×2 runs) | 500 | 0 | 0 | 0 | 117 / 634 / 737 ms | 88 → 160 → 152 MB | n/a |
| Phonon-2, 15 min | 10,740 | 0 | 0 | 0 | 68 / 397 / 1,324 ms | 93 → 173 → 124 MB | 1.56x (upward drift, cause unknown) |
| v2, 500 calls | 500 | 0 | 0 | 0 | 66 / 437 / 887 ms | 96 → 122 → 121 MB | n/a |

- Memory plateaus within about 100 calls and then stays flat or falls. **There is no leak.**
- The occasional 1–1.6 s outliers were short clips arriving in clusters (for example calls 2795–2796, 7324–7326). That pattern points to contention on the shared machine rather than a model stall. All outliers were far below the 10 s watchdog.
- The **VoiceInk #987 "Failed to prepare the model… Encoder" error (M5, macOS 27) did not appear on macOS 26.6.2** in about 20,000 calls and about 25 loads.
- **Offline confirmation:** every model loaded and ran under `sandbox-exec` with outbound IP denied, using both `loadLocal` and `load(from:)`+`offlineMode` (`results/raw/sandbox_loads.txt`). A `curl` to huggingface.co inside the same profile failed (control).

## 5. Custom vocabulary biasing
- **Decode-time biasing without a CTC head exists, but only for Nemotron.** v0.15.7 PR #866, "decode-time custom vocabulary biasing (no CTC head required)", implemented `NemotronVocabularyBias` (`ASR/Parakeet/Streaming/Nemotron/NemotronVocabularyBias.swift:55`) for `StreamingNemotronMultilingualAsrManager` only.
- `CustomVocabularyTerm.tokenIds` ("decode-time biasing can operate directly on RNNT/TDT token IDs", `CustomVocabularyContext.swift:10`) is **never consumed by any TDT decoder**.
- **For Ultra, Phonon-2 and v2, the only option is the S1 Approach-2 path**: the separate CTC-110M encoder (+98 MB disk) with `VocabularyRescorer`.
- The per-term threshold is real: `CustomVocabularyTerm.minSimilarity` (`CustomVocabularyContext.swift:25`). It belongs to the CTC rescorer.

Tested on the 63 fixtures that contain one of [Wispr Flow, Tailscale, Kubernetes, Grafana], with aliases `Wispr Flow: Whisper Flow, Whisperflow` and `Tailscale: Tail scale`. A false-fire check ran on the 28 fixtures that contain none of the terms.

| Model | Config | WER base → boosted | target hits | non-target words lost | false fires (of 28 clips) | extra latency (median) |
|---|---|---|---|---|---|---|
| Ultra | library default | 7.44 → **32.08 %** ❌ | 49 → 71/81 | **339** | **28/28** | 231 ms |
| Ultra | `spotterRescueEnabled: false` | 7.44 → 4.51 % | 49 → 80/81 | 17 | 0 | 222 ms |
| **Ultra** | **`spotterRescueEnabled: false` + per-term `minSimilarity: 0.70`** | **7.44 → 3.17 %** | **49 → 79/81** | **0** | **0** | 199–226 ms |
| Phonon-2 | rescue off + 0.70 | 12.03 → 7.10 % | 27 → 65/81 | 0 | 0 | 102 ms |
| v2 | rescue off + 0.70 | 8.44 → 4.01 % | 38 → 74/81 | 0 | 0 | 100 ms |

- **The S1 neighbouring-word deletions came from the "spotter rescue" stage, which is on by default.** With the default setting the rescorer rewrites ordinary words into vocabulary terms ("The Kubernetes cluster has twelve pods…" → "The Tailscale has Tailscale in a Grafana") on 100 % of non-jargon clips. That reproduces #967.
- With rescue off and a 0.70 per-term floor, every change was a correct target fix ("Whisperflow→Wispr Flow", "tail scale→Tailscale", "Grafano→Grafana"). There was no collateral damage. The only side effect is that a comma after the replaced term is sometimes dropped.
- Cost: +98 MB on disk, a second encoder pass of +100–230 ms per utterance, and a one-time 22 s compile.
- **Caveat:** the configuration was tuned and tested on the same small TTS set with only 4 terms. Larger vocabularies raise the false-fire risk (see #967).

**Biasing verdict:**
- **Don't ship it on by default for v1.** Use a deterministic replacement dictionary first ("Whisperflow / Whisper Flow / Wispflow → Wispr Flow", "tail scale → Tailscale"). Those mappings cover every misspelling seen here (not measured as a separate run) at about 0 ms, plus optional LLM cleanup (S3).
- Offer CTC rescoring as an **opt-in** with `VocabularyRescorer.Config(spotterRescueEnabled: false)` and `minSimilarity: 0.70` per term. **Never use the library defaults.**
- Re-validate it on a real human voice with a real word list before turning it on.

## Recommendation
- **Primary: Parakeet Ultra.** It has the best accuracy, especially under background speech, and the best Kubernetes/Tailscale recognition. It is CC-BY-4.0, needs only macOS 14, compiles once in 18 s, warm-loads in about 0.2 s, takes about 0.15–0.4 s for 28 s of audio, and stays under 300 MB RSS. 0 hangs in about 10,000 calls.
- **Fallback: Phonon-2**, (the original plan). It is the smaller download (358 MB vs 632 MB) and was stable. But it was the least accurate model here, it compiles for about 90 s, it showed upward latency drift, and its training-data NOTICE needs attention. **Bundling both costs 990 MB.** Suggestion: bundle Ultra only, and make Phonon-2 an optional download, or substitute v2 (464 MB, stronger accuracy than Phonon-2 here).
- Load with `AsrModels.loadLocal`, ANE only (never `.cpuAndGPU`), pre-warm after install and after OS updates, and add an adjacent-duplicate-word guard for dictations over 15 s (#954).
- Vocabulary: replacement dictionary now. CTC rescoring only as an opt-in, with rescue off and a per-term 0.70 floor.

## Escalation conditions
| Condition | Result |
|---|---|
| Ultra fails or hangs on macOS 26 | **Not hit.** 0 hangs and 0 errors in about 10,000 calls and about 25 loads |
| Ultra >2 s for a 30 s clip or >2 GB RSS (M1 Pro) | **Not hit on M5.** 0.15–0.38 s and ≤270 MB. **M1 Pro still to be measured** with `run_bench.sh`. Its ANE is roughly 2–3x slower, so expect 0.4–1.2 s, still under the limit. |
| Phonon-2 beats Ultra on accuracy | **Not hit.** Ultra wins every condition |

## Not tested here
- **M1 Pro 16 GB**: run `./run_bench.sh` there. It prints `ESCALATE:` lines automatically.
- **Real human voice and microphone**: run `./run_bench.sh --my-voice <dir>`.
- Real room noise, far-field audio, and accents beyond the TTS voices. All fixtures are synthetic `say` speech.
- Thermal behaviour and battery drain on a laptop.
- macOS 27, where the VoiceInk #987 encoder failure is reported.
- Long dictations beyond 3.4 min.
