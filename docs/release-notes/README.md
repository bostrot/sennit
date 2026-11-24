# Release notes

One file per version, `<version>.md`, written before running
`tooling/scripts/release.sh <version>`. It is the only copy of the full notes:
`tooling/scripts/release_notes.py` turns it into the GitHub release body, the
TestFlight "What to Test" and App Store "What's New" text, and the asset the
app's "What's new" sheet reads.

Play's "What's new" shows only 500 characters, so every version also has a
short Play text: `<version>.play.md` (en-US) and `<version>.play.de-DE.md`
(German), plus `<version>.play.<Play language code>.md` for any other
language. Name every highlight in one short line, at most 500 characters per
file, counted as Play does (UTF-16 code units). CI fails without them or over
the limit (`release_notes.py --check`).

Keep it to a short Markdown list for people who use the app, not for people
who build it — it is what the stores show. Bold, `code` and links are fine;
they are dropped from the store and in-app text. English only, except the
Play texts.

A version without a file still gets notes: the script lists the pull request
titles and direct commit subjects on `main` since the previous `Release x.y.z`
commit. That is the fallback, not the plan — commit titles are written for
reviewers.
