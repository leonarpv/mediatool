#!/bin/bash
# Builds the Swift package and packages it as MediaTool.app on the Desktop.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "🔨 Building (release)…"
swift build -c release

APP="/Users/leonarpv/Desktop/MediaTool.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/MediaTool "$APP/Contents/MacOS/MediaTool"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MediaTool</string>
    <key>CFBundleIdentifier</key>
    <string>com.leonarpv.mediatool</string>
    <key>CFBundleName</key>
    <string>Media Tool</string>
    <key>CFBundleDisplayName</key>
    <string>Media Tool</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
EOF

echo "✍️  Signing ad-hoc…"
codesign --force --deep --sign - "$APP"

echo "✅ Done: $APP"
echo "   (First time: right-click -> Open, to bypass the Gatekeeper warning for an unsigned app)"
