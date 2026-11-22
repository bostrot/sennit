#!/usr/bin/env bash
# Makes the Apple Distribution certificate deploy_testflight.yml signs with,
# and stores it as the repository secrets IOS_DISTRIBUTION_P12_BASE64 and
# IOS_DISTRIBUTION_P12_PASSWORD. Run once a year; see "Renewal" in
# docs/decisions/adr-002-ios-signing-handoff.md.
#
#     tooling/store/renew_ios_signing.sh [ref]
#
# The split is the point. The private key and the .p12 exist only here, in a
# temporary directory removed on exit, and leave only encrypted, as a secret.
# The App Store Connect key exists only in GitHub, and is used only by
# ios_signing.yml, which gets the CSR, makes the certificate and the profiles,
# and hands back the certificate, which is public. No token that can write
# secrets is ever given to a workflow.
#
# Needs gh, logged in with access to the repository's secrets, and openssl.
set -euo pipefail

ref="${1:-main}"
work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

openssl genrsa -out "$work/key.pem" 2048 2> /dev/null
openssl req -new -key "$work/key.pem" -out "$work/request.csr" \
  -subj "/CN=Sennit CI Distribution/C=DE"

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
gh workflow run ios_signing.yml --ref "$ref" \
  -f action=create -f csr="$(base64 < "$work/request.csr" | tr -d '\n')"

run=""
for _ in $(seq 30); do
  sleep 5
  run="$(gh run list --workflow ios_signing.yml --event workflow_dispatch \
    --created ">=$since" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [ -n "$run" ] && break
done
[ -n "$run" ] || { echo "the ios_signing.yml run did not start" >&2; exit 1; }
gh run watch "$run" --exit-status > /dev/null
gh run download "$run" --name distribution-certificate --dir "$work"

# The certificate the portal made must be for this key, or the .p12 is junk.
cert_key="$(openssl x509 -inform der -in "$work/distribution.cer" -noout -pubkey)"
own_key="$(openssl pkey -in "$work/key.pem" -pubout)"
[ "$cert_key" = "$own_key" ] || { echo "the certificate is not for this key" >&2; exit 1; }

# SHA-1 and 3DES because `security import` on the runner reads those, and
# not every macOS reads OpenSSL 3's AES default.
password="$(openssl rand -base64 24)"
openssl x509 -inform der -in "$work/distribution.cer" -out "$work/cert.pem"
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -name "Sennit CI Distribution" -out "$work/distribution.p12" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout "pass:$password"

base64 < "$work/distribution.p12" | tr -d '\n' | gh secret set IOS_DISTRIBUTION_P12_BASE64
printf '%s' "$password" | gh secret set IOS_DISTRIBUTION_P12_PASSWORD

openssl x509 -in "$work/cert.pem" -noout -subject -serial -enddate
echo "Stored IOS_DISTRIBUTION_P12_BASE64 and IOS_DISTRIBUTION_P12_PASSWORD (run $run)."
