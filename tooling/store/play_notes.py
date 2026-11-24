#!/usr/bin/env python3
"""Rewrites the "What's new" text of a release already on a Play track.

    play_notes.py <version> [--track TRACK] [--apply]

The text is this checkout's `docs/release-notes/<version>.play*.md`, the
same files tooling/scripts/release_notes.py hands the deploy. For a release
that went out with a text that was wrong or cut short: fix the files, merge,
and run the "Play release notes" workflow. Nothing but the release notes
changes; the release keeps its builds, name and status, and every other
release on the track stays as it is.

Without `--apply` it prints what it would set and lets
Play validate it in an edit that is then deleted. With it, the edit is
committed.

Credentials as for iap_products.py: GOOGLE_PLAY_SERVICE_ACCOUNT_JSON.
"""

import os
import sys

from iap_products import PLAY, ApiError, call, play_token

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                'scripts'))
from release_notes import PLAY_LIMIT, play_length, play_problems, play_texts  # noqa: E402


def with_notes(releases, version, notes):
    """The track's releases, the one named [version] with [notes]. None
    when the track has no release of that name."""
    found = False
    updated = []
    for release in releases:
        if release.get('name') == version or release.get('name', '').startswith(f'{version} '):
            release = dict(release, releaseNotes=notes)
            found = True
        updated.append(release)
    return updated if found else None


def main(argv):
    args = list(argv)
    apply = '--apply' in args
    if apply:
        args.remove('--apply')
    track = 'internal'
    if '--track' in args:
        i = args.index('--track')
        track = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit(__doc__)
    version = args[0]

    problems = play_problems(version)
    if problems:
        sys.exit('\n'.join(problems))
    texts = play_texts(version)

    token = play_token()
    edit = call('POST', f'{PLAY}/edits', token, body={})['id']
    committed = False
    try:
        base = f'{PLAY}/edits/{edit}'
        notes = []
        for language, text in texts.items():
            notes.append({'language': language, 'text': text})
            print(f'play: {language} ({play_length(text)}/{PLAY_LIMIT}):\n{text}')

        current = call('GET', f'{base}/tracks/{track}', token) or {}
        for release in current.get('releases', []):
            for note in release.get('releaseNotes', []):
                print(f'play: {track} {release.get("name")} {release.get("versionCodes")} '
                      f'now, {note["language"]}:\n{note["text"]}')
        releases = with_notes(current.get('releases', []), version, notes)
        if releases is None:
            names = [r.get('name') for r in current.get('releases', [])]
            sys.exit(f'play: no release {version} on {track}; it has {names}')
        call('PUT', f'{base}/tracks/{track}', token, body={'track': track, 'releases': releases})
        call('POST', f'{base}:validate', token, body={})
        print(f'play: Play validated the {track} track')
        if apply:
            call('POST', f'{base}:commit', token, body={})
            committed = True
            print(f'play: SET the release notes of {version} on {track}')
        else:
            print('play: dry run: not committed')
    except ApiError as error:
        sys.exit(f'play: {error}')
    finally:
        if not committed:
            try:
                call('DELETE', f'{PLAY}/edits/{edit}', token)
            except ApiError:
                pass


if __name__ == '__main__':
    main(sys.argv[1:])
