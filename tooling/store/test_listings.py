"""Tests for listings.py: every listing fits its store, and "What's New"
falls back as described. Run with `python3 -m unittest discover -s tooling/store`."""

import os
import unittest

import listings


class ListingsTest(unittest.TestCase):
    def test_every_language_fits_the_stores(self):
        # load() exits with the list of what does not fit.
        loaded = listings.load()
        self.assertEqual(set(loaded), set(listings.LOCALES))

    def test_every_language_has_screenshots(self):
        for language in listings.LOCALES:
            for pattern in {**listings.PLAY_IMAGES, **listings.ASC_IMAGES}.values():
                self.assertTrue(listings.shots(language, pattern), f'{language}/{pattern}')

    def test_whats_new_falls_back_to_a_generic_line(self):
        self.assertEqual(listings.whats_new('fr', 'fr-FR', '0.0.0'),
                         listings.WHATS_NEW['fr'])

    def test_whats_new_reads_the_play_text(self):
        notes = listings.NOTES
        version = '1.0.26'
        if not os.path.exists(os.path.join(notes, f'{version}.play.de-DE.md')):
            self.skipTest('no Play text for 1.0.26')
        text = listings.whats_new('de', 'de-DE', version)
        self.assertTrue(text.startswith('• '))


if __name__ == '__main__':
    unittest.main()
