#!/usr/bin/env python3
"""Creates the Sennit Pro in-app product in Google Play and App Store Connect.

The product ids are the ones the app asks the stores for, in
`apps/weft/lib/services/billing/entitlements.dart`. A product id is for
keeps in both consoles — a deleted one cannot be used again — so this script
only ever creates what is missing and never deletes.

    iap_products.py [play|appstore|all] [--apply]

Without `--apply` it reads and reports, and changes nothing.

Credentials come from the environment, the same ones the deploy workflows
use: GOOGLE_PLAY_SERVICE_ACCOUNT_JSON for Play; APP_STORE_CONNECT_KEY_ID,
APP_STORE_CONNECT_ISSUER_ID and APP_STORE_CONNECT_KEY_P8_BASE64 for the App
Store. Needs nothing but Python 3 and the `openssl` command.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

PACKAGE = 'com.bostrot.weft'
PRODUCT_ID = 'braid_pro_lifetime'

# One payment, in the base currency. The stores convert it for everyone else.
PRICE_EUR = '14.99'

# Store-facing copy. Apple allows 30 characters for the name and 45 for the
# description; Play allows 55 and 200.
LISTINGS = {
    'en-US': ('Sennit Pro', 'AI features and integrations. One payment.'),
    'de-DE': ('Sennit Pro', 'KI-Funktionen und Integrationen. Einmalig.'),
}
REVIEW_NOTE = (
    'Unlocks the AI features (auto-replies, reply suggestions, semantic '
    'search, voice-note transcription), the MCP server and the Home '
    'Assistant, paperless-ngx and calendar integrations. Settings > Sennit '
    'Pro shows the purchase screen.'
)


class ApiError(Exception):
    pass


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def openssl_sign(pem, message):
    """SHA-256 signature of `message` with the PEM private key, DER-encoded
    for an EC key and PKCS#1 v1.5 for an RSA one."""
    with tempfile.NamedTemporaryFile('w', suffix='.pem') as key:
        key.write(pem)
        key.flush()
        return subprocess.run(
            ['openssl', 'dgst', '-sha256', '-sign', key.name],
            input=message, capture_output=True, check=True,
        ).stdout


def der_to_raw(der):
    """An ECDSA signature as JWT wants it: r and s, 32 bytes each."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        assert der[i] == 0x02
        length = der[i + 1]
        value = der[i + 2:i + 2 + length].lstrip(b'\x00')
        parts.append(value.rjust(32, b'\x00'))
        i += 2 + length
    return b''.join(parts)


def jwt(header, payload, pem, ecdsa):
    head = b64url(json.dumps(header).encode())
    body = b64url(json.dumps(payload).encode())
    signature = openssl_sign(pem, f'{head}.{body}'.encode())
    if ecdsa:
        signature = der_to_raw(signature)
    return f'{head}.{body}.{b64url(signature)}'


def call(method, url, token, body=None, form=None):
    """One request. Returns the decoded JSON, or None for a 404."""
    headers = {'Accept': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    elif form is not None:
        data = urllib.parse.urlencode(form).encode()
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        if error.code == 404 and method == 'GET':
            return None
        detail = error.read().decode(errors='replace')
        raise ApiError(f'{method} {url} -> {error.code}\n{detail}') from None


# --- Google Play ------------------------------------------------------------

PLAY = f'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PACKAGE}'


def play_token():
    account = json.loads(os.environ['GOOGLE_PLAY_SERVICE_ACCOUNT_JSON'])
    now = int(time.time())
    assertion = jwt(
        {'alg': 'RS256', 'typ': 'JWT'},
        {
            'iss': account['client_email'],
            'scope': 'https://www.googleapis.com/auth/androidpublisher',
            'aud': 'https://oauth2.googleapis.com/token',
            'iat': now,
            'exp': now + 600,
        },
        account['private_key'],
        ecdsa=False,
    )
    return call('POST', 'https://oauth2.googleapis.com/token', None, form={
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': assertion,
    })['access_token']


def play(apply):
    token = play_token()
    existing = call('GET', f'{PLAY}/onetimeproducts/{PRODUCT_ID}', token)
    if existing is not None:
        options = [
            (o.get('purchaseOptionId'), o.get('state'))
            for o in existing.get('purchaseOptions', [])
        ]
        print(f'play: {PRODUCT_ID} exists, purchase options {options}')
        return

    units, cents = PRICE_EUR.split('.')
    converted = call('POST', f'{PLAY}/pricing:convertRegionPrices', token, body={
        'price': {'currencyCode': 'EUR', 'units': units, 'nanos': int(cents) * 10_000_000},
    })
    regions = converted.get('convertedRegionPrices', {})
    version = converted.get('regionVersion', {}).get('version')
    others = converted.get('convertedOtherRegionsPrice', {})
    print(f'play: {PRODUCT_ID} is missing; {len(regions)} regional prices from '
          f'EUR {PRICE_EUR}, regions version {version}')
    if not apply:
        print('play: dry run, nothing created')
        return

    product = {
        'packageName': PACKAGE,
        'productId': PRODUCT_ID,
        'listings': [
            {'languageCode': locale, 'title': title, 'description': description}
            for locale, (title, description) in LISTINGS.items()
        ],
        'purchaseOptions': [{
            'purchaseOptionId': 'lifetime',
            # What `in_app_purchase` and older Play Billing clients buy.
            'buyOption': {'legacyCompatible': True, 'multiQuantityEnabled': False},
            'regionalPricingAndAvailabilityConfigs': [
                {'regionCode': code, 'price': region['price'], 'availability': 'AVAILABLE'}
                for code, region in sorted(regions.items())
            ],
            'newRegionsConfig': {
                'usdPrice': others.get('usdPrice'),
                'eurPrice': others.get('eurPrice'),
                'availability': 'AVAILABLE',
            },
        }],
    }
    query = urllib.parse.urlencode({
        'allowMissing': 'true',
        'updateMask': 'listings,purchaseOptions',
        'regionsVersion.version': version,
    })
    call('PATCH', f'{PLAY}/onetimeproducts/{PRODUCT_ID}?{query}', token, body=product)
    print(f'play: created {PRODUCT_ID}')
    call('POST', f'{PLAY}/onetimeproducts/{PRODUCT_ID}/purchaseOptions:batchUpdateStates',
         token, body={'requests': [{'activatePurchaseOptionRequest': {
             'packageName': PACKAGE,
             'productId': PRODUCT_ID,
             'purchaseOptionId': 'lifetime',
         }}]})
    print('play: activated the purchase option')


# --- App Store Connect ------------------------------------------------------

ASC = 'https://api.appstoreconnect.apple.com'


def asc_token():
    now = int(time.time())
    pem = base64.b64decode(os.environ['APP_STORE_CONNECT_KEY_P8_BASE64']).decode()
    return jwt(
        {'alg': 'ES256', 'kid': os.environ['APP_STORE_CONNECT_KEY_ID'], 'typ': 'JWT'},
        {
            'iss': os.environ['APP_STORE_CONNECT_ISSUER_ID'],
            'iat': now,
            'exp': now + 900,
            'aud': 'appstoreconnect-v1',
        },
        pem,
        ecdsa=True,
    )


def asc_all(url, token):
    """Every page of a list."""
    items = []
    while url:
        page = call('GET', url, token)
        items += page['data']
        url = page.get('links', {}).get('next')
    return items


def appstore(apply):
    token = asc_token()
    apps = call('GET', f'{ASC}/v1/apps?filter[bundleId]={PACKAGE}', token)['data']
    if not apps:
        raise ApiError(f'appstore: no app with bundle id {PACKAGE}')
    app = apps[0]['id']

    found = call('GET', f'{ASC}/v1/apps/{app}/inAppPurchasesV2'
                        f'?filter[productId]={PRODUCT_ID}', token)['data']
    if found:
        attributes = found[0]['attributes']
        print(f"appstore: {PRODUCT_ID} exists, {attributes.get('inAppPurchaseType')}, "
              f"state {attributes.get('state')}")
        return
    print(f'appstore: {PRODUCT_ID} is missing on app {app}')
    if not apply:
        print('appstore: dry run, nothing created')
        return

    iap = call('POST', f'{ASC}/v2/inAppPurchases', token, body={'data': {
        'type': 'inAppPurchases',
        'attributes': {
            'name': 'Sennit Pro',
            'productId': PRODUCT_ID,
            'inAppPurchaseType': 'NON_CONSUMABLE',
            'familySharable': False,
            'reviewNote': REVIEW_NOTE,
        },
        'relationships': {'app': {'data': {'type': 'apps', 'id': app}}},
    }})['data']['id']
    print(f'appstore: created {PRODUCT_ID} ({iap})')
    link = {'data': {'type': 'inAppPurchases', 'id': iap}}

    for locale, (name, description) in LISTINGS.items():
        call('POST', f'{ASC}/v1/inAppPurchaseLocalizations', token, body={'data': {
            'type': 'inAppPurchaseLocalizations',
            'attributes': {'locale': locale, 'name': name, 'description': description},
            'relationships': {'inAppPurchaseV2': link},
        }})
    print(f'appstore: added listings {sorted(LISTINGS)}')

    points = asc_all(f'{ASC}/v2/inAppPurchases/{iap}/pricePoints'
                     f'?filter[territory]=DEU&limit=200', token)
    point = next((p['id'] for p in points
                  if p['attributes']['customerPrice'] == PRICE_EUR), None)
    if point is None:
        raise ApiError(f'appstore: no price point at EUR {PRICE_EUR} for Germany')
    call('POST', f'{ASC}/v1/inAppPurchasePriceSchedules', token, body={
        'data': {
            'type': 'inAppPurchasePriceSchedules',
            'relationships': {
                'inAppPurchase': link,
                'baseTerritory': {'data': {'type': 'territories', 'id': 'DEU'}},
                'manualPrices': {'data': [{'type': 'inAppPurchasePrices', 'id': '${price}'}]},
            },
        },
        'included': [{
            'type': 'inAppPurchasePrices',
            'id': '${price}',
            'attributes': {'startDate': None},
            'relationships': {'inAppPurchasePricePoint': {
                'data': {'type': 'inAppPurchasePricePoints', 'id': point},
            }},
        }],
    })
    print(f'appstore: priced at EUR {PRICE_EUR}, base territory Germany')

    territories = asc_all(f'{ASC}/v1/territories?limit=200', token)
    call('POST', f'{ASC}/v1/inAppPurchaseAvailabilities', token, body={'data': {
        'type': 'inAppPurchaseAvailabilities',
        'attributes': {'availableInNewTerritories': True},
        'relationships': {
            'inAppPurchase': link,
            'availableTerritories': {'data': [
                {'type': 'territories', 'id': t['id']} for t in territories
            ]},
        },
    }})
    print(f'appstore: available in {len(territories)} territories')
    print('appstore: still by hand — a review screenshot of the Pro screen, then '
          'submit the product together with the next app version')


def main(argv):
    apply = '--apply' in argv
    targets = [a for a in argv if not a.startswith('--')] or ['all']
    stores = {'play': play, 'appstore': appstore}
    chosen = list(stores) if 'all' in targets else targets
    failed = False
    for name in chosen:
        if name not in stores:
            sys.exit(f'unknown store {name!r}; expected play, appstore or all')
        try:
            stores[name](apply)
        except (ApiError, KeyError, subprocess.CalledProcessError) as error:
            failed = True
            print(f'{name}: FAILED: {error!r}' if isinstance(error, KeyError)
                  else f'{name}: FAILED: {error}', file=sys.stderr)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main(sys.argv[1:])
