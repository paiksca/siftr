#!/bin/zsh
# Build VoiceTrim and install it on the connected iPhone.
# It installs over the existing app, because uninstalling resets the free team's developer trust.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"
BUILD="${BUILD_DIR:-$PWD/build}"

swift scripts/make_icon.swift "VoiceTrimExtension/Assets.xcassets/iMessage App Icon.stickersiconset" \
  "VoiceTrim/Assets.xcassets/AppIcon.appiconset" >/dev/null
rm -rf VoiceTrimExtension/Assets.xcassets/AppIcon.appiconset
cp -R VoiceTrim/Assets.xcassets/AppIcon.appiconset VoiceTrimExtension/Assets.xcassets/
xcodegen generate --quiet
# A new build number each time makes iOS drop its cached icon.
xcodebuild -project VoiceTrim.xcodeproj -target VoiceTrim -sdk iphoneos -configuration Debug \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$(date +%s)" SYMROOT="$BUILD" -quiet build
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep connected | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"
xcrun devicectl device install app --device "$DEVICE" "$BUILD/Debug-iphoneos/VoiceTrim.app" | grep -E "App installed|rror"
