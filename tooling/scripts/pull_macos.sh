#!/usr/bin/env bash
# Runs on the TEST Mac: pull the freshest Braid.app from the build Mac and
# relaunch. The mirror image of deploy_macos.sh, for when the test side wants
# to drive — no inbound access to the test Mac needed at all.
#
# One-time setup:
#   • On the BUILD Mac: System Settings → General → Sharing → "Remote Login".
#   • On this (test) Mac:  ssh-copy-id user@build-mac
#   • Get this script over once, using those same credentials:
#       ssh user@build-mac cat \
#         <repo>/tooling/scripts/pull_macos.sh \
#         > ~/braid-pull.sh && chmod +x ~/braid-pull.sh
#   • First launch only: right-click Braid.app → Open past Gatekeeper.
#
# Usage:
#   ~/braid-pull.sh            # pull whatever is built and relaunch
#   ~/braid-pull.sh --build    # have the build Mac rebuild first, then pull

set -euo pipefail

# Point these at your build host and checkout — or export BRAID_HOST and
# BRAID_REPO instead of editing.
HOST="${BRAID_HOST:-user@build-mac}"
REPO="${BRAID_REPO:-$HOME/braid}"

APP="$REPO/apps/weft/build/macos/Build/Products/Release/Braid.app"

if [ "${1:-}" = "--build" ]; then
  echo "==> Building on $HOST"
  ssh "$HOST" "cd '$REPO/apps/weft' && \
    RUSTC=\"\$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc\" \
    flutter build macos --release"
fi

echo "==> Pulling Braid.app from $HOST"
mkdir -p ~/Applications
# --delete keeps the bundle exact; a stale dylib from a previous build inside
# a .app is a crash with a misleading stack.
rsync -az --delete "$HOST:$APP/" ~/Applications/Braid.app/

echo "==> Relaunching"
pkill -x Braid 2>/dev/null || true
sleep 1
open ~/Applications/Braid.app

echo "==> Done"
