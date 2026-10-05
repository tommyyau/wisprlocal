#!/bin/bash
# The full local gate, in order: zero warnings -> swift test -> the offline (network-denied) suite
# -> the incremental release build-time gate (last: it rebuilds in release).
# Stops at the first failure. Run before every PR. RepoHygieneTests pins this list.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "### 1/4 warnings";   scripts/check_warnings.sh
echo "### 2/4 swift test"; swift test --disable-automatic-resolution
echo "### 3/4 offline";    scripts/test_offline.sh
echo "### 4/4 build time"; scripts/check_build_time.sh
echo "### ci: all green"
