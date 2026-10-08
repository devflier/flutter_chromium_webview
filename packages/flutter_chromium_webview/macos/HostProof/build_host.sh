#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "Compiling main.mm..."
clang++ -std=c++20 -arch arm64 -x objective-c++   -I../cef/root   -F../cef/root/Release   -L../cef/build/lib   main.mm   -framework "Chromium Embedded Framework"   -framework Cocoa   -lcef_dll_wrapper   -o ChromiumWebViewHost

echo "Creating bundle structure..."
APP="ChromiumWebViewHost.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Resources"

mv ChromiumWebViewHost "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ChromiumWebViewHost</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.ChromiumWebViewHost</string>
    <key>CFBundleName</key>
    <string>ChromiumWebViewHost</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "Running embed_cef.py..."
export TARGET_BUILD_DIR="$DIR"
export FULL_PRODUCT_NAME="ChromiumWebViewHost.app"
export PRODUCT_BUNDLE_IDENTIFIER="com.example.ChromiumWebViewHost"
export PROJECT_DIR="$DIR"
export ARCHS="arm64"
python3 ../scripts/embed_cef.py

echo "Done!"
