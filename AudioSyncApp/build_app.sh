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
