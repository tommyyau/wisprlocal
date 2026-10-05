# S4: Speaker gating feasibility (FluidAudio WeSpeaker embeddings)

**Verdict: GO, with caveats (synthetic voices only; needs real TV and music tests).** A single cosine threshold cleanly separates the enrolled voice A from every other single voice B, with a wide margin. It also keeps A when B talks over A at -6 dB or quieter. At **0 dB** overlap the similarity collapses toward the B range, so gating is unreliable there.

Environment: M5 Pro, macOS 26.6.2, FluidAudio **v0.17.5**, model `speaker-diarization/wespeaker_v2.mlmodelc` (7.6 MB; the whole diarizer dir is 13 MB). Release build. Runs were offline (`sandbox-exec` network deny + `ModelHub.offlineMode = true`).

## How to run
```
cd WisprLocal/Spikes/S4-speaker
swift build -c release
.build/release/S4Speaker download      # ONLINE, one-time -> ./Models (gitignored)
S4_UNITS=ane .build/release/S4Speaker run   # S4_UNITS = cpu | ane | gpu | all (default all)
```

## Setup
- **Enrollment (A):** `say -v Daniel` (en_GB male) reading a 31.1 s passage (`Fixtures/enroll.txt`). The enrolled embedding is the L2-normalised mean of the L2-normalised embeddings of non-overlapping windows of length L.
- **A alone (test):** Daniel reading two texts that differ from the enrollment text. One is `testA.txt`. The other is `testB.txt`, the same "news" text the B voices read, which controls for content.
- **B alone:** Samantha (US female), Karen (AU female), Moira (IE female) and **Fred (US male, the hard case)**, all reading `testB.txt`.
- **Mixtures:** A_test + B, with B's RMS set to −12 / −6 / 0 dB relative to A and the result rescaled to A's RMS. B = Samantha and B = Fred.
- Segments: non-overlapping windows of L = 1.5 / 3 / 5 s. Windows with RMS < 0.005 are dropped. Score = cosine(segment embedding, enrolled embedding).

## Results: cosine similarity to the enrolled embedding
### L = 3.0 s (closest to a typical dictation utterance)
| Stream | n | mean | min | max |
|---|---|---|---|---|
| A alone (test text) | 6 | **0.896** | 0.864 | 0.915 |
| A alone (news text) | 7 | **0.906** | 0.875 | 0.926 |
| B Samantha | 7 | 0.161 | 0.107 | 0.195 |
| B Karen | 7 | 0.147 | 0.116 | 0.180 |
| B Moira | 7 | 0.072 | 0.039 | 0.134 |
| B Fred (male) | 8 | **0.315** | 0.253 | **0.414** |
| A + Samantha −12 dB | 6 | 0.845 | 0.820 | 0.871 |
| A + Samantha −6 dB | 6 | 0.785 | 0.744 | 0.836 |
| A + Samantha 0 dB | 6 | 0.374 | 0.179 | 0.534 |
| A + Fred −12 dB | 6 | 0.868 | 0.820 | 0.910 |
| A + Fred −6 dB | 6 | 0.819 | 0.785 | 0.862 |
| A + Fred 0 dB | 6 | 0.611 | 0.421 | 0.751 |

### Separation summary
| Window | min(A alone) | max(B alone) | Margin | Clean threshold? |
|---|---|---|---|---|
| 1.5 s | 0.612 | 0.349 | 0.264 | yes (≈0.48) |
| **3.0 s** | **0.864** | **0.414** | **0.451** | **yes (≈0.64)** |
| 5.0 s | 0.932 | 0.390 | 0.543 | yes (≈0.66) |

5 s means: A ≈ 0.94; B 0.08 to 0.33; A+B −6 dB 0.84 to 0.88; A+B 0 dB 0.38 to 0.69.

**What the numbers show:**
- B-only segments gate cleanly at every window length. A threshold around **0.6 at L ≥ 3 s** rejected 100% of the B-only segments and accepted 100% of the A-only segments.
- When A talks with B in the background at **−6 dB or quieter**, every segment stays above 0.74, so A's dictation is kept.
- At **0 dB** (B as loud as A), the mixture scores fall into the 0.18 to 0.75 range. Some segments would be dropped and others kept. Speaker gating cannot clean up the content of an overlap anyway: it decides keep or drop, and does no separation.
- Same-gender impostors are the hard case: Fred sits at 0.25 to 0.41, against 0.04 to 0.20 for the female voices. The margin is still about 0.45 at 3 s.
- Shorter windows are noisier. At 1.5 s, A's minimum drops to 0.61, so apply the gate per utterance (≥ 3 s if possible) or on a running average, not per 1 s chunk.

## Latency and memory (per embedding call, 315 calls per run)
| Compute units | Median | p95 | Model load |
|---|---|---|---|
| cpuOnly | 131 ms | 181 to 199 ms | 82 ms (first-ever compile 8.9 s) |
| cpuAndNeuralEngine | 77 to 113 ms | 148 to 185 ms | 82 to 156 ms |
| cpuAndGPU | 111 ms | 139 ms | 738 ms |
| all (FluidAudio default) | 99 to 113 ms | 134 to 142 ms | 103 to 167 ms |

- The cost is about **100 ms per segment no matter how long the segment is.** The WeSpeaker CoreML model has fixed inputs (`waveform [3,160000]`, `mask [3,589]`), i.e. 10 s × 3 speaker slots, and `EmbeddingExtractor` repeat-pads shorter audio up to 10 s. Gating once per utterance (~100 ms, which can run in parallel with ASR) is fine. Gating every 1.5 s window is expensive.
- **Memory gotcha:** without an `autoreleasepool` around each `getEmbeddings` call, peak RSS grew to **754 MB** over 315 calls (CoreML outputs are autoreleased and never drained in an async loop). With `autoreleasepool { ... }` it stayed at **112 to 140 MB**. The app must wrap every call.

## Exact APIs used (FluidAudio v0.17.5, `Sources/FluidAudio/...`)
- One-time download: `ModelHub.loadModels(.diarizer, modelNames: Array(ModelNames.Diarizer.requiredModels), directory:)`: `Shared/Download/ModelHub.swift:85`
- Offline load (no ModelHub at all): `MLModel(contentsOf: Models/speaker-diarization/wespeaker_v2.mlmodelc)`. There is also a helper, `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` (`Diarizer/Core/DiarizerModels.swift:120`), which documents "No models are downloaded".
- `EmbeddingExtractor(embeddingModel:)`: `Diarizer/Extraction/EmbeddingExtractor.swift:11`. `getEmbeddings(audio:masks:minActivityThreshold:)`: `:27`, with masks = `[[Float](repeating: 1, count: 589)]` (whole segment = one speaker). It returns a 256-d embedding, and cosine is computed in the harness.
- The pyannote segmentation model is not needed for gating; only the embedding model is used.

## Limitations and next steps
- **Synthetic voices only.** `say` voices are very consistent and acoustically far apart. Real enrollment/test variation (mic distance, room, cold/tired voice, Bluetooth headset codecs) will shrink A's scores. **Real TV, podcast, music and other-person tests are manual follow-ups.**
- Music was not tested. Embeddings of music or noise-only segments are undefined territory, so gate with VAD first.
- Mixtures are sample-aligned digital sums, with no room acoustics.
- Not tried: FluidAudio's newer `Speaker/CampPlusEmbedder.swift` (CAM++, 192-d, beta, variable-length input). It may be faster and more accurate for verification than the fixed-10 s WeSpeaker window, so it is worth an A/B test.

## Recommendation
**GO** on including speaker gating as an *optional* "only my voice" feature. Design:
1. Enroll with about 30 s of speech (mean of 3 s-window embeddings).
2. Per utterance, after VAD, take one embedding over the utterance (≤ 10 s; if longer, use several and average them), with `autoreleasepool` around each call, running in parallel with ASR. Drop the utterance if cosine < about 0.6, and calibrate that threshold on real voices.
3. Don't promise rejection when someone else talks as loudly as you (0 dB overlap). Offer a sensitivity slider.
4. Default the setting to off until real-world tests (TV, music, a second person) confirm the margins.
