Snapshot of external checks on 2026-10-04; not re-verified by later builds.

Written before public release; the repository is now public, and the redistribution analysis below applies to the public source.

# WisprLocal license and terms audit

Checked on 4 October 2026 against the working tree dated 2026-10-04, the local packaged app, immutable
upstream revisions, and current published terms. The GitHub repository is
**private**, confirmed through the authenticated GitHub API.

The default app's speech models and library licenses support personal use.
Its Parakeet and Silero model attribution is well covered. However, this is
**not an unconditional clearance of every experiment or future distribution**:
the legacy speaker weights used by S4 have unresolved provenance and license
scope. The unused Rust engine found during the initial inspection has been
disabled, and the Apple-voice test recording has been replaced.

Personal software still has license conditions. Giving credit does not replace
permission, license copies, or service acceptable-use requirements. This audit
reports the published grants and observed implementation; it is not a legal
opinion on rights that an upstream publisher may not own.

## Scope and verification

Three checks were used:

1. Read every current Swift package manifest and lockfile, the model downloader,
   packaging scripts, credits UI, source imports, Python imports, and tracked
   assets. The app and S1, S1b, S4 and S5 lockfiles all pin FluidAudio 0.17.5 at
   `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7`. S2 has no third-party package;
   S3 uses Apple's system Foundation Models framework.
2. Inspect the actual `build.noindex/WisprLocal.app`: all three model folders
   contain license and notice files, and neither test resources nor the
   LuxTTS resource bundle is present. The initial build included five library
   notices and native Rust symbols. The clean rebuild of the app and receiver
   excludes the unused engine and its notice; both binaries have no matching
   native Rust symbols, and their signatures verify.
3. Fetch the pinned model cards and current upstream license/terms pages.
   Compare every bundled model file against Hugging Face Git blob or LFS
   hashes: **22/22 Parakeet v2, 20/20 Ultra, 6/6 Silero VAD match**, with no
   unknown files or mismatches. Added local `LICENSE` and `NOTICE` files are
   excluded from the upstream weight comparison. Current model repository
   heads equal the configured model revisions.

The source digests, model file comparisons and local verification metadata are
in [the evidence manifest](license-audit-2026-10-04-evidence.json).

## Production stack clarification

**FluidAudio is an essential, retained and credited dependency.** The app's
`FluidAudioTranscriber` uses `AsrModels` and `AsrManager` for both Parakeet
variants; `SileroSpeechTrimmer` uses `VadManager` for speech detection.
Neither these app paths nor FluidAudio's ASR/VAD implementations call the
optional NeMo native text-normalization APIs. The disabled component is
`NemoTextProcessing`, not FluidAudio or the NVIDIA speech-model weights.

The follow-up edit removes the rejected Phonon-2 model from the app's model
catalog, replay tool, packaging configuration and downloader. Its original
benchmark sources and results remain in S1b. Existing history records retain
their engine string and text; unknown/retired engines still select a supported
Parakeet variant for re-transcription. No model version or weight file changed.

About, Credits, the README and release notes now state FluidAudio's role.
The FAQ explicitly distinguishes the two CC-BY-4.0 speech models, MIT Silero
VAD and Apache-2.0 FluidAudio. Each model notice carries the exact download
revision and conversion attribution. `scripts/verify_bundle.sh` inspects each
assembled app/receiver before signing: actual retained FluidAudio symbols,
matching attribution files, supported model folders, and absence of the
unused native engine, LuxTTS resource bundle and test resources. Retained
library notices are preserved even for upstream Swift features the app does
not call; unused execution paths alone do not justify dropping their notices.

The follow-up full CI reports **733 tests in 133 suites passing**, normally
and with network access denied, zero warnings in our code, and an **8.627 s**
incremental release build. Both final packages pass the bundle validator and
signature verification; all 48 model files remain unchanged and match their
pinned upstream hashes. Tests with deliberately broken copies confirm the
validator rejects missing FluidAudio attribution, LuxTTS assets and unsupported
speaker-model folders. The downloader rejects the retired Phonon-2 token
before accessing the network.

Headless real-model replay also transcribes the fixture through both Parakeet
variants with network access denied. Core ML prints the existing E5RT
zero-shape diagnostic during v2 warm-up; the transcription still completes
successfully. This does not claim a manual microphone, UI or two-Mac test.

## Stack and applicable licenses

| Component | Actual role | Terms and assessment |
|---|---|---|
| Swift 6.2 and SwiftPM | Native build and packaging | Apple Xcode/SDK terms apply to the installed tools. Swift runtime libraries resolve to system paths in the inspected binary; no separate Swift runtime is packaged. |
| SwiftUI, AppKit, Foundation, AVFoundation, Core ML, Accelerate, NaturalLanguage, CryptoKit, Network and other macOS APIs | UI, capture, inference, local text processing, insertion and remote bridge | System frameworks, not bundled Apple binaries. Development and system use remain subject to Apple's licenses. |
| Apple Foundation Models | Optional on-device punctuation and layout | Proprietary framework with acceptable-use requirements; see the Apple assessment below. |
| FluidAudio 0.17.5 | Statically linked audio/inference library | Apache-2.0. Its pinned and current root licenses match the checked-in copy. FluidAudio has no upstream root NOTICE; WisprLocal supplies its own attribution notice. |
| FluidAudio internal components | fastcluster, VBx and G2P ports/data | The four retained third-party license files match the pinned checkout byte-for-byte and ship in the app. They cover BSD-2-Clause, Apache-2.0, MIT and UniDic's BSD option. |
| Parakeet TDT 0.6B v2 | Default English recognition | CC-BY-4.0, including its NVIDIA origin and FluidInference Core ML conversion. Required attribution, source links, license URI, modification history and warranty reference are present. |
| Parakeet Ultra | Optional noisy-room/multilingual recognition | CC-BY-4.0 across NVIDIA, Moondream and FluidInference. Credits preserve the post-training and conversion/quantization history. |
| Silero VAD | Speech trimming | MIT, with the original Silero Team copyright and permission text included. FluidInference conversion is credited. |
| Tailscale | Separately installed service for optional Remote Macs | No Tailscale code or client is bundled. Account plan, service terms and acceptable-use rules apply to remote use. |
| NumPy | S1b benchmark fixture generator | BSD-3-Clause; developer-only import, with no NumPy distribution in the app or repo. The repository does not pin a Python environment. |
| eSpeak NG 1.52.0 | Regeneration of the replacement test WAV | GPL-3.0-or-later developer tool. Only its synthesized speech output is committed; no executable, library or voice-data files are shipped. Tests need no eSpeak installation. |
| Icons and fonts | App appearance | The app icons have a repository CoreGraphics/CoreImage generator. The app uses system fonts and SF Symbols through system APIs; no font files are tracked. The uncertified design PNGs have been removed; the app icon is generated by `Resources/IconSource/make_icon_B.swift`. |

Primary grants: [FluidAudio at the pinned commit](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/LICENSE),
[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0),
[MIT](https://opensource.org/license/mit),
[NumPy](https://numpy.org/doc/stable/license.html), and
[Xcode and Apple SDKs](https://www.apple.com/legal/sla/docs/xcode.pdf).

## Default model assessment

| Model repository | Revision | Current declared license |
|---|---|---|
| FluidInference/parakeet-tdt-0.6b-v2-coreml | `ee09c569f73759e6d44c9bd16766f477b2b36d39` | CC-BY-4.0 |
| FluidInference/parakeet-ultra-coreml | `95eaa59a39d4394f047a4dc5cce480388a60d1b6` | CC-BY-4.0 |
| FluidInference/silero-vad-coreml | `b419383c55c110e2c9271fa6ee0ea83d03c70d96` | MIT |

Both NVIDIA origin cards still specify CC-BY-4.0, and Moondream's Ultra card
retains the same license. The permission is not limited to hobby projects;
NVIDIA's v2 card expressly permits commercial and non-commercial use.
The repo's MIT license covers WisprLocal's own work and does not relicense
third-party weights. [NVIDIA v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2),
[NVIDIA v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
[Moondream Ultra](https://huggingface.co/moondream/parakeet-ultra),
[pinned v2 conversion card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/blob/ee09c569f73759e6d44c9bd16766f477b2b36d39/README.md),
[pinned Ultra conversion card](https://huggingface.co/FluidInference/parakeet-ultra-coreml/blob/95eaa59a39d4394f047a4dc5cce480388a60d1b6/README.md).

CC-BY-4.0 section 3 requires attribution when sharing, preserving supplied
notices and prior modifications. It permits providing the license by URI;
the short local model LICENSE files therefore need not contain the full legal
code. Sections 2 and 6 make the grant irrevocable while its conditions are
satisfied: a publisher subsequently changing terms or stopping distribution
does not terminate a valid earlier CC grant. This does not establish rights
the publisher never had. [CC-BY-4.0 legal code](https://creativecommons.org/licenses/by/4.0/legalcode.en).

The inspected build retains the model creators, original/conversion sources,
license URLs, modifications and warranty references in `ACKNOWLEDGEMENTS.md`
and model NOTICE files. The build refuses missing model licenses/notices, and
the Credits UI reads the bundled material. This supports a positive assessment
of the **default models' attribution and redistribution conditions**.

## Unused native engine excluded

FluidAudio 0.17.5 enables its optional `NemoTextProcessing` trait by default.
The initial app inspection confirmed that its Rust xcframework was linked,
even though no app or benchmark source called it. That engine serves NeMo
text normalization for text-to-speech frontends and inverse text normalization.
WisprLocal uses FluidAudio for speech recognition and VAD; its cleanup comes
from its own rules and optional Apple Foundation Models formatting.

The app and all FluidAudio benchmark manifests now declare `traits: []`.
The benchmark manifests use Swift tools 6.2 so they can select dependency
traits. The unused engine's notice is removed from app and receiver packaging;
the four notices for retained Swift-library components remain unchanged.
`LicenseTests` checks the library's actual `NemoTextNormalizer.isAvailable`
value so an accidentally re-enabled dependency fails the test gate.
[Upstream opt-out and feature scope](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Package%40swift-6.2.swift).

The initial build's Rust dependency notice material was incomplete. Excluding
this unused engine resolves that issue for rebuilt app and receiver bundles.
The evidence manifest preserves the initial inspection separately from the
remediation checks. Earlier built copies are superseded by the rebuilt ones.

## Apple framework and content terms

The Xcode/SDK agreement section 2.11.C and Developer Program agreement section
3.3.11.A require compliance with the Foundation Models acceptable-use rules
and reasonable supporting guardrails. These rules apply even though inference
is on-device. Credits do not satisfy them. Current rules include prohibited
harmful or unlawful content, safety circumvention, training-data extraction,
and certain high-risk decisions. The SDK agreement also prohibits using Apple
model outputs to train, fine-tune or improve another AI model.
[Apple acceptable-use requirements](https://developer.apple.com/support/terms/acceptable-use-requirements-for-the-foundation-models-framework),
[Xcode/SDK agreement](https://www.apple.com/legal/sla/docs/xcode.pdf),
[Developer Program agreement](https://developer.apple.com/support/downloads/terms/apple-developer-program/Apple-Developer-Program-License-Agreement-English.pdf).

WisprLocal's implementation limits the model to transforming the supplied
transcript's punctuation, capitalization and layout; its output guard rejects
word changes, and model refusals fall back to deterministic rules. No model
training or extraction code was found. `.permissiveContentTransformations`
is an official API documented for sensitive user-provided material, so its
use is not itself evidence of a jailbreak. However, Apple says this mode
skips input/output guardrail checks for string responses; the lexical output
guard is not an acceptable-use classifier. The implementation appears
consistent with a content-transformation use case, while actual prohibited
use remains outside the license. This is an assessment, not certification
of every possible dictated input.
[Apple safety documentation](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output).

### Apple voice fixture replacement

The original `Tests/WisprLocalCoreTests/Fixtures/clip05.wav` was generated with
`say -v Samantha`, as documented by `scripts/make_fixtures.sh`. macOS Tahoe
license section 2.F restricts system-voice recordings to personal,
non-commercial use and expressly excludes public sharing. It was a test
recording, not an Apple voice engine embedded in the product. The inspected
app contains neither the recording nor the test resource bundle. The private
repo and stated personal use do not establish a public-sharing violation,
but the file would be a problem for future public source distribution.
[macOS Tahoe license](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf).

At the user's request, this audit replaced the WAV with **eSpeak NG 1.52.0
formant speech**, retained the original sentence, changed the regeneration
script, and recorded [fixture provenance](../App/Tests/WisprLocalCoreTests/Fixtures/README.md).
The replacement is 4.219125 seconds, mono 16-bit PCM at 16 kHz, SHA-256 `2213e8169d5ebce1139a2309e5406954e81a6316bf67b6fb95bac7ed5cc0e2a0`.
The synthesizer is a separate developer tool. GPLv3 section 2 does not
automatically license every output of running a GPL program; this fixture
contains generated speech of repository-authored text. No synthesizer code,
voice data or recorded speaker samples are distributed.
[eSpeak NG GPL license](https://github.com/espeak-ng/espeak-ng/blob/1.52.0/COPYING).

The public repository starts with one fresh commit of the cleaned tree; earlier history and the old Apple rendering are not published. Frozen spike results retain their historical descriptions; their local Apple-voice recordings are not tracked.

## Experiments and services

**Phonon-2 in S1b:** current original and Core ML model cards specify
CC-BY-4.0 for weights; the original repository's code has a separate Apache-2.0
license. It is not bundled by default. `BUNDLE_MODELS=phonon2` is refused as an unknown model token by
`models_common.sh`. It also lacks a local licence folder. Future inclusion needs
Fermion Research, NVIDIA and FluidInference attribution and retention of the
upstream change/training-data NOTICE. Private evaluation is not the same
thing as having no applicable terms.
[Phonon-2](https://huggingface.co/FermionResearch/Phonon-2),
[Core ML conversion](https://huggingface.co/FluidInference/phonon-2-coreml).

**S4 speaker experiment:** it downloads `pyannote_segmentation.mlmodelc` and
`wespeaker_v2.mlmodelc` from `FluidInference/speaker-diarization-coreml`, and
loads the latter for speaker embeddings. The current repository is marked
`other`, with a scoped CC-BY-4.0 notice covering the newer Community-1 artifact
set. The current NOTICE explicitly excludes those legacy filenames from its
provenance/license confirmation and requires evaluating their original
source and license separately. Therefore the current top-level model card
cannot clear S4's exact weights. This is an unresolved grant/provenance issue,
not proof that an earlier valid license was revoked. These weights are absent
from the default app. Establish their downloaded revision and upstream
licensing before shipping or relying on a blanket licensing claim.
[current model card](https://huggingface.co/FluidInference/speaker-diarization-coreml),
[scope notice](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/main/NOTICE.md).

**Hugging Face:** the build-only downloader retrieves public, ungated model
files; the default app does not call a hosted inference service. The current
service terms preserve applicable open-source/Creative Commons rights and
require retaining license references. No access bypass was observed.
[Hugging Face terms](https://huggingface.co/terms-of-service).

**Tailscale:** ordinary remote use is permitted under the applicable plan.
The Personal plan is expressly for non-commercial use; using personally
written software for an employer or paid work does not itself make the
Tailscale traffic personal. The user's subscription and actual remote-use
purpose were not inspected, so this remains conditional. No Tailscale client
redistribution was found.
[Tailscale terms section 2.1](https://tailscale.com/terms),
[personal and business use explanation](https://tailscale.com/pricing).

## Validation and follow-up

The replacement fixture and copied test resources have matching hashes.
Shell syntax and the tracked/staged privacy checks pass. The initial selected
fixture checks passed 14 tests with a 71 ms median perceived warm-pipeline
latency. The initial engine-removal check reports **731 tests
in 133 suites passing**, both normally and with network access denied. Opt-in
benchmarks remain skipped; socket integration tests run only in the normal
suite. Both Parakeet variants recognize the fixture, and Silero trims speech
and rejects silence with the native normalization APIs unavailable.

The clean release/debug/test builds produce zero warnings in our code. The
incremental release gate takes **9.676 s** against its 180 s budget. The S5
release build also passes without native Rust symbols. Both rebuilt app and
receiver contain four unchanged upstream library notices, exclude the unused
engine and test/LuxTTS resources, and pass signature verification. All **48
model files** in the rebuilt app still match the pinned upstream hashes.
License structure tests check file presence and selected text; they do not
prove legal completeness. Manual microphone, UI and two-Mac testing are not
claimed by these automated checks.

Before public source distribution, review old Apple-voice blobs in the Git
history. The rebuilt app and receiver exclude the unused Rust engine. Keep
the unresolved S4 legacy weights out of the default bundle. When adding a model, changing a dependency/trait, distributing
a new artifact, or enabling a new service, repeat the inventory, pin-level
license/provenance check, and final-bundle inspection. Preserve valid earlier
license evidence. Recheck mutable Apple and service terms for continued use.

This audit does not clear trademarks, every image's authorship, training-data
rights held by upstream publishers. The earlier Python CLI and cloud prototype are not part of this repository. The
current WisprLocal app's model grants and notices are supported by the
evidence above; the stated unresolved items prevent a blanket compliance
claim for the entire repository and every use.
