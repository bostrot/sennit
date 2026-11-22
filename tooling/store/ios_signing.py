#!/usr/bin/env python3
"""The one Apple Distribution certificate deploy_testflight.yml signs with,
and the App Store profiles that go with it.

    ios_signing.py certificates
    ios_signing.py create-certificate <csr.pem> <out.cer>
    ios_signing.py create-profiles <certificate serial>
    ios_signing.py revoke-ci-development [--apply]
    ios_signing.py install-profiles
    ios_signing.py configure-project <project.pbxproj> <team id>
    ios_signing.py export-profiles

The first four are portal work and run in ios_signing.yml, by hand, about
once a year; see "Renewal" in docs/decisions/adr-002-ios-signing-handoff.md.
The private key is never here: create-certificate takes a CSR, and
tooling/store/renew_ios_signing.sh makes the key and the .p12 on the
owner's machine. The last three run in every deploy_testflight.yml job and
only read from the portal: they fetch the profiles by name, point each
target of the Xcode project at its profile, and print the export options'
profile map.

Credentials as for iap_products.py: APP_STORE_CONNECT_KEY_ID,
APP_STORE_CONNECT_ISSUER_ID and APP_STORE_CONNECT_KEY_P8_BASE64.
"""

import base64
import datetime
import os
import re
import subprocess
import sys
import urllib.parse

from iap_products import ASC, ApiError, asc_all, asc_token, call

# Every target the archive signs, by bundle id. The tests (RunnerTests,
# RunnerUITests) are not archived and need nothing. The watch app and its
# complication take iOS App Store profiles too: the portal has no watchOS
# profile type, a watch app ships inside its iPhone app.
BUNDLES = [
    'com.bostrot.weft',
    'com.bostrot.weft.ShareExtension',
    'com.bostrot.weft.NotificationService',
    'com.bostrot.weft.WeftWidget',
    'com.bostrot.weft.watchkitapp',
    'com.bostrot.weft.watchkitapp.WeftWatchComplication',
]

PROFILE_TYPE = 'IOS_APP_STORE'

# What a run warns about ahead of an expiry, so the renewal is a chore and
# not an outage.
WARN_DAYS = 30

PROFILE_DIRS = [
    # Where Xcode 16 and later look, and where older ones did.
    os.path.expanduser('~/Library/Developer/Xcode/UserData/Provisioning Profiles'),
    os.path.expanduser('~/Library/MobileDevice/Provisioning Profiles'),
]


def profile_name(bundle):
    return f'Sennit CI App Store {bundle}'


def serial(number):
    """A serial as both sides can compare it: hex, upper case, no leading
    zeros."""
    return number.upper().lstrip('0')


def days_left(expiration):
    """Whole days until an App Store Connect timestamp."""
    when = datetime.datetime.fromisoformat(expiration.replace('Z', '+00:00'))
    return (when - datetime.datetime.now(datetime.timezone.utc)).days


def get(path, token, **params):
    url = f'{ASC}{path}'
    if params:
        url += '?' + urllib.parse.urlencode(params, safe='[],')
    return asc_all(url, token)


def certificates(_argv):
    token = asc_token()
    for certificate in get('/v1/certificates', token, limit=200):
        a = certificate['attributes']
        print(f"{a['certificateType']:<24} {serial(a['serialNumber']):<18} "
              f"expires {a['expirationDate'][:10]}  {a['name']}")


def create_certificate(argv):
    csr_path, out_path = argv
    with open(csr_path) as f:
        csr = ''.join(line.strip() for line in f if '-----' not in line)
    token = asc_token()
    created = call('POST', f'{ASC}/v1/certificates', token, body={'data': {
        'type': 'certificates',
        'attributes': {'certificateType': 'DISTRIBUTION', 'csrContent': csr},
    }})['data']
    a = created['attributes']
    with open(out_path, 'wb') as f:
        f.write(base64.b64decode(a['certificateContent']))
    print(f"Created {a['certificateType']} {a['name']}, serial "
          f"{serial(a['serialNumber'])}, expires {a['expirationDate']}")


def certificate_by_serial(number, token):
    for certificate in get('/v1/certificates', token, limit=200):
        if serial(certificate['attributes']['serialNumber']) == serial(number):
            return certificate
    raise ApiError(f'no certificate with serial {number}')


def bundle_id(identifier, token):
    # The filter matches by prefix; only an exact match will do.
    for found in get('/v1/bundleIds', token, **{'filter[identifier]': identifier}):
        if found['attributes']['identifier'] == identifier:
            return found['id']
    raise ApiError(f'{identifier} is not registered on the developer portal')


def profiles_named(name, token):
    return get('/v1/profiles', token, **{'filter[name]': name})


def create_profiles(argv):
    """One App Store profile per bundle id, carrying the one certificate.
    A profile of the same name is replaced: that is what renewing is."""
    token = asc_token()
    certificate = certificate_by_serial(argv[0], token)
    for bundle in BUNDLES:
        name = profile_name(bundle)
        for old in profiles_named(name, token):
            call('DELETE', f"{ASC}/v1/profiles/{old['id']}", token)
            print(f'Deleted the old {name}')
        created = call('POST', f'{ASC}/v1/profiles', token, body={'data': {
            'type': 'profiles',
            'attributes': {'name': name, 'profileType': PROFILE_TYPE},
            'relationships': {
                'bundleId': {'data': {'type': 'bundleIds', 'id': bundle_id(bundle, token)}},
                'certificates': {'data': [{'type': 'certificates', 'id': certificate['id']}]},
            },
        }})['data']
        print(f"Created {name}, expires {created['attributes']['expirationDate']}")


def revoke_ci_development(argv):
    """The Apple Development certificates automatic signing made on hosted
    runners before this file existed. Xcode names one it makes with an API
    key "Created via API"; a person's own is named after them and is left
    alone."""
    apply = '--apply' in argv
    token = asc_token()
    found = [
        c for c in get('/v1/certificates', token, limit=200)
        if c['attributes']['certificateType'] in ('DEVELOPMENT', 'IOS_DEVELOPMENT')
        and 'Created via API' in c['attributes']['name']
    ]
    for certificate in found:
        a = certificate['attributes']
        print(f"{'Revoking' if apply else 'Would revoke'} {a['name']}, serial "
              f"{serial(a['serialNumber'])}, expires {a['expirationDate'][:10]}")
        if apply:
            call('DELETE', f"{ASC}/v1/certificates/{certificate['id']}", token)
    print(f"{len(found)} CI development certificate(s){'' if apply else ', nothing revoked'}.")


def install_profiles(_argv):
    token = asc_token()
    for directory in PROFILE_DIRS:
        os.makedirs(directory, exist_ok=True)
    for bundle in BUNDLES:
        name = profile_name(bundle)
        active = [p for p in profiles_named(name, token)
                  if p['attributes']['name'] == name
                  and p['attributes']['profileState'] == 'ACTIVE']
        if not active:
            raise ApiError(f'no active profile "{name}"; run ios_signing.yml '
                           '(see adr-002, "Renewal")')
        a = active[0]['attributes']
        content = base64.b64decode(a['profileContent'])
        for directory in PROFILE_DIRS:
            with open(os.path.join(directory, f"{a['uuid']}.mobileprovision"), 'wb') as f:
                f.write(content)
        left = days_left(a['expirationDate'])
        print(f'Installed {name}, {left} days left')
        if left < WARN_DAYS:
            print(f'::warning::The profile "{name}" expires in {left} days; '
                  'renew it (adr-002, "Renewal")')


# Settings that decide how a target signs. Removed wherever the project sets
# them, in any SDK-conditional spelling, before the manual ones go in.
SIGNING_KEY = re.compile(
    r'^\s*"?(CODE_SIGN_STYLE|DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|'
    r'PROVISIONING_PROFILE|PROVISIONING_PROFILE_SPECIFIER)(\[[^\]]*\])?"? = .*;\n',
    re.M,
)
RELEASE_BLOCK = re.compile(
    r'(/\* Release \*/ = \{\n\s*isa = XCBuildConfiguration;.*?'
    r'buildSettings = \{\n)(.*?)(\n\s*\};\n\s*name = Release;)',
    re.S,
)


def configure_project(argv):
    """Signs every archived target's Release configuration manually with
    the Apple Distribution identity and its own profile. Only the copy on
    the runner is changed; the committed project stays automatic, which is
    what anyone building locally wants."""
    path, team = argv
    with open(path) as f:
        project = f.read()
    done = set()

    def manual(match):
        head, settings, tail = match.groups()
        found = re.search(r'PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;', settings)
        if not found or found.group(1) not in BUNDLES:
            return match.group(0)
        bundle = found.group(1)
        done.add(bundle)
        indent = re.match(r'\s*', settings).group(0)
        lines = [
            'CODE_SIGN_STYLE = Manual;',
            f'DEVELOPMENT_TEAM = {team};',
            'CODE_SIGN_IDENTITY = "Apple Distribution";',
            '"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "Apple Distribution";',
            '"CODE_SIGN_IDENTITY[sdk=watchos*]" = "Apple Distribution";',
            f'PROVISIONING_PROFILE_SPECIFIER = "{profile_name(bundle)}";',
        ]
        added = ''.join(f'{indent}{line}\n' for line in lines)
        return head + added + SIGNING_KEY.sub('', settings + '\n')[:-1] + tail

    project = RELEASE_BLOCK.sub(manual, project)
    missing = set(BUNDLES) - done
    if missing:
        raise ApiError(f'no Release configuration for {sorted(missing)} in {path}')
    with open(path, 'w') as f:
        f.write(project)
    print(f'{len(done)} targets sign manually for Release')


def export_profiles(_argv):
    """The provisioningProfiles entries of ExportOptions.plist."""
    for bundle in BUNDLES:
        print(f'<key>{bundle}</key><string>{profile_name(bundle)}</string>')


COMMANDS = {
    'certificates': certificates,
    'create-certificate': create_certificate,
    'create-profiles': create_profiles,
    'revoke-ci-development': revoke_ci_development,
    'install-profiles': install_profiles,
    'configure-project': configure_project,
    'export-profiles': export_profiles,
}


if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    try:
        COMMANDS[sys.argv[1]](sys.argv[2:])
    except (ApiError, subprocess.CalledProcessError, ValueError) as error:
        sys.exit(f'{sys.argv[1]} failed: {error}')
