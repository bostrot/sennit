#!/usr/bin/env bash
# Runs on the TEST Mac: pull the freshest Braid.app from the build Mac and
# relaunch. The mirror image of deploy_macos.sh, for when the test side wants
# to drive — no inbound access to the test Mac needed at all.
#
# One-time setup:
#   • On the BUILD Mac: System Settings → General → Sharing → "Remote Login".
#   • On this (test) Mac:  ssh-copy-id eric@build-host
#   • Get this script over once, using those same credentials:
#       ssh eric@build-host cat \
#         /Users/me/Documents/projects/messenger/tooling/scripts/pull_macos.sh \
#         > ~/braid-pull.sh && chmod +x ~/braid-pull.sh
#   • First launch only: right-click Braid.app → Open past Gatekeeper.
#
# Usage:
#   ~/braid-pull.sh            # pull whatever is built and relaunch
#   ~/braid-pull.sh --build    # have the build Mac rebuild first, then pull

set -euo pipefail

# Adjust these two lines if the build host or checkout ever moves.
# "eric@build-host" assumes an SSH alias on this test Mac; the ground truth of
# the build Mac is account `erict`, IP 192.0.2.10, hostname
# Mac-Studio-von-Eric — and across subnets the .local mDNS name may not
# resolve, so `user@192.0.2.10` is the address that always works.
HOST="${BRAID_HOST:-eric@build-host}"
REPO="/Users/me/Documents/projects/messenger"

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
