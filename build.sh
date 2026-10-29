#!/bin/bash
# 建置 PadCast.app（需要 Xcode 或 Command Line Tools：xcode-select --install）
set -e
cd "$(dirname "$0")"

APP="PadCast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 同時編 Apple Silicon 與 Intel，合併成 universal binary
mkdir -p build
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13.0" Sources/*.swift -o "build/PadCast-$arch" \
        -framework Cocoa -framework AVFoundation -framework CoreMediaIO -framework CoreImage \
        -framework VideoToolbox
done
lipo -create build/PadCast-arm64 build/PadCast-x86_64 -output "$APP/Contents/MacOS/PadCast"

# 由 icon.png（1024×1024）產生 App 圖示
if [ -f icon.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.yui1227.padcast</string>
    <key>CFBundleName</key><string>PadCast</string>
    <key>CFBundleExecutable</key><string>PadCast</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key><string>用來擷取有線連接的 iPad 畫面</string>
    <key>NSMicrophoneUsageDescription</key><string>用來擷取 iPad 的聲音</string>
</dict>
</plist>
EOF

codesign --force --deep -s - "$APP"
touch "$APP"   # 讓 Finder 重新讀取圖示
echo "完成：$(pwd)/$APP"
echo "執行：open $APP"
