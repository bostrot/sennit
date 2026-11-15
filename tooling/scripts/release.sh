#!/usr/bin/env bash
# Cut a release: write the version into pubspec.yaml and into the constant a
# backup archive records, commit, tag.
#
#   tooling/scripts/release.sh 1.2.0
#   git push && git push origin v1.2.0     # this triggers the Release workflow
#
# The build number after the + is the commit count, so it rises monotonically
# — Android's versionCode and iOS's CFBundleVersion both come from it.

set -euo pipefail

VERSION="${1:?usage: release.sh <version, e.g. 1.2.0>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "'$VERSION' is not a plain semver (expected e.g. 1.2.0)" >&2
  exit 1
}

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PUBSPEC="$REPO/apps/weft/pubspec.yaml"
BACKUP="$REPO/apps/weft/lib/services/backup/backup_service.dart"

if ! git -C "$REPO" diff --quiet || ! git -C "$REPO" diff --cached --quiet; then
  echo "the working tree is not clean — commit or stash first" >&2
  exit 1
fi

# +1 for the release commit this script is about to make.
BUILD=$(( $(git -C "$REPO" rev-list --count HEAD) + 1 ))

perl -pi -e "s/^version: .*/version: $VERSION+$BUILD/" "$PUBSPEC"
grep -q "^version: $VERSION+$BUILD$" "$PUBSPEC" || {
  echo "failed to rewrite the version in $PUBSPEC" >&2
  exit 1
}

# backup_version_test.dart holds this constant to the pubspec version.
perl -pi -e "s/^const String kSennitVersion = '.*';/const String kSennitVersion = '$VERSION';/" "$BACKUP"
grep -q "^const String kSennitVersion = '$VERSION';$" "$BACKUP" || {
  echo "failed to rewrite kSennitVersion in $BACKUP" >&2
  exit 1
}

git -C "$REPO" add "$PUBSPEC" "$BACKUP"
git -C "$REPO" commit -m "Release $VERSION"
git -C "$REPO" tag "v$VERSION"

echo "Tagged v$VERSION (build $BUILD)."
echo "Publish with:  git push && git push origin v$VERSION"
