#!/usr/bin/env bash
# Makes the Developer ID Application certificate release.yml signs the macOS
# build with, and stores it as the repository secrets MACOS_CERTIFICATE_BASE64
# and MACOS_CERTIFICATE_PASSWORD. Developer ID certificates last five years.
#
#     tooling/store/renew_macos_signing.sh [ref]
#
# The same split as renew_ios_signing.sh: the private key and the .p12 exist
# only here, in a temporary directory removed on exit, and leave only
# encrypted, as a secret; ios_signing.yml turns the CSR into the certificate
# with the App Store Connect key, which never leaves GitHub.
#
# Needs gh, logged in with access to the repository's secrets, curl and
# openssl.
set -euo pipefail

ref="${1:-main}"
work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

openssl genrsa -out "$work/key.pem" 2048 2> /dev/null
openssl req -new -key "$work/key.pem" -out "$work/request.csr" \
  -subj "/CN=Sennit CI Developer ID/C=DE"

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
gh workflow run ios_signing.yml --ref "$ref" \
  -f action=developer-id -f csr="$(base64 < "$work/request.csr" | tr -d '\n')"

run=""
for _ in $(seq 30); do
  sleep 5
  run="$(gh run list --workflow ios_signing.yml --event workflow_dispatch \
    --created ">=$since" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [ -n "$run" ] && break
done
[ -n "$run" ] || { echo "the ios_signing.yml run did not start" >&2; exit 1; }
gh run watch "$run" --exit-status > /dev/null
gh run download "$run" --name developer-id-certificate --dir "$work"

cert_key="$(openssl x509 -inform der -in "$work/developer_id.cer" -noout -pubkey)"
own_key="$(openssl pkey -in "$work/key.pem" -pubout)"
[ "$cert_key" = "$own_key" ] || { echo "the certificate is not for this key" >&2; exit 1; }

# The intermediate travels in the .p12, so codesign on the runner can build
# the chain whether or not the image carries it.
curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer \
  | openssl x509 -inform der -out "$work/intermediate.pem"

password="$(openssl rand -base64 24)"
openssl x509 -inform der -in "$work/developer_id.cer" -out "$work/cert.pem"
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -certfile "$work/intermediate.pem" \
  -name "Sennit CI Developer ID" -out "$work/developer_id.p12" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout "pass:$password"

base64 < "$work/developer_id.p12" | tr -d '\n' | gh secret set MACOS_CERTIFICATE_BASE64
printf '%s' "$password" | gh secret set MACOS_CERTIFICATE_PASSWORD

openssl x509 -in "$work/cert.pem" -noout -subject -serial -enddate
echo "Stored MACOS_CERTIFICATE_BASE64 and MACOS_CERTIFICATE_PASSWORD (run $run)."
