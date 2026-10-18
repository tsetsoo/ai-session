#!/usr/bin/env bash
# Create a reusable local code-signing identity for the Mac app.
#
# Ad-hoc signatures change every build, and the login keychain trusts an app by
# its designated requirement. A stable certificate keeps that requirement the
# same, so SSH keys and the hub token stop prompting after one Allow.
#
# The certificate lives only in this Mac's login keychain. Other Macs create
# their own on first build. It is not an Apple Developer certificate.
set -euo pipefail

CERT_NAME="AI Session Remote Local"
OPENSSL="/usr/bin/openssl"

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"${CERT_NAME}\""; then
  exit 0
fi

KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
if [[ ! -f "$KEYCHAIN" ]]; then
  KEYCHAIN="${HOME}/Library/Keychains/login.keychain"
fi

trust_certificate() {
  local pem="$1"
  # Makes the identity show up in `security find-identity -p codesigning`.
  # The first run on a Mac can ask once for permission to change trust settings.
  security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$pem"
}

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  exported="$(mktemp)"
  security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" >"$exported"
  trust_certificate "$exported"
  rm -f "$exported"
  if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"${CERT_NAME}\""; then
    exit 0
  fi
  # A certificate without its private key cannot sign. Replace it.
  security delete-identity -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1 \
    || security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1 \
    || true
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"${work}/cert.cfg" <<EOF
[ req ]
distinguished_name = req_dn
x509_extensions = codesign_ext
prompt = no
[ req_dn ]
CN = ${CERT_NAME}
[ codesign_ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -config "${work}/cert.cfg" \
  -keyout "${work}/key.pem" \
  -out "${work}/cert.pem" >/dev/null 2>&1

# A one-shot password for the PKCS#12 blob. The key is unlocked for codesign
# on import (-A); this password is not kept.
pkcs_pass="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export \
  -inkey "${work}/key.pem" \
  -in "${work}/cert.pem" \
  -out "${work}/cert.p12" \
  -passout "pass:${pkcs_pass}" >/dev/null 2>&1

# -A lets codesign use the key without a keychain prompt on later builds.
security import "${work}/cert.p12" \
  -k "$KEYCHAIN" \
  -P "$pkcs_pass" \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

trust_certificate "${work}/cert.pem"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"${CERT_NAME}\""; then
  echo "Created \"${CERT_NAME}\" but it is not a code-signing identity." >&2
  exit 1
fi

echo "Created local code-signing identity \"${CERT_NAME}\" in the login keychain." >&2
