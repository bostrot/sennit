#!/usr/bin/env bash
# Point the Sennit cask in bostrot/homebrew-tap at a released macOS zip.
#
#   tooling/scripts/update_homebrew_cask.sh <version> <path to the release zip>
#
# Rewrites the cask's version and sha256, commits, pushes, and reads the
# pushed cask back to prove the change landed. The zip it is handed must be
# the bytes the release serves: a cask whose checksum matches nothing fails
# every `brew install --cask bostrot/tap/sennit` with "Cask reports different
# checksum". release.yml downloads the asset from the release for that reason
# rather than hashing what it built.
#
# Environment:
#   TAP_DEPLOY_KEY  private half of a write deploy key on the tap — required.
#   TAP             owner/repo of the tap.         Default bostrot/homebrew-tap.
#   CASK_PATH       path to the cask in that repo. Default Casks/sennit.rb.
#   TAP_URL         clone URL; a local path in tests. Default the tap over SSH.
set -euo pipefail

VERSION="${1:?usage: update_homebrew_cask.sh <version> <zip>}"
ZIP="${2:?usage: update_homebrew_cask.sh <version> <zip>}"
TAP="${TAP:-bostrot/homebrew-tap}"
CASK_PATH="${CASK_PATH:-Casks/sennit.rb}"
TAP_URL="${TAP_URL:-git@github.com:$TAP.git}"

[ -f "$ZIP" ] || { echo "::error::$ZIP does not exist; nothing to checksum." >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::'$VERSION' is not semver" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -n "${TAP_DEPLOY_KEY:-}" ]; then
  printf '%s\n' "$TAP_DEPLOY_KEY" > "$WORK/key"
  chmod 600 "$WORK/key"
  export GIT_SSH_COMMAND="ssh -i $WORK/key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
elif [[ "$TAP_URL" == git@* ]]; then
  echo "::error::TAP_DEPLOY_KEY is empty; cannot push to $TAP." >&2
  exit 1
fi

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

# The two lines this owns are written one per line with two spaces of
# indent; reading them back in the same shape is how the edit proves itself.
cask_field() { # <file> <field>
  sed -n -E "s|^  $2 \"(.*)\"\$|\1|p" "$1" | head -1
}

git clone --quiet --depth 1 "$TAP_URL" "$WORK/tap"
CASK="$WORK/tap/$CASK_PATH"
[ -f "$CASK" ] || { echo "::error::$TAP has no $CASK_PATH" >&2; exit 1; }

if [ "$(cask_field "$CASK" version)" = "$VERSION" ] && [ "$(cask_field "$CASK" sha256)" = "$SHA" ]; then
  echo "::notice::The cask is already at $VERSION with this checksum."
  exit 0
fi

perl -pi -e "s|^  version \".*\"\$|  version \"$VERSION\"|; s|^  sha256 \".*\"\$|  sha256 \"$SHA\"|" "$CASK"
[ "$(cask_field "$CASK" version)" = "$VERSION" ] || { echo "::error::version line not updated" >&2; exit 1; }
[ "$(cask_field "$CASK" sha256)" = "$SHA" ] || { echo "::error::sha256 line not updated" >&2; exit 1; }

git -C "$WORK/tap" -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit --quiet -am "sennit $VERSION"
git -C "$WORK/tap" push --quiet origin HEAD

# Read it back from the remote, not the clone that just pushed.
git clone --quiet --depth 1 "$TAP_URL" "$WORK/check"
[ "$(cask_field "$WORK/check/$CASK_PATH" version)" = "$VERSION" ] \
  && [ "$(cask_field "$WORK/check/$CASK_PATH" sha256)" = "$SHA" ] || {
  echo "::error::$TAP does not serve sennit $VERSION ($SHA) after the push." >&2
  exit 1
}
echo "::notice::Cask updated to $VERSION ($SHA)."
