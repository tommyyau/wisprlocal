#!/bin/bash
# Build the tests normally (SwiftPM may need the network to resolve packages), then run the
# whole built suite under sandbox-exec with ALL network denied. `swift test` itself can't run
# inside the sandbox (manifest compile fails), so we invoke SwiftPM's testing helper directly.
# WISPRLOCAL_REQUIRE_MODELS=1 (default here; legacy WISPRLITE_REQUIRE_MODELS also honoured) turns "models absent -> skip" into a failure.
# Socket-dependent and opt-in tests are skipped: WISPRLOCAL_NO_SOCKETS=1 disables
# BridgeLoopbackTests and socket-dependent parts of RemoteSecureInputTests and
# TailscaleInterfaceTests. Private-denylist and Foundation Models tests are environment-gated;
# benchmarks are opt-in. `swift test` runs socket-dependent tests outside this sandbox.
# Models: $WISPRLOCAL_MODELS_DIR (or legacy $WISPRLITE_MODELS_DIR) wins; else the tests use this
# checkout's .models-cache. In a git worktree that cache is usually absent, so fall back to the
# same relative path in the main checkout (parent of `git rev-parse --git-common-dir`).
set -euo pipefail
cd "$(dirname "$0")/.."
MODELS_DIR="${WISPRLOCAL_MODELS_DIR:-${WISPRLITE_MODELS_DIR:-}}"
if [ -z "$MODELS_DIR" ] && [ ! -d .models-cache ]; then
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  prefix="$(git rev-parse --show-prefix 2>/dev/null || true)"
  if [ -n "$common" ] && [ -d "$(dirname "$common")/${prefix}.models-cache" ]; then
    MODELS_DIR="$(dirname "$common")/${prefix}.models-cache"
    echo "models: using the main checkout's cache $MODELS_DIR"
  fi
fi
swift build --disable-automatic-resolution --build-tests
DEV="$(xcode-select -p)"
PD="$DEV/Platforms/MacOSX.platform/Developer"
HELPER="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
BUNDLE="$(swift build --disable-automatic-resolution --show-bin-path)/WisprLocalCoreTests.xctest/Contents/MacOS/WisprLocalCoreTests"
P='(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))'
echo "sanity: network must be blocked inside the sandbox:"
if sandbox-exec -p "$P" /usr/bin/curl -sS -m 5 -o /dev/null https://example.com 2>/dev/null; then
  echo "ERROR: network reachable inside sandbox" >&2; exit 1
fi
echo "  blocked."
MODELS_ENV=()
if [ -n "$MODELS_DIR" ]; then MODELS_ENV=(WISPRLOCAL_MODELS_DIR="$MODELS_DIR"); fi
# DYLD_* is stripped when entering SIP-protected sandbox-exec, so set it via env inside.
sandbox-exec -p "$P" /usr/bin/env \
  DYLD_FRAMEWORK_PATH="$PD/Library/Frameworks" DYLD_LIBRARY_PATH="$PD/usr/lib" \
  WISPRLOCAL_REQUIRE_MODELS="${WISPRLOCAL_REQUIRE_MODELS:-${WISPRLITE_REQUIRE_MODELS:-1}}" WISPRLOCAL_NO_SOCKETS=1 \
  ${MODELS_ENV[@]+"${MODELS_ENV[@]}"} \
  "$HELPER" --test-bundle-path "$BUNDLE" --testing-library swift-testing "$@"
