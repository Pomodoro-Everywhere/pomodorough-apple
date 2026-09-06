#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_NAME="17"
WATCH_NAME="GUCCI SmartToilet 7 Nano"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/DerivedData/install-real-17}"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release-iphoneos/Pomodorough.app"
BUILT_WATCH_APP="$DERIVED_DATA_DIR/Build/Products/Release-watchos/Pomodorough.app"

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

xcrun devicectl device install app --device "$DEVICE_NAME" "$BUILT_APP"

printf 'Installed iOS app on device %s\n' "$DEVICE_NAME"

# Watch app ships embedded in the iOS bundle (Embed Watch Content) and is
# delivered to the paired watch through the normal companion channel, which
# is what registers the WatchConnectivity counterpart linkage.
# Verify the embedded payload made it into the bundle:
if [[ ! -d "$BUILT_APP/Watch/Pomodorough.app" ]]; then
    printf 'WARNING: no embedded watch app in iOS bundle; WatchConnectivity pairing will fail\n' >&2
fi
