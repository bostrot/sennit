"""Tests for Play's short "What's new" texts: how they are found and counted
(tooling/scripts/release_notes.py) and how a track's release gets them
(play_notes.py, promote.py).

    python3 -m unittest discover -s tooling/store
"""

import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                'scripts'))
import release_notes  # noqa: E402
from play_notes import with_notes
from promote import play_notes_from


class PlayTextTest(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        patcher = mock.patch.object(release_notes, 'NOTES_DIR', self.dir)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, name, text):
        with open(os.path.join(self.dir, name), 'w', encoding='utf-8') as f:
            f.write(text)

    def test_counts_like_play_does(self):
        self.assertEqual(release_notes.play_length('Sennit'), 6)
        self.assertEqual(release_notes.play_length('für'), 3)
        # Outside the Basic Multilingual Plane: two UTF-16 code units.
        self.assertEqual(release_notes.play_length('🎉'), 2)

    def test_reads_every_language_as_plain_text(self):
        self.write('1.2.0.md', '- **Long** notes')
        self.write('1.2.0.play.md', '- **Faster** sync\n')
        self.write('1.2.0.play.de-DE.md', '- Schneller abgleichen\n')
        self.write('1.2.1.play.md', '- Other version')
        self.assertEqual(release_notes.play_texts('1.2.0'), {
            'en-US': '• Faster sync',
            'de-DE': '• Schneller abgleichen',
        })

    def test_wants_english_and_german(self):
        self.write('1.2.0.play.md', '- Faster')
        problems = release_notes.play_problems('1.2.0')
        self.assertEqual(len(problems), 1)
        self.assertIn('1.2.0.play.de-DE.md', problems[0])

    def test_refuses_more_than_play_shows(self):
        self.write('1.2.0.play.md', '- ' + 'a' * 499)
        self.write('1.2.0.play.de-DE.md', '- ' + 'ä' * 497)
        problems = release_notes.play_problems('1.2.0')
        self.assertEqual(len(problems), 1)
        self.assertIn('en-US', problems[0])
        self.assertIn('501 characters', problems[0])

    def test_play_dir_writes_one_file_per_language(self):
        self.write('1.2.0.md', '- Long notes')
        self.write('1.2.0.play.md', '- Faster')
        self.write('1.2.0.play.de-DE.md', '- Schneller')
        out = tempfile.mkdtemp()
        release_notes.main(['1.2.0', '--play-dir', out])
        self.assertEqual(play_notes_from(out), [
            {'language': 'de-DE', 'text': '• Schneller'},
            {'language': 'en-US', 'text': '• Faster'},
        ])

    def test_play_dir_without_a_play_text_cuts_the_notes(self):
        self.write('1.2.0.md', '\n'.join(f'- Change number {i}' for i in range(60)))
        out = tempfile.mkdtemp()
        release_notes.main(['1.2.0', '--play-dir', out])
        [note] = play_notes_from(out)
        self.assertEqual(note['language'], 'en-US')
        self.assertLessEqual(len(note['text']), 500)
        self.assertTrue(note['text'].endswith('…'))


class WithNotesTest(unittest.TestCase):

    NOTES = [{'language': 'en-US', 'text': '• Faster'}]

    def test_replaces_only_the_notes_of_that_release(self):
        releases = [
            {'name': '1.0.25', 'versionCodes': ['461'], 'status': 'completed',
             'releaseNotes': [{'language': 'en-US', 'text': '• Long…'}]},
            {'name': '1.0.24', 'versionCodes': ['439'], 'status': 'completed'},
        ]
        self.assertEqual(with_notes(releases, '1.0.25', self.NOTES), [
            {'name': '1.0.25', 'versionCodes': ['461'], 'status': 'completed',
             'releaseNotes': self.NOTES},
            {'name': '1.0.24', 'versionCodes': ['439'], 'status': 'completed'},
        ])

    def test_none_without_that_release(self):
        self.assertIsNone(with_notes([{'name': '1.0.24'}], '1.0.25', self.NOTES))


if __name__ == '__main__':
    unittest.main()
