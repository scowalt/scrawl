#!/usr/bin/env bash
# Makes (once) and unlocks the self-signed code-signing identity Scrawl Remote is signed with,
# then prints the keychain path. macOS keeps Screen Recording, Microphone and Accessibility
# grants against the signature's designated requirement: an ad-hoc signature's is its cdhash,
# which every rebuild changes, while a certificate's is the bundle id plus the certificate,
# which rebuilds keep. The identity lives in its own keychain, unlocked with a password kept
# in a 0600 file, so signing never prompts and the login keychain is left alone.
set -euo pipefail

NAME="${SCRAWL_SIGN_NAME:-Scrawl Remote Local Signing}"
STATE_DIR="${HOME}/.config/scrawl-remote/signing"
KEYCHAIN="${HOME}/Library/Keychains/scrawl-remote-signing.keychain-db"
PASSWORD_FILE="${STATE_DIR}/keychain-password"

mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"
if [[ ! -s "${PASSWORD_FILE}" ]]; then
  (umask 077 && /usr/bin/openssl rand -hex 24 > "${PASSWORD_FILE}")
fi
PASSWORD="$(cat "${PASSWORD_FILE}")"

if [[ ! -f "${KEYCHAIN}" ]]; then
  security create-keychain -p "${PASSWORD}" "${KEYCHAIN}"
fi
security unlock-keychain -p "${PASSWORD}" "${KEYCHAIN}"
# No auto-lock, so a build an hour from now still signs.
security set-keychain-settings "${KEYCHAIN}"

if ! security find-certificate -c "${NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' EXIT
  cat > "${work}/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = ${NAME}
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  # LibreSSL: macOS's `security import` reads its PKCS#12 (OpenSSL 3+ defaults to AES/PBKDF2,
  # which it can't).
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "${work}/cert.cnf" \
    -keyout "${work}/key.pem" -out "${work}/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "${work}/key.pem" -in "${work}/cert.pem" \
    -name "${NAME}" -passout "pass:${PASSWORD}" -out "${work}/identity.p12"
  security import "${work}/identity.p12" -k "${KEYCHAIN}" -P "${PASSWORD}" \
    -T /usr/bin/codesign >/dev/null
  # Lets codesign use the key without a "codesign wants to access key" prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${PASSWORD}" \
    "${KEYCHAIN}" >/dev/null
fi

echo "${KEYCHAIN}"
