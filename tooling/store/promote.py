#!/usr/bin/env python3
"""Promotes the newest tested build to Google Play and the App Store.

    promote.py [play|appstore|all] [--apply] [--audit]
               [--schedule CRON] [--max-age-hours N] [--play-tracks TRACKS]

Run every night by promote_to_stores.yml; see
docs/decisions/adr-005-daily-store-promotion.md for why it decides what it
decides. Per store, it takes the newest build on the test track — Play's
internal track, TestFlight — and promotes it when all of these hold:

1. it is newer, by build number, than anything the target already has —
   the Play track, the App Store or App Review — which is what makes a
   second run a no-op;
2. it landed on the test track within the last N hours (default 26: one
   night's window, plus GitHub's habit of starting scheduled runs late);
3. CI passed on the commit it was built from, and the deploy workflow that
   uploaded it succeeded on that commit.

On the App Store, a build that fails only the third rule — say its CI was
cancelled because a later push superseded it — is skipped, and the next
older App Store eligible build on TestFlight is tried under the same rules.
The run fails only when no build qualifies and one was skipped.

The build number is the commit count of main (`git rev-list --count`), so
the commit is found again from the number, on the first-parent line of
origin/main; the checkout needs the full history.

Without `--apply` it reads, prints exactly what it would do, and changes
nothing. Play's would-be release is still checked by Play itself, in an
edit that is validated and then deleted, never committed.

On Play the build goes to two tracks, in one edit that is committed once,
so the night sends Google one set of changes to review:

- open testing, `beta`, to everyone at once;
- `production`, as a staged rollout to PLAY_PRODUCTION_ROLLOUT of users
  (default 0.2), next to the last completed release, which everyone else
  keeps. The first release on production cannot be staged, so it goes to
  everyone.

Before that, a staged production rollout that has been out a night is
completed: when its build landed on the internal track 24 hours ago or more
(Play does not say when a rollout started; the nightly run that started it
came after the landing, and the one now running is the next), it goes to
100 % and becomes the completed release. If a newer build goes out the same
night, it is staged next to that one. A staged release not yet out a night
(only after a promotion by hand) is replaced by the newer one, as Play does:
the release it replaces is dropped, the users who got it keep it until the
new one reaches them, and the completed release stays everyone else's. A
halted rollout stops production until someone resumes or replaces it in the
Console. `--play-tracks` (PLAY_PROMOTION_TRACKS in the workflow, comma
separated) picks the tracks; `beta` alone takes production out.
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
from build_notes import store_text
from listings import LOCALES, whats_new

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BERLIN = ZoneInfo('Europe/Berlin')
PROMOTION_HOUR = 3
DEFAULT_MAX_AGE_HOURS = 26
# Open testing to everyone, production staged.
DEFAULT_PLAY_TRACKS = ('beta', 'production')
STAGED_TRACK = 'production'
DEFAULT_PRODUCTION_ROLLOUT = 0.2
# How long a staged production rollout runs before the nightly run
# completes it.
STAGED_HOURS = 24

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


def play_label(release):
    codes = ', '.join(str(c) for c in release.get('versionCodes', []))
    return f'{release.get("name")} ({codes})'


def percent(fraction):
    return f'{fraction * 100:g} %'


def play_plan(track, target, release, decision, rollout, staged_landed, now):
    """What tonight does to one Play track: (Decision, the releases the
    track should list afterwards, or None to leave it as it is).

    `decision` is decide()'s verdict on the candidate `release` for this
    track; `rollout` the fraction a new release starts at; `staged_landed`
    when the build of the track's staged release landed on the internal
    track, or None when that is unknown or there is none. The steps are
    ('complete', release) and ('promote', release, fraction)."""
    releases = (target or {}).get('releases', [])
    halted = next((r for r in releases if r.get('status') == 'halted'), None)
    if halted:
        return Decision(False, f'{play_label(halted)} is halted on {track}: nothing goes '
                               f'to {track} until someone resumes or replaces it in the '
                               'Console'), None
    completed = [r for r in releases if r.get('status') == 'completed']
    staged = next((r for r in releases if r.get('status') == 'inProgress'), None)
    steps = []
    reasons = []
    failed = decision.failed

    if staged:
        label = f'{play_label(staged)} at {percent(staged.get("userFraction", 0))}'
        if staged_landed is None:
            reasons.append(f'{label}: cannot tell when it landed, so it is not completed; '
                           'complete it in the Console')
            failed = True
        elif now - staged_landed >= datetime.timedelta(hours=STAGED_HOURS):
            done = {k: v for k, v in staged.items() if k != 'userFraction'}
            done['status'] = 'completed'
            steps.append(('complete', staged))
            reasons.append(f'{label} has been out a night: completing it, to 100 %')
            completed, staged = [done], None
        else:
            hours = int((now - staged_landed).total_seconds() // 3600)
            reasons.append(f'{label} landed {hours} h ago, under {STAGED_HOURS} h: '
                           'it stays staged')

    reasons.append(decision.reason)
    fraction = rollout if track == STAGED_TRACK else 1
    if decision.promote and fraction < 1 and not completed:
        # Play: "The first release on a track cannot be staged". So the first
        # one goes to everyone, and the ones after it are staged again.
        reasons.append(f'Play cannot stage the first release on {track}: it goes to everyone')
        fraction = 1
    after = None
    if decision.promote:
        after = play_track_releases(release, {'releases': completed}, fraction)
        steps.append(('promote', release, fraction))
        if fraction < 1 and staged:
            reasons.append(f'it replaces the staged {play_label(staged)}; whoever got that '
                           'keeps it until the new one reaches them')
    elif steps:
        after = completed
    return Decision(bool(steps), '; '.join(reasons), failed=failed, steps=steps), after


def describe_play(track, step):
    if step[0] == 'complete':
        return (f'complete the staged {play_label(step[1])} on {track}: '
                f'{percent(step[1].get("userFraction", 0))} -> 100 %')
    _, release, fraction = step
    how = 'to everyone' if fraction >= 1 else f'staged to {percent(fraction)}'
    return f'promote {play_label(release)} to {track}, {how}'


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


def commit_refused(candidate):
    """Whether the commit behind `candidate` is what keeps it back: no
    commit, CI not green or no successful deploy."""
    return candidate.sha is None or not candidate.ci_green or not candidate.deployed


def appstore_choice(builds, versions, now, max_age_hours, check):
    """Walks the App Store eligible `builds` newest first and returns
    (build, candidate, decision, skipped): the first build the plan
    promotes, or the refusal that holds for the older ones too. A build kept
    back only by its commit — CI cancelled by a later push, say — is
    skipped, with why, in `skipped`, and the next older one is tried.
    `check` fills in a Candidate's commit, as check_commit does."""
    skipped = []
    for build in sorted(builds, key=lambda b: b['build'], reverse=True):
        candidate = Candidate(build['version'], build['build'], landed=build['uploaded'])
        check(candidate)
        decision = appstore_plan(candidate, versions, now, max_age_hours)
        if decision.promote:
            return build, candidate, decision, skipped
        if decision.failed and commit_refused(candidate):
            skipped.append(decision.reason)
            continue
        if skipped:
            # The older builds are out too; what kept the newer ones back
            # still needs a look.
            decision = Decision(False, f'{decision.reason}; and {"; ".join(skipped)}',
                                failed=True)
        return build, candidate, decision, skipped
    if skipped:
        return None, None, Decision(False, 'no build qualifies: ' + '; '.join(skipped),
                                    failed=True), skipped
    return None, None, decide(None, None, now, max_age_hours), skipped


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
            if flag == '--play-dir':
                return play_notes_from(out)
            with open(out, encoding='utf-8') as f:
                return f.read().strip()
        finally:
            git('worktree', 'remove', '--force', tree)


def play_notes_from(directory):
    """Play's releaseNotes from release_notes.py's `whatsnew-<language>`
    files."""
    notes = []
    for name in sorted(os.listdir(directory)):
        if name.startswith('whatsnew-'):
            with open(os.path.join(directory, name), encoding='utf-8') as f:
                notes.append({'language': name[len('whatsnew-'):],
                              'text': f.read().strip()[:PLAY_LIMIT]})
    return notes


# --- Google Play --------------------------------------------------------------

def log(store, message):
    print(f'{store}: {message}', flush=True)


IN_REVIEW_SKIP = 'previous release still in review, not replacing'
# Play's refusal of a commit with ERROR_IF_IN_REVIEW, in the error's text.
IN_REVIEW = re.compile(r'\b(?:in|under) review\b|being reviewed|IN_REVIEW', re.IGNORECASE)


def play_commit(token, base):
    """Commits the edit `base`, unless changes sent earlier are still in
    Google's review: a commit then would withdraw them and restart the review
    with this edit, and a nightly promotion would keep any release from ever
    getting through. Returns False when Play refused for that reason."""
    params = {'changesInReviewBehavior': 'ERROR_IF_IN_REVIEW'}
    if os.environ.get('PLAY_CHANGES_NOT_SENT_FOR_REVIEW') == 'true':
        params['changesNotSentForReview'] = 'true'
    try:
        call('POST', f'{base}:commit?{urllib.parse.urlencode(params)}', token, body={})
    except ApiError as error:
        # The first line is the request, whose URL names ERROR_IF_IN_REVIEW
        # itself; Play's answer follows it.
        if IN_REVIEW.search(str(error).partition('\n')[2]):
            return False
        raise
    return True


def play(apply, audit, now, max_age_hours, rollout, tracks):
    token = play_token()
    edit = call('POST', f'{PLAY}/edits', token, body={})['id']
    committed = False
    try:
        base = f'{PLAY}/edits/{edit}'
        internal = call('GET', f'{base}/tracks/internal', token)
        release = play_candidate_release(internal)
        candidate = None
        if release:
            code = max(int(c) for c in release['versionCodes'])
            candidate = Candidate(release.get('name') or '?', code)
            log('play', f'internal track: {release.get("name")} ({code})')
            check_commit(candidate, 'play')
            log('play', f'commit {candidate.sha or "?"}, CI '
                        f'{"green" if candidate.ci_green else "not green"}, deploy '
                        f'{"succeeded" if candidate.deployed else "not found"}, landed '
                        f'{candidate.landed.isoformat() if candidate.landed else "?"}')
            if not release.get('releaseNotes') and candidate.sha:
                release['releaseNotes'] = release_notes(candidate.sha, candidate.version,
                                                        '--play-dir')
        if audit:
            play_audit(token, base, tracks)

        failed = False
        planned = []
        for track in tracks:
            decision = play_track(token, base, track, release, candidate, now,
                                  max_age_hours, rollout)
            failed |= decision.failed
            if decision.promote:
                planned += [describe_play(track, step) for step in decision.steps]

        if planned:
            # Play's own verdict on the releases, without publishing them.
            try:
                call('POST', f'{base}:validate', token, body={})
                log('play', 'Play validated the releases')
            except ApiError as error:
                log('play', f'Play refuses the releases:\n{error}')
                failed = True
                planned = []
        if planned and apply:
            if play_commit(token, base):
                committed = True
                log('play', f'DONE: {"; ".join(planned)}')
            else:
                log('play', f'{IN_REVIEW_SKIP}: Play still reviews what was sent '
                            'earlier; committing would withdraw it and restart the '
                            'review, so Play (beta and production alike) waits for '
                            'another night')
                planned = []
        elif planned:
            log('play', 'dry run: not committed. Whether Play still reviews an earlier '
                        'release it says only at commit; if it does, the real run '
                        f'logs "{IN_REVIEW_SKIP}" and leaves Play alone')
        log('play', f'--- tonight on Play{"" if apply else " (dry run)"}: '
                    f'{"; ".join(planned) or "nothing"} ---')
        return Decision(bool(planned), 'play', failed=failed)
    finally:
        if not committed:
            delete_edit(token, edit)


def delete_edit(token, edit):
    # An edit that is never committed changes nothing; deleting it keeps it
    # from blocking the next one.
    try:
        call('DELETE', f'{PLAY}/edits/{edit}', token)
    except ApiError:
        pass


def staged_since(target):
    """When the build of a track's staged release landed on the internal
    track, which is as close as Play lets anyone get to when its rollout
    started: None when there is no staged release or the landing is not
    found."""
    staged = next((r for r in (target or {}).get('releases', [])
                   if r.get('status') == 'inProgress' and r.get('versionCodes')), None)
    if staged is None:
        return None
    build = Candidate(staged.get('name') or '?', max(int(c) for c in staged['versionCodes']))
    check_commit(build, 'play')
    return build.landed


def play_track(token, base, track, release, candidate, now, max_age_hours, rollout):
    """Plans one Play track and puts the result in the edit `base`, which
    play() validates and commits once for all tracks."""
    log('play', f'--- {track} ---')
    target = call('GET', f'{base}/tracks/{track}', token)
    log('play', f'{track} now: ' + (', '.join(
        f'{play_label(r)} {r.get("status")}'
        f'{" " + percent(r["userFraction"]) if "userFraction" in r else ""}'
        for r in (target or {}).get('releases', [])) or 'nothing'))
    decision, releases = play_plan(
        track, target, release,
        decide(candidate, play_current(target), now, max_age_hours),
        rollout, staged_since(target), now)
    log('play', decision.reason)
    if releases is None:
        return decision

    for step in decision.steps:
        log('play', f'plan: {describe_play(track, step)}')
    log('play', f'{track} would become:')
    for r in releases:
        text = ' / '.join(n.get('text', '').replace('\n', ' ⏎ ')[:120] + '…'
                          for n in r.get('releaseNotes', []))
        log('play', f'  {play_label(r)} {r["status"]}'
                    f'{" " + percent(r["userFraction"]) if "userFraction" in r else ""}'
                    f' notes: {text or "none"}')
    call('PUT', f'{base}/tracks/{track}', token, body={'track': track, 'releases': releases})
    return decision


def play_audit(token, base, tracks):
    print(f'play: --- what Play wants for a release on {", ".join(tracks)} ---')
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
    for track in tracks:
        countries = call('GET', f'{base}/countryAvailability/{track}', token) or {}
        regions = [c.get('countryCode') for c in countries.get('countries', [])]
        print(f'play: [{"x" if regions else " "}] {track} countries: {len(regions)}'
              f'{" (" + ", ".join(sorted(regions)[:12]) + "…)" if regions else ""}'
              f'{" restOfWorld" if countries.get("restOfWorld") else ""}')
    for t in (call('GET', f'{base}/tracks', token) or {}).get('tracks', []):
        print(f'play: track {t["track"]}: ' + (', '.join(
            f'{r.get("name")} {r.get("versionCodes")} {r.get("status")}'
            f'{" " + str(r["userFraction"]) if "userFraction" in r else ""}'
            for r in t.get('releases', [])) or 'empty'))
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
    newest_eligible = max(eligible, key=lambda b: b['build'], default=None)
    if newest:
        log('appstore', f'newest TestFlight build: {newest["version"]} ({newest["build"]}), '
                        f'{newest["state"]}, {newest["audience"]}, uploaded {newest["uploaded"]}')
    if newest and (newest_eligible is None or newest['build'] > newest_eligible['build']):
        log('appstore', 'the newest build is internal-only or not processed; only an App '
                        'Store eligible build can be attached to a version (deploy_testflight.yml '
                        'uploads those while STORE_PROMOTION_ENABLED is true)')

    versions = appstore_versions(token, app)
    for vid, string, state, build in versions:
        log('appstore', f'App Store version {string}: {state}, build {build}')

    def check(candidate):
        check_commit(candidate, 'appstore')
        log('appstore', f'candidate {candidate.version} ({candidate.build}), commit '
                        f'{candidate.sha or "?"}, CI {"green" if candidate.ci_green else "not green"}, '
                        f'deploy {"succeeded" if candidate.deployed else "not found"}')

    best, candidate, decision, skipped = appstore_choice(eligible, versions, now,
                                                         max_age_hours, check)
    for reason in skipped:
        log('appstore', f'skipped: {reason}')
    if newest and newest is not newest_eligible and newest['state'] == 'VALID':
        # What tonight would have done, had the newest build been eligible.
        what_if = Candidate(newest['version'], newest['build'], landed=newest['uploaded'])
        check_commit(what_if, 'appstore')
        plan = appstore_plan(what_if, versions, now, max_age_hours)
        log('appstore', f'were {newest["version"]} ({newest["build"]}) eligible: {plan.reason}'
                        + ''.join(f'; {describe(step)}' for step in plan.steps))
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
            if not any(l['attributes'].get('locale') == 'en-US' for l in localizations):
                raise ApiError(f'version {candidate.version} has no en-US localization')
            # Apple wants "What's New" in every language of an update, and a new
            # version starts with the previous one's: each gets this version's
            # Play text in its language, or a generic line (listings.py).
            for loc in localizations:
                locale = loc['attributes'].get('locale')
                language = next((lang for lang, (_, apple) in LOCALES.items()
                                 if locale in apple), 'en')
                text = notes if locale == 'en-US' else whats_new(
                    language, locale, candidate.version)
                call('PATCH', f'{ASC}/v1/appStoreVersionLocalizations/{loc["id"]}', token,
                     body={'data': {'type': 'appStoreVersionLocalizations', 'id': loc['id'],
                                    'attributes': {'whatsNew': store_text(text)}}})
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
    print('appstore: --- what App Review will want for the next version ---')
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
        # Fields only some apps answer: a Korean rating number, a link, a
        # Kids category band.
        optional = {'developerAgeRatingInfoUrl', 'gracRatingClassificationNumber',
                    'kidsAgeBand', 'koreaAgeRatingOverride', 'ageRatingOverride',
                    'ageRatingOverrideV2'}
        unanswered = sorted(k for k, v in ((rating or {}).get('attributes') or {}).items()
                            if v is None and k not in optional)
        print(f'appstore: [{mark(rating and not unanswered)}] age rating questionnaire'
              f'{": unanswered " + ", ".join(unanswered) if unanswered else ""}')
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
    declarations = call('GET', f'{ASC}/v1/appEncryptionDeclarations?filter[app]={app}',
                        token)['data']
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
    play_tracks = list(DEFAULT_PLAY_TRACKS)
    targets = []
    while args:
        arg = args.pop(0)
        if arg in ('--apply', '--audit'):
            continue
        if arg == '--schedule' and args:
            schedule = args.pop(0) or None
        elif arg == '--play-tracks' and args:
            play_tracks = [t.strip() for t in args.pop(0).split(',') if t.strip()] or list(
                DEFAULT_PLAY_TRACKS)
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
    rollout = float(os.environ.get('PLAY_PRODUCTION_ROLLOUT') or DEFAULT_PRODUCTION_ROLLOUT)
    if not 0 < rollout <= 1:
        sys.exit(f'PLAY_PRODUCTION_ROLLOUT must be above 0 and at most 1, not {rollout}')
    print(f'{"APPLY" if apply else "DRY RUN"} at {now.astimezone(BERLIN):%Y-%m-%d %H:%M %Z}, '
          f'window {max_age_hours or "unlimited"} h, Play tracks '
          + ', '.join(f'{t} {percent(rollout if t == STAGED_TRACK else 1)}'
                      for t in play_tracks)
          + f', staged rollouts completed after {STAGED_HOURS} h')

    failed = False
    for name in chosen:
        try:
            if name == 'play':
                decision = play(apply, audit, now, max_age_hours, rollout, play_tracks)
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
