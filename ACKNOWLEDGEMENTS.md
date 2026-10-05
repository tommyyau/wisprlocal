# Acknowledgements

WisprLocal's dictation depends on **FluidAudio by FluidInference**: its Swift library runs both Parakeet speech recognition and Silero voice activity detection on this Mac. We thank FluidInference, NVIDIA, Moondream and the Silero Team for the library, models and Core ML conversions that make this app possible.

Verified on **4 October 2026** against the pinned Swift package and model revisions, the production call paths, and rebuilt app and receiver packages. The default app bundles Parakeet v2, Parakeet Ultra and Silero VAD. The receiver links FluidAudio through the shared core but bundles no model weights.

| Component | Role in WisprLocal | Author and conversion | Licence |
|---|---|---|---|
| FluidAudio 0.17.5 | Essential Swift library for ASR and VAD | FluidInference | Apache-2.0 |
| Parakeet TDT 0.6B v2 | Default English speech recognition | NVIDIA; Core ML by FluidInference | CC-BY-4.0 |
| Parakeet Ultra | Noisy-room and multilingual speech recognition | Moondream, derived from NVIDIA; Core ML by FluidInference | CC-BY-4.0 |
| Silero VAD | Finds speech and trims outer silence | Silero Team; Core ML by FluidInference | MIT |

The app's **Help › Credits…** sheet renders this file and the bundled licence files. Library and model licences are in `Contents/Resources/Licenses/<component>/`; each model also carries its `LICENSE` and `NOTICE` beside the weights in `Contents/Resources/Models/<model>/`. Their source is `WisprLocal/App/Licenses/`. The receiver carries FluidAudio's licence and retained third-party notices in its own `Contents/Resources/Licenses/` folder.

## Library and model credits

### FluidAudio 0.17.5 (Swift package, statically linked)

| | |
|---|---|
| Pin | `Package.resolved`: `https://github.com/FluidInference/FluidAudio.git` @ `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7` (0.17.5, `exact:`) |
| Author | **FluidInference** — https://github.com/FluidInference/FluidAudio |
| Used for | `AsrModels` / `AsrManager` load and run Parakeet; `VadManager` runs Silero VAD. These are the app's production transcription and speech-trimming paths. |
| Licence | **Apache-2.0**. Its `LICENSE` ships in `Licenses/FluidAudio/LICENSE`. The pinned upstream package has no `NOTICE` file; WisprLocal supplies a short attribution notice in `Licenses/FluidAudio/NOTICE`. |
| Its third-party components | The notices for fastcluster (BSD-2-Clause), VBx (Apache-2.0), and the Japanese / Spanish-French G2P frontends ship unchanged in `Licenses/FluidAudio/ThirdPartyLicenses/`. They cover code and data retained in the Swift library, including features WisprLocal does not call. The optional native text-normalization dependency is disabled and excluded from the app and receiver. |
| Modifications | Upstream source is unmodified. The supported `traits: []` dependency setting excludes its unused native text-normalization engine. |
| Not shipped | `FluidAudio_FluidAudio.bundle` contains only the LuxTTS lexicon. That lexicon is phoneme data harvested from espeak-ng. Only LuxTTS reads `Bundle.module`; ASR and VAD never do. `build_app.sh` therefore **excludes** this bundle, so no espeak-derived data ships. |

### Parakeet TDT 0.6B v2 (default "English" speech recognition model) — `Models/parakeet-tdt-0.6b-v2`

| | |
|---|---|
| What ships | `FluidInference/parakeet-tdt-0.6b-v2-coreml` at revision `ee09c569f73759e6d44c9bd16766f477b2b36d39` — a Core ML build of Parakeet TDT 0.6B v2 (English) |
| Authors | **NVIDIA** (`nvidia/parakeet-tdt-0.6b-v2`). Core ML conversion by **FluidInference**. |
| URLs | https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml · https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 |
| Licence | **CC-BY-4.0**. NVIDIA's source model card says: "GOVERNING TERMS: Use of this model is governed by the CC-BY-4.0 license." It also says it is "ready for commercial/non-commercial use". Legal code: https://creativecommons.org/licenses/by/4.0/legalcode |
| Modifications | FluidInference converted NVIDIA's checkpoint to Core ML (Preprocessor, Encoder, Decoder and JointDecision models). **WisprLocal makes no modifications**: the files are bundled exactly as published at the pinned revision. |

### Parakeet Ultra ("Noisy room / other languages" speech recognition model) — `Models/parakeet-ultra`

| | |
|---|---|
| What ships | `FluidInference/parakeet-ultra-coreml` at revision `95eaa59a39d4394f047a4dc5cce480388a60d1b6` — a Core ML build of Parakeet Ultra |
| Authors | **Moondream** (`moondream/parakeet-ultra`): a post-trained version of **NVIDIA**'s `nvidia/parakeet-tdt-0.6b-v3`. Core ML conversion by **FluidInference**. |
| URLs | https://huggingface.co/FluidInference/parakeet-ultra-coreml · https://huggingface.co/moondream/parakeet-ultra · https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |
| Licence | **CC-BY-4.0** for all three. The model cards say: "License CC-BY-4.0, as the upstream checkpoint" and "License is CC-BY-4.0, same as the original". Legal code: https://creativecommons.org/licenses/by/4.0/legalcode |
| Modifications | Moondream post-trained NVIDIA's checkpoint. FluidInference converted it to Core ML and quantised the encoder to **int8, linear per-channel** (632.3 MB for the complete Ultra model files, including metadata; measured disk allocation: 617,540 KiB, about 603.1 MiB). Their recipe is `FluidInference/mobius models/stt/parakeet-ultra/coreml`. **WisprLocal makes no modifications**: the files are bundled exactly as published. |

### Silero VAD (voice activity detection model) — `Models/silero-vad`

| | |
|---|---|
| What ships | `FluidInference/silero-vad-coreml` at revision `b419383c55c110e2c9271fa6ee0ea83d03c70d96`, file `silero-vad-unified-256ms-v6.2.1.mlmodelc`. This is the model FluidAudio 0.17.5 loads: `ModelNames.VAD.sileroVad`. |
| Authors | **Silero Team** (original model). Core ML conversion by **FluidInference**. |
| URLs | https://github.com/snakers4/silero-vad · https://huggingface.co/FluidInference/silero-vad-coreml |
| Licence | **MIT**. The model card says "License: mit". The upstream LICENSE says "Copyright (c) 2020-present Silero Team". |
| Modifications | Core ML conversion by FluidInference. Bundled unmodified by WisprLocal. |

### Other SwiftPM dependencies

None. `Package.resolved` contains exactly one pin, FluidAudio, and FluidAudio's own `Package.swift` declares `dependencies: []`.

## Pinned model provenance and downloads

Model weights are **never committed to git**: `.gitignore` excludes `Models/`, `*.mlmodelc`, `build/` and `*.app`, and `RepoHygieneTests` enforces it.

`WisprLocal/App/scripts/fetch_models.sh` first copies models from configured local source directories, previous App Support model directories or local spike directories if they are present. Otherwise it runs the dev-only tool `wisprlocal-fetch-models` once, while online. That tool calls FluidAudio's `AsrModels.download(to:version:)` (`.v2` and `.ultra`) and `ModelHub.loadModels(.vad, …)` for Silero VAD, which fetch files from:

    https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/ee09c569f73759e6d44c9bd16766f477b2b36d39/<file>
    https://huggingface.co/FluidInference/parakeet-ultra-coreml/resolve/95eaa59a39d4394f047a4dc5cce480388a60d1b6/<file>

The VAD download uses `FluidInference/silero-vad-coreml` at the revision below. The download is **pinned to an immutable commit**:

| Repo | Pinned revision |
|---|---|
| `FluidInference/parakeet-tdt-0.6b-v2-coreml` | `ee09c569f73759e6d44c9bd16766f477b2b36d39` |
| `FluidInference/parakeet-ultra-coreml` | `95eaa59a39d4394f047a4dc5cce480388a60d1b6` |
| `FluidInference/silero-vad-coreml` (`silero-vad-unified-256ms-v6.2.1.mlmodelc`) | `b419383c55c110e2c9271fa6ee0ea83d03c70d96` |

How the pin works:
- The pins are set in `WisprLocal/App/scripts/models_common.sh` (`WISPRLOCAL_REV_*`).
- The fetcher passes them to FluidAudio via `ModelRegistry.revisionOverrides`.
- It refuses to download a shipped model without a pin.

On 4 October 2026 all **48 model files** in the rebuilt app matched the pinned Hugging Face revisions: **22/22 Parakeet v2, 20/20 Ultra and 6/6 Silero VAD**. Verification uses the LFS SHA-256 for weights and Git blob SHA-1 for other files. The model cards, licence evidence and file comparisons are recorded in [the audit](WisprLocal/docs/license-audit-2026-10-04.md) and [its evidence manifest](WisprLocal/docs/license-audit-2026-10-04-evidence.json).

`build_app.sh` copies only manifest-listed model files (plus `LICENSE`/`NOTICE`) into the app. `scripts/model-manifest.sha256` pins SHA-256 for every shipped model file; `fetch_models.sh`, `build_app.sh` and `verify_bundle.sh` verify against it. The app does not re-hash at runtime. Speech recognition, speech detection and cleanup never access the network. Optional Remote Macs sends finished text over the user's Tailscale connection; no Tailscale client is bundled.

## Apple system frameworks

We also thank **Apple** for Core ML and Accelerate (on-device inference), AVFoundation (audio capture), SwiftUI and AppKit (the app), NaturalLanguage (local language and word checks), and Foundation Models (optional Apple Intelligence formatting). These frameworks are provided by macOS rather than copied into WisprLocal. Their system and developer terms continue to apply.

## Developer experiments

S1–S5 sources and recorded measurements are retained under `WisprLocal/Spikes/`; their candidate models, local benchmark audio and build outputs are excluded from the app and receiver. Phonon-2 and the S4 speaker weights are experimental candidates, not supported app models. Credits and provenance for those experiments remain in their own reports. Experimental model weights, audio and tools are excluded from packaged builds.
