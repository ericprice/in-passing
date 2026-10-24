#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
MODE="${1:-development}"
case "$MODE" in development|distribution) ;; *) echo "usage: $0 [development|distribution]" >&2; exit 2 ;; esac
APP_BUNDLE="$PROJECT_ROOT/build/App/$MODE/In Passing.app"
BUNDLE_ID="com.ericprice.InPassing"
BUILD_ARGS=(-c debug)
if [[ "$MODE" == distribution ]]; then BUILD_ARGS=(-c release --arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BINARY_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
rm -rf "$APP_BUNDLE"
RESOURCE_DIR="$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$RESOURCE_DIR"
cp "$BINARY_DIR/InPassing" "$APP_BUNDLE/Contents/MacOS/InPassing"
cp -X "$PROJECT_ROOT/Resources/in-passing-menu-icon.pdf" "$RESOURCE_DIR/"
for RESOURCE in "$BINARY_DIR/"*.bundle; do
  [[ -d "$RESOURCE" ]] && ditto "$RESOURCE" "$RESOURCE_DIR/$(basename "$RESOURCE")"
done
SPARKLE_SOURCE="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_DEST="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
rm -rf "$SPARKLE_DEST"
ditto "$SPARKLE_SOURCE" "$SPARKLE_DEST"
cp -X "$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$RESOURCE_DIR/Sparkle-LICENSE.txt"
# Compile the supplied Icon Composer document into the native asset catalog and ICNS.
xcrun actool "$PROJECT_ROOT/in-passing-app-icon.icon" \
  --compile "$RESOURCE_DIR" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon in-passing-app-icon --output-partial-info-plist "$PROJECT_ROOT/build/icon-info-$MODE.plist" \
  --output-format human-readable-text --warnings --notices
cp "$PROJECT_ROOT/Configuration/App.plist" "$APP_BUNDLE/Contents/Info.plist"
if [[ "$MODE" == distribution ]]; then
  python3 "$PROJECT_ROOT/script/configure_posthog.py" "$RESOURCE_DIR/PostHogConfiguration.plist" --distribution
else
  python3 "$PROJECT_ROOT/script/configure_posthog.py" "$RESOURCE_DIR/PostHogConfiguration.plist"
fi
mkdir -p "$RESOURCE_DIR/Licenses"
cp -X "$PROJECT_ROOT/.build/checkouts/posthog-ios/LICENSE" "$RESOURCE_DIR/Licenses/PostHog.txt"
cp -X "$PROJECT_ROOT/.build/checkouts/posthog-ios/vendor/libwebp/COPYING" "$RESOURCE_DIR/Licenses/libwebp.txt"
cp -X "$PROJECT_ROOT/.build/checkouts/posthog-ios/vendor/PHPLCrashReporter/LICENSE" "$RESOURCE_DIR/Licenses/PLCrashReporter.txt"
/usr/libexec/PlistBuddy -c "Merge '$PROJECT_ROOT/Configuration/Updates.plist'" "$APP_BUNDLE/Contents/Info.plist"
# A stable signing identity preserves Accessibility trust across later rebuilds.
# Other Macs can supply IN_PASSING_SIGN_IDENTITY; otherwise fall back to ad-hoc.
IN_PASSING_SIGN_IDENTITY="${IN_PASSING_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ {print $2; exit}')}"
IN_PASSING_SIGN_IDENTITY="${IN_PASSING_SIGN_IDENTITY:--}"
# Sign Sparkle's nested helpers before signing the enclosing framework and app.
for PART in "$SPARKLE_DEST/Versions/B/Autoupdate" \
  "$SPARKLE_DEST/Versions/B/Updater.app" \
  "$SPARKLE_DEST/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE_DEST/Versions/B/XPCServices/Installer.xpc"; do
  codesign --force --timestamp --options runtime --preserve-metadata=entitlements --sign "$IN_PASSING_SIGN_IDENTITY" "$PART"
done
codesign --force --timestamp --options runtime --sign "$IN_PASSING_SIGN_IDENTITY" "$SPARKLE_DEST"
codesign --force --timestamp --options runtime --sign "$IN_PASSING_SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
if [[ "$MODE" == distribution ]]; then
  [[ "$IN_PASSING_SIGN_IDENTITY" != "-" ]] || { echo "Distribution requires a Developer ID Application signing identity." >&2; exit 1; }
  ARCHS="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/InPassing")"
  [[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] || { echo "Distribution app must be universal." >&2; exit 1; }
fi
printf 'Built: %s\n' "$APP_BUNDLE"
