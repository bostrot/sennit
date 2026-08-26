#!/usr/bin/env bash
# Runs on the TEST Mac: pull the freshest Braid.app from the build Mac and
# relaunch. The mirror image of deploy_macos.sh, for when the test side wants
# to drive — no inbound access to the test Mac needed at all.
#
# One-time setup:
#   • On the BUILD Mac: System Settings → General → Sharing → "Remote Login".
#   • On this (test) Mac:  ssh-copy-id you@build-mac
#   • Get this script over once, using those same credentials:
#       ssh you@build-mac cat \
#         <repo>/tooling/scripts/pull_macos.sh \
#         > ~/braid-pull.sh && chmod +x ~/braid-pull.sh
#   • Put the build host in your shell profile, so you type it once:
#       export BRAID_HOST=you@build-mac
#       export BRAID_REPO=/path/to/messenger
#   • First launch only: right-click Braid.app → Open past Gatekeeper.
#
# Usage:
#   ~/braid-pull.sh            # pull whatever is built and relaunch
#   ~/braid-pull.sh --build    # have the build Mac rebuild first, then pull

set -euo pipefail

# No default host on purpose. A placeholder here is a script that reaches for
# a machine called "build-mac", and what the user sees is eight lines of rsync
# protocol error about a hostname they never chose.
HOST="${BRAID_HOST:-}"
REPO="${BRAID_REPO:-}"
CONFIG="${BRAID_CONFIG:-Release}"

if [ -z "$HOST" ] || [ -z "$REPO" ]; then
  cat >&2 <<'USAGE'
Set the build host and its checkout first:

  export BRAID_HOST=you@build-mac        # whatever `ssh` already reaches
  export BRAID_REPO=/path/to/messenger   # the repo on that machine

Then:  ~/braid-pull.sh          (pull what is built)
       ~/braid-pull.sh --build  (rebuild there first, then pull)
USAGE
  exit 2
fi

APP="$REPO/apps/weft/build/macos/Build/Products/$CONFIG/Braid.app"

if [ "${1:-}" = "--build" ]; then
  # `tr` rather than ${CONFIG,,}: macOS still ships bash 3.2 as /bin/bash, and
  # this script's whole job is to run on the *other* Mac.
  MODE="$(printf '%s' "$CONFIG" | tr '[:upper:]' '[:lower:]')"
  echo "==> Building on $HOST"
  ssh "$HOST" "cd '$REPO/apps/weft' && \
    RUSTC=\"\$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc\" \
    flutter build macos --$MODE"
fi

# Checked before the copy rather than diagnosed after it: rsync's answer to a
# missing source is a protocol error, which reads like a broken connection.
if ! ssh "$HOST" "[ -d '$APP' ]"; then
  echo "No $CONFIG build on $HOST at:" >&2
  echo "  $APP" >&2
  echo "Run with --build, or set BRAID_CONFIG=Debug if that is what is there." >&2
  exit 1
fi

# When it was built, said out loud. A stale bundle syncs perfectly happily and
# then behaves exactly like the change you were testing never landed, which is
# a long way to walk before suspecting the copy.
#
# The executable, not the bundle: a directory's mtime only moves when its own
# entries change, so a rebuilt .app whose contents are all one level down still
# reports the date of the build before it.
BUILT="$(ssh "$HOST" "stat -f '%Sm' '$APP/Contents/MacOS/Braid'")"
echo "==> Pulling $CONFIG Braid.app from $HOST (built $BUILT)"

mkdir -p ~/Applications
# --delete keeps the bundle exact; a stale dylib from a previous build inside
# a .app is a crash with a misleading stack.
rsync -az --delete "$HOST:$APP/" ~/Applications/Braid.app/

echo "==> Relaunching"
pkill -x Braid 2>/dev/null || true
sleep 1
open ~/Applications/Braid.app

echo "==> Done"
