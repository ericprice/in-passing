#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
./script/build_app.sh distribution
BUILT_APP="$ROOT_DIR/build/App/distribution/In Passing.app"
python3 "$ROOT_DIR/script/validate_release_app.py" "$BUILT_APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
mkdir -p "$ROOT_DIR/dist"
STAGING="$(mktemp -d "$ROOT_DIR/build/package-zip.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP" "$STAGING/In-Passing-$VERSION.zip"
"$ROOT_DIR/script/notarize_zip.sh" "$STAGING/In-Passing-$VERSION.zip"
if [[ -f "$ROOT_DIR/dist/In-Passing-$VERSION.zip" ]]; then
  BACKUP="$(mktemp -d "$ROOT_DIR/build/previous-zip.XXXXXX")"
  ditto "$ROOT_DIR/dist/In-Passing-$VERSION.zip" "$BACKUP/previous.zip"
fi
mv "$STAGING/In-Passing-$VERSION.zip" "$ROOT_DIR/dist/In-Passing-$VERSION.zip"
printf 'Created: %s\n' "$ROOT_DIR/dist/In-Passing-$VERSION.zip"
