#!/bin/bash
# Build-time gate (STRUCTURAL). Brings the release build up to date, touches ONE SwiftUI view,
# times the incremental `swift build -c release`, and FAILS if it takes longer than the budget.
# Healthy on an M-series Mac (2026-10-04, Swift 6.4 / swiftbuild): ~8 s incremental, ~80 s clean.
#   scripts/check_build_time.sh                    # budget 180 s, touches SettingsView.swift
#   BUDGET_SECONDS=120 VIEW=Sources/WisprLocal/HUD.swift scripts/check_build_time.sh
# It also prints CPU utilisation ((user+sys)/wall). A slow build at LOW utilisation means the
# build was waiting (another build or test run, a lock, a starved machine), not compiling; a slow
# build at HIGH utilisation means the code got more expensive to compile (look for a slow
# type-check with -warn-long-expression-type-checking).
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"
BUDGET_SECONDS="${BUDGET_SECONDS:-180}"
VIEW="${VIEW:-Sources/WisprLocal/SettingsView.swift}"
[ -f "$VIEW" ] || { echo "ERROR: $VIEW not found" >&2; exit 2; }
BUILD=(swift build --disable-automatic-resolution -c release)
TIMES="$(mktemp -t wisprlocal-buildtime)"
trap 'rm -f "$TIMES"' EXIT

echo "==> warm-up: bring the release build up to date (not timed)"
# `|| true`: no matching line must not abort under pipefail (the build's own status still does).
"${BUILD[@]}" 2>&1 | { grep -E '^\[ *[0-9]+ */ *[0-9]+\]|Build complete|error:' || true; } | awk 'NR % 25 == 1 || /Build complete|error:/'

echo "==> touch $VIEW; timing the incremental release build (budget ${BUDGET_SECONDS} s)"
touch "$VIEW"
TIMEFORMAT='%R %U %S'
{ time "${BUILD[@]}" 2>&1 | { grep -E '^\[ *[0-9]+ */ *[0-9]+\]|Build complete|error:' || true; } ; } 2>"$TIMES"
read -r REAL USER_CPU SYS_CPU <"$TIMES"
UTIL="$(awk -v r="$REAL" -v u="$USER_CPU" -v s="$SYS_CPU" 'BEGIN { printf "%.0f", (r > 0 ? 100 * (u + s) / r : 0) }')"
echo "    wall ${REAL} s, user ${USER_CPU} s, sys ${SYS_CPU} s, CPU utilisation ${UTIL}%"

if awk -v r="$REAL" -v b="$BUDGET_SECONDS" 'BEGIN { exit !(r > b) }'; then
  echo "FAIL: incremental release build took ${REAL} s (> ${BUDGET_SECONDS} s)" >&2
  if [ "$UTIL" -lt 50 ]; then
    echo "      Utilisation ${UTIL}%: the build was mostly WAITING, not compiling. Check for" >&2
    echo "      other builds or test runs, and for machine load ($(sysctl -n vm.loadavg)):" >&2
    ps -axo pid,pcpu,etime,command | grep -E 'swift-(build|frontend|test)|xcodebuild|sourcekit-lsp' \
      | grep -v grep | cut -c1-160 >&2 || true
  else
    echo "      Utilisation ${UTIL}%: the compiler is doing more work. Rebuild with" >&2
    echo "      -Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=200 to find it." >&2
  fi
  exit 1
fi
echo "OK: incremental release build ${REAL} s (budget ${BUDGET_SECONDS} s)"
