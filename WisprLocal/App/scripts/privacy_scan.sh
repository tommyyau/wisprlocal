#!/bin/bash
# privacy_scan.sh — fail if personal data would be (or is) committed.
#
#   scripts/privacy_scan.sh            scan every tracked file (working-tree content)
#   scripts/privacy_scan.sh --staged   scan the staged content of added/changed files (pre-commit hook)
#   scripts/privacy_scan.sh --dir D    scan every text file under directory D (used by tests)
#
# Generic checks (always on; mirrored by Tests/WisprLocalCoreTests/PrivacyGuardTests.swift):
#   - absolute home paths /Users/<name>/ (only the placeholder /Users/x/ is allowed)
#   - *.local hostnames and *.ts.net names (allowed: a label "example", or an exact allowlist entry)
#   - Tailscale/CGNAT IPv4 100.64.0.0/10 (allowed: exact allowlist entries, synthetic test values)
#   - e-mail addresses outside example.com/.org/.net, x.com and noreply.github.com
# Allowlist: scripts/privacy_allowlist.txt (tracked; exact tokens, one per line, # comments).
#
# Private checks: every non-empty line of the PRIVATE denylist
#   ${WISPRLOCAL_PRIVATE_DENYLIST:-$HOME/.config/wisprlocal/private-denylist.txt}
# is a case-insensitive term that must never appear. That file lives OUTSIDE the repo so the
# terms themselves are never committed. If it is missing, the generic checks still run (warning).
#
# Install the hook once per clone (from the repo root):
#   git config core.hooksPath WisprLocal/App/scripts/hooks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="$SCRIPT_DIR/privacy_allowlist.txt"
DENYLIST="${WISPRLOCAL_PRIVATE_DENYLIST:-$HOME/.config/wisprlocal/private-denylist.txt}"

mode=tracked
dir=""
case "${1:-}" in
  "") ;;
  --staged) mode=staged ;;
  --dir) mode=dir; dir="${2:?--dir needs a directory}" ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "privacy_scan: unknown option $1" >&2; exit 2 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/privacy_scan.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
LIST="$WORK/files"   # NUL-separated paths, relative to $BASE
: > "$LIST"

case "$mode" in
  tracked)
    BASE="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
    git -C "$BASE" ls-files -z > "$LIST"
    ;;
  staged)
    TOP="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
    BASE="$WORK/staged"
    mkdir -p "$BASE"
    # Materialise the STAGED blob of each added/copied/modified/renamed file.
    while IFS= read -r -d '' f; do
      mkdir -p "$BASE/$(dirname "$f")"
      git -C "$TOP" show ":$f" > "$BASE/$f" 2>/dev/null || true
      printf '%s\0' "$f" >> "$LIST"
    done < <(git -C "$TOP" diff --cached --name-only -z --diff-filter=ACMR)
    ;;
  dir)
    BASE="$(cd "$dir" && pwd)"
    (cd "$BASE" && find . -type f -not -path './.git/*' -print0) > "$LIST"
    ;;
esac

status=0

# ---- generic checks -------------------------------------------------------------------------
if ! (cd "$BASE" && ALLOWLIST="$ALLOWLIST" perl -e '
  use strict; use warnings;
  my %allow;
  if (open(my $al, "<", $ENV{ALLOWLIST})) {
    while (<$al>) { s/#.*//; s/^\s+|\s+$//g; $allow{lc $_} = 1 if length; }
  }
  local $/ = "\0";
  my @files = <STDIN>; chomp @files;
  my $bad = 0;
  sub example_host { my $h = lc shift; return scalar grep { $_ eq "example" } split /\./, $h; }
  for my $f (@files) {
    next unless -f $f;
    open(my $fh, "<", $f) or next;
    binmode $fh;
    local $/; my $data = <$fh>; close $fh;
    next if $data =~ /\x00/;              # binary
    my $n = 0;
    for my $line (split /\n/, $data, -1) {
      $n++;
      my @hits;
      while ($line =~ m{/Users/([A-Za-z0-9._-]+)/}g) {
        push @hits, "home path /Users/$1/" unless $1 eq "x";
      }
      while ($line =~ /((?:[A-Za-z0-9-]+\.)+local)(?![A-Za-z0-9-])/gi) {
        my $h = $1;
        push @hits, "local hostname $h" unless example_host($h) || $allow{lc $h};
      }
      while ($line =~ /((?:[A-Za-z0-9-]+\.)+ts\.net)(?![A-Za-z0-9-])/gi) {
        my $h = $1;
        push @hits, "tailnet name $h" unless example_host($h) || $allow{lc $h};
      }
      while ($line =~ /(?<![0-9.])(100\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9])/g) {
        my ($ip, $o2) = ($1, $2);
        push @hits, "tailnet IPv4 $ip" if $o2 >= 64 && $o2 <= 127 && !$allow{$ip};
      }
      while ($line =~ /([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)/g) {
        my ($user, $dom) = ($1, lc $2);
        next if $dom =~ /^[0-9]+x\./;      # asset scale suffix: icon@2x.png
        next if $dom =~ /(^|\.)example\.(com|org|net)$/ || $dom eq "x.com" || $dom =~ /(^|\.)noreply\.github\.com$/;
        next if $allow{lc "$user\@$dom"};
        push @hits, "e-mail $user\@$dom";
      }
      for (@hits) { print "$f:$n: $_\n"; $bad = 1; }
    }
  }
  exit $bad;
' < "$LIST"); then
  status=1
fi

# ---- private denylist -----------------------------------------------------------------------
if [ -f "$DENYLIST" ]; then
  TERMS="$WORK/terms"
  grep -v '^[[:space:]]*$' "$DENYLIST" | grep -v '^[[:space:]]*#' > "$TERMS" || true
  if [ -s "$TERMS" ]; then
    hits="$(cd "$BASE" && tr '\0' '\n' < "$LIST" | while IFS= read -r f; do
              [ -f "$f" ] && grep -IHniF -f "$TERMS" -- "$f" || true
            done)"
    if [ -n "$hits" ]; then
      printf '%s\n' "$hits" | sed 's/^/private term: /' | cut -c1-200
      status=1
    fi
  fi
else
  echo "privacy_scan: warning: private denylist not found at $DENYLIST (generic checks only)" >&2
fi

nfiles="$(tr -cd '\0' < "$LIST" | wc -c | tr -d ' ')"
if [ "$status" -ne 0 ]; then
  echo "privacy_scan: FAILED ($mode, $nfiles files). Remove the personal data above, or (for a synthetic" >&2
  echo "test value only) add the exact token to WisprLocal/App/scripts/privacy_allowlist.txt." >&2
  exit 1
fi
echo "privacy_scan: OK ($mode, $nfiles files)"
