#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_NAME="17"
WATCH_NAME="GUCCI SmartToilet 7 Nano"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/DerivedData/install-real-17}"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release-iphoneos/Pomodorough.app"
BUILT_WATCH_APP="$BUILT_APP/Watch/Pomodorough.app"

if [[ -f "$ROOT_DIR/Supporting/SentryDSN.local" ]]; then
    SENTRY_DSN="$(tr -d '[:space:]' < "$ROOT_DIR/Supporting/SentryDSN.local")"
    export SENTRY_DSN
fi

xcodebuild \
    -project "$ROOT_DIR/Pomodorough.xcodeproj" \
    -scheme Pomodorough-iOS \
    -configuration Release \
    -destination "platform=iOS,name=$DEVICE_NAME" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -allowProvisioningUpdates \
    build

if [[ ! -d "$BUILT_APP" ]]; then
    printf 'Built app not found: %s\n' "$BUILT_APP" >&2
    exit 1
fi

PLATFORM_NAME="$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$BUILT_APP/Info.plist")"
if [[ "$PLATFORM_NAME" != "iphoneos" ]]; then
    printf 'Refusing to install non-device build with platform %s\n' "$PLATFORM_NAME" >&2
    exit 1
fi

if [[ ! -d "$BUILT_WATCH_APP" ]]; then
    printf 'Embedded watch app not found: %s\n' "$BUILT_WATCH_APP" >&2
    exit 1
fi

WATCH_PLATFORM_NAME="$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$BUILT_WATCH_APP/Info.plist")"
if [[ "$WATCH_PLATFORM_NAME" != "watchos" ]]; then
    printf 'Refusing to install non-device watch build with platform %s\n' "$WATCH_PLATFORM_NAME" >&2
    exit 1
fi

xcrun devicectl device install app --device "$DEVICE_NAME" "$BUILT_APP" --timeout 180

printf 'Installed iOS app on device %s\n' "$DEVICE_NAME"

# Keep the embedded companion payload, but do not depend on automatic Watch
# delivery finishing. Install that same signed payload directly on the watch.
if ! xcrun devicectl device install app --device "$WATCH_NAME" "$BUILT_WATCH_APP" --timeout 180; then
    printf 'iOS installed, but direct watchOS installation failed. See devicectl error above.\n' >&2
    exit 1
fi

printf 'Installed watchOS app on device %s\n' "$WATCH_NAME"
