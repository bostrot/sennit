#!/bin/sh
# Makes each embedded framework's Info.plist claim the iOS version its binary
# was actually built for.
#
# Flutter wraps every native-assets library in a framework whose Info.plist
# says MinimumOSVersion 15.0, whatever the library needs (flutter_tools
# hard-codes it). llamadart's llama.cpp is built for 16.4, and App Store
# Connect refuses a bundle whose framework promises less than its binary
# requires (ITMS-90208). The app itself keeps its own floor: the framework is
# only loaded when the on-device model is used, which is not offered below
# 16.4.
#
# Runs after Flutter's "Thin Binary" phase, which embeds and signs those
# frameworks; a framework it changes is signed again with the same identity.
set -eu

dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
[ -d "$dir" ] || exit 0

for framework in "$dir"/*.framework; do
  [ -d "$framework" ] || continue
  name=$(basename "$framework" .framework)
  binary="$framework/$name"
  plist="$framework/Info.plist"
  [ -f "$binary" ] && [ -f "$plist" ] || continue

  needed=$(xcrun vtool -show-build "$binary" 2>/dev/null |
    awk '$1 == "minos" { print $2; exit }')
  claimed=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist" 2>/dev/null || true)
  [ -n "$needed" ] && [ -n "$claimed" ] || continue

  # Greater only: sort -V puts the larger version last.
  highest=$(printf '%s\n%s\n' "$claimed" "$needed" | sort -V | tail -n 1)
  [ "$highest" = "$claimed" ] && continue

  echo "note: $name.framework: MinimumOSVersion $claimed -> $needed"
  /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $needed" "$plist"
  if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] &&
    [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
      ${OTHER_CODE_SIGN_FLAGS:-} --preserve-metadata=identifier,entitlements \
      "$framework"
  fi
done
