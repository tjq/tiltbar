#!/bin/bash
# Build, sign, notarize, and package TiltBar for a release.
#
# One-time setup:
#   1. "Developer ID Application" certificate in the login keychain.
#   2. xcrun notarytool store-credentials <profile> --apple-id <email> --team-id <TEAMID>
#
# Usage: NOTARY_PROFILE=<profile> ./release.sh
#   → dist/TiltBar-<version>.zip, universal, signed + notarized + stapled
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TiltBar"
PROFILE="${NOTARY_PROFILE:-gifford-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DIST="dist"
APP_BUNDLE="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME-$VERSION.zip"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
    echo "✗ No 'Developer ID Application' identity found in the keychain." >&2
    exit 1
fi
echo "▶ Signing identity: $IDENTITY"

echo "▶ Compiling universal binary…"
rm -rf "$DIST"
mkdir -p "$DIST"
swift build -c release --arch arm64 --arch x86_64
BINARY=".build/apple/Products/Release/$APP_NAME"

echo "▶ Assembling bundle…"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "▶ Signing…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"

echo "▶ Zipping…"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"

echo "▶ Notarizing (profile: $PROFILE)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "▶ Stapling…"
xcrun stapler staple "$APP_BUNDLE"

# Re-zip so the published archive contains the stapled app.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"

echo "✓ Release artifact: $ZIP"
echo "  sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
