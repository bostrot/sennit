#!/bin/sh
# Install the latest desktop release on macOS or Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/bostrot/sennit/main/tooling/install/install.sh | sh
#
# macOS: the .app goes to /Applications (or ~/Applications when that is not
# writable). Linux: the bundle goes to ~/.local/share/<app>, a launcher to
# ~/.local/bin and a desktop entry to ~/.local/share/applications.
#
# Pin a version with VERSION=1.0.6, pick the install root with PREFIX=… .

set -eu

REPO="bostrot/sennit"
VERSION="${VERSION:-}"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"

case "$(uname -s)" in
  Darwin) os=macos; pattern='-macos\.zip$' ;;
  Linux)
    os=linux
    case "$(uname -m)" in
      x86_64|amd64) arch=x64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) die "unsupported architecture $(uname -m)" ;;
    esac
    pattern="-linux-$arch\\.tar\\.gz\$"
    ;;
  *) die "unsupported OS $(uname -s) — on Windows use install.ps1" ;;
esac

if [ -n "$VERSION" ]; then
  api="https://api.github.com/repos/$REPO/releases/tags/v${VERSION#v}"
else
  api="https://api.github.com/repos/$REPO/releases/latest"
fi

# Release assets are named <App>-<version>-<platform>.<ext>; matching on the
# suffix keeps this working across renames of the app. The patterns start with
# "-", so they go in through -e or grep reads them as options.
url=$(curl -fsSL "$api" \
  | grep -o '"browser_download_url": *"[^"]*"' \
  | sed 's/.*"\(https[^"]*\)"/\1/' \
  | grep -E -e "$pattern" | head -n 1) || true
[ -n "$url" ] || die "no $os${arch:+ $arch} build in ${VERSION:-the latest} release of $REPO"

file=$(basename "$url")
name=${file%%-*}
lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading $file"
curl -fL --progress-bar -o "$tmp/$file" "$url"

if [ "$os" = macos ]; then
  ditto -x -k "$tmp/$file" "$tmp/x"
  app=$(find "$tmp/x" -maxdepth 1 -name '*.app' | head -n 1)
  [ -n "$app" ] || die "no .app inside $file"
  dest="${PREFIX:-/Applications}"
  [ -w "$dest" ] || dest="$HOME/Applications"
  mkdir -p "$dest"
  target="$dest/$(basename "$app")"
  rm -rf "$target"
  ditto "$app" "$target"
  xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
  say "Installed $target"
  say "Open it with:  open \"$target\""
else
  prefix="${PREFIX:-$HOME/.local}"
  dest="$prefix/share/$lower"
  rm -rf "$dest"
  mkdir -p "$dest" "$prefix/bin" "$prefix/share/applications" \
    "$prefix/share/icons/hicolor/256x256/apps"
  tar -xzf "$tmp/$file" -C "$dest"
  bin=$(find "$dest" -maxdepth 1 -type f -perm -u+x | head -n 1)
  [ -n "$bin" ] || die "no executable inside $file"
  ln -sf "$bin" "$prefix/bin/$lower"
  curl -fsSL -o "$prefix/share/icons/hicolor/256x256/apps/$lower.png" \
    "https://raw.githubusercontent.com/$REPO/main/docs/images/sennit-icon.png" || true
  cat > "$prefix/share/applications/$lower.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=Every conversation, one thread
Exec=$bin
Icon=$lower
Categories=Network;InstantMessaging;Chat;
Terminal=false
EOF
  say "Installed to $dest"
  case ":$PATH:" in
    *":$prefix/bin:"*) say "Run it with:  $lower" ;;
    *) say "Run it with:  $prefix/bin/$lower  (add $prefix/bin to PATH for '$lower')" ;;
  esac
  say "Needs GTK 3, libsecret and SQLite — e.g. sudo apt install libgtk-3-0 libsecret-1-0 libsqlite3-0"
fi
