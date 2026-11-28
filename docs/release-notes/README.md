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

Name each change and stop there: one bullet per feature, just its short
topic, optionally under short `###` headings. No explanations — the GitHub
release and the app show the list as it is.

```markdown
### Messages
- Polls
- React with any emoji

### Sennit Web
- Sennit Web copy & paste

### Fixes
- Bug fixes
```

At most 60 characters a bullet and 30 a heading, one sentence with no full
stop, nothing but headings and bullets. Bug fixes get one short line each,
or a single "Bug fixes". It is for people who use the app, not for people
who build it. Bold, `code` and links are fine; they are dropped from the
store and in-app text. English only, except the Play texts.
`release_notes.py --check` (CI) holds every version after 1.0.27 to this;
published notes stay as they were.

A version without a file still gets notes: the script lists the pull request
titles and direct commit subjects on `main` since the previous `Release x.y.z`
commit. That is the fallback, not the plan — commit titles are written for
reviewers.
