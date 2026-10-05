#!/bin/bash
# Create a stable, self-signed code-signing identity "WisprLocal Local Signing" in your login
# keychain, so macOS keeps WisprLocal's Accessibility / Input Monitoring grants across rebuilds.
#
# RUN THIS YOURSELF, ONCE. It changes your keychain; nothing in the build runs it for you.
#   ./scripts/create_signing_identity.sh
# Then: ./scripts/build_app.sh && ./scripts/install.sh, and re-grant the permissions one last time.
#
# ---------------------------------------------------------------------------------------------
# WHY THIS FIXES THE PERMISSION LOSS
# TCC (the privacy database behind System Settings > Privacy & Security) stores, for each grant,
# the app's *designated requirement* (DR) and checks the running binary against it.
#   - Ad-hoc signed:  DR = `cdhash H"<hash of this exact binary>"`  -> every rebuild is a new app.
#   - Self-signed:    DR = `identifier "com.tommyyau.wisprlocal" and certificate leaf = H"<SHA-1 of
#                     this certificate>"` (codesign prints `certificate root = H"…"` for some
#                     self-signed chains; for a single self-signed cert leaf == root, same hash).
#                     Same certificate + same identifier on every build -> same DR -> grants stick.
# build_app.sh prints the DR after signing (`codesign -d -r- <app>`) so you can see this.
#
# NO TRUST SETTINGS ARE NEEDED. The DR pins the certificate by hash; it does not ask whether the
# certificate chains to a trusted root, and TCC only evaluates the DR. Apple TN2206 ("macOS Code
# Signing In Depth"): stability "is determined through the designated requirement (DR)
# mechanism, and does not depend on the nature of the certificate authority used ... Self-signed
# identities and homemade certificate authorities (CA) work by default for this case." (Gatekeeper
# is the exception, and it does not matter for an app you build and run yourself.)
# Consequence you'll notice: `security find-identity -v -p codesigning` (valid-only) still shows
# 0 identities, because the cert is untrusted. `security find-identity -p codesigning` (no -v)
# lists it, and codesign signs with it fine. build_app.sh looks it up without -v.
#
# BETTER ALTERNATIVE (if you have an Apple ID): a free "Apple Development" certificate.
#   Xcode > Settings > Accounts > + (Apple ID) > select your team > Manage Certificates… > + >
#   Apple Development. build_app.sh prefers it automatically. Its DR pins Apple's anchor plus your
#   certificate's subject name, so it also survives certificate renewal.
#
# PROMPTS YOU WILL SEE
#   1. This script: possibly a macOS dialog "security wants to modify the keychain 'login'" or a
#      request for your login keychain password if the keychain is locked. Allow / enter it.
#      (No passphrase is asked for the .p12: the script uses a random one-time passphrase.)
#   2. First build_app.sh afterwards: "codesign wants to sign using key 'WisprLocal Local
#      Signing' in your keychain." Enter your login password and click **Always Allow** (otherwise
#      it asks on every build). The import below already lists /usr/bin/codesign as an allowed
#      application, so this may not appear at all.
#   3. After installing the first stably-signed build: grant Accessibility and Input Monitoring
#      one final time (System Settings > Privacy & Security; if WisprLocal is already listed,
#      select it, click -, then + and add ~/Applications/WisprLocal.app again). From then on
#      rebuilds keep the grants. The app shows a "Relaunch WisprLocal" button once it sees them.
#
# Idempotent: exits without changes if the identity already exists.
# The certificate is valid for 10 years. Replacing it changes the DR (one more re-grant).
# To remove it later: Keychain Access > login > My Certificates > "WisprLocal Local Signing" > Delete.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

NAME="WisprLocal Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Apple's LibreSSL: its PKCS#12 output (3DES/SHA-1) is what `security import` accepts.
# (Homebrew OpenSSL 3 defaults to AES/PBKDF2 .p12 files, which fail with "MAC verification failed".)
OPENSSL=/usr/bin/openssl

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$NAME\""; then
  echo "Signing identity \"$NAME\" already exists — nothing to do."
  security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\""
  exit 0
fi
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "ERROR: a certificate named \"$NAME\" exists but has no usable private key (not a signing identity)." >&2
  echo "Delete it in Keychain Access (login > Certificates) and run this script again." >&2
  exit 1
fi
[ -x "$OPENSSL" ] || { echo "ERROR: $OPENSSL not found" >&2; exit 1; }

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wisprlocal-signing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT   # private key cleanup also runs on INT/TERM
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "$WORK"

cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = codesign_ext
prompt             = no

[ dn ]
CN = $NAME

[ codesign_ext ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
EOF

echo "==> generating RSA-2048 key + self-signed certificate (CN=$NAME, EKU=codeSigning, 10 years)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" x509 -in "$WORK/cert.pem" -noout -subject -enddate -ext extendedKeyUsage 2>/dev/null \
  || "$OPENSSL" x509 -in "$WORK/cert.pem" -noout -subject -enddate

"$OPENSSL" rand -hex 24 > "$WORK/passphrase"
chmod 600 "$WORK/passphrase"
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "file:$WORK/passphrase"

echo "==> importing into $KEYCHAIN (codesign pre-authorised to use the key)"
# one-time random passphrase; briefly visible to same-user processes during import;
# the key is imported non-extractable (-x). -T keeps codesign pre-authorised for the maintainer's
# builds: the trade-off is that any process invoking codesign can request signing with this key.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -x -P "$(cat "$WORK/passphrase")" -T /usr/bin/codesign

echo "==> verifying"
if ! security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\""; then
  echo "ERROR: import finished but \"$NAME\" is not listed as a code-signing identity." >&2
  exit 1
fi
cat <<EOF

Done. "$NAME" is in your login keychain (untrusted by design — see the header; no trust change needed).
Next:
  ./scripts/build_app.sh     # picks "$NAME" automatically and prints the designated requirement
  ./scripts/install.sh
Then re-grant Accessibility + Input Monitoring once (remove WisprLocal with -, add it with +).
EOF
