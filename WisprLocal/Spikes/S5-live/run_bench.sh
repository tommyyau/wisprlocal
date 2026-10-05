#!/bin/zsh
# Re-run the S5 measurements (e.g. on the M1 Pro). Offline: network denied via sandbox-exec.
set -e
cd "$(dirname "$0")"
swift build -c release
B=.build/release; SB="sandbox-exec -f offline.sb"; F=(Fixtures/c05.wav Fixtures/c15.wav Fixtures/c30.wav Fixtures/c60.wav)
mkdir -p results
for m in v2 ultra; do $SB $B/S5Live probe $m Fixtures/c60.wav; done > results/probe.txt 2>/dev/null
(for m in v2 ultra; do for c in 300 500 1000; do $SB $B/S5Live full $m $c $F; done; done) > results/full.jsonl 2>/dev/null
(for m in v2 ultra; do for c in 300 500 1000; do $SB $B/S5Live tail $m $c 14 1.5 $F; done; done) > results/tail.jsonl 2>/dev/null
$SB $B/S5Translate availability > results/translate_availability.txt
python3 scripts/summarize.py
