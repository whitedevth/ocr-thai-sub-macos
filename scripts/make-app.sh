#!/bin/zsh
# Builds build/OCRThaiSub.app (release) so macOS shows the camera/microphone permission prompts for this app.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
APP=build/OCRThaiSub.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OCRThaiSub "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OCR Thai Sub</string>
    <key>CFBundleDisplayName</key><string>OCR Thai Sub</string>
    <key>CFBundleIdentifier</key><string>local.ocrthaisub</string>
    <key>CFBundleExecutable</key><string>OCRThaiSub</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key><string>อ่านภาพเกมจาก capture card เพื่อ OCR ซับ</string>
    <key>NSMicrophoneUsageDescription</key><string>เล่นเสียงเกมจาก capture card</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
