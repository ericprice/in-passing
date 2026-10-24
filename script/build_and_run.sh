#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
MODE="${1:-run}"
case "$MODE" in run|--verify|--debug|--logs|--telemetry|--build-only) ;; *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry|--build-only]" >&2; exit 2 ;; esac
./script/build_app.sh development
if [[ "$MODE" == --build-only ]]; then exit 0; fi
APP_BUNDLE="/Applications/In Passing.app"
BUILT_BUNDLE="$PROJECT_ROOT/build/App/development/In Passing.app"
# Build first; keep the current app intact if compilation or signing fails.
if [[ -d "$APP_BUNDLE" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")" == com.ericprice.InPassing ]] || exit 1
fi
pkill -x InPassing >/dev/null 2>&1 || true
if [[ -d "$APP_BUNDLE" ]]; then
  BACKUP="$(mktemp -d "$PROJECT_ROOT/build/replaced.XXXXXX")"
  mv "$APP_BUNDLE" "$BACKUP/previous-app.retired"
fi
ditto "$BUILT_BUNDLE" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x InPassing >/dev/null ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/InPassing" ;;
  --logs|--telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "InPassing"' ;;
esac
