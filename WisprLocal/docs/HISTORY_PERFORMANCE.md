# History performance

History I/O belongs to `HistoryIndex` (`App/Sources/WisprLocalCore/History/HistoryIndex.swift:5`). It seeks backwards in 64 KiB chunks, publishes the recent window, then decodes the complete file off the main actor. File order, duplicate occurrences and byte-derived legacy identities are preserved. The initial page contains Today and Yesterday and at least 200 visible entries where available; subsequent requests expand it by seven days. Search uses cached case/diacritic folding, confirms candidates with `localizedCaseInsensitiveContains`, and has independent paging state.

Per-day buckets hold counts, words, speaking time and sorted timestamp/word prefixes. Dashboard calculations visit days rather than the full entry list, including exact partial-day retention and future-timestamp boundaries. Insights retains its existing accumulators and cleanup cache, with explicit append/remove operations. A deletion rebuilds only affected day buckets; surviving entries are not re-ingested into Insights.

Deletion and clearing publish memory changes before disk work; failed rewrites reconcile rows with disk and expose Retry. Rewrites filter original JSONL bytes by identity on the append queue; untouched lines remain byte-identical apart from repairing a missing final newline. Queue ordering protects concurrent appends. `flush()` awaits submitted appends and rewrites and propagates rewrite errors. App termination awaits it. Recording pairs follow deletions, and the orphan sweep uses in-memory identities after complete loading. Unused legacy library APIs were removed. Full-file helpers are internal and live beside the index; playback and retention tests exercise the actor.

`HistoryPresentation` (`App/Sources/WisprLocalCore/History/HistoryPresentation.swift:7`) owns the main-actor cache: a bounded recent window, loaded day groups, diagnostics, stats and Insights. New dictations update that cache through deltas. `AppModel` subscribes instead of rereading on revision; day rollover and system time-zone changes rebuild day buckets and refresh cached summaries and titles. Search invalidates on every index event, immediately removes deleted ids, and rejects stale results. Microphone diagnostics retain the last 20 *measured* dictations, even when unmeasured attempts intervene.

History exposes a virtual flat collection to `Page`'s `LazyVStack` (`App/Sources/WisprLocal/HistoryView.swift:31`). Individual rows draw card slices, continuous side borders, exterior shadows and the original dividers. Rows use the entry id as stable identity, with card position kept separately, so appends preserve row state. They receive plain playback/dictation/clip values; SwiftUI may still reevaluate them as observed model state changes. The three-dot menu glyph is drawn directly because its native symbol deferred drawing in offscreen lazy rows. Home's polling-dependent hero is a separate view (`App/Sources/WisprLocal/HomeView.swift:168`).

`DictionaryStore` caches replacement compilation by content, normalised snippet triggers and the vocabulary snapper index (`App/Sources/WisprLocalCore/Dictionary/DictionaryStore.swift:151`). Editors synchronously enqueue saves before starting their completion Tasks, preserving edit order on a serial background queue. Learning uses the same queue. Context names use a small overlay over the immutable vocabulary index. Learning mutations operate on the latest committed dictionary so concurrent additions survive. Unchanged dictionaries do not recompile during dictation.

## Measurements

The UI measurement uses a seeded 10,000-entry history, 150 entries per day, and the DEBUG preview harness for the baseline and updated implementation.

The timer covers window creation, layout, the settling run loop and display. It records main-thread CPU before bitmap export. Wall time includes a 450 ms settling interval; that interval is not subtracted from CPU time. These are local samples from DEBUG builds. They do not measure release builds or interactive mouse input. The measured CPU reduction is about 324-fold.

| Check | Measured result | Budget |
| --- | ---: | ---: |
| Baseline: History open, 10,000 entries | 24,759.21 ms CPU | baseline |
| Updated History open, 10,000 entries | 76.52 ms CPU | 150 ms CPU |
| Recent window, 50,000 entries | 9.27 ms | 50 ms |
| Apply append with all 50,000 rows already loaded | 0.111 ms | 2 ms |
| Read cached Home stats | 0.0155 ms | 1 ms |
| Actor bucket stats, 50,000 entries | 0.268 ms | 1 ms |

All automated budgets use `TimingBudget.scale`; the UI harness honours `WISPRLOCAL_TIMING_SCALE` as well.

## Reproduce

From `WisprLocal/App`, after `swift build`:

```sh
mkdir -p .build/history-perf/tmp .build/history-perf/home
TMPDIR="$PWD/.build/history-perf/tmp" \
CFFIXED_USER_HOME="$PWD/.build/history-perf/home" \
WISPRLOCAL_PREVIEW_HISTORY_COUNT=10000 WISPRLOCAL_UI_BENCH=1 \
.build/debug/WisprLocal --ui-preview .build/history-perf/bench --only history
```

`WISPRLOCAL_UI_BENCH=1` measures the first matching screen, asserts the CPU budget and exits the preview without exporting a bitmap. `baseline` measures identically without asserting the new budget. To render PNGs, omit `WISPRLOCAL_UI_BENCH`; omit the count override for the normal reference scenes. The harness remains DEBUG-only.

## Verification

`HistoryIndexTests` adds timeline/day-group parity at 0, 1, 400 and 10,000 entries, concatenated page deltas, DST and out-of-order timestamps, duplicates and legacy lines; seeded append/delete/clear/prune/day-rollover stats and Insights parity; case, diacritic and Unicode search parity; byte-preserving deletion and append/rewrite/load races; partial-day prefixes; main-actor and recent-load budgets; and a structural full-history-I/O scan. `DictionaryCacheTests` adds compilation/output parity, unchanged-rule reuse, off-main compilation, context/tombstone parity and concurrent learning updates. There are 13 added test methods, with parameterised history sizes.

The recorded full suite passed with 888 tests in 156 suites; the network-denied suite also passed all 888 tests. The build warning count was zero, and the tracked-file privacy scan passed.

The normal preview produced 144 PNGs before and after. Insights and every history-detail variant are pixel-identical in light and dark. Home differs only in the hovered menu dots' antialiasing (mean channel difference below 0.001 on a 0–255 scale); its remaining layout and pixels match. History and compact History retain the layout, text, controls, corners and dividers; their per-row card rendering has minor shadow, border and glyph antialiasing differences (largest mean channel difference below 0.18). The PNGs were compared numerically and inspected visually. References, rendered images, comparisons and logs are under the ignored `App/.build/history-perf` directory.
