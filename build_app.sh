#!/bin/bash
# Compila el paquete Swift y lo empaqueta como MediaTool.app en el Escritorio.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "🔨 Compilando (release)…"
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

echo "✍️  Firmando ad-hoc…"
codesign --force --deep --sign - "$APP"

echo "✅ Listo: $APP"
echo "   (Primera vez: clic derecho -> Abrir, para saltar el aviso de Gatekeeper de app sin firma)"
