#!/usr/bin/env python3
"""Revokes, in App Store Connect, every certificate a keychain holds.

    revoke_keychain_certificates.py <keychain>

deploy_testflight.yml runs on a hosted Mac that is new every time, so
automatic signing makes a fresh Apple Development certificate on each run and
the private key is gone with the runner. Left alone they pile up on the
developer portal until it refuses to make another. The job signs with a
keychain of its own, so whatever that keychain holds is what this run made,
and this revokes exactly those — matched by serial number — and nothing else.

Credentials as for iap_products.py: APP_STORE_CONNECT_KEY_ID,
APP_STORE_CONNECT_ISSUER_ID and APP_STORE_CONNECT_KEY_P8_BASE64.
"""

import re
import subprocess
import sys

from iap_products import ASC, ApiError, asc_all, asc_token, call


def serial(number):
    """A serial as both sides can compare it: hex, upper case, no leading
    zeros."""
    return number.upper().lstrip('0')


def keychain_serials(keychain):
    pems = subprocess.run(
        ['security', 'find-certificate', '-a', '-p', keychain],
        capture_output=True, text=True, check=True,
    ).stdout
    serials = set()
    for pem in re.findall(
        r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', pems, re.S,
    ):
        out = subprocess.run(
            ['openssl', 'x509', '-noout', '-serial'],
            input=pem, capture_output=True, text=True, check=True,
        ).stdout
        serials.add(serial(out.strip().split('=', 1)[1]))
    return serials


def main():
    serials = keychain_serials(sys.argv[1])
    if not serials:
        print('The keychain holds no certificate; nothing to revoke.')
        return
    token = asc_token()
    revoked = 0
    for certificate in asc_all(f'{ASC}/v1/certificates?limit=200', token):
        attributes = certificate['attributes']
        if serial(attributes['serialNumber']) in serials:
            call('DELETE', f"{ASC}/v1/certificates/{certificate['id']}", token)
            print(f"Revoked {attributes['certificateType']} {attributes['name']}")
            revoked += 1
    print(f'{revoked} of {len(serials)} certificate(s) revoked.')


if __name__ == '__main__':
    try:
        main()
    except (ApiError, subprocess.CalledProcessError) as error:
        sys.exit(f'Revoking failed: {error}')
