#!/usr/bin/env python3
"""Puts a build's release notes into App Store Connect.

    build_notes.py <version> <build number> <notes file>

Run by deploy_testflight.yml once the upload has finished. Two places:

- the build's TestFlight "What to Test" (en-US), which testers see. The build
  appears in the API a few minutes after the upload, so this waits for it;
- the App Store "What's New" (en-US) of the version <version>, when that
  version exists and can still be edited. Apple has no "What's New" for an
  app's very first version and refuses it; that, and a version nobody has
  created yet, is reported and skipped, not failed.

The notes file is the `--store` output of tooling/scripts/release_notes.py.
Credentials as for iap_products.py: APP_STORE_CONNECT_KEY_ID,
APP_STORE_CONNECT_ISSUER_ID and APP_STORE_CONNECT_KEY_P8_BASE64.
"""

import re
import sys
import time
import urllib.parse

from iap_products import ASC, PACKAGE, ApiError, asc_token, call

# Long enough for App Store Connect to register an upload; it is usually
# under five minutes.
WAIT_SECONDS = 30 * 60
POLL_SECONDS = 30

# App Store states in which the version's metadata can still change.
EDITABLE = {
    'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED',
    'METADATA_REJECTED', 'INVALID_BINARY',
}


# What App Store Connect refuses in "What to Test" and "What's New": emoji,
# with their joiners, variation selectors and keycaps. It answers 409
# INVALID_TEXT for the whole text over a single one.
EMOJI = re.compile(
    '[\U00010000-\U0010FFFF\u2600-\u27BF\u2B00-\u2BFF\u200D\uFE0E\uFE0F\u20E3]')


def store_text(notes):
    """[notes] without the characters App Store Connect refuses."""
    text = EMOJI.sub('', notes)
    return re.sub(r'(?<=\S)[ \t]{2,}', ' ', re.sub(r'[ \t]+$', '', text, flags=re.M))


def query(params):
    return urllib.parse.urlencode(params, safe='[],')


def find_build(app, version, build):
    url = f'{ASC}/v1/builds?' + query({
        'filter[app]': app,
        'filter[version]': build,
        'filter[preReleaseVersion.version]': version,
        'limit': 1,
    })
    deadline = time.time() + WAIT_SECONDS
    while True:
        # A fresh token each time: one lives 15 minutes, the wait is longer.
        found = call('GET', url, asc_token())['data']
        if found:
            return found[0]['id']
        if time.time() > deadline:
            raise ApiError(f'build {version} ({build}) did not appear in App Store Connect')
        print(f'waiting for build {version} ({build}) to appear…')
        time.sleep(POLL_SECONDS)


def what_to_test(build_id, notes):
    token = asc_token()
    existing = call('GET', f'{ASC}/v1/builds/{build_id}/betaBuildLocalizations', token)['data']
    english = next((l for l in existing if l['attributes'].get('locale') == 'en-US'), None)
    if english:
        call('PATCH', f"{ASC}/v1/betaBuildLocalizations/{english['id']}", token, body={'data': {
            'type': 'betaBuildLocalizations',
            'id': english['id'],
            'attributes': {'whatsNew': notes},
        }})
    else:
        call('POST', f'{ASC}/v1/betaBuildLocalizations', token, body={'data': {
            'type': 'betaBuildLocalizations',
            'attributes': {'locale': 'en-US', 'whatsNew': notes},
            'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}},
        }})
    print('testflight: "What to Test" set')


def whats_new(app, version, notes):
    token = asc_token()
    versions = call('GET', f'{ASC}/v1/apps/{app}/appStoreVersions?' + query({
        'filter[versionString]': version,
        'filter[platform]': 'IOS',
    }), token)['data']
    editable = [v for v in versions if v['attributes'].get('appStoreState') in EDITABLE]
    if not editable:
        print(f'appstore: no editable App Store version {version}; "What\'s New" not set')
        return
    localizations = call(
        'GET', f"{ASC}/v1/appStoreVersions/{editable[0]['id']}/appStoreVersionLocalizations",
        token)['data']
    english = next((l for l in localizations if l['attributes'].get('locale') == 'en-US'), None)
    if english is None:
        print(f'appstore: version {version} has no en-US localization; "What\'s New" not set')
        return
    try:
        call('PATCH', f"{ASC}/v1/appStoreVersionLocalizations/{english['id']}", token, body={
            'data': {
                'type': 'appStoreVersionLocalizations',
                'id': english['id'],
                'attributes': {'whatsNew': notes},
            },
        })
    except ApiError as error:
        # The app's first version cannot have "What's New"; Apple says 409.
        print(f'appstore: "What\'s New" refused, skipped:\n{error}')
        return
    print(f'appstore: "What\'s New" set on {version}')


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    version, build, path = argv
    with open(path, encoding='utf-8') as f:
        notes = store_text(f.read()).strip()
    if not notes:
        print('no notes; nothing to set')
        return
    try:
        apps = call('GET', f'{ASC}/v1/apps?filter[bundleId]={PACKAGE}', asc_token())['data']
        if not apps:
            raise ApiError(f'no app with bundle id {PACKAGE}')
        app = apps[0]['id']
        what_to_test(find_build(app, version, build), notes)
        whats_new(app, version, notes)
    except (ApiError, KeyError) as error:
        sys.exit(f'FAILED: {error!r}' if isinstance(error, KeyError) else f'FAILED: {error}')


if __name__ == '__main__':
    main(sys.argv[1:])
