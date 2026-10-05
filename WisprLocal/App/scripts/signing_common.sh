# Shared code-signing identity resolution for build_app.sh and build_receiver.sh (source it).
# Sets SIGN_IDENTITY (name/SHA-1, or "-" for ad-hoc) and SIGN_SOURCE. Order:
#   1. $WISPRLOCAL_SIGN_IDENTITY (name or SHA-1; "-" forces ad-hoc). Legacy alias: $SIGN_IDENTITY.
#   2. the first valid "Apple Development" identity.
#   3. "WisprLocal Local Signing" (self-signed; scripts/create_signing_identity.sh), looked up
#      WITHOUT `find-identity -v` because it is untrusted by design.
#   4. ad-hoc ("-").
resolve_sign_identity() {
  LOCAL_IDENTITY_NAME="WisprLocal Local Signing"
  SIGN_SOURCE=""
  SIGN_IDENTITY="${WISPRLOCAL_SIGN_IDENTITY:-${SIGN_IDENTITY:-}}"
  if [ -n "$SIGN_IDENTITY" ]; then
    SIGN_SOURCE="\$WISPRLOCAL_SIGN_IDENTITY"
  else
    # Valid-only list: Apple Development certs chain to Apple's trusted roots.
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/{print $2; exit}')"
    [ -n "$SIGN_IDENTITY" ] && SIGN_SOURCE="Apple Development identity"
  fi
  if [ -z "$SIGN_IDENTITY" ]; then
    # Not -v: the self-signed cert is untrusted (fine — the DR pins it by hash; see create_signing_identity.sh).
    SIGN_IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk -v n="\"$LOCAL_IDENTITY_NAME\"" 'index($0, n) && length($2) == 40 {print $2; exit}')"
    [ -n "$SIGN_IDENTITY" ] && SIGN_SOURCE="$LOCAL_IDENTITY_NAME (self-signed)"
  fi
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
}

# Print the SHA-256 of the signing leaf certificate. Safe to source without building/packaging.
certificate_hash() (
  set -euo pipefail
  work="$(mktemp -d "${TMPDIR:-/tmp}/wisprlocal-cert.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  prefix="$work/cert-"
  codesign -d --extract-certificates="$prefix" "$2" 2>/dev/null || { echo "ERROR: missing signing certificate for $2" >&2; exit 1; }
  [ -s "${prefix}0" ] || { echo "ERROR: missing signing certificate for $2" >&2; exit 1; }
  shasum -a 256 "${prefix}0" | awk '{print $1}'
)
