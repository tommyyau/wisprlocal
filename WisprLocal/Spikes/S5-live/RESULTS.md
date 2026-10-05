# S5: Live transcript preview + on-device translation (measurement spike)

**Verdicts**
- **Part 1, live preview: GO.** Use the strategy "committed prefix + re-decoded tail" with the model that is already loaded, every 500 ms. On v2 each update takes about 43 ms (p50) and stays flat however long the dictation runs. The ASR is busy about 9% of the time and uses 0.043 CPU-s per audio-second. The final preview matches the full-buffer transcript to 0–0.5% WER (normalized). You need no new model and no extra bundle size.
- **FluidAudio's built-in streaming (1b):** do not use it for the preview. `SlidingWindowAsrManager` gives its first update only after about 13.8 s of audio. True streaming models (EOU, Nemotron, Unified-streaming) are not installed and would add 220–620 MB.
- **Part 2, translation: API feasible, quality NOT measured.** Headless `TranslationSession(installedSource:target:)` works from a plain CLI with no SwiftUI host. But **no language packs are installed** on this Mac: en→fr/de/es all report `supported`, not `installed`. Per the brief, I stopped there. I triggered no downloads.

Environment: Apple **M5 Pro**, macOS 26.6.2, Swift 6.4, FluidAudio **0.17.5**. Models were loaded with `AsrModels.loadLocal` from `~/Applications/WisprLocal.app/Contents/Resources/Models` (v2 = `parakeet-tdt-0.6b-v2`, Ultra = `parakeet-ultra`), with `.cpuAndNeuralEngine`. Every run went through `sandbox-exec -f offline.sb`, which denies all IP traffic. Load average was 4–6 during the runs because other agents were building, so the occasional max-latency spikes (≈240–390 ms) are contention, not the model.

Fixtures are `say -v Samantha -o` files (nothing played aloud), resampled to 16 kHz WAV: `c05` 6.2 s, `c15` 13.2 s, `c30` 29.7 s, `c60` 62.2 s. The text is dictation-style and includes Kubernetes, Tailscale, numbers and percentages. The `.txt` next to each WAV is the reference.

## How to run
```
cd WisprLocal/Spikes/S5-live
./run_bench.sh                     # builds, runs everything offline, prints the summary table
S5_TRACE=1 .build/release/S5Live full v2 500 Fixtures/c15.wav          # watch every update
S5_TRACE=1 .build/release/S5Live tail v2 500 14 1.5 Fixtures/c30.wav   # committed | tail
.build/release/S5Live probe v2 Fixtures/c60.wav                         # one-pass cost vs buffer length
S5_PACE=1 .build/release/S5Live sliding v2 Fixtures/c30.wav             # FluidAudio SlidingWindowAsrManager
.build/release/S5Translate availability | headless fr | quality fr [low|high] | incremental fr
```
`run_bench.sh` is ready for the **M1 Pro**. Raw data is in `results/*.jsonl|txt`, and `results/summary.md` is the full table.

## Metrics
- **Latency**: wall time of one `AsrManager.transcribe` call (one preview update).
- **Duty**: Σ latency / audio duration, i.e. the fraction of wall time the ASR (ANE + CPU) is busy.
- **CPU s / audio s**: process user+sys time from `getrusage` over the whole run, divided by audio length.
- **Energy J**: `proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj`, which is identical to `task_info(TASK_POWER_INFO_V2).task_energy`. This is the kernel's estimate of energy for the process's CPU (and GPU) work. **ANE energy is almost certainly not attributed to the process**, so read it as a relative CPU-side proxy, not wall-plug energy. `powermetrics` (sudo) was not used.
- **Flicker**: on each update, how many already-shown words changed, not counting the last word shown (that word is expected to grow).
  - *raw* counts what the user actually sees, including case and punctuation.
  - *norm* ignores case and punctuation.
  - "upd. w/ rewrite" is the number of updates that changed any earlier word.
  - "max depth" is how far back from the end a rewrite reached, in words.
- **Preview WER vs full**: the last preview text compared with a single full-buffer pass (what we insert today), normalized.

## Part 1

### One-pass cost vs buffer length (probe, p50 of 5)
| buffer | 1 s | 4 s | 8 s | 12 s | 15 s | 16 s | 30 s | 60 s |
|---|---|---|---|---|---|---|---|---|
| v2 ms | 35 | 40 | 48 | 57 | 59 | 66 | 93 | 148 |
| v2 CPU ms/pass | 12 | 18 | 26 | 35 | 38 | 56 | 95 | 194 |
| Ultra ms | 65* | 76 | 79 | 102 | 106 | 130 | 159 | 226 |
| Ultra CPU ms/pass | 25 | 64 | 101 | 151 | 163 | 297 | 412 | 664 |

The encoder input is fixed at 15 s, and anything ≤15 s is zero-padded (`AsrManager+Transcription.swift:15`), so the ANE cost per pass is roughly constant. The part that grows is the CPU-side TDT decode, which scales with token count. Past 15 s, `AsrManager` chunks the audio, and cost steps up with every extra window. Ultra's decode is about 3–4× more CPU-heavy than v2's. (*The Ultra 1 s figure is noisy: its minimum was 41 ms.)

### (a) Pseudo-streaming: re-transcribe the whole growing buffer
| model | cadence | clip | lat p50/p95/max ms | duty | CPU s/audio s | energy J | upd. w/ rewrite raw/norm | words rewritten raw/norm | max depth |
|---|---|---|---|---|---|---|---|---|---|
| v2 | 500 | 6.2 s | 40/44/44 | 8% | 0.036 | 1.1 | 0/0 | 0/0 | 1 |
| v2 | 500 | 13.2 s | 47/62/64 | 10% | 0.053 | 3.1 | 17/6 of 27 | 274/17 | 35 |
| v2 | 500 | 29.7 s | 65/91/92 | 12% | 0.091 | 12.2 | 13/10 of 60 | 226/102 | 39 |
| v2 | 500 | 62.2 s | 98/146/151 | 19% | 0.192 | 52.8 | 29/11 of 125 | 465/191 | 42 |
| Ultra | 500 | 13.2 s | 53/73/73 | 11% | 0.128 | 6.2 | 9/6 | 65/13 | 17 |
| Ultra | 500 | 29.7 s | 113/145/149 | 18% | 0.342 | 36.4 | 19/10 | 123/33 | 28 |
| Ultra | 500 | 62.2 s | 150/229/278 | 29% | 0.797 | 149.7 | 36/24 | 243/158 | 42→21 |

The 300 and 1000 ms rows are in `results/summary.md`. Cost grows roughly quadratically with dictation length: a 60 s dictation on Ultra uses 0.8 CPU-s per audio-second. Every update met its cadence (no update ran longer than the cadence), but **flicker is bad**. Re-decoding the whole buffer re-punctuates the *start* of the text, so "release." becomes "release," then "release:" (rewrite depth up to 42 words, ≈12 s back). Real word changes also happen, for example "backup" ↔ "back up", "3.15" ↔ "3:15" and "Tailscale" ↔ "tail scale". The live edge also briefly hallucinates, as in "The data is a good thing.", which then becomes "the database migration". See `S5_TRACE=1` output.

### (b) FluidAudio's own streaming APIs (0.17.5 source)
| API | Status here | What a live preview would need |
|---|---|---|
| `SlidingWindowAsrManager` (TDT v2/Ultra, `.streaming` config 11 s chunk + 2 s left/right context) | **Works offline** with our models (v2 needs `TdtConfig(blankId: 1024)`). | It emits only once per 11 s chunk. **First update came at 13.8 s** (paced in real time), then every ≈11.7 s, and every update arrives `isConfirmed=true`. The `hypothesisChunkSeconds` setting is never read by the processing loop, so no volatile hypotheses come out. A 6–13 s dictation shows nothing until release. **Not usable for a live preview.** Final WER is the same as offline. |
| `StreamingEouAsrManager` (Parakeet realtime EOU 120M) | Models not present. `loadModels(from:)` can load a local directory offline. | About 222 MB per chunk tier (160/320/1280 ms). Licence: **NVIDIA Open Model License**. LibriSpeech WER 4.9% at 320 ms and 8.2% at 160 ms, which is worse than v2. A second model to bundle. |
| `StreamingNemotronAsrManager` (0.6B cache-aware RNNT, en) | Not present. | About 620 MB per tier (560/1120/2240 ms). Licence: **NVIDIA Open Model License**. WER 2.3–2.6%. |
| `StreamingUnifiedAsrManager` (Parakeet Unified 0.6B, chunked attention) | Not present. | About 605 MB for the int8 streaming encoder plus a 14 MB decoder. Licence: **CC-BY-4.0**. WER 2.21% with punctuation and capitalisation, 2.08 s latency. This is the most attractive true-streaming option if we ever want one: it is a single checkpoint with batch and stream modes. |

The sizes and licences come from the Hugging Face API metadata (fetched at research time; nothing was downloaded). The WER figures are from FluidAudio's `Documentation/Benchmarks.md`.

### (c) Capping cost: committed prefix + re-decoded tail
**Algorithm** (`runTail` in `Sources/S5Live/main.swift`). On each tick, decode the audio from `[commitTime − 2 s context, now]`. Drop any decoded word that starts before `commitTime`, because that word is already committed. Display `committed + tail`.

**Commit rule.** A word is committed when all four conditions hold:
1. It appears in the shared prefix of this tick's tail and the previous tick's tail, meaning it was stable across 2 consecutive decodes.
2. It ends at least **1.5 s** before the live edge.
3. The cut falls at a boundary: the word ends in `.,?!:;` *or* is followed by a gap of at least 0.2 s.
4. At least one later word exists.

If the window would exceed a cap of **14 s**, the stability requirement is waived. This keeps every decode in one encoder pass. The cap was never hit: windows stayed at 5–13 s and there were 0 forced commits.

| model | cadence | clip | lat p50/p95/max ms | duty | CPU s/audio s | energy J | upd. w/ rewrite raw/norm | words rewritten raw/norm | max depth | preview WER vs full |
|---|---|---|---|---|---|---|---|---|---|---|
| v2 | 300 | 62.2 s | 44/84/281 | 19% | 0.075 | 19.5 | 39/11 of 208 | 183/32 | 15 | 0.5% |
| **v2** | **500** | 13.2 s | 46/219†/242 | 13% | 0.046 | 2.5 | 8/4 of 27 | 37/10 | 12 | 5.3%‡ |
| **v2** | **500** | 29.7 s | 44/49/82 | 9% | 0.042 | 5.5 | 12/2 of 60 | 72/4 | 15 | 0.0% |
| **v2** | **500** | 62.2 s | **43/48/50** | **9%** | **0.043** | **12.3** | 28/5 of 125 | 172/15 | 18 | 0.5% |
| v2 | 1000 | 62.2 s | 50/63/102 | 5% | 0.028 | 6.6 | 18/1 of 63 | 200/1 | 29 | 0.5% |
| Ultra | 500 | 29.7 s | 48/61/64 | 10% | 0.100 | 9.9 | 12/9 | 68/58 | 18 | 0.0% |
| Ultra | 500 | 62.2 s | 51/67/83 | 10% | 0.112 | 23.2 | 24/8 | 118/16 | 14 | 0.5% |
| Ultra | 1000 | 62.2 s | 55/66/75 | 6% | 0.062 | 12.4 | 10/3 | 51/6 | 10 | 0.5% |

† Contention spike. ‡ This is one word ("3.15" vs "3:15") in a 19-word clip.

For 60 s on v2 at 500 ms, compared with the full-buffer strategy (a):
- latency drops from 98 to **43 ms** and stays flat;
- CPU drops by **4.5×**, from 0.192 to 0.043;
- energy proxy drops by **4.3×**, from 52.8 to 12.3 J;
- normalized rewrites drop from 191 to 15 words, and depth is bounded at 18 words, all inside the uncommitted tail.

Sensitivity (v2 at 500 ms; see `results/tail.jsonl`):
- **Holdback.** 1.0 s gives similar flicker. 2.5 s adds more raw rewrites.
- **Context.** 0.5 s context is slightly cheaper (40 ms) but increases rewrites on c30. 4 s context costs more and adds a 2% seam error on c30. **2 s is the sweet spot.**
- **Cadence.** 300 ms roughly doubles the cost for little UX gain. 1000 ms halves the cost again but makes the tail visibly laggy.

### M1 Pro concern (not measured)
On M5, the per-update cost is about 43 ms with 9% duty. If the M1 Pro ANE is 2–3× slower (the S1b assumption), expect about 90–130 ms per update and 20–25% duty at a 500 ms cadence. That is still within cadence, but the preview then competes with the final pass, which waits behind an in-flight preview on the same `AsrManager` actor (worst case +1 update latency at key release). Run `./run_bench.sh` on the M1 Pro. If p95 exceeds 250 ms, drop to a 1000 ms cadence, or use an adaptive cadence of `max(500 ms, 3× last latency)`. Keep Ultra previews off on M1: Ultra's CPU-side decode costs 2.5× v2's.

### Recommended design (Part 1)
1. **Engine.** Reuse the dictation `AsrManager` that is already loaded, as a separate preview task. Do not bundle a streaming model. Use **v2 for the preview even when Ultra is the final model**, *only if* both are already resident. Otherwise use the selected model.
2. **Cadence.** **500 ms**, and skip a tick if the previous one is still running (never queue). Start after 0.5 s of voiced audio, since VAD is already in the pipeline.
3. **Window.** Decode from the committed point minus 2 s of context up to the live edge. Cap the window at 14 s so it never spills into a second encoder pass.
4. **Commit rule.** Commit a word when it is stable across 2 decodes, ends at least 1.5 s before the edge, and sits at punctuation or a pause of 0.2 s or more. Force a commit at the cap. Committed text is frozen and never re-rendered. Render the tail in a lighter colour.
5. **Final insert stays as it is today.** At key release, cancel the preview and run the normal full-buffer pass (plus cleanup). The preview is display-only, so its seam artefacts (a mid-sentence lowercase "first", "and") never reach the inserted text.
6. **Expected cost on M5.** About 43 ms every 500 ms (9% ANE duty) and about 0.04 CPU-s per audio-second, roughly 2–4% of one core. The cost is flat in dictation length.

## Part 2: Apple Translation framework (macOS 26)

### Feasibility findings
- **A headless CLI works.** On macOS 26 SDK, `TranslationSession(installedSource:target:)` (plus a 26.4 overload with `preferredStrategy: .lowLatency | .highFidelity`) constructs in about 1 ms. It needs no SwiftUI `.translationTask` and no AppKit host. The session has `canRequestDownloads == false`, so it **can never trigger a download**. When the pack is missing, `translate()` throws `TranslationError.Cause.notInstalled` in 7–14 ms. A SwiftUI or AppKit host is only needed for the *download prompt* path (`.translationTask` with a Configuration).
- **Pack availability on this Mac** (`LanguageAvailability().status(from: en-US, to:)`): fr, de, es, it, pt-BR, ja, zh-Hans, ko and nl are all **`supported`, none `installed`**. Twenty-one languages are supported in total (`results/translate_availability.txt`). The system has the UAF translation asset catalogs registered, but no en→X model is downloaded.
- **Stopped here, per the brief.** The quality run (15 sentences) and the incremental run were **not executed**. Both are implemented and ready: `S5Translate quality fr [low|high]` covers per-sentence cold and warm latency, the batch API and outputs, and `S5Translate incremental fr` covers word-by-word growing-prefix latency and the stable-prefix ratio. To run them, install en→fr/de/es in **System Settings › General › Language & Region › Translation Languages**. That is a one-time Apple download made by the user, not by our app. Then rerun the commands.

### Recommended designs (provisional until the quality and latency run)
- **(i) Live translated preview.** Translate only the **committed prefix** from Part 1, sentence by sentence as each sentence commits, and cache the results by sentence. Never translate the volatile tail. Re-translating a growing partial makes translation flicker worse than ASR flicker, because word order changes in de and fr. Show the translated preview one sentence behind the transcript. Use the `.lowLatency` strategy for the preview. The latency target to check is under 150 ms per sentence; this is unmeasured.
- **(ii) "Dictate in English, insert in <language>" mode.** On release, take the final cleaned English text and send it through one `translations(from:)` batch call, split into sentences, with `.highFidelity`. Then insert the result. When the pack is missing, show a settings deep link: we never download, and the session cannot download anyway. Keep it **opt-in per target language**, and also keep the English text in History. Before shipping, verify with a packet capture that `translationd` makes no network calls once a pack is installed.

## Blockers / open items
1. Translation packs are not installed, so Part 2 quality and latency are unmeasured. This needs the maintainer's go-ahead to install en→fr/de/es through System Settings.
2. The M1 Pro is unmeasured (`./run_bench.sh`).
3. The energy proxy excludes the ANE. A true power figure needs `sudo powermetrics --samplers ane_power,cpu_power` during `run_bench.sh`.
4. The voices are synthetic. Real speech has more disfluency, which will raise tail flicker but should not change cost.

## Files
- `Package.swift` defines the standalone SwiftPM package (FluidAudio 0.17.5 exact), with targets `S5Live` and `S5Translate`.
- `Sources/S5Live/main.swift` contains the full / tail / probe / sliding modes, the rusage, energy and flicker accounting, and WER.
- `Sources/S5Translate/main.swift` contains the availability / headless / quality / incremental modes.
- `offline.sb` is the sandbox profile that denies network. `run_bench.sh` reruns everything, and `scripts/summarize.py` builds the table.
- `Fixtures/` holds the `say`-generated clips and reference texts. `results/` holds the raw outputs.
