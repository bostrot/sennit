#!/usr/bin/env python3
"""The release notes for a version, in every shape something needs them.

    release_notes.py <version> [--github FILE] [--store FILE]
                               [--play-dir DIR] [--app-asset FILE]
    release_notes.py --check

One source, so the GitHub release, Play, TestFlight / the App Store and the
app's "What's new" sheet cannot disagree:

1. `docs/release-notes/<version>.md`, when someone wrote it — the plan;
2. otherwise the history: every pull request merged into `main` since the
   previous `Release x.y.z` commit, by title, and every commit pushed to
   `main` directly, by subject. Commits, not tags: v1.0.2 to v1.0.11 were
   never pushed as tags, and pushes straight to main have no pull request
   for GitHub's own generator to list.

Both are plain reads of the checkout, so every workflow that runs this on the
same commit gets the same text — none of them has to wait for another to
publish anything first. Needs the full history (`fetch-depth: 0`) for 2.

    --github     Markdown, for the GitHub release body.
    --store      Plain text for App Store Connect (TestFlight "What to Test",
                 App Store "What's New"), at most 4000 characters.
    --play-dir   Writes `whatsnew-<language>` there, one per language, for
                 r0adkll/upload-google-play's `whatsNewDirectory`. Not
                 from the notes above: Play shows 500 characters, so Play
                 gets its own short text, `docs/release-notes/<version>.play.md`
                 (en-US) and `<version>.play.<language>.md` (de-DE, ...).
                 A text over the limit fails rather than being cut.
    --app-asset  The JSON `apps/weft/assets/release_notes.json` the app reads.
    --check      Fails when the version in pubspec.yaml, or any version with
                 notes since 1.0.25, lacks the en-US or de-DE Play text or
                 has one over 500 characters, and when the notes of a version
                 after 1.0.27 are more than short topic lines (see
                 topic_problems). CI runs it.

Python 3 and git, nothing else.
"""

import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NOTES_DIR = os.path.join(REPO, 'docs', 'release-notes')

PLAY_LIMIT = 500
# The first version with a separate Play text; older ones were cut at 500.
FIRST_PLAY_VERSION = (1, 0, 25)
PLAY_NAME = re.compile(r'^(\d+\.\d+\.\d+)\.play(?:\.([A-Za-z]{2,3}(?:-[A-Za-z0-9]+)?))?\.md$')
# Every release has these; more languages are welcome.
PLAY_REQUIRED = ('en-US', 'de-DE')
PUBSPEC = os.path.join(REPO, 'apps', 'weft', 'pubspec.yaml')
APP_STORE_LIMIT = 4000

# From 1.0.28 on the notes name each change and stop there: one bullet per
# feature ("Polls", "React with any emoji"), under optional short headings.
# Published notes stay as they were.
FIRST_TOPIC_VERSION = (1, 0, 28)
TOPIC_LIMIT = 60
HEADING_LIMIT = 30
# A full stop, "!" or "?" with more after it: a second sentence.
SENTENCE_BREAK = re.compile(r'[.!?]\s+\S')

RELEASE_SUBJECT = re.compile(r'^Release (\d+\.\d+\.\d+)$')
# Merges that carry no change of their own: main into a branch, and back.
NOISE = re.compile(r"^Merge (remote-tracking )?branch '")
PR_MERGE = re.compile(r'^Merge pull request #\d+ from ')


def git(*args):
    return subprocess.run(
        ['git', '-C', REPO, *args], capture_output=True, text=True, check=True,
    ).stdout


def from_history(version):
    """Bullets for everything on the first-parent line since the last release
    commit that is not this version's."""
    log = git('log', '--first-parent', '--format=%H%x00%s%x00%b%x1e', 'HEAD')
    items = []
    for entry in log.split('\x1e'):
        entry = entry.strip('\n')
        if not entry:
            continue
        _, subject, body = entry.split('\x00', 2)
        release = RELEASE_SUBJECT.match(subject)
        if release:
            if release.group(1) == version:
                continue
            break
        if NOISE.match(subject):
            continue
        if PR_MERGE.match(subject):
            # GitHub puts the pull request's title on the first body line.
            title = next((l.strip() for l in body.splitlines() if l.strip()), '')
            if title:
                items.append(title)
            continue
        items.append(subject)
    if not items:
        items = ['Fixes and improvements']
    return '\n'.join(f'- {item}' for item in items) + '\n'


def source(version):
    path = os.path.join(NOTES_DIR, f'{version}.md')
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            return f.read().strip() + '\n', path
    return from_history(version), 'history'


def plain(markdown):
    """What a store text box shows: no Markdown, `•` for a list."""
    lines = []
    for line in markdown.splitlines():
        line = line.rstrip()
        if re.match(r'^\s*<!--.*-->\s*$', line):
            continue
        line = re.sub(r'^#+\s*', '', line)
        line = re.sub(r'^(\s*)[-*+]\s+', r'\1• ', line)
        line = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', line)
        line = re.sub(r'(\*\*|__|`)', '', line)
        lines.append(line)
    text = '\n'.join(lines)
    return re.sub(r'\n{3,}', '\n\n', text).strip()


def fit(text, limit):
    """At most [limit] characters, cut after the last whole line that fits."""
    if len(text) <= limit:
        return text
    suffix = '\n…'
    kept = []
    for line in text.splitlines():
        if len('\n'.join(kept + [line])) + len(suffix) > limit:
            break
        kept.append(line)
    if not kept:
        return text[:limit - 1].rstrip() + '…'
    return '\n'.join(kept) + suffix


def play_length(text):
    """Characters as Play's console counts them: UTF-16 code units, so an
    emoji counts two."""
    return len(text.encode('utf-16-le')) // 2


def play_texts(version):
    """{language: plain text} from the version's Play files; en-US is
    `<version>.play.md`."""
    texts = {}
    for name in sorted(os.listdir(NOTES_DIR)):
        match = PLAY_NAME.match(name)
        if not match or match.group(1) != version:
            continue
        with open(os.path.join(NOTES_DIR, name), encoding='utf-8') as f:
            texts[match.group(2) or 'en-US'] = plain(f.read())
    return texts


def play_problems(version):
    texts = play_texts(version)
    problems = []
    for language in PLAY_REQUIRED:
        if language not in texts:
            name = 'play' if language == 'en-US' else f'play.{language}'
            problems.append(f'{version}: no docs/release-notes/{version}.{name}.md (the '
                            f'{language} Play "What\'s new" text, at most {PLAY_LIMIT} characters)')
    for language, text in texts.items():
        if not text:
            problems.append(f'{version} {language}: the Play text is empty')
        elif play_length(text) > PLAY_LIMIT:
            problems.append(f'{version} {language}: the Play text has '
                            f'{play_length(text)} characters, Play takes {PLAY_LIMIT}')
    return problems


def topic_problems(version, markdown):
    """Why [markdown] is more than short topic lines: only headings and
    bullets, each a short topic of a single sentence with no full stop."""
    problems = []
    for line in markdown.splitlines():
        if not line.strip() or re.match(r'^\s*<!--.*-->\s*$', line):
            continue
        heading = re.match(r'^#+\s+(.*)$', line)
        bullet = re.match(r'^\s*[-*+]\s+(.*)$', line)
        if not heading and not bullet:
            problems.append(f'{version}: {line.strip()!r} is neither a heading nor a bullet')
            continue
        text = plain(heading.group(1) if heading else bullet.group(1))
        limit = HEADING_LIMIT if heading else TOPIC_LIMIT
        if len(text) > limit:
            problems.append(f'{version}: {text!r} has {len(text)} characters, '
                            f'at most {limit} — name the change, do not describe it')
        if SENTENCE_BREAK.search(text) or text.endswith('.'):
            problems.append(f'{version}: {text!r} is a sentence, not a topic — '
                            f'drop the explanation and the full stop')
    return problems


def check():
    versions = set()
    with open(PUBSPEC, encoding='utf-8') as f:
        match = re.search(r'^version: (\d+\.\d+\.\d+)\+', f.read(), re.M)
    if match:
        versions.add(match.group(1))
    for name in os.listdir(NOTES_DIR):
        match = re.match(r'^(\d+\.\d+\.\d+)(?:\.play.*)?\.md$', name)
        if match:
            versions.add(match.group(1))
    key = lambda v: tuple(int(p) for p in v.split('.'))
    problems = []
    for version in sorted(versions, key=key):
        if key(version) < FIRST_PLAY_VERSION:
            continue
        problems += play_problems(version)
        path = os.path.join(NOTES_DIR, f'{version}.md')
        if key(version) >= FIRST_TOPIC_VERSION and os.path.exists(path):
            with open(path, encoding='utf-8') as f:
                problems += topic_problems(version, f.read())
        for language, text in play_texts(version).items():
            print(f'{version} {language}: {play_length(text)}/{PLAY_LIMIT}')
    for problem in problems:
        print(f'error: {problem}', file=sys.stderr)
    sys.exit(1 if problems else 0)


def write(path, text):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def main(argv):
    args = list(argv)
    if args == ['--check']:
        return check()
    if not args or not re.match(r'^\d+\.\d+\.\d+$', args[0]):
        sys.exit(__doc__)
    version = args.pop(0)
    options = {}
    while args:
        flag = args.pop(0)
        if flag not in ('--github', '--store', '--play-dir', '--app-asset') or not args:
            sys.exit(f'unknown or incomplete option {flag!r}\n{__doc__}')
        options[flag] = args.pop(0)

    markdown, origin = source(version)
    store = fit(plain(markdown), APP_STORE_LIMIT)
    print(f'release notes for {version} from {origin}:\n{markdown}', file=sys.stderr)

    if '--github' in options:
        write(options['--github'], markdown)
    if '--store' in options:
        write(options['--store'], store + '\n')
    if '--play-dir' in options:
        texts = play_texts(version)
        if texts:
            problems = play_problems(version)
            if problems:
                sys.exit('\n'.join(problems))
        else:
            # A version from before the Play texts, or one released without:
            # the notes, cut at a whole line. --check keeps this from main.
            print(f'warning: no docs/release-notes/{version}.play.md — Play gets '
                  f'the notes cut to {PLAY_LIMIT} characters', file=sys.stderr)
            texts = {'en-US': fit(plain(markdown), PLAY_LIMIT)}
        for language, text in texts.items():
            write(os.path.join(options['--play-dir'], f'whatsnew-{language}'), text + '\n')
    if '--app-asset' in options:
        write(options['--app-asset'],
              json.dumps({'version': version, 'notes': store}, ensure_ascii=False) + '\n')
    if not options:
        print(markdown, end='')


if __name__ == '__main__':
    main(sys.argv[1:])
