#!/bin/zsh
# Focused checks for the bridge and changed app interfaces; no real camera traffic.
set -euo pipefail
cd "$(dirname "$0")/.."

BRIDGE_CHECK_BUILD_ROOT=${CAMERA_BRIDGE_BUILD_ROOT:-"$(pwd)/.camera-rig/build"}
BRIDGE_CHECK_HELPER_BUILD="$BRIDGE_CHECK_BUILD_ROOT/helper"
BRIDGE_CHECK_APP_BUILD="$BRIDGE_CHECK_BUILD_ROOT/app"

swift test --package-path Packages/CameraControlBridge --scratch-path "$BRIDGE_CHECK_HELPER_BUILD"
swift build --package-path Packages/CameraControlBridge --scratch-path "$BRIDGE_CHECK_HELPER_BUILD" --product camera-control-bridge
BRIDGE_CHECK_BINARY="$(swift build --package-path Packages/CameraControlBridge --scratch-path "$BRIDGE_CHECK_HELPER_BUILD" --show-bin-path)/camera-control-bridge"

PYTHONPATH=Tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/camera_rig/tests -v
python3 Tools/camera-rig.py bridge-test --bridge-binary "$BRIDGE_CHECK_BINARY" --output .camera-rig/helper-verification.json
swift test --scratch-path "$BRIDGE_CHECK_APP_BUILD" --filter 'CameraBridgeAdapterTests|BridgeAdapterRoutingTests'
