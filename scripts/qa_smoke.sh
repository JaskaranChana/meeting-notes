#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/jaskaransingh/Projects/stt/ios/Scribeflow/Scribeflow.xcodeproj"
SCHEME="Scribeflow"
BUNDLE_ID="ai.scribeflow.app"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17}"
ARTIFACT_DIR="/Users/jaskaransingh/Projects/stt/ios/Scribeflow/qa-artifacts"
ROUTES=(
  home
  library
  ask
  quickNote
  meetingDetail
  liveCapture
  folderDetail
)

mkdir -p "$ARTIFACT_DIR"

DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/'"$SIMULATOR_NAME"' \(/ {print $2; exit}')"
if [[ -z "${DEVICE_ID:-}" ]]; then
  echo "Unable to find simulator named '$SIMULATOR_NAME'."
  exit 1
fi

echo "Using simulator: $SIMULATOR_NAME ($DEVICE_ID)"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  build >/tmp/scribeflow-qa-build.log

APP_PATH="$(find /Users/jaskaransingh/Library/Developer/Xcode/DerivedData -path '*/Build/Products/Debug-iphonesimulator/Scribeflow.app' | grep -v '/Index.noindex/' | head -n 1)"
if [[ -z "${APP_PATH:-}" ]]; then
  echo "Unable to locate built app in DerivedData."
  exit 1
fi

xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
open -a Simulator >/dev/null 2>&1 || true
xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE_ID" "$APP_PATH"

for route in "${ROUTES[@]}"; do
  echo "Capturing route: $route"
  xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" \
    -SCRIBEFLOW_RESET_DATA \
    -ScribeflowQARoute "$route" >/tmp/scribeflow-qa-launch.log
  sleep 3
  xcrun simctl io "$DEVICE_ID" screenshot "$ARTIFACT_DIR/${route}.png" >/dev/null
done

echo "QA screenshots saved to $ARTIFACT_DIR"
