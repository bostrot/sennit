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
    Candidate, appstore_plan, decide, play_candidate_release, play_current,
    play_production_releases, promotion_slot,
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

    def test_production_counts_what_is_out_or_rolling_out(self):
        self.assertIsNone(play_current({'track': 'production'}))
        self.assertIsNone(play_current(None))
        self.assertEqual(play_current({'releases': [
            {'versionCodes': ['300'], 'status': 'completed'},
            {'versionCodes': ['350'], 'status': 'inProgress', 'userFraction': 0.2},
            {'versionCodes': ['999'], 'status': 'draft'},
        ]}), 350)

    def test_a_full_release_replaces_the_track(self):
        release = play_candidate_release(self.internal)
        releases = play_production_releases(release, None, 1)
        self.assertEqual(releases, [{
            'name': '1.0.16', 'versionCodes': ['412'],
            'releaseNotes': [{'language': 'en-US', 'text': '• Faster'}],
            'status': 'completed',
        }])

    def test_a_staged_rollout_keeps_the_release_everyone_has(self):
        release = play_candidate_release(self.internal)
        production = {'releases': [{'name': '1.0.10', 'versionCodes': ['300'],
                                    'status': 'completed'}]}
        new, kept = play_production_releases(release, production, 0.2)
        self.assertEqual((new['status'], new['userFraction']), ('inProgress', 0.2))
        self.assertEqual(kept['versionCodes'], ['300'])


def version(state, string='1.0.16', build=None, vid='v1'):
    return (vid, string, state, build)


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
