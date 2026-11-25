#!/usr/bin/env python3
"""Puts the store listings in `tooling/store/listings/` into Google Play and
App Store Connect, with the screenshots in `tooling/store/screenshots/`.

    listings.py [play|appstore|all] [--apply] [--screenshots]
                [--create-version X.Y.Z]

One folder per language, one file per field, so a translator touches plain
text and nothing else:

    name.txt               App Store name             30
    subtitle.txt           App Store subtitle         30
    title.txt              Play title                 30
    short_description.txt  Play short description     80
    description.txt        both stores              4000
    keywords.txt           App Store keywords        100
    promotional_text.txt   App Store promo text      170

The limits are checked before anything is sent. Each folder fans out to the
store locales in LOCALES; Spanish serves Spain and Latin America alike, and a
language missing from one store is simply not sent there.

Play takes everything in one edit: the listing text of every locale and, with
`--screenshots`, its phone, 7" and 10" screenshots (replacing what is there).
Listings are not a release: no track, price or product is touched. The commit
honours PLAY_CHANGES_NOT_SENT_FOR_REVIEW like promote.py does.

The App Store keeps name and subtitle on the app info and the rest on a
version, and only an editable one (Prepare for Submission) takes changes; a
live version only takes its promotional text. So the description, keywords
and screenshots go on the editable version — `--create-version` makes one
when there is none, which the nightly promote.py then picks up — and a
new localization gets the release notes as "What's New", which Apple wants on
every language of an update: `docs/release-notes/<version>.play.<locale>.md`
where it exists, else WHATS_NEW below. Nothing is submitted for review.

Without `--apply` it reads, checks and prints what it would change.

Credentials as for iap_products.py. For a run from a laptop, PLAY_ACCESS_TOKEN
stands in for the service-account key (`gcloud auth print-access-token
--impersonate-service-account=… --scopes=…/auth/androidpublisher`).
"""

import glob
import hashlib
import os
import sys
import time
import urllib.request

from iap_products import ASC, PACKAGE, PLAY, ApiError, asc_all, asc_token, call, play_token

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
LISTINGS = os.path.join(HERE, 'listings')
SCREENSHOTS = os.path.join(HERE, 'screenshots')
NOTES = os.path.join(REPO, 'docs', 'release-notes')
APP_ID = '6804951341'
PRIVACY_URL = 'https://erictrenkel.com/apps/sennit/privacy.html'

LIMITS = {
    'name': 30, 'subtitle': 30, 'title': 30, 'short_description': 80,
    'description': 4000, 'keywords': 100, 'promotional_text': 170,
}

# Folder -> (Play locales, App Store locales).
LOCALES = {
    'en': (['en-US'], ['en-US']),
    'de': (['de-DE'], ['de-DE']),
    'es': (['es-ES', 'es-419', 'es-US'], ['es-ES', 'es-MX']),
    'fr': (['fr-FR', 'fr-CA'], ['fr-FR', 'fr-CA']),
    'pt': (['pt-BR'], ['pt-BR']),
    'zh': (['zh-CN'], ['zh-Hans']),
    'hi': (['hi-IN'], ['hi']),
    'ar': (['ar'], ['ar-SA']),
}

# Play's image slots, by the files that fill them.
PLAY_IMAGES = {
    'phoneScreenshots': 'play_phone_*.png',
    'sevenInchScreenshots': 'play_tablet_*.png',
    'tenInchScreenshots': 'play_tablet_*.png',
}
# App Store display types, by the files that fill them.
ASC_IMAGES = {
    'APP_IPHONE_67': 'iphone_69_*.png',
    'APP_IPAD_PRO_3GEN_129': 'ipad_13_*.png',
}

EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED'}

# "What's New" for a language that has no Play text of its own for the version
# — a new localization cannot be left without one.
WHATS_NEW = {
    'en': 'Bug fixes and improvements.',
    'de': 'Fehlerbehebungen und Verbesserungen.',
    'es': 'Correcciones de errores y mejoras.',
    'fr': 'Corrections de bugs et améliorations.',
    'pt': 'Correções de bugs e melhorias.',
    'zh': '问题修复和改进。',
    'hi': 'बग फ़िक्स और सुधार।',
    'ar': 'إصلاحات للأخطاء وتحسينات.',
}


def log(store, message):
    print(f'[{store}] {message}', flush=True)


def load():
    """Every language's fields, checked against the limits."""
    listings, problems = {}, []
    for language in LOCALES:
        fields = {}
        for field, limit in LIMITS.items():
            path = os.path.join(LISTINGS, language, f'{field}.txt')
            if not os.path.exists(path):
                problems.append(f'{language}/{field}.txt is missing')
                continue
            with open(path, encoding='utf-8') as f:
                text = f.read().strip()
            if len(text) > limit:
                problems.append(f'{language}/{field}.txt: {len(text)} > {limit} characters')
            fields[field] = text
        listings[language] = fields
    if problems:
        raise SystemExit('listings do not fit:\n  ' + '\n  '.join(problems))
    return listings


def shots(language, pattern):
    return sorted(glob.glob(os.path.join(SCREENSHOTS, language, pattern)))


def send(method, url, token, data, headers):
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    if token:
        request.add_header('Authorization', f'Bearer {token}')
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors='replace')
        raise ApiError(f'{method} {url} -> {error.code}\n{detail}') from None


# --- Google Play ------------------------------------------------------------

def play(listings, apply, screenshots):
    token = os.environ.get('PLAY_ACCESS_TOKEN') or play_token()
    edit = call('POST', f'{PLAY}/edits', token, body={})['id']
    base = f'{PLAY}/edits/{edit}'
    upload = base.replace('/androidpublisher/v3/', '/upload/androidpublisher/v3/')
    committed = False
    try:
        for language, fields in listings.items():
            for locale in LOCALES[language][0]:
                body = {
                    'language': locale,
                    'title': fields['title'],
                    'shortDescription': fields['short_description'],
                    'fullDescription': fields['description'],
                }
                current = call('GET', f'{base}/listings/{locale}', token) or {}
                same = all(current.get(k) == v for k, v in body.items())
                log('play', f'{locale}: listing {"unchanged" if same else "updated"}')
                if not same:
                    call('PUT', f'{base}/listings/{locale}', token, body=body)
                if not screenshots:
                    continue
                for image_type, pattern in PLAY_IMAGES.items():
                    files = shots(language, pattern)
                    if not files:
                        raise ApiError(f'no {pattern} in screenshots/{language}')
                    call('DELETE', f'{base}/listings/{locale}/{image_type}', token)
                    for path in files:
                        with open(path, 'rb') as f:
                            send('POST', f'{upload}/listings/{locale}/{image_type}'
                                         '?uploadType=media', token, f.read(),
                                 {'Content-Type': 'image/png'})
                    log('play', f'{locale}: {image_type} <- {len(files)} from {language}/')
        call('POST', f'{base}:validate', token, body={})
        log('play', 'Play validated the edit')
        if apply:
            params = ''
            if os.environ.get('PLAY_CHANGES_NOT_SENT_FOR_REVIEW') == 'true':
                params = '?changesNotSentForReview=true'
            call('POST', f'{base}:commit{params}', token, body={})
            committed = True
            log('play', 'committed')
        else:
            log('play', 'dry run: not committed')
    finally:
        if not committed:
            try:
                call('DELETE', base, token)
            except ApiError:
                pass


# --- App Store --------------------------------------------------------------

def whats_new(language, locale, version):
    names = [f'{version}.play.{locale}.md']
    if language == 'en':
        names.append(f'{version}.play.md')
    for name in names:
        path = os.path.join(NOTES, name)
        if os.path.exists(path):
            with open(path, encoding='utf-8') as f:
                lines = [l.strip().lstrip('-•').strip() for l in f if l.strip()]
            return '\n'.join('• ' + l for l in lines)
    return WHATS_NEW[language]


def asc_upsert(kind, existing, attributes, parent, token, apply, label):
    """Creates or patches one localization; returns its id (None in a dry run
    of a new one)."""
    if existing is None:
        log('appstore', f'{label}: new localization')
        if not apply:
            return None
        return call('POST', f'{ASC}/v1/{kind}', token, body={'data': {
            'type': kind, 'attributes': attributes, 'relationships': parent,
        }})['data']['id']
    changed = {k: v for k, v in attributes.items()
               if k != 'locale' and existing['attributes'].get(k) != v}
    log('appstore', f'{label}: {", ".join(sorted(changed)) or "unchanged"}')
    if changed and apply:
        call('PATCH', f'{ASC}/v1/{kind}/{existing["id"]}', token, body={'data': {
            'type': kind, 'id': existing['id'], 'attributes': changed,
        }})
    return existing['id']


def asc_screenshots(localization, language, token, label):
    sets = call('GET', f'{ASC}/v1/appStoreVersionLocalizations/{localization}'
                       '/appScreenshotSets?limit=50', token)['data']
    for display, pattern in ASC_IMAGES.items():
        files = shots(language, pattern)
        if not files:
            raise ApiError(f'no {pattern} in screenshots/{language}')
        found = next((s for s in sets
                      if s['attributes']['screenshotDisplayType'] == display), None)
        if found is None:
            set_id = call('POST', f'{ASC}/v1/appScreenshotSets', token, body={'data': {
                'type': 'appScreenshotSets',
                'attributes': {'screenshotDisplayType': display},
                'relationships': {'appStoreVersionLocalization': {'data': {
                    'type': 'appStoreVersionLocalizations', 'id': localization}}},
            }})['data']['id']
        else:
            set_id = found['id']
            for old in call('GET', f'{ASC}/v1/appScreenshotSets/{set_id}/appScreenshots',
                            token)['data']:
                call('DELETE', f'{ASC}/v1/appScreenshots/{old["id"]}', token)
        for path in files:
            with open(path, 'rb') as f:
                data = f.read()
            shot = call('POST', f'{ASC}/v1/appScreenshots', token, body={'data': {
                'type': 'appScreenshots',
                'attributes': {'fileName': os.path.basename(path), 'fileSize': len(data)},
                'relationships': {'appScreenshotSet': {'data': {
                    'type': 'appScreenshotSets', 'id': set_id}}},
            }})['data']
            for op in shot['attributes']['uploadOperations']:
                part = data[op['offset']:op['offset'] + op['length']]
                headers = {h['name']: h['value'] for h in op.get('requestHeaders', [])}
                send(op['method'], op['url'], None, part, headers)
            call('PATCH', f'{ASC}/v1/appScreenshots/{shot["id"]}', token, body={'data': {
                'type': 'appScreenshots', 'id': shot['id'],
                'attributes': {'uploaded': True,
                               'sourceFileChecksum': hashlib.md5(data).hexdigest()},
            }})
        log('appstore', f'{label}: {display} <- {len(files)} from {language}/')


def appstore(listings, apply, screenshots, create_version):
    token = asc_token()
    versions = asc_all(f'{ASC}/v1/apps/{APP_ID}/appStoreVersions?filter[platform]=IOS'
                       '&limit=50', token)
    editable = [v for v in versions if v['attributes']['appStoreState'] in EDITABLE]
    if editable:
        version = editable[0]
    elif create_version:
        log('appstore', f'no editable version: creating {create_version}')
        if not apply:
            version = None
        else:
            version = call('POST', f'{ASC}/v1/appStoreVersions', token, body={'data': {
                'type': 'appStoreVersions',
                'attributes': {'platform': 'IOS', 'versionString': create_version,
                               'releaseType': 'AFTER_APPROVAL'},
                'relationships': {'app': {'data': {'type': 'apps', 'id': APP_ID}}},
            }})['data']
    else:
        version = None
        log('appstore', 'no editable version: only the promotional text of the live '
                        'one changes (pass --create-version for the rest)')

    if version is not None:
        string = version['attributes']['versionString']
        log('appstore', f'version {string} ({version["attributes"]["appStoreState"]})')
        infos = call('GET', f'{ASC}/v1/apps/{APP_ID}/appInfos', token)['data']
        info = next((i for i in infos if i['attributes'].get('state') != 'READY_FOR_DISTRIBUTION'),
                    None)
        info_locs = {l['attributes']['locale']: l for l in call(
            'GET', f'{ASC}/v1/appInfos/{info["id"]}/appInfoLocalizations?limit=50',
            token)['data']} if info else {}
        # App info first: a new app info localization brings an empty version
        # localization with it, which the loop below then fills.
        for language, fields in listings.items():
            for locale in LOCALES[language][1]:
                if info:
                    asc_upsert('appInfoLocalizations', info_locs.get(locale), {
                        'locale': locale, 'name': fields['name'],
                        'subtitle': fields['subtitle'], 'privacyPolicyUrl': PRIVACY_URL,
                    }, {'appInfo': {'data': {'type': 'appInfos', 'id': info['id']}}},
                        token, apply, f'{locale} app info')
        version_locs = {l['attributes']['locale']: l for l in call(
            'GET', f'{ASC}/v1/appStoreVersions/{version["id"]}'
                   '/appStoreVersionLocalizations?limit=50', token)['data']}
        live = bool([v for v in versions if v['attributes']['appStoreState'] == 'READY_FOR_SALE'])
        for language, fields in listings.items():
            for locale in LOCALES[language][1]:
                attributes = {
                    'locale': locale, 'description': fields['description'],
                    'keywords': fields['keywords'],
                    'promotionalText': fields['promotional_text'],
                    'supportUrl': 'https://erictrenkel.com/apps/sennit/',
                    'marketingUrl': 'https://erictrenkel.com/apps/sennit/',
                }
                existing = version_locs.get(locale)
                if live and (existing is None or not existing['attributes'].get('whatsNew')):
                    attributes['whatsNew'] = whats_new(language, locale, string)
                localization = asc_upsert(
                    'appStoreVersionLocalizations', existing, attributes,
                    {'appStoreVersion': {'data': {'type': 'appStoreVersions',
                                                  'id': version['id']}}},
                    token, apply, f'{locale} version')
                if screenshots and apply and localization:
                    asc_screenshots(localization, language, token, locale)
    else:
        live = next((v for v in versions if v['attributes']['appStoreState'] == 'READY_FOR_SALE'),
                    None)
        if live is None:
            return
        for loc in call('GET', f'{ASC}/v1/appStoreVersions/{live["id"]}'
                               '/appStoreVersionLocalizations?limit=50', token)['data']:
            language = next((lang for lang, (_, apple) in LOCALES.items()
                             if loc['attributes']['locale'] in apple), None)
            if language:
                asc_upsert('appStoreVersionLocalizations', loc,
                           {'promotionalText': listings[language]['promotional_text']},
                           None, token, apply, f'{loc["attributes"]["locale"]} live version')
    if not apply:
        log('appstore', 'dry run: nothing changed')


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    store = args[0] if args else 'all'
    create_version = None
    if '--create-version' in argv:
        create_version = argv[argv.index('--create-version') + 1]
        store = next((a for a in args if a != create_version), 'all')
    if store not in ('play', 'appstore', 'all'):
        raise SystemExit(__doc__)
    apply = '--apply' in argv
    screenshots = '--screenshots' in argv
    listings = load()
    if store in ('play', 'all'):
        play(listings, apply, screenshots)
    if store in ('appstore', 'all'):
        appstore(listings, apply, screenshots, create_version)


if __name__ == '__main__':
    main(sys.argv[1:])
