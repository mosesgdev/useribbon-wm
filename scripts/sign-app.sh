#!/usr/bin/env bash
# Sign an assembled Ribbon.app inside-out: Sparkle's helpers, then its framework, then the app.
# Never --deep: it would stamp the app's flags and identifier onto Sparkle's code.
# Usage: scripts/sign-app.sh APP IDENTITY [codesign options...]
#   dev:     scripts/sign-app.sh build/Ribbon.app "$(scripts/local-signing.sh identity)"   (or - for ad-hoc)
#   release: scripts/sign-app.sh build/Ribbon.app "Developer ID Application: ..." --options runtime --timestamp
set -euo pipefail

app=$1 identity=$2
shift 2
sparkle=$app/Contents/Frameworks/Sparkle.framework

for item in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
  codesign --force --sign "$identity" "$@" "$item"
done
codesign --force --sign "$identity" --identifier com.makeautomation.ribbon "$@" "$app"
