#!/usr/bin/env bash
# Put SQLite's WebAssembly build next to the browser build, which loads it at
# start (packages/weft_store/lib/src/sqlite_web.dart).
#
#   tooling/scripts/fetch_sqlite_wasm.sh apps/weft/build/web
#
# The wasm must match the Dart `sqlite3` package exactly — its bindings and the
# module are released together — so the version is read from pubspec.lock and
# the file is checked against a hash pinned here. A lock bump without a new
# hash fails the build rather than shipping an unverified binary.
set -euo pipefail

out=${1:?usage: fetch_sqlite_wasm.sh <web build dir>}
root=$(cd "$(dirname "$0")/../.." && pwd)

version=$(awk '/^  sqlite3:$/{f=1} f&&/version:/{gsub(/"/,"",$2); print $2; exit}' "$root/pubspec.lock")
case "$version" in
  3.5.1) sha=13d3f11d05b39ba0618a7115fb41640a5d48b6300f5d3f325f554b42bd6688a4 ;;
  *)
    echo "No pinned sqlite3.wasm hash for sqlite3 $version — add one here." >&2
    exit 1
    ;;
esac

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" \
  "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-$version/sqlite3.wasm"
echo "$sha  $tmp" | shasum -a 256 -c - >/dev/null
mkdir -p "$out"
mv "$tmp" "$out/sqlite3.wasm"
trap - EXIT
echo "sqlite3.wasm $version → $out"
