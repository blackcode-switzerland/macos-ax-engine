#!/bin/bash
# Build the probe and the fixture with the Swift compiler that comes with
# Xcode or with Apple's command-line developer tools. No other dependency.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
echo "swift: $(swiftc --version 2>&1 | head -1)"

swiftc -swift-version 5 -O -o build/axprobe probe/main.swift
swiftc -swift-version 5 -O -o build/axfixture fixture/main.swift
swiftc -swift-version 5 -O -o build/axengine engine/main.swift

# The same probe inside an application bundle with its own identity, to see
# whether macOS judges the permission by the program or by what started it.
app=build/AXProbe.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp build/axprobe "$app/Contents/MacOS/axprobe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>org.example.axprobe</string>
  <key>CFBundleName</key><string>AXProbe</string>
  <key>CFBundleExecutable</key><string>axprobe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1 || echo "note: ad-hoc signing of the bundle failed"

echo "built: build/axprobe build/axfixture build/axengine $app"
