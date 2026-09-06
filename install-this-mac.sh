#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/DerivedData/install-this-mac}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/Pomodorough.app"
INSTALLED_APP="$INSTALL_DIR/Pomodorough.app"

if [[ -f "$ROOT_DIR/Supporting/SentryDSN.local" ]]; then
    SENTRY_DSN="$(tr -d '[:space:]' < "$ROOT_DIR/Supporting/SentryDSN.local")"
    export SENTRY_DSN
fi

xcodebuild \
    -project "$ROOT_DIR/Pomodorough.xcodeproj" \
    -scheme Pomodorough-macOS \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build

if [[ ! -d "$BUILT_APP" ]]; then
    printf 'Built app not found: %s\n' "$BUILT_APP" >&2
    exit 1
fi

PLATFORM_NAME="$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$BUILT_APP/Contents/Info.plist")"
if [[ "$PLATFORM_NAME" != "macosx" ]]; then
    printf 'Refusing to install non-native build with platform %s\n' "$PLATFORM_NAME" >&2
    exit 1
fi

if [[ -w "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALLED_APP"
    /usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"
else
    sudo rm -rf "$INSTALLED_APP"
    sudo /usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"
fi

printf 'Installed native macOS app at %s\n' "$INSTALLED_APP"
