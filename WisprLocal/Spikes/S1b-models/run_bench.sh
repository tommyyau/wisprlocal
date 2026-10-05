#!/bin/bash
# S1b: reproduce the Parakeet Ultra / Phonon-2 latency, RSS, stability and WER numbers on this Mac
# (written for an M1 Pro 16 GB; works on any Apple Silicon Mac running macOS 15+).
#
#   ./run_bench.sh                     full run: build, download if missing, first-ever compile, cold load,
#                                      latency + WER (network-denied sandbox), 500-call soak, escalation check
#   ./run_bench.sh --quick             skip first-ever compile + soak (about 2 min once models are compiled)
#   ./run_bench.sh --with-v2           also benchmark the Parakeet TDT v2 baseline
#   ./run_bench.sh --my-voice <dir>    ONLY score your own recordings: <dir>/*.wav (any rate / channels) plus
#                                      <dir>/transcripts.txt with one "<file name><TAB><exact text>" per line.
#                                      Reports WER for Ultra vs Phonon-2.
#
# Needs: Xcode or Command Line Tools (swift), python3. Internet only for the first build (SwiftPM fetches
# FluidAudio 0.17.5) and the one-time model download (~1 GB). Everything measured runs under sandbox-exec
# with the network denied. Results: results/run_<host>_<timestamp>/ (summary.txt + raw logs).
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)

MODELS="ultra phonon2"
QUICK=0; MYVOICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --with-v2) MODELS="ultra phonon2 v2" ;;
    --my-voice) MYVOICE="${2:?--my-voice needs a directory}"; shift ;;
    -h|--help) sed -n 2,17p "$0"; exit 0 ;;
    *) echo "unknown arg $1"; exit 2 ;;
  esac
  shift
done

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$HERE/results/run_$(sysctl -n machdep.cpu.brand_string | tr -d ' ')_$STAMP"
mkdir -p "$OUT" results/raw
SUM="$OUT/summary.txt"
log() { echo "$*" | tee -a "$SUM"; }
SANDBOX='(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))'
BIN="$HERE/.build/release/S1bModels"

log "== S1b run $STAMP"
log "host: $(sysctl -n machdep.cpu.brand_string) / $(( $(sysctl -n hw.memsize) / 1073741824 )) GB / macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
[ "$(uname -m)" = "arm64" ] || { log "ERROR: Apple Silicon required"; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ] || { log "ERROR: macOS 15+ required (Phonon-2 needs iOS18/macOS15 ops)"; exit 1; }

log "-- build (release)"
swift build -c release 2>&1 | tail -1 | tee -a "$SUM"

log "-- models (download only if missing; this is the only networked step)"
for m in $MODELS; do
  case $m in ultra) d=parakeet-ultra ;; phonon2) d=phonon-2 ;; v2) d=parakeet-tdt-0.6b-v2 ;; esac
  if [ ! -d "Models/$d/Encoder.mlmodelc" ]; then "$BIN" download $m | tee -a "$SUM"; fi
  log "disk $m: $(du -sh Models/$d | cut -f1) ($(find Models/$d -type f -exec stat -f %z {} + | awk '{s+=$1}END{printf "%.1f MB", s/1e6}'))"
done

# ---------- my-voice mode ----------
if [ -n "$MYVOICE" ]; then
  [ -f "$MYVOICE/transcripts.txt" ] || { log "ERROR: $MYVOICE/transcripts.txt missing"; exit 1; }
  for m in ultra phonon2; do
    "$BIN" load $m >/dev/null 2>&1 || true   # make sure the ANE plan is compiled before timing
    sandbox-exec -p "$SANDBOX" "$BIN" myvoice $m "$MYVOICE" 2>&1 | grep -v E5RT | tee "$OUT/myvoice_$m.log" | grep -E "HYPS|ERROR" | tee -a "$SUM"
    cp results/raw/myvoice_$m.jsonl "$OUT/"
  done
  python3 scripts/score.py myvoice "$MYVOICE/transcripts.txt" "$OUT/myvoice_ultra.jsonl" "$OUT/myvoice_phonon2.jsonl" | tee -a "$SUM"
  U=$(grep "^MYVOICE ultra" "$SUM" | sed -E 's/.*WER=([0-9.]+).*/\1/'); P=$(grep "^MYVOICE phonon2" "$SUM" | sed -E 's/.*WER=([0-9.]+).*/\1/')
  if python3 -c "import sys; sys.exit(0 if float('$P') < float('$U') else 1)"; then
    log "ESCALATE: Phonon-2 beats Ultra on your voice ($P % vs $U %)"; else log "OK: Ultra >= Phonon-2 on your voice ($U % vs $P %)"; fi
  log "summary: $SUM"; exit 0
fi

# ---------- fixtures ----------
if [ ! -f Fixtures/manifest.json ]; then
  log "-- generating fixtures (needs numpy)"
  python3 -c "import numpy" 2>/dev/null || python3 -m pip install --user numpy
  python3 scripts/make_fixtures.py | tee -a "$SUM"
fi

# ---------- first-ever ANE compile (fresh process name => empty e5rt cache) ----------
if [ $QUICK = 0 ]; then
  log "-- first-ever ANE compile (one fresh process name per model)"
  for m in $MODELS; do
    name="s1bfirst_${m}_$STAMP"; cp "$BIN" "$HERE/.build/$name"
    /usr/bin/time -l "$HERE/.build/$name" load $m > "$OUT/firstever_$m.txt" 2>&1 || true
    log "first-ever $m: $(grep -o 'load_ms=[0-9.]*' "$OUT/firstever_$m.txt") $(grep -o 'footprint_mb=[0-9.]*' "$OUT/firstever_$m.txt") maxRSS=$(awk '/maximum resident/{printf "%.0f MB", $1/1048576}' "$OUT/firstever_$m.txt")"
    rm -f "$HERE/.build/$name"; rm -rf "$HOME/Library/Caches/$name"   # our own throwaway compile cache
  done
fi

log "-- warm-up compile for the main binary (no-op if already cached)"
for m in $MODELS; do "$BIN" load $m 2>&1 | grep -o 'load_ms=[0-9.]*' | sed "s/^/warm-up $m /" | tee -a "$SUM"; done

log "-- cold load, ANE cache warm (3 fresh processes each, network denied)"
for m in $MODELS; do
  for k in 1 2 3; do
    /usr/bin/time -l sandbox-exec -p "$SANDBOX" "$BIN" load $m > "$OUT/cold_${m}_$k.txt" 2>&1
    log "cold $m #$k: $(grep -o 'load_ms=[0-9.]*' "$OUT/cold_${m}_$k.txt") $(grep -o 'first_transcribe_ms=[0-9.]*' "$OUT/cold_${m}_$k.txt") maxRSS=$(awk '/maximum resident/{printf "%.0f MB", $1/1048576}' "$OUT/cold_${m}_$k.txt")"
  done
done

log "-- latency (first + median of 5) and one pass over all fixtures for WER (network denied)"
for m in $MODELS; do
  /usr/bin/time -l sandbox-exec -p "$SANDBOX" "$BIN" bench $m > "$OUT/bench_$m.txt" 2>&1
  grep -E "^LAT|ERROR" "$OUT/bench_$m.txt" | tee -a "$SUM"
  log "bench $m: peak RSS $(awk '/maximum resident/{printf "%.0f MB", $1/1048576}' "$OUT/bench_$m.txt"), peak footprint $(awk '/peak memory footprint/{printf "%.0f MB", $1/1048576}' "$OUT/bench_$m.txt")"
  cp results/raw/hyps_$m.jsonl "$OUT/"
done
python3 scripts/score.py wer $(for m in $MODELS; do echo "$OUT/hyps_$m.jsonl"; done) | tee -a "$SUM"

if [ $QUICK = 0 ]; then
  log "-- stability soak: 500 sequential mixed clips per model, 10 s per-call watchdog (network denied)"
  for m in $MODELS; do
    set +e; sandbox-exec -p "$SANDBOX" "$BIN" soak $m 500 900 > "$OUT/soak_$m.txt" 2>&1; rc=$?; set -e
    grep -E "SOAK_END|HANG|ERROR" "$OUT/soak_$m.txt" | tee -a "$SUM"
    [ $rc = 0 ] || log "ESCALATE: soak $m exited rc=$rc (3 = hang watchdog, other = crash/error)"
    cp results/raw/soak_$m.jsonl "$OUT/"
  done
fi

log "-- escalation check (Ultra = primary)"
ESC=0
U30=$(grep "^LAT ultra s1/clip30" "$SUM" | grep -o 'median5_ms=[0-9.]*' | cut -d= -f2)
URSS=$(awk '/maximum resident/{print int($1/1048576)}' "$OUT/bench_ultra.txt")
if [ -z "$U30" ]; then log "ESCALATE: Ultra produced no latency result (failed to load/run?)"; ESC=1
elif python3 -c "import sys; sys.exit(0 if float('$U30') > 2000 else 1)"; then log "ESCALATE: Ultra 28 s clip median ${U30} ms > 2000 ms"; ESC=1
else log "OK: Ultra 28 s clip median ${U30} ms (limit 2000)"; fi
if [ "${URSS:-0}" -gt 2048 ]; then log "ESCALATE: Ultra peak RSS ${URSS} MB > 2 GB"; ESC=1; else log "OK: Ultra peak RSS ${URSS} MB (limit 2048)"; fi
UW=$(grep "^| clean (S1" "$SUM" | tail -1 | awk -F'|' '{print $3}' | tr -dc '0-9.')
PW=$(grep "^| clean (S1" "$SUM" | tail -1 | awk -F'|' '{print $4}' | tr -dc '0-9.')
if python3 -c "import sys; sys.exit(0 if float('$PW') < float('$UW') else 1)"; then log "ESCALATE: Phonon-2 clean WER $PW % < Ultra $UW %"; ESC=1
else log "OK: Ultra clean WER $UW % <= Phonon-2 $PW %"; fi
grep -q "^HANG" "$OUT"/soak_*.txt 2>/dev/null && { log "ESCALATE: hang during soak"; ESC=1; } || true
log "escalation: $([ $ESC = 1 ] && echo YES || echo none)"
log "summary: $SUM"
