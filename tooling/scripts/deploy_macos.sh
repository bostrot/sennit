#!/usr/bin/env bash
# Build Braid for macOS on this Mac and push it to the test Mac.
#
# The iteration loop this exists for: the build Mac (192.0.2.10) compiles,
# rsync ships only the changed bytes across to the test Mac in the
# 192.0.2.0/24 subnet, and the app is relaunched there — a few seconds per
# round after the first full copy.
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
#   tooling/scripts/deploy_macos.sh user@192.0.2.20
#   BRAID_MAC=user@192.0.2.20 tooling/scripts/deploy_macos.sh
#   tooling/scripts/deploy_macos.sh --no-build user@192.0.2.20   # ship as-is

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
APP="$REPO/apps/weft/build/macos/Build/Products/Release/Braid.app"

if $BUILD; then
  echo "==> Building Braid.app (release)"
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
rsync -az --delete "$APP/" "$TARGET:Applications/Braid.app/"

echo "==> Relaunching"
ssh "$TARGET" 'pkill -x Braid 2>/dev/null || true; sleep 1; open ~/Applications/Braid.app'

echo "==> Done"
