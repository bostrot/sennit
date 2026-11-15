#!/usr/bin/env bash
# Build Sennit for macOS on this Mac and push it to the test Mac.
#
# The iteration loop this exists for: the build Mac compiles, rsync ships
# only the changed bytes across to the test Mac, and the app is relaunched
# there — a few seconds per round after the first full copy.
#
# One-time setup on the TEST Mac:
#   1. System Settings → General → Sharing → enable "Remote Login".
#   2. From the build Mac:  ssh-copy-id <user>@<test-mac-ip>
#      (or paste ~/.ssh/id_*.pub into the test Mac's ~/.ssh/authorized_keys)
#   3. First launch only: macOS may warn about an unidentified developer —
#      right-click the app → Open. rsync sets no quarantine flag, so
#      subsequent updates launch without ceremony.
#
# Usage:
#   tooling/scripts/deploy_macos.sh user@test-mac
#   BRAID_MAC=user@test-mac tooling/scripts/deploy_macos.sh
#   tooling/scripts/deploy_macos.sh --no-build user@test-mac   # ship as-is

set -euo pipefail

BUILD=true
if [ "${1:-}" = "--no-build" ]; then
  BUILD=false
  shift
fi

TARGET="${1:-${BRAID_MAC:-}}"
if [ -z "$TARGET" ]; then
  echo "usage: $0 [--no-build] user@test-mac-ip   (or set BRAID_MAC)" >&2
  exit 1
fi

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$REPO/apps/weft/build/macos/Build/Products/Release/Sennit.app"

if $BUILD; then
  echo "==> Building Sennit.app (release)"
  (
    cd "$REPO/apps/weft"
    RUSTC="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc" \
      flutter build macos --release
  )
fi

[ -d "$APP" ] || { echo "no app at $APP — build first" >&2; exit 1; }

echo "==> Syncing to $TARGET"
ssh "$TARGET" 'mkdir -p ~/Applications'
# --delete keeps the bundle exact; a stale dylib from a previous build inside
# a .app is a crash with a misleading stack.
rsync -az --delete "$APP/" "$TARGET:Applications/Sennit.app/"

echo "==> Relaunching"
ssh "$TARGET" 'pkill -x Sennit 2>/dev/null || true; sleep 1; open ~/Applications/Sennit.app'

echo "==> Done"
