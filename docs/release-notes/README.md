# Release notes

One file per version, `<version>.md`, written before running
`tooling/scripts/release.sh <version>`. It is the only copy of the notes:
`tooling/scripts/release_notes.py` turns it into the GitHub release body, the
Play "What's new" text (500 characters, cut at a whole line), the TestFlight
"What to Test" and App Store "What's New" text, and the asset the app's
"What's new" sheet reads.

Keep it to a short Markdown list for people who use the app, not for people
who build it — it is what the stores show. Bold, `code` and links are fine;
they are dropped from the store and in-app text. English only.

A version without a file still gets notes: the script lists the pull request
titles and direct commit subjects on `main` since the previous `Release x.y.z`
commit. That is the fallback, not the plan — commit titles are written for
reviewers.
