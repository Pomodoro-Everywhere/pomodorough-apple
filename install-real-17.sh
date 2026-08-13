#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_NAME="17"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/DerivedData/install-real-17}"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release-iphoneos/Pomodorough.app"

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
