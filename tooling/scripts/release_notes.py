#!/usr/bin/env python3
"""The release notes for a version, in every shape something needs them.

    release_notes.py <version> [--github FILE] [--store FILE]
                               [--play-dir DIR] [--app-asset FILE]

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
    --play-dir   Writes `whatsnew-en-US` there, at most 500 characters, for
                 r0adkll/upload-google-play's `whatsNewDirectory`.
    --app-asset  The JSON `apps/weft/assets/release_notes.json` the app reads.

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
APP_STORE_LIMIT = 4000

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
        items = ['Fixes and improvements.']
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


def write(path, text):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def main(argv):
    args = list(argv)
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
        play = fit(plain(markdown), PLAY_LIMIT)
        write(os.path.join(options['--play-dir'], 'whatsnew-en-US'), play + '\n')
    if '--app-asset' in options:
        write(options['--app-asset'],
              json.dumps({'version': version, 'notes': store}, ensure_ascii=False) + '\n')
    if not options:
        print(markdown, end='')


if __name__ == '__main__':
    main(sys.argv[1:])
