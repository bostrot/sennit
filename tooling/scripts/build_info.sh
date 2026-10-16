#!/usr/bin/env bash
# Print the build details the About dialog shows, as JSON for
# `flutter build --dart-define-from-file`. Read by apps/weft/lib/app/build_info.dart.
#
#   tooling/scripts/build_info.sh > "$RUNNER_TEMP/build_info.json"
#   flutter build ipa --dart-define-from-file="$RUNNER_TEMP/build_info.json"
#
# GIT_TAG is set when the commit is a release; the dialog then shows only the
# version. On Actions the ref comes from GITHUB_REF_NAME, since a checkout of a
# commit is a detached HEAD with no branch name to ask git for.
set -euo pipefail

clean() { tr -d '"\\\n'; }

sha=$(git rev-parse --short HEAD)
ref=${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
  tag=$GITHUB_REF_NAME
else
  tag=$(git describe --tags --exact-match 2>/dev/null || true)
fi
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf '{"GIT_SHA":"%s","GIT_REF":"%s","GIT_TAG":"%s","BUILD_TIME":"%s"}\n' \
  "$(printf %s "$sha" | clean)" "$(printf %s "$ref" | clean)" \
  "$(printf %s "$tag" | clean)" "$built"
