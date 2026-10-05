#!/bin/bash
# Prints the automated test inventory: tests per suite (from `swift test list`, the same unit
# `swift test` reports — a parameterised test counts once) and @Test annotations per file.
# Use this instead of quoting test counts in docs (they go stale). Builds, runs nothing.
#   scripts/test_inventory.sh            # suites + files + totals
#   scripts/test_inventory.sh --total    # just "N tests / M suites"
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"
LIST="$(swift test list 2>/dev/null | grep -E '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+/' || true)"
if [ -z "$LIST" ]; then echo "ERROR: swift test list returned nothing (does the package build?)" >&2; exit 1; fi
TESTS="$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')"
SUITES="$(printf '%s\n' "$LIST" | sed -E 's#^[^.]+\.([^/]+)/.*#\1#' | sort -u | wc -l | tr -d ' ')"
if [ "${1:-}" = "--total" ]; then echo "$TESTS tests / $SUITES suites"; exit 0; fi

echo "Tests per suite (swift test list):"
printf '%s\n' "$LIST" | sed -E 's#^[^.]+\.([^/]+)/.*#\1#' | sort | uniq -c | sort -k2 | awk '{printf "  %-36s %4d\n", $2, $1}'
echo
echo "@Test annotations per file (Tests/WisprLocalCoreTests):"
for f in Tests/WisprLocalCoreTests/*.swift; do
  n="$(grep -cE '^[[:space:]]*(@MainActor[[:space:]]+)?@Test' "$f" || true)"
  [ "$n" -gt 0 ] && printf '  %-36s %4d\n' "$(basename "$f")" "$n"
done
echo
echo "Total: $TESTS tests / $SUITES suites"
