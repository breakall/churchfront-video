#!/bin/zsh
# Builds "Churchfront Video.app" (release) next to this script.
# ./build.sh release universal includes Apple silicon and Intel executables.
# The executable inside, the bundle ID and the MCP binary keep their CueVideo names on purpose.
set -e
cd "$(dirname "$0")"
MODE=${1:-release}
SWIFT_ARGS=(-c "$MODE")
if [[ $# -gt 2 ]]; then
  echo "Usage: ./build.sh [release|debug] [universal]" >&2
  exit 1
fi
if [[ "${2:-}" == "universal" ]]; then
  SWIFT_ARGS+=(--arch arm64 --arch x86_64)
elif [[ -n "${2:-}" ]]; then
  echo "Usage: ./build.sh [release|debug] [universal]" >&2
  exit 1
fi
swift build "${SWIFT_ARGS[@]}"
swift build --package-path Packages/CameraControlBridge "${SWIFT_ARGS[@]}" --product camera-control-bridge
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/CueVideo"
BRIDGE_BIN="$(swift build --package-path Packages/CameraControlBridge "${SWIFT_ARGS[@]}" --show-bin-path)/camera-control-bridge"
APP="Churchfront Video.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/CueVideo"
cp "$(dirname "$BIN")/cuevideo-mcp" "$APP/Contents/MacOS/cuevideo-mcp"
cp "$BRIDGE_BIN" "$APP/Contents/Helpers/camera-control-bridge"
cp Resources/LaunchAgents/com.churchfront.cuevideo.camera-bridge.plist "$APP/Contents/Library/LaunchAgents/"
codesign --force --sign - "$APP/Contents/Helpers/camera-control-bridge"
cp -R "$(dirname "$BIN")/CueKit_CueDesign.bundle" "$APP/Contents/Resources/"
swift Tools/check-app-resources.swift "$APP" "$(dirname "$BIN")/CueKit_CueDesign.bundle"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Churchfront Video</string>
  <key>CFBundleDisplayName</key><string>Churchfront Video</string>
  <key>CFBundleIdentifier</key><string>com.churchfront.cuevideo</string>
  <key>CFBundleExecutable</key><string>CueVideo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.2</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Churchfront Video controls your ATEM switcher and PTZ cameras and shows NDI video from your network.</string>
  <key>NSBonjourServices</key><array><string>_ndi._tcp</string><string>_blackmagic._tcp</string><string>_http._tcp</string></array>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
# Tell Finder and the Dock the bundle changed, so they drop the icon they remembered.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "Built $(pwd)/$APP"
