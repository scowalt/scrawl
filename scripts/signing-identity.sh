#!/usr/bin/env bash
# Makes (once) and unlocks the self-signed code-signing identity Scrawl Remote is signed with,
# then prints the keychain path. macOS keeps Screen Recording, Microphone and Accessibility
# grants against the signature's designated requirement: an ad-hoc signature's is its cdhash,
# which every rebuild changes, while a certificate's is the bundle id plus the certificate,
# which rebuilds keep. Local builds and the release workflow (docs/fork-release.md) sign with the
# same identity, so an update keeps the grants.
#
# The identity is ~/.config/scrawl-remote/signing/identity.p12 (and its password), made here
# once. CI passes it instead as SCRAWL_SIGNING_P12 (base64) and SCRAWL_SIGNING_P12_PASSWORD.
# Either way it goes into its own keychain, unlocked with a generated password, so signing never
# prompts and the login keychain is left alone.
set -euo pipefail

NAME="Scrawl Remote Signing"

if [[ -n "${SCRAWL_SIGNING_P12:-}" ]]; then
  STATE_DIR="$(mktemp -d)"
  KEYCHAIN="${RUNNER_TEMP:-${STATE_DIR}}/scrawl-remote-signing.keychain-db"
  P12="${STATE_DIR}/identity.p12"
  printf '%s' "${SCRAWL_SIGNING_P12}" | base64 --decode > "${P12}"
  P12_PASSWORD="${SCRAWL_SIGNING_P12_PASSWORD:?SCRAWL_SIGNING_P12_PASSWORD is required with SCRAWL_SIGNING_P12}"
else
  STATE_DIR="${HOME}/.config/scrawl-remote/signing"
  KEYCHAIN="${HOME}/Library/Keychains/scrawl-remote-signing.keychain-db"
  P12="${STATE_DIR}/identity.p12"
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"
  if [[ ! -s "${STATE_DIR}/identity-password" ]]; then
    (umask 077 && /usr/bin/openssl rand -hex 24 > "${STATE_DIR}/identity-password")
  fi
  P12_PASSWORD="$(cat "${STATE_DIR}/identity-password")"
  if [[ ! -s "${P12}" ]]; then
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
    (umask 077 && /usr/bin/openssl pkcs12 -export -inkey "${work}/key.pem" -in "${work}/cert.pem" \
      -name "${NAME}" -passout "pass:${P12_PASSWORD}" -out "${P12}")
  fi
fi

KEYCHAIN_PASSWORD_FILE="$(dirname "${P12}")/keychain-password"
if [[ ! -s "${KEYCHAIN_PASSWORD_FILE}" ]]; then
  (umask 077 && /usr/bin/openssl rand -hex 24 > "${KEYCHAIN_PASSWORD_FILE}")
fi
KEYCHAIN_PASSWORD="$(cat "${KEYCHAIN_PASSWORD_FILE}")"

if [[ ! -f "${KEYCHAIN}" ]]; then
  security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
fi
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
# No auto-lock, so a build an hour from now still signs.
security set-keychain-settings "${KEYCHAIN}"

if ! security find-certificate -c "${NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
  security import "${P12}" -k "${KEYCHAIN}" -P "${P12_PASSWORD}" -T /usr/bin/codesign >/dev/null
  # Lets codesign use the key without a "codesign wants to access key" prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PASSWORD}" \
    "${KEYCHAIN}" >/dev/null
fi

if [[ -n "${SCRAWL_SIGNING_P12:-}" ]]; then
  # A CI runner's codesign only finds identities in keychains on the search list.
  existing=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    existing+=("${line//\"/}")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${KEYCHAIN}" "${existing[@]}"
  security find-identity -p codesigning "${KEYCHAIN}" >&2
fi

echo "${KEYCHAIN}"
