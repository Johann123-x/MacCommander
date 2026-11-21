#!/bin/bash
# Builds MacCommander.app into ./build
set -e
cd "$(dirname "$0")"
# Universal binary: build each architecture separately, then merge with lipo
for ARCH in arm64 x86_64; do
  swift build -c release --build-system native --triple "$ARCH-apple-macosx13.0"
done
APP=build/MacCommander.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/MacCommander" \
  .build/arm64-apple-macosx/release/MacCommander \
  .build/x86_64-apple-macosx/release/MacCommander
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacCommander</string>
  <key>CFBundleDisplayName</key><string>MacCommander</string>
  <key>CFBundleIdentifier</key><string>local.maccommander</string>
  <key>CFBundleExecutable</key><string>MacCommander</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
