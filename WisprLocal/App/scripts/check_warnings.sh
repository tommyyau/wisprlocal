#!/bin/bash
# Zero-warnings gate (STRUCTURAL). Builds release, debug and the test targets and FAILS if any
# compiler/linker warning originates in our own code (Sources/, Tests/, Tools/). Warnings from
# dependencies (.build/checkouts) are listed for information only, so an upstream warning never
# breaks a build (which is why this is a script, not -warnings-as-errors in Package.swift).
# SwiftPM only re-emits warnings for files it recompiles, so our sources are touched first to
# force a full recompile of our targets (dependencies stay cached).
#   scripts/check_warnings.sh
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"
LOG="$(mktemp -t wisprlocal-warnings)"
trap 'rm -f "$LOG"' EXIT

find Sources Tests Tools \( -name '*.swift' -o -name '*.c' -o -name '*.h' \) -exec touch {} +
for args in "-c release" "" "--build-tests"; do
  echo "== swift build $args"
  # shellcheck disable=SC2086
  if ! swift build --disable-automatic-resolution $args >>"$LOG" 2>&1; then
    sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' "$LOG" | tail -40 >&2
    echo "ERROR: swift build $args failed" >&2; exit 1
  fi
done

CLEAN="$(sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g; s/\x1B\]8;;[^\x1B]*\x1B\\//g' "$LOG")"
ALL="$(printf '%s\n' "$CLEAN" | grep -E '^[^ ].*:[0-9]+:[0-9]+: warning:|^ld: warning:|^warning:' | sort -u || true)"
OURS="$(printf '%s\n' "$ALL" | grep -E "^$APP_DIR/(Sources|Tests|Tools)/" || true)"
DEPS="$(printf '%s\n' "$ALL" | grep -vE "^$APP_DIR/(Sources|Tests|Tools)/" | grep -v '^$' || true)"

if [ -n "$DEPS" ]; then
  echo "Dependency / toolchain warnings (informational, not ours):"
  printf '%s\n' "$DEPS" | sed "s#^$APP_DIR/##; s/^/  /"
fi
if [ -n "$OURS" ]; then
  echo "ERROR: $(printf '%s\n' "$OURS" | wc -l | tr -d ' ') warning(s) in our code:" >&2
  printf '%s\n' "$OURS" | sed "s#^$APP_DIR/##; s/^/  /" >&2
  exit 1
fi
echo "OK: zero warnings in Sources/, Tests/ and Tools/ (release, debug, tests)."
