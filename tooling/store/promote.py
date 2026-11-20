#!/usr/bin/env python3
"""Promotes the newest tested build to Google Play open testing and the App Store.

    promote.py [play|appstore|all] [--apply] [--audit]
               [--schedule CRON] [--max-age-hours N] [--play-track TRACK]

Run every night by promote_to_stores.yml; see
docs/decisions/adr-005-daily-store-promotion.md for why it decides what it
decides. Per store, it takes the newest build on the test track — Play's
internal track, TestFlight — and promotes it when all of these hold:

1. it is newer, by build number, than anything the target already has —
   Play's target track, the App Store or App Review — which is what makes a
   second run a no-op;
2. it landed on the test track within the last N hours (default 26: one
   night's window, plus GitHub's habit of starting scheduled runs late);
3. CI passed on the commit it was built from, and the deploy workflow that
   uploaded it succeeded on that commit.

The build number is the commit count of main (`git rev-list --count`), so
the commit is found again from the number, on the first-parent line of
origin/main; the checkout needs the full history.

Without `--apply` it reads, prints exactly what it would do, and changes
nothing. Play's would-be release is still checked by Play itself, in an
edit that is validated and then deleted, never committed.

On Play the target is the open testing track, `beta`; production stays a
step taken in the Console for now. `--play-track production` (or the
PLAY_PROMOTION_TRACK variable, in the workflow) points the same steps at
production instead.
`--audit` adds the list of what each store still wants before the first
public release, as far as the APIs can tell.

`--schedule` is the cron line of the scheduled run that started this
(`github.event.schedule`). GitHub's cron is UTC and Berlin is not, so the
workflow is scheduled at 01:00 and 02:00 UTC and only the run whose slot is
03:00 in Berlin on that day goes on; the other one exits early.

Credentials as for iap_products.py: GOOGLE_PLAY_SERVICE_ACCOUNT_JSON;
APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID and
APP_STORE_CONNECT_KEY_P8_BASE64. GITHUB_TOKEN and GITHUB_REPOSITORY read the
CI results. Python 3.10+, git and openssl, nothing else.
"""

import datetime
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
from dataclasses import dataclass, field
from zoneinfo import ZoneInfo

from iap_products import (
    ASC, PACKAGE, PLAY, PRODUCT_ID, ApiError, asc_all, asc_token, call,
    play_token,
)

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BERLIN = ZoneInfo('Europe/Berlin')
PROMOTION_HOUR = 3
DEFAULT_MAX_AGE_HOURS = 26
# Open testing. Production later, through --play-track.
DEFAULT_PLAY_TRACK = 'beta'

PLAY_LIMIT = 500

CI_WORKFLOW = 'ci.yaml'
DEPLOY_WORKFLOW = {'play': 'deploy_internal.yml', 'appstore': 'deploy_testflight.yml'}

# App Store version states, by what they mean for tonight's run.
LIVE = {
    'READY_FOR_SALE', 'READY_FOR_DISTRIBUTION', 'REPLACED_WITH_NEW_VERSION',
    'REMOVED_FROM_SALE', 'DEVELOPER_REMOVED_FROM_SALE',
}
EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED'}
NEEDS_A_PERSON = {'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY'}
# Anything else — waiting for review, in review, accepted, pending release,
# processing — is in Apple's hands, and Apple allows one such version at a
# time.


# --- Deciding, with no network ----------------------------------------------

def promotion_slot(schedule, now):
    """Whether the scheduled run `schedule` (a cron line, or None for a run
    started by hand) is tonight's 03:00 in Berlin.

    The slot, not the clock: GitHub starts scheduled runs late, sometimes by
    an hour, and the 01:00 UTC run starting at 02:05 must not count as the
    02:00 one. Its date is the day the run started, in UTC."""
    if not schedule:
        return True
    fields = schedule.split()
    if len(fields) != 5 or not fields[0].isdigit() or not fields[1].isdigit():
        raise ValueError(f'expected a cron line with a fixed minute and hour: {schedule!r}')
    utc = now.astimezone(datetime.timezone.utc)
    slot = utc.replace(hour=int(fields[1]), minute=int(fields[0]), second=0, microsecond=0)
    return slot.astimezone(BERLIN).hour == PROMOTION_HOUR


def version_key(version):
    return tuple(int(part) for part in version.split('.'))


@dataclass
class Candidate:
    """The newest build on a test track."""
    version: str
    build: int
    landed: datetime.datetime | None = None
    sha: str | None = None
    ci_green: bool = False
    deployed: bool = False


@dataclass
class Decision:
    promote: bool
    reason: str
    # A refusal someone has to look at fails the run; a quiet night does not.
    failed: bool = False
    steps: list = field(default_factory=list)


def decide(candidate, store_build, now, max_age_hours):
    """The checks both stores share. `store_build` is the highest build
    number the target already has, or None for none."""
    if candidate is None:
        return Decision(False, 'nothing on the test track')
    label = f'{candidate.version} ({candidate.build})'
    if store_build is not None and store_build >= candidate.build:
        return Decision(False, f'{label} is not newer than build {store_build}, '
                               'which the store already has')
    if max_age_hours and candidate.landed is not None:
        age = now - candidate.landed
        if age > datetime.timedelta(hours=max_age_hours):
            hours = int(age.total_seconds() // 3600)
            return Decision(False, f'{label} landed {hours} h ago, before this '
                                   f'run\'s {max_age_hours} h window; nothing new today')
    if candidate.sha is None:
        return Decision(False, f'no commit on main has the build number {candidate.build}',
                        failed=True)
    if not candidate.ci_green:
        return Decision(False, f'CI did not pass on {candidate.sha[:10]}, the commit of {label}',
                        failed=True)
    if not candidate.deployed:
        return Decision(False, f'no successful deploy run on {candidate.sha[:10]}, '
                               f'the commit of {label}', failed=True)
    return Decision(True, f'{label} goes out')


def play_current(track):
    """The highest version code a Play track serves or is rolling out."""
    codes = [
        int(code)
        for release in (track or {}).get('releases', [])
        if release.get('status') in ('completed', 'inProgress', 'halted')
        for code in release.get('versionCodes', [])
    ]
    return max(codes, default=None)


def play_candidate_release(internal):
    """The internal-track release testers have now: the completed one with
    the highest version code."""
    releases = [
        r for r in (internal or {}).get('releases', [])
        if r.get('status') == 'completed' and r.get('versionCodes')
    ]
    return max(releases, key=lambda r: max(int(c) for c in r['versionCodes']), default=None)


def play_track_releases(release, target, rollout):
    """What the target track should list after the promotion.

    All of it at once, by default. A staged rollout (`rollout` < 1) keeps
    the release everyone else has beside it, as Play requires."""
    notes = release.get('releaseNotes') or []
    new = {
        'name': release.get('name'),
        'versionCodes': [str(c) for c in release['versionCodes']],
        'releaseNotes': notes,
        'status': 'completed',
    }
    if rollout >= 1:
        return [new]
    new['status'] = 'inProgress'
    new['userFraction'] = rollout
    kept = [
        r for r in (target or {}).get('releases', []) if r.get('status') == 'completed'
    ]
    return [new] + kept[:1]


def appstore_state(version):
    attributes = version['attributes']
    return attributes.get('appStoreState') or attributes.get('appVersionState')


def appstore_plan(candidate, versions, now, max_age_hours):
    """What to do on the App Store. `versions` are the app's App Store
    versions as (id, versionString, state, build number or None)."""
    store_build = max(
        (build for _, _, state, build in versions
         if build is not None and state not in EDITABLE),
        default=None,
    )
    decision = decide(candidate, store_build, now, max_age_hours)
    if not decision.promote:
        return decision
    label = f'{candidate.version} ({candidate.build})'

    live = [v for v in versions if v[2] in LIVE]
    newest_live = max((v[1] for v in live), key=version_key, default=None)
    if newest_live and version_key(candidate.version) <= version_key(newest_live):
        return Decision(False, f'{label}: version {newest_live} is already on the App '
                               'Store; a newer build needs a newer version', failed=True)

    stuck = [v for v in versions if v[2] in NEEDS_A_PERSON]
    if stuck:
        vid, string, state, _ = stuck[0]
        return Decision(False, f'version {string} is {state}: read what App Review '
                               'said in App Store Connect before anything else goes',
                        failed=True)
    busy = [v for v in versions if v[2] not in LIVE | EDITABLE]
    if busy:
        _, string, state, _ = busy[0]
        return Decision(False, f'version {string} is {state}; Apple takes one version at '
                               f'a time, so {label} waits for the next night')

    editable = [v for v in versions if v[2] in EDITABLE]
    steps = []
    if editable:
        vid, string, state, build = editable[0]
        if string != candidate.version:
            steps.append(('rename_version', vid, candidate.version))
        else:
            steps.append(('use_version', vid, candidate.version))
    else:
        steps.append(('create_version', None, candidate.version))
    steps += [
        ('attach_build', candidate.build),
        ('release_after_approval',),
        ('whats_new' if live else 'no_whats_new_on_first_version',),
        ('export_compliance',),
        ('submit_for_review',),
    ]
    return Decision(True, decision.reason, steps=steps)


# --- Git and GitHub -----------------------------------------------------------

def git(*args):
    return subprocess.run(['git', '-C', REPO, *args], capture_output=True, text=True,
                          check=True).stdout.strip()


def sha_for_build(build, ref='origin/main'):
    """The commit on the first-parent line of `ref` whose commit count is
    `build`: the commit that build number was made from."""
    for sha in git('rev-list', '--first-parent', ref).split():
        count = int(git('rev-list', '--count', sha))
        if count == build:
            return sha
        if count < build:
            return None
    return None


def github(path):
    repo = os.environ['GITHUB_REPOSITORY']
    return call('GET', f'https://api.github.com/repos/{repo}/{path}',
                os.environ.get('GITHUB_TOKEN'))


def successful_runs(workflow, sha):
    runs = github(f'actions/workflows/{workflow}/runs?head_sha={sha}&status=success'
                  '&per_page=20') or {}
    return runs.get('workflow_runs', [])


def parse_time(text):
    return datetime.datetime.fromisoformat(text.replace('Z', '+00:00'))


def pubspec_version(sha):
    pubspec = git('show', f'{sha}:apps/weft/pubspec.yaml')
    match = re.search(r'^version: (\d+\.\d+\.\d+)\+', pubspec, re.M)
    return match.group(1) if match else None


def check_commit(candidate, store):
    """Fills in the commit and its CI and deploy results."""
    candidate.sha = sha_for_build(candidate.build)
    if candidate.sha is None:
        return
    # Play names a release whatever the uploader called it; the version is
    # what pubspec.yaml said on that commit.
    candidate.version = pubspec_version(candidate.sha) or candidate.version
    candidate.ci_green = bool(successful_runs(CI_WORKFLOW, candidate.sha))
    deploys = successful_runs(DEPLOY_WORKFLOW[store], candidate.sha)
    candidate.deployed = bool(deploys)
    if candidate.landed is None and deploys:
        # Play says nothing about when a release reached a track; the run
        # that put it there does.
        candidate.landed = min(parse_time(r['updated_at']) for r in deploys)


def release_notes(sha, version, flag):
    """release_notes.py's text for `version`, run on the commit the build
    came from, so it is the text that commit's deploy wrote."""
    with tempfile.TemporaryDirectory() as tmp:
        tree = os.path.join(tmp, 'tree')
        git('worktree', 'add', '--detach', tree, sha)
        try:
            out = os.path.join(tmp, 'out')
            subprocess.run([sys.executable, os.path.join(tree, 'tooling', 'scripts',
                                                         'release_notes.py'),
                            version, flag, out], check=True, capture_output=True)
            path = os.path.join(out, 'whatsnew-en-US') if flag == '--play-dir' else out
            with open(path, encoding='utf-8') as f:
                return f.read().strip()
        finally:
            git('worktree', 'remove', '--force', tree)


# --- Google Play --------------------------------------------------------------

def log(store, message):
    print(f'{store}: {message}', flush=True)


def play(apply, audit, now, max_age_hours, rollout, track):
    token = play_token()
    edit = call('POST', f'{PLAY}/edits', token, body={})['id']
    committed = False
    try:
        base = f'{PLAY}/edits/{edit}'
        internal = call('GET', f'{base}/tracks/internal', token)
        target = call('GET', f'{base}/tracks/{track}', token)
        release = play_candidate_release(internal)
        candidate = None
        if release:
            code = max(int(c) for c in release['versionCodes'])
            candidate = Candidate(release.get('name') or '?', code)
            log('play', f'internal track: {release.get("name")} ({code})')
            check_commit(candidate, 'play')
        current = play_current(target)
        log('play', f'{track}: {"build " + str(current) if current else "nothing yet"}')
        decision = decide(candidate, current, now, max_age_hours)
        if candidate is not None:
            log('play', f'commit {candidate.sha or "?"}, CI '
                        f'{"green" if candidate.ci_green else "not green"}, deploy '
                        f'{"succeeded" if candidate.deployed else "not found"}, landed '
                        f'{candidate.landed.isoformat() if candidate.landed else "?"}')
        log('play', decision.reason)

        if decision.promote:
            if not release.get('releaseNotes') and candidate.sha:
                notes = release_notes(candidate.sha, candidate.version, '--play-dir')
                release['releaseNotes'] = [{'language': 'en-US', 'text': notes[:PLAY_LIMIT]}]
            releases = play_track_releases(release, target, rollout)
            body = {'track': track, 'releases': releases}
            log('play', f'{track} track would become:')
            for r in releases:
                text = ' / '.join(n.get('text', '').replace('\n', ' ⏎ ')[:120] + '…'
                                  for n in r.get('releaseNotes', []))
                log('play', f'  {r["name"]} {r["versionCodes"]} {r["status"]}'
                            f'{" " + str(r["userFraction"]) if "userFraction" in r else ""}'
                            f' notes: {text or "none"}')
            call('PUT', f'{base}/tracks/{track}', token, body=body)
            # Play's own verdict on the release, without publishing it.
            try:
                call('POST', f'{base}:validate', token, body={})
                log('play', f'Play validated the {track} release')
            except ApiError as error:
                log('play', f'Play refuses the {track} release:\n{error}')
                decision.failed = True
                decision.promote = False
            if decision.promote and apply:
                params = ''
                if os.environ.get('PLAY_CHANGES_NOT_SENT_FOR_REVIEW') == 'true':
                    params = '?changesNotSentForReview=true'
                call('POST', f'{base}:commit{params}', token, body={})
                committed = True
                log('play', f'PROMOTED {release.get("name")} to {track}')
            elif decision.promote:
                log('play', 'dry run: not committed')

        if audit:
            play_audit(token, base, track)
        return decision
    finally:
        if not committed:
            # An edit that is never committed changes nothing; deleting it
            # keeps it from blocking the next one.
            try:
                call('DELETE', f'{PLAY}/edits/{edit}', token)
            except ApiError:
                pass


def play_audit(token, base, track):
    print(f'play: --- before the first public release on {track} ---')
    details = call('GET', f'{base}/details', token) or {}
    for key in ('defaultLanguage', 'contactEmail', 'contactWebsite'):
        print(f'play: [{"x" if details.get(key) else " "}] details.{key}')
    listings = (call('GET', f'{base}/listings', token) or {}).get('listings', [])
    if not listings:
        print('play: [ ] store listing: none in any language')
    for listing in listings:
        language = listing.get('language')
        for key in ('title', 'shortDescription', 'fullDescription'):
            print(f'play: [{"x" if listing.get(key) else " "}] listing {language} {key}')
        for kind, needed in (('icon', 1), ('featureGraphic', 1), ('phoneScreenshots', 2),
                             ('sevenInchScreenshots', 0), ('tenInchScreenshots', 0)):
            images = (call('GET', f'{base}/listings/{language}/{kind}', token) or {}
                      ).get('images', [])
            mark = 'x' if len(images) >= needed else ' '
            print(f'play: [{mark}] listing {language} {kind}: {len(images)}'
                  f'{f" (needs {needed})" if needed else " (optional)"}')
    countries = call('GET', f'{base}/countryAvailability/{track}', token) or {}
    regions = [c.get('countryCode') for c in countries.get('countries', [])]
    print(f'play: [{"x" if regions else " "}] {track} countries: {len(regions)}'
          f'{" (" + ", ".join(sorted(regions)[:12]) + "…)" if regions else ""}'
          f'{" restOfWorld" if countries.get("restOfWorld") else ""}')
    tracks = (call('GET', f'{base}/tracks', token) or {}).get('tracks', [])
    print('play: tracks: ' + ', '.join(
        f'{t["track"]}={[r.get("name") + ":" + r.get("status", "") for r in t.get("releases", [])]}'
        for t in tracks))
    product = call('GET', f'{PLAY}/oneTimeProducts/{PRODUCT_ID}', token)
    states = [o.get('state') for o in (product or {}).get('purchaseOptions', [])]
    print(f'play: [{"x" if "ACTIVE" in states else " "}] in-app product {PRODUCT_ID}: '
          f'{states or "missing"}')
    print('play: not readable through the API — check under Policy > App content: '
          'privacy policy, app access (review login), ads, content rating, target '
          'audience, data safety, government/financial/health declarations; and the '
          'Android Auto form factor opt-in and review under Advanced settings')


# --- App Store Connect --------------------------------------------------------

def appstore(apply, audit, now, max_age_hours):
    token = asc_token()
    apps = call('GET', f'{ASC}/v1/apps?filter[bundleId]={PACKAGE}', token)['data']
    if not apps:
        raise ApiError(f'no app with bundle id {PACKAGE}')
    app = apps[0]['id']

    builds = appstore_builds(token, app)
    usable = [b for b in builds if b['state'] == 'VALID' and not b['expired']]
    newest = max(builds, key=lambda b: b['build'], default=None)
    eligible = [b for b in usable if b['audience'] != 'INTERNAL_ONLY']
    best = max(eligible, key=lambda b: b['build'], default=None)
    if newest:
        log('appstore', f'newest TestFlight build: {newest["version"]} ({newest["build"]}), '
                        f'{newest["state"]}, {newest["audience"]}, uploaded {newest["uploaded"]}')
    if newest and (best is None or newest['build'] > best['build']):
        log('appstore', 'the newest build is internal-only or not processed; only an App '
                        'Store eligible build can be attached to a version (deploy_testflight.yml '
                        'uploads those while STORE_PROMOTION_ENABLED is true)')
    candidate = None
    if best:
        candidate = Candidate(best['version'], best['build'], landed=best['uploaded'])
        check_commit(candidate, 'appstore')
        log('appstore', f'candidate {best["version"]} ({best["build"]}), commit '
                        f'{candidate.sha or "?"}, CI {"green" if candidate.ci_green else "not green"}, '
                        f'deploy {"succeeded" if candidate.deployed else "not found"}')

    versions = appstore_versions(token, app)
    for vid, string, state, build in versions:
        log('appstore', f'App Store version {string}: {state}, build {build}')
    if newest and best is not newest and newest['state'] == 'VALID':
        # What tonight would have done, had the newest build been eligible.
        what_if = Candidate(newest['version'], newest['build'], landed=newest['uploaded'])
        check_commit(what_if, 'appstore')
        plan = appstore_plan(what_if, versions, now, max_age_hours)
        log('appstore', f'were {newest["version"]} ({newest["build"]}) eligible: {plan.reason}'
                        + ''.join(f'; {describe(step)}' for step in plan.steps))
    decision = appstore_plan(candidate, versions, now, max_age_hours)
    log('appstore', decision.reason)
    if decision.promote:
        for step in decision.steps:
            log('appstore', f'{"" if apply else "would "}{describe(step)}')
        if apply:
            appstore_apply(token, app, best, candidate, decision.steps)
        else:
            appstore_preview(token, app, best, candidate, decision.steps)
    if audit:
        appstore_audit(token, app, versions)
    return decision


def describe(step):
    kind = step[0]
    return {
        'rename_version': lambda: f'rename the open App Store version to {step[2]}',
        'use_version': lambda: f'use the open App Store version {step[2]}',
        'create_version': lambda: f'create App Store version {step[2]}',
        'attach_build': lambda: f'attach build {step[1]}',
        'release_after_approval': lambda: 'release automatically once approved',
        'whats_new': lambda: 'set "What\'s New" (en-US) from release_notes.py',
        'no_whats_new_on_first_version': lambda: 'leave "What\'s New" empty: Apple has none '
                                                 'for an app\'s first version',
        'export_compliance': lambda: 'answer export compliance as the last answered build was',
        'submit_for_review': lambda: 'submit for App Review',
    }[kind]()


def appstore_builds(token, app):
    page = call('GET', f'{ASC}/v1/builds?' + urllib.parse.urlencode({
        'filter[app]': app,
        'sort': '-uploadedDate',
        'limit': 20,
        'include': 'preReleaseVersion',
    }, safe='[],'), token)
    versions = {
        i['id']: i['attributes']['version']
        for i in page.get('included', []) if i['type'] == 'preReleaseVersions'
    }
    builds = []
    for b in page['data']:
        attributes = b['attributes']
        pre = (b['relationships'].get('preReleaseVersion') or {}).get('data') or {}
        builds.append({
            'id': b['id'],
            'build': int(attributes['version']),
            'version': versions.get(pre.get('id'), '?'),
            'uploaded': parse_time(attributes['uploadedDate']),
            'state': attributes.get('processingState'),
            'expired': attributes.get('expired'),
            'audience': attributes.get('buildAudienceType'),
            'encryption': attributes.get('usesNonExemptEncryption'),
        })
    return builds


def appstore_versions(token, app):
    page = call('GET', f'{ASC}/v1/apps/{app}/appStoreVersions?' + urllib.parse.urlencode({
        'filter[platform]': 'IOS',
        'include': 'build',
        'limit': 50,
    }, safe='[],'), token)
    numbers = {
        i['id']: int(i['attributes']['version'])
        for i in page.get('included', []) if i['type'] == 'builds'
    }
    versions = []
    for v in page['data']:
        build = ((v.get('relationships') or {}).get('build') or {}).get('data') or {}
        versions.append((v['id'], v['attributes']['versionString'], appstore_state(v),
                         numbers.get(build.get('id'))))
    return versions


def compliance_source(token, app):
    """The newest build whose export compliance a person answered, and the
    declaration that answer made. Sennit's answer never changes — standard
    algorithms, not on sale in France; see docs/RELEASING.md — so the next
    build gets the same one."""
    page = call('GET', f'{ASC}/v1/builds?' + urllib.parse.urlencode({
        'filter[app]': app,
        'sort': '-uploadedDate',
        'limit': 50,
    }, safe='[],'), token)
    for b in page['data']:
        answer = b['attributes'].get('usesNonExemptEncryption')
        if answer is None:
            continue
        declaration = (call('GET', f'{ASC}/v1/builds/{b["id"]}/appEncryptionDeclaration',
                            token) or {}).get('data')
        return b, answer, declaration
    return None, None, None


def check_declaration(declaration):
    if declaration is None:
        return None
    attributes = declaration['attributes']
    if attributes.get('availableOnFrenchStore') or attributes.get('containsProprietaryCryptography'):
        raise ApiError('the last export compliance answer says France or proprietary '
                       'cryptography; docs/RELEASING.md says neither, so a person decides')
    return declaration['id']


def appstore_preview(token, app, best, candidate, steps):
    source, answer, declaration = compliance_source(token, app)
    if best['encryption'] is not None:
        log('appstore', f'  export compliance already answered on build {best["build"]}')
    elif source is None:
        log('appstore', '  no build has an export compliance answer to copy: answer '
                        'this one by hand first')
    else:
        log('appstore', f'  export compliance: copy usesNonExemptEncryption={answer} from '
                        f'build {source["attributes"]["version"]}, declaration '
                        f'{declaration["id"] if declaration else "none"} '
                        f'{declaration["attributes"] if declaration else ""}')
    if any(s[0] == 'whats_new' for s in steps):
        notes = release_notes(candidate.sha, candidate.version, '--store')
        log('appstore', f'  "What\'s New":\n{notes}')


def appstore_apply(token, app, best, candidate, steps):
    version_id = None
    for step in steps:
        kind = step[0]
        if kind in ('rename_version', 'use_version'):
            version_id = step[1]
            call('PATCH', f'{ASC}/v1/appStoreVersions/{version_id}', token, body={'data': {
                'type': 'appStoreVersions', 'id': version_id,
                'attributes': {'versionString': step[2], 'releaseType': 'AFTER_APPROVAL'},
            }})
        elif kind == 'create_version':
            version_id = call('POST', f'{ASC}/v1/appStoreVersions', token, body={'data': {
                'type': 'appStoreVersions',
                'attributes': {'platform': 'IOS', 'versionString': step[2],
                               'releaseType': 'AFTER_APPROVAL'},
                'relationships': {'app': {'data': {'type': 'apps', 'id': app}}},
            }})['data']['id']
        elif kind == 'attach_build':
            call('PATCH', f'{ASC}/v1/appStoreVersions/{version_id}/relationships/build',
                 token, body={'data': {'type': 'builds', 'id': best['id']}})
        elif kind == 'whats_new':
            notes = release_notes(candidate.sha, candidate.version, '--store')
            localizations = call('GET', f'{ASC}/v1/appStoreVersions/{version_id}'
                                        '/appStoreVersionLocalizations', token)['data']
            english = next((l for l in localizations
                            if l['attributes'].get('locale') == 'en-US'), None)
            if english is None:
                raise ApiError(f'version {candidate.version} has no en-US localization')
            call('PATCH', f'{ASC}/v1/appStoreVersionLocalizations/{english["id"]}', token,
                 body={'data': {'type': 'appStoreVersionLocalizations', 'id': english['id'],
                                'attributes': {'whatsNew': notes}}})
        elif kind == 'export_compliance' and best['encryption'] is None:
            source, answer, declaration = compliance_source(token, app)
            if source is None:
                raise ApiError('no build has an export compliance answer to copy')
            declaration_id = check_declaration(declaration)
            if declaration_id:
                call('POST', f'{ASC}/v1/appEncryptionDeclarations/{declaration_id}'
                             '/relationships/builds', token,
                     body={'data': [{'type': 'builds', 'id': best['id']}]})
            call('PATCH', f'{ASC}/v1/builds/{best["id"]}', token, body={'data': {
                'type': 'builds', 'id': best['id'],
                'attributes': {'usesNonExemptEncryption': answer},
            }})
        elif kind == 'submit_for_review':
            submit(token, app, version_id)
        log('appstore', f'done: {describe(step)}')
    log('appstore', f'SUBMITTED {candidate.version} ({candidate.build}) for review')


def submit(token, app, version_id):
    # A submission a crashed run left unsubmitted is reused, not doubled.
    open_ones = call('GET', f'{ASC}/v1/reviewSubmissions?' + urllib.parse.urlencode({
        'filter[app]': app, 'filter[platform]': 'IOS', 'filter[state]': 'READY_FOR_REVIEW',
    }, safe='[],'), token)['data']
    if open_ones:
        submission = open_ones[0]['id']
    else:
        submission = call('POST', f'{ASC}/v1/reviewSubmissions', token, body={'data': {
            'type': 'reviewSubmissions',
            'attributes': {'platform': 'IOS'},
            'relationships': {'app': {'data': {'type': 'apps', 'id': app}}},
        }})['data']['id']
    items = call('GET', f'{ASC}/v1/reviewSubmissions/{submission}/items', token)['data']
    if not items:
        call('POST', f'{ASC}/v1/reviewSubmissionItems', token, body={'data': {
            'type': 'reviewSubmissionItems',
            'relationships': {
                'reviewSubmission': {'data': {'type': 'reviewSubmissions', 'id': submission}},
                'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version_id}},
            },
        }})
    call('PATCH', f'{ASC}/v1/reviewSubmissions/{submission}', token, body={'data': {
        'type': 'reviewSubmissions', 'id': submission, 'attributes': {'submitted': True},
    }})


def mark(ok):
    return 'x' if ok else ' '


def appstore_audit(token, app, versions):
    print('appstore: --- before the first App Store release ---')
    attributes = call('GET', f'{ASC}/v1/apps/{app}', token)['data']['attributes']
    print(f'appstore: [{mark(attributes.get("contentRightsDeclaration"))}] content rights '
          f'declaration: {attributes.get("contentRightsDeclaration")}')

    infos = call('GET', f'{ASC}/v1/apps/{app}/appInfos', token)['data']
    info = next((i for i in infos if i['attributes'].get('state') not in
                 ('READY_FOR_DISTRIBUTION',)), infos[0] if infos else None)
    if info:
        category = (call('GET', f'{ASC}/v1/appInfos/{info["id"]}/primaryCategory', token)
                    or {}).get('data')
        print(f'appstore: [{mark(category)}] primary category: '
              f'{category["id"] if category else "none"}')
        rating = (call('GET', f'{ASC}/v1/appInfos/{info["id"]}/ageRatingDeclaration', token)
                  or {}).get('data')
        unanswered = [k for k, v in ((rating or {}).get('attributes') or {}).items() if v is None]
        print(f'appstore: [{mark(rating and not unanswered)}] age rating questionnaire'
              f'{": unanswered " + ", ".join(sorted(unanswered)) if unanswered else ""}')
        for loc in call('GET', f'{ASC}/v1/appInfos/{info["id"]}/appInfoLocalizations',
                        token)['data']:
            a = loc['attributes']
            for key in ('name', 'subtitle', 'privacyPolicyUrl'):
                print(f'appstore: [{mark(a.get(key))}] app info {a.get("locale")} {key}')

    schedule = call('GET', f'{ASC}/v1/apps/{app}/appPriceSchedule', token)
    print(f'appstore: [{mark(schedule and schedule.get("data"))}] price schedule')
    availability = call('GET', f'{ASC}/v1/apps/{app}/appAvailabilityV2', token)
    if availability and availability.get('data'):
        territories = asc_all(f'{ASC}/v2/appAvailabilities/{availability["data"]["id"]}'
                              '/territoryAvailabilities?limit=200&include=territory', token)
        available = {
            ((t.get('relationships') or {}).get('territory') or {}).get('data', {}).get('id')
            for t in territories if t['attributes'].get('available')
        }
        print(f'appstore: [{mark(available)}] available in {len(available)} territories')
        for code, name in (('FRA', 'France'), ('CHN', 'mainland China')):
            print(f'appstore: [{mark(code not in available)}] {name} not available')
    else:
        print('appstore: [ ] availability: not set')

    # The open version, or else the one on sale: a new version starts as a
    # copy of its listing.
    editable = [v for v in versions if v[2] in EDITABLE]
    live = sorted((v for v in versions if v[2] in LIVE), key=lambda v: version_key(v[1]))
    shown = editable[:1] or live[-1:]
    if not shown:
        print('appstore: no App Store version to check the listing on')
    for vid, string, state, build in shown:
        print(f'appstore: listing of version {string} ({state}):')
        for loc in call('GET', f'{ASC}/v1/appStoreVersions/{vid}/appStoreVersionLocalizations',
                        token)['data']:
            a = loc['attributes']
            locale = a.get('locale')
            for key in ('description', 'keywords', 'supportUrl', 'marketingUrl'):
                optional = ' (optional)' if key == 'marketingUrl' else ''
                print(f'appstore: [{mark(a.get(key))}] {locale} {key}{optional}')
            sets = call('GET', f'{ASC}/v1/appStoreVersionLocalizations/{loc["id"]}'
                               '/appScreenshotSets', token)['data']
            found = {}
            for s in sets:
                shots = call('GET', f'{ASC}/v1/appScreenshotSets/{s["id"]}/appScreenshots',
                             token)['data']
                found[s['attributes']['screenshotDisplayType']] = len(shots)
            # The largest size of each device family is the one Apple asks
            # for; the app runs on iPad and has a watch app.
            for kinds, label in ((('APP_IPHONE_67', 'APP_IPHONE_65'), 'iPhone 6.9" or 6.5"'),
                                 (('APP_IPAD_PRO_3GEN_129', 'APP_IPAD_PRO_129'), 'iPad 13"'),
                                 (('APP_WATCH_',), 'Apple Watch')):
                count = sum(n for k, n in found.items() if k.startswith(kinds))
                print(f'appstore: [{mark(count)}] {locale} screenshots {label}: {count}')
        review = (call('GET', f'{ASC}/v1/appStoreVersions/{vid}/appStoreReviewDetail', token)
                  or {}).get('data')
        r = (review or {}).get('attributes') or {}
        # Whether each is set, never what it is: the log is public.
        for key in ('contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail',
                    'demoAccountName', 'demoAccountPassword', 'notes'):
            print(f'appstore: [{mark(r.get(key))}] review detail {key}')
        print(f'appstore: [{mark(r.get("demoAccountRequired"))}] review detail '
              'demoAccountRequired (a Matrix login is needed to see anything)')

    found = call('GET', f'{ASC}/v1/apps/{app}/inAppPurchasesV2?filter[productId]={PRODUCT_ID}',
                 token)['data']
    state = found[0]['attributes'].get('state') if found else 'missing'
    print(f'appstore: [{mark(state in ("READY_TO_SUBMIT", "WAITING_FOR_REVIEW", "APPROVED"))}] '
          f'in-app purchase {PRODUCT_ID}: {state} (the first one goes to review with a version)')
    declarations = call('GET', f'{ASC}/v1/apps/{app}/appEncryptionDeclarations', token)['data']
    print(f'appstore: export compliance declarations: '
          f'{[(d["id"], d["attributes"]) for d in declarations] or "none"}')
    source, answer, _ = compliance_source(token, app)
    print(f'appstore: [{mark(source)}] a build with an export compliance answer to copy'
          f'{": build " + source["attributes"]["version"] + " says usesNonExemptEncryption=" + str(answer) if source else ""}')
    submissions = call('GET', f'{ASC}/v1/reviewSubmissions?filter[app]={app}'
                              '&filter[platform]=IOS&limit=10', token)['data']
    print(f'appstore: review submissions: '
          f'{[s["attributes"].get("state") for s in submissions] or "none"}')
    print('appstore: not readable through the API — check in App Store Connect: App '
          'Privacy (data collection labels), and that the review notes explain the demo '
          'homeserver')


# --- Entry point --------------------------------------------------------------

def main(argv):
    args = list(argv)
    apply = '--apply' in args
    audit = '--audit' in args
    schedule = None
    max_age_hours = DEFAULT_MAX_AGE_HOURS
    play_track = DEFAULT_PLAY_TRACK
    targets = []
    while args:
        arg = args.pop(0)
        if arg in ('--apply', '--audit'):
            continue
        if arg == '--schedule' and args:
            schedule = args.pop(0) or None
        elif arg == '--play-track' and args:
            play_track = args.pop(0) or DEFAULT_PLAY_TRACK
        elif arg == '--max-age-hours' and args:
            max_age_hours = int(args.pop(0) or DEFAULT_MAX_AGE_HOURS)
        elif arg in ('play', 'appstore', 'all'):
            targets.append(arg)
        else:
            sys.exit(f'unknown option {arg!r}\n{__doc__}')
    chosen = ['play', 'appstore'] if not targets or 'all' in targets else targets

    now = datetime.datetime.now(datetime.timezone.utc)
    if not promotion_slot(schedule, now):
        print(f'the {schedule!r} slot is not {PROMOTION_HOUR}:00 in Berlin today; '
              'the other scheduled run is the one')
        return
    rollout = float(os.environ.get('PLAY_PRODUCTION_ROLLOUT') or 1)
    print(f'{"APPLY" if apply else "DRY RUN"} at {now.astimezone(BERLIN):%Y-%m-%d %H:%M %Z}, '
          f'window {max_age_hours or "unlimited"} h, Play track {play_track}, '
          f'rollout {rollout:.0%}')

    failed = False
    for name in chosen:
        try:
            if name == 'play':
                decision = play(apply, audit, now, max_age_hours, rollout, play_track)
            else:
                decision = appstore(apply, audit, now, max_age_hours)
            failed |= decision.failed
        except (ApiError, KeyError, subprocess.CalledProcessError) as error:
            failed = True
            print(f'{name}: FAILED: {error!r}' if isinstance(error, KeyError)
                  else f'{name}: FAILED: {error}', file=sys.stderr)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main(sys.argv[1:])
