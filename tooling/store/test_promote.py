"""Tests for promote.py's decisions: which build, whether it is already out,
and whether tonight's run is the 03:00 Berlin one.

    python3 -m unittest discover -s tooling/store
"""

import datetime
import os
import subprocess
import tempfile
import unittest
from unittest import mock

import promote
from promote import (
    Candidate, Decision, appstore_choice, appstore_plan, decide, play_candidate_release, play_current,
    play_plan, play_track_releases, promotion_slot,
)

UTC = datetime.timezone.utc


def at(text):
    return datetime.datetime.fromisoformat(text).replace(tzinfo=UTC)


NOW = at('2026-11-21T02:04:00')


def tested(build=412, version='1.0.16', hours_ago=5):
    return Candidate(version, build, landed=NOW - datetime.timedelta(hours=hours_ago),
                     sha='a' * 40, ci_green=True, deployed=True)


class PromotionSlotTest(unittest.TestCase):
    def test_winter_runs_at_two_utc(self):
        self.assertFalse(promotion_slot('0 1 * * *', at('2026-11-21T01:00:00')))
        self.assertTrue(promotion_slot('0 2 * * *', at('2026-11-21T02:00:00')))

    def test_summer_runs_at_one_utc(self):
        self.assertTrue(promotion_slot('0 1 * * *', at('2026-07-01T01:00:00')))
        self.assertFalse(promotion_slot('0 2 * * *', at('2026-07-01T02:00:00')))

    def test_a_late_start_keeps_its_slot(self):
        # The 01:00 UTC winter run starting an hour late is still 02:00 Berlin.
        self.assertFalse(promotion_slot('0 1 * * *', at('2026-11-21T02:10:00')))
        self.assertTrue(promotion_slot('0 2 * * *', at('2026-11-21T02:59:00')))

    def test_exactly_one_slot_on_every_day_of_the_year(self):
        day = at('2026-01-01T00:00:00')
        while day.year == 2026:
            slots = [promotion_slot(cron, day.replace(hour=hour))
                     for cron, hour in (('0 1 * * *', 1), ('0 2 * * *', 2))]
            self.assertEqual(slots.count(True), 1, day.date())
            day += datetime.timedelta(days=1)

    def test_the_days_the_clocks_change(self):
        # 2026-03-29: CEST from 01:00 UTC, so 01:00 UTC is already 03:00.
        self.assertTrue(promotion_slot('0 1 * * *', at('2026-03-29T01:00:00')))
        # 2026-10-25: CET again from 01:00 UTC, so 02:00 UTC is 03:00.
        self.assertTrue(promotion_slot('0 2 * * *', at('2026-10-25T02:00:00')))

    def test_a_manual_run_always_goes_on(self):
        self.assertTrue(promotion_slot(None, at('2026-11-21T14:00:00')))
        self.assertTrue(promotion_slot('', at('2026-11-21T14:00:00')))

    def test_a_cron_line_without_a_fixed_hour_is_refused(self):
        with self.assertRaises(ValueError):
            promotion_slot('0 * * * *', NOW)


class DecideTest(unittest.TestCase):
    def test_a_new_tested_build_goes_out(self):
        decision = decide(tested(), 400, NOW, 26)
        self.assertTrue(decision.promote, decision.reason)
        self.assertFalse(decision.failed)

    def test_the_first_release_goes_out(self):
        self.assertTrue(decide(tested(), None, NOW, 26).promote)

    def test_nothing_on_the_test_track(self):
        decision = decide(None, 400, NOW, 26)
        self.assertFalse(decision.promote)
        self.assertFalse(decision.failed)

    def test_a_build_the_store_has_is_not_promoted_twice(self):
        for store in (412, 413):
            decision = decide(tested(412), store, NOW, 26)
            self.assertFalse(decision.promote)
            self.assertFalse(decision.failed)
            self.assertIn('not newer', decision.reason)

    def test_a_build_from_before_the_window_is_not_new_today(self):
        decision = decide(tested(hours_ago=30), 400, NOW, 26)
        self.assertFalse(decision.promote)
        self.assertFalse(decision.failed)
        self.assertIn('nothing new today', decision.reason)

    def test_no_window_promotes_any_age(self):
        self.assertTrue(decide(tested(hours_ago=300), 400, NOW, 0).promote)

    def test_red_ci_blocks_and_fails_the_run(self):
        candidate = tested()
        candidate.ci_green = False
        decision = decide(candidate, 400, NOW, 26)
        self.assertFalse(decision.promote)
        self.assertTrue(decision.failed)
        self.assertIn('CI', decision.reason)

    def test_a_failed_deploy_blocks(self):
        candidate = tested()
        candidate.deployed = False
        decision = decide(candidate, 400, NOW, 26)
        self.assertFalse(decision.promote)
        self.assertTrue(decision.failed)

    def test_a_build_number_with_no_commit_blocks(self):
        candidate = tested()
        candidate.sha = None
        self.assertTrue(decide(candidate, 400, NOW, 26).failed)


class PlayTest(unittest.TestCase):
    internal = {'track': 'internal', 'releases': [
        {'name': '1.0.15', 'versionCodes': ['405'], 'status': 'completed'},
        {'name': '1.0.16', 'versionCodes': ['412'], 'status': 'completed',
         'releaseNotes': [{'language': 'en-US', 'text': '• Faster'}]},
        {'name': 'draft', 'versionCodes': ['420'], 'status': 'draft'},
    ]}

    def test_the_candidate_is_the_newest_completed_internal_release(self):
        self.assertEqual(play_candidate_release(self.internal)['name'], '1.0.16')
        self.assertIsNone(play_candidate_release({'track': 'internal'}))
        self.assertIsNone(play_candidate_release(None))

    def test_the_target_counts_what_is_out_or_rolling_out(self):
        self.assertIsNone(play_current({'track': 'production'}))
        self.assertIsNone(play_current(None))
        self.assertEqual(play_current({'releases': [
            {'versionCodes': ['300'], 'status': 'completed'},
            {'versionCodes': ['350'], 'status': 'inProgress', 'userFraction': 0.2},
            {'versionCodes': ['999'], 'status': 'draft'},
        ]}), 350)

    def test_a_full_release_replaces_the_track(self):
        release = play_candidate_release(self.internal)
        releases = play_track_releases(release, None, 1)
        self.assertEqual(releases, [{
            'name': '1.0.16', 'versionCodes': ['412'],
            'releaseNotes': [{'language': 'en-US', 'text': '• Faster'}],
            'status': 'completed',
        }])

    def test_a_staged_rollout_keeps_the_release_everyone_has(self):
        release = play_candidate_release(self.internal)
        production = {'releases': [{'name': '1.0.10', 'versionCodes': ['300'],
                                    'status': 'completed'}]}
        new, kept = play_track_releases(release, production, 0.2)
        self.assertEqual((new['status'], new['userFraction']), ('inProgress', 0.2))
        self.assertEqual(kept['versionCodes'], ['300'])


def rel(code, status, fraction=None, name=None):
    release = {'name': name or f'1.0.{code}', 'versionCodes': [str(code)], 'status': status,
               'releaseNotes': [{'language': 'en-US', 'text': f'• {code}'}]}
    if fraction is not None:
        release['userFraction'] = fraction
    return release


class PlayPlanTest(unittest.TestCase):
    """Nightly: beta gets the build at 100 %, production gets it staged, and
    a staged production rollout that has been out a night is completed."""

    new = rel(420, 'completed')

    def plan(self, track, releases, promote=True, landed_hours_ago=None, rollout=0.2):
        decision = Decision(promote, 'new build' if promote else 'nothing new')
        landed = (NOW - datetime.timedelta(hours=landed_hours_ago)
                  if landed_hours_ago is not None else None)
        return play_plan(track, {'releases': releases}, self.new, decision, rollout,
                         landed, NOW)

    def kinds(self, decision):
        return [step[0] for step in decision.steps]

    def test_beta_gets_the_build_at_full_rollout(self):
        decision, after = self.plan('beta', [rel(400, 'completed')])
        self.assertEqual(after, [{**self.new, 'status': 'completed'}])
        self.assertEqual(decision.steps, [('promote', self.new, 1)])

    def test_production_gets_it_staged_beside_the_completed_one(self):
        decision, after = self.plan('production', [rel(400, 'completed')])
        self.assertEqual([(r['versionCodes'], r['status'], r.get('userFraction'))
                          for r in after],
                         [(['420'], 'inProgress', 0.2), (['400'], 'completed', None)])
        self.assertEqual(decision.steps, [('promote', self.new, 0.2)])

    def test_a_rollout_out_a_night_is_completed_before_the_new_one(self):
        decision, after = self.plan('production', [
            rel(410, 'inProgress', 0.2), rel(400, 'completed')], landed_hours_ago=30)
        self.assertEqual(self.kinds(decision), ['complete', 'promote'])
        self.assertTrue(decision.promote)
        self.assertEqual([(r['versionCodes'], r['status'], r.get('userFraction'))
                          for r in after],
                         [(['420'], 'inProgress', 0.2), (['410'], 'completed', None)])
        # The completed release keeps its "What's new".
        self.assertEqual(after[1]['releaseNotes'], [{'language': 'en-US', 'text': '• 410'}])
        self.assertNotIn('userFraction', after[1])

    def test_a_night_without_a_new_build_still_completes(self):
        decision, after = self.plan('production', [
            rel(410, 'inProgress', 0.2), rel(400, 'completed')],
            promote=False, landed_hours_ago=24)
        self.assertEqual(self.kinds(decision), ['complete'])
        self.assertTrue(decision.promote)
        self.assertEqual([(r['versionCodes'], r['status']) for r in after],
                         [(['410'], 'completed')])

    def test_a_rollout_under_a_day_old_stays_staged(self):
        decision, after = self.plan('production', [
            rel(410, 'inProgress', 0.2), rel(400, 'completed')],
            promote=False, landed_hours_ago=10)
        self.assertFalse(decision.promote)
        self.assertIsNone(after)
        self.assertIn('stays staged', decision.reason)

    def test_a_newer_build_replaces_a_rollout_under_a_day_old(self):
        decision, after = self.plan('production', [
            rel(410, 'inProgress', 0.2), rel(400, 'completed')], landed_hours_ago=10)
        self.assertEqual(self.kinds(decision), ['promote'])
        self.assertEqual([(r['versionCodes'], r['status']) for r in after],
                         [(['420'], 'inProgress'), (['400'], 'completed')])
        self.assertIn('replaces', decision.reason)

    def test_a_halted_rollout_stops_the_track(self):
        decision, after = self.plan('production', [
            rel(410, 'halted', 0.2), rel(400, 'completed')], landed_hours_ago=48)
        self.assertFalse(decision.promote)
        self.assertFalse(decision.failed)
        self.assertIsNone(after)
        self.assertIn('halted', decision.reason)

    def test_an_unknown_landing_is_not_completed_and_fails_the_run(self):
        decision, after = self.plan('production', [
            rel(410, 'inProgress', 0.2), rel(400, 'completed')], promote=False)
        self.assertFalse(decision.promote)
        self.assertTrue(decision.failed)
        self.assertIsNone(after)

    def test_the_first_production_release_is_not_staged(self):
        # Play: "The first release on a track cannot be staged".
        decision, after = self.plan('production', [])
        self.assertFalse(decision.promote)
        self.assertFalse(decision.failed)
        self.assertIsNone(after)
        self.assertIn('first release', decision.reason)

    def test_the_first_production_release_can_go_to_everyone(self):
        decision, after = self.plan('production', [], rollout=1)
        self.assertEqual([r['status'] for r in after], ['completed'])

    def test_a_full_rollout_setting_releases_production_at_once(self):
        decision, after = self.plan('production', [rel(400, 'completed')], rollout=1)
        self.assertEqual([r['status'] for r in after], ['completed'])

    def test_nothing_to_do(self):
        decision, after = self.plan('production', [rel(400, 'completed')], promote=False)
        self.assertFalse(decision.promote)
        self.assertIsNone(after)
        self.assertEqual(decision.steps, [])


def version(state, string='1.0.16', build=None, vid='v1'):
    return (vid, string, state, build)


class PlayNightTest(unittest.TestCase):
    """play() end to end against a mocked Play: one edit for both tracks,
    committed once, or not at all while Play still reviews earlier changes."""

    def night(self, refuse_commit=False):
        tracks = {
            'internal': {'releases': [{'name': '1.0.17', 'versionCodes': ['420'],
                                       'status': 'completed', 'releaseNotes': []}]},
            'beta': {'releases': [{'name': '1.0.16', 'versionCodes': ['412'],
                                   'status': 'completed'}]},
            'production': {'releases': [
                {'name': '1.0.16', 'versionCodes': ['412'], 'status': 'inProgress',
                 'userFraction': 0.2},
                {'name': '1.0.15', 'versionCodes': ['400'], 'status': 'completed'}]},
        }
        calls = []

        def call(method, url, token, body=None):
            calls.append((method, url.rsplit('/', 1)[-1]))
            if method == 'POST' and url.endswith('/edits'):
                return {'id': '7'}
            if method == 'GET':
                return tracks[url.rsplit('/', 1)[-1]]
            if ':commit' in url and refuse_commit:
                raise promote.ApiError(f'POST {url} -> 400\n{{"error": {{"message": '
                                       '"Changes are currently in review"}}')
            return {}

        def check(candidate, store):
            candidate.sha = 'abc'
            candidate.ci_green = candidate.deployed = True
            candidate.landed = NOW - datetime.timedelta(hours=30 if candidate.build == 412 else 5)

        with mock.patch.object(promote, 'call', call), \
                mock.patch.object(promote, 'play_token', lambda: 'token'), \
                mock.patch.object(promote, 'check_commit', check), \
                mock.patch.object(promote, 'release_notes', lambda *a: []), \
                mock.patch('builtins.print'):
            decision = promote.play(True, False, NOW, 26, 0.2, ['beta', 'production'])
        return decision, calls

    def test_both_tracks_and_the_completion_in_one_commit(self):
        decision, calls = self.night()
        self.assertTrue(decision.promote)
        self.assertEqual([c for c in calls if c[0] == 'POST' and c[1] == 'edits'],
                         [('POST', 'edits')])
        self.assertEqual([c[1] for c in calls if c[0] == 'PUT'], ['beta', 'production'])
        self.assertEqual(len([c for c in calls if ':commit' in c[1]]), 1)
        self.assertNotIn('DELETE', [c[0] for c in calls])

    def test_changes_in_review_hold_back_the_whole_night(self):
        decision, calls = self.night(refuse_commit=True)
        self.assertFalse(decision.promote)
        self.assertFalse(decision.failed)
        self.assertIn('DELETE', [c[0] for c in calls])


class PlayCommitTest(unittest.TestCase):
    base = f'{promote.PLAY}/edits/7'

    def commit(self, outcome, env=None):
        calls = []

        def call(method, url, token, body=None):
            calls.append(url)
            if isinstance(outcome, Exception):
                raise outcome
            return {}
        with mock.patch.object(promote, 'call', call), \
                mock.patch.dict(os.environ, env or {}, clear=False):
            return promote.play_commit('token', self.base), calls

    def refusal(self, detail):
        return promote.ApiError(f'POST {self.base}:commit?changesInReviewBehavior='
                                f'ERROR_IF_IN_REVIEW -> 400\n{detail}')

    def test_commits_only_if_nothing_is_in_review(self):
        committed, calls = self.commit({})
        self.assertTrue(committed)
        self.assertEqual(calls, [f'{self.base}:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW'])

    def test_keeps_changes_not_sent_for_review(self):
        _, calls = self.commit({}, {'PLAY_CHANGES_NOT_SENT_FOR_REVIEW': 'true'})
        self.assertIn('changesInReviewBehavior=ERROR_IF_IN_REVIEW', calls[0])
        self.assertIn('changesNotSentForReview=true', calls[0])

    def test_changes_in_review_skip_the_night(self):
        committed, _ = self.commit(self.refusal(
            '{"error": {"code": 400, "message": "Changes are currently in review and '
            'cannot be committed.", "status": "FAILED_PRECONDITION"}}'))
        self.assertFalse(committed)

    def test_any_other_refusal_still_fails(self):
        # The URL names ERROR_IF_IN_REVIEW; only Play's answer counts.
        with self.assertRaises(promote.ApiError):
            self.commit(self.refusal(
                '{"error": {"code": 403, "message": "The caller does not have permission"}}'))


class AppStorePlanTest(unittest.TestCase):
    def kinds(self, decision):
        return [step[0] for step in decision.steps]

    def test_the_first_version_uses_the_open_one_without_whats_new(self):
        decision = appstore_plan(tested(), [version('PREPARE_FOR_SUBMISSION', '1.0')],
                                 NOW, 26)
        self.assertTrue(decision.promote, decision.reason)
        self.assertEqual(decision.steps[0], ('rename_version', 'v1', '1.0.16'))
        self.assertIn('no_whats_new_on_first_version', self.kinds(decision))
        self.assertEqual(self.kinds(decision)[-1], 'submit_for_review')

    def test_an_update_creates_a_version_with_whats_new(self):
        decision = appstore_plan(tested(), [version('READY_FOR_SALE', '1.0.15', 405)],
                                 NOW, 26)
        self.assertTrue(decision.promote, decision.reason)
        self.assertEqual(decision.steps[0], ('create_version', None, '1.0.16'))
        self.assertIn('whats_new', self.kinds(decision))
        self.assertIn('export_compliance', self.kinds(decision))
        self.assertIn('release_after_approval', self.kinds(decision))

    def test_a_crashed_run_is_picked_up_where_it_stopped(self):
        decision = appstore_plan(tested(), [
            version('READY_FOR_SALE', '1.0.15', 405, 'old'),
            version('PREPARE_FOR_SUBMISSION', '1.0.16', 412, 'new'),
        ], NOW, 26)
        self.assertTrue(decision.promote, decision.reason)
        self.assertEqual(decision.steps[0], ('use_version', 'new', '1.0.16'))

    def test_the_build_in_review_is_not_submitted_again(self):
        for state in ('WAITING_FOR_REVIEW', 'IN_REVIEW', 'PENDING_APPLE_RELEASE'):
            decision = appstore_plan(tested(), [version(state, '1.0.16', 412)], NOW, 26)
            self.assertFalse(decision.promote, state)
            self.assertFalse(decision.failed, state)

    def test_a_newer_build_waits_while_another_is_in_review(self):
        decision = appstore_plan(tested(), [
            version('READY_FOR_SALE', '1.0.14', 390, 'live'),
            version('IN_REVIEW', '1.0.15', 405, 'review'),
        ], NOW, 26)
        self.assertFalse(decision.promote)
        self.assertFalse(decision.failed)
        self.assertIn('waits', decision.reason)

    def test_a_rejection_stops_the_line(self):
        decision = appstore_plan(tested(), [version('REJECTED', '1.0.15', 405)], NOW, 26)
        self.assertFalse(decision.promote)
        self.assertTrue(decision.failed)

    def test_a_newer_build_of_a_released_version_needs_a_bump(self):
        decision = appstore_plan(tested(412, '1.0.16'),
                                 [version('READY_FOR_SALE', '1.0.16', 410)], NOW, 26)
        self.assertFalse(decision.promote)
        self.assertTrue(decision.failed)

    def test_what_is_on_sale_is_not_promoted_again(self):
        decision = appstore_plan(tested(412), [version('READY_FOR_SALE', '1.0.16', 412)],
                                 NOW, 26)
        self.assertFalse(decision.promote)
        self.assertFalse(decision.failed)


class AppStoreChoiceTest(unittest.TestCase):
    """Which TestFlight build goes out when the newest one's commit has no
    green CI."""

    def build(self, number, version='1.0.26', hours_ago=5):
        return {'id': f'b{number}', 'build': number, 'version': version,
                'uploaded': NOW - datetime.timedelta(hours=hours_ago)}

    def choose(self, builds, green, versions=(), max_age_hours=26):
        checked = []

        def check(candidate):
            checked.append(candidate.build)
            candidate.sha = f'{candidate.build:040d}'
            candidate.ci_green = candidate.deployed = candidate.build in green

        result = appstore_choice(builds, list(versions), NOW, max_age_hours, check)
        return result, checked

    def test_a_cancelled_ci_falls_back_to_the_older_green_build(self):
        (best, candidate, decision, skipped), checked = self.choose(
            [self.build(469, hours_ago=20), self.build(487)], green={469},
            versions=[version('READY_FOR_SALE', '1.0.25', 440)])
        self.assertTrue(decision.promote, decision.reason)
        self.assertEqual(best['build'], 469)
        self.assertEqual(candidate.build, 469)
        self.assertEqual(checked, [487, 469])
        self.assertEqual(len(skipped), 1)
        self.assertIn('CI did not pass', skipped[0])
        self.assertIn(('attach_build', 469), decision.steps)

    def test_the_newest_green_build_wins_and_older_ones_are_not_checked(self):
        (best, _, decision, skipped), checked = self.choose(
            [self.build(469), self.build(487)], green={469, 487})
        self.assertTrue(decision.promote)
        self.assertEqual(best['build'], 487)
        self.assertEqual(checked, [487])
        self.assertEqual(skipped, [])

    def test_no_green_build_fails_the_run(self):
        (best, _, decision, skipped), _ = self.choose(
            [self.build(469), self.build(487)], green=set())
        self.assertIsNone(best)
        self.assertFalse(decision.promote)
        self.assertTrue(decision.failed)
        self.assertEqual(len(skipped), 2)

    def test_a_green_build_outside_the_window_still_fails_for_the_red_one(self):
        (_, _, decision, skipped), checked = self.choose(
            [self.build(469, hours_ago=40), self.build(487)], green={469})
        self.assertFalse(decision.promote)
        self.assertTrue(decision.failed)
        self.assertIn('window', decision.reason)
        self.assertIn('CI did not pass', decision.reason)

    def test_an_older_build_the_store_has_is_a_quiet_night_without_skips(self):
        (_, _, decision, skipped), checked = self.choose(
            [self.build(469)], green={469},
            versions=[version('WAITING_FOR_REVIEW', '1.0.26', 469)])
        self.assertFalse(decision.promote)
        self.assertFalse(decision.failed)
        self.assertEqual(skipped, [])

    def test_nothing_eligible(self):
        (best, _, decision, _), checked = self.choose([], green=set())
        self.assertIsNone(best)
        self.assertFalse(decision.promote)
        self.assertFalse(decision.failed)
        self.assertEqual(checked, [])


class ShaForBuildTest(unittest.TestCase):
    """The build number is `git rev-list --count HEAD` on main; the commit
    is found again from it, merges included."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = {**os.environ, 'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t',
               'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@t'}

        def run(*args):
            return subprocess.run(['git', '-C', self.tmp.name, *args], check=True,
                                  capture_output=True, text=True, env=env).stdout.strip()
        self.run_git = run
        run('init', '-q', '-b', 'main')
        run('commit', '-q', '--allow-empty', '-m', 'one')
        run('commit', '-q', '--allow-empty', '-m', 'two')
        run('checkout', '-q', '-b', 'topic')
        run('commit', '-q', '--allow-empty', '-m', 'three')
        run('commit', '-q', '--allow-empty', '-m', 'four')
        run('checkout', '-q', 'main')
        run('merge', '-q', '--no-ff', 'topic', '-m', 'merge')
        run('update-ref', 'refs/remotes/origin/main', 'HEAD')
        patcher = mock.patch.object(promote, 'REPO', self.tmp.name)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_finds_the_commit_with_that_count(self):
        merge = self.run_git('rev-parse', 'HEAD')
        self.assertEqual(promote.sha_for_build(5), merge)
        self.assertEqual(promote.sha_for_build(2), self.run_git('rev-parse', 'HEAD~1'))

    def test_a_count_only_a_side_branch_had_is_not_main(self):
        # Commit four (count 4) was never main's tip.
        self.assertIsNone(promote.sha_for_build(4))
        self.assertIsNone(promote.sha_for_build(99))


if __name__ == '__main__':
    unittest.main()
