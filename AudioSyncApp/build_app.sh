#!/bin/bash
# Build AudioSyncApp and wrap in .app bundle for proper macOS permissions
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building AudioSyncApp..."
swift build

echo "Creating .app bundle..."
APP_BUNDLE="AudioSyncApp.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Create Info.plist (stable bundle identity across rebuilds)
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AudioSyncApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.audiosync.app</string>
    <key>CFBundleVersion</key>
    <string>1.2</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2</string>
    <key>CFBundleExecutable</key>
    <string>AudioSyncApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>AudioSyncApp needs microphone access for acoustic calibration.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>AudioSyncApp needs screen recording permission to capture system audio for routing to multiple speakers.</string>
</dict>
</plist>
PLIST

# Copy binary
cp -f .build/debug/AudioSyncApp "$APP_BUNDLE/Contents/MacOS/AudioSyncApp"
chmod +x "$APP_BUNDLE/Contents/MacOS/AudioSyncApp"

# Codesign the app bundle (ad-hoc, no developer account needed)
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || {
    echo "WARNING: codesign failed. The app may not trigger permission dialogs."
    echo "Try: System Settings → Privacy & Security → Screen Recording → add AudioSyncApp manually."
}

echo ""
echo "✅ Built: $APP_BUNDLE"
echo "📍 Launch: open $APP_BUNDLE"
echo "📋 Log:   ~/Library/Logs/AudioSyncApp.log"
echo ""
echo "⚠️  IMPORTANT: On first launch, grant Screen Recording permission when prompted."
echo "   If not prompted: System Settings → Privacy & Security → Screen Recording → + AudioSyncApp"
