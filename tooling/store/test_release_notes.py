"""Tests for the release notes' shape from 1.0.28 on: short topic lines
(tooling/scripts/release_notes.py).

    python3 -m unittest discover -s tooling/store
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                'scripts'))
import release_notes  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class TopicLinesTest(unittest.TestCase):

    def problems(self, markdown):
        return release_notes.topic_problems('1.2.0', markdown)

    def test_takes_topics_under_headings(self):
        self.assertEqual(self.problems(
            '### Messages\n'
            '- Polls\n'
            '- **React with any emoji**\n'
            '- Voice messages at 1.5× or 2×\n'
            '\n'
            '### Sennit Web\n'
            '- Sennit Web copy & paste\n'
            '- Bug fixes\n'), [])

    def test_refuses_a_description(self):
        problems = self.problems(
            '- **Polls**: vote, change your vote, see who voted and create your own\n')
        self.assertEqual(len(problems), 1)
        self.assertIn('characters', problems[0])

    def test_refuses_a_second_sentence(self):
        problems = self.problems('- Polls. Vote in them\n')
        self.assertEqual(len(problems), 1)
        self.assertIn('sentence', problems[0])

    def test_refuses_a_full_stop(self):
        self.assertEqual(len(self.problems('- Polls.\n')), 1)

    def test_refuses_a_paragraph(self):
        problems = self.problems('Lots of new things this time\n- Polls\n')
        self.assertEqual(len(problems), 1)
        self.assertIn('neither a heading nor a bullet', problems[0])

    def test_refuses_a_long_heading(self):
        self.assertEqual(len(self.problems('### Everything about writing and sending\n')), 1)

    def test_published_notes_would_not_pass(self):
        # 1.0.27 predates the rule and stays as published; it is what the
        # rule is there to stop.
        with open(os.path.join(REPO, 'docs', 'release-notes', '1.0.27.md'),
                  encoding='utf-8') as f:
            self.assertTrue(release_notes.topic_problems('1.0.27', f.read()))
        self.assertGreater(release_notes.FIRST_TOPIC_VERSION, (1, 0, 27))


if __name__ == '__main__':
    unittest.main()
