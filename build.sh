#!/bin/bash
# Build ThaiPTT.app — ต้องมี Xcode หรือ Command Line Tools (xcode-select --install)
#   ./build.sh            build สำหรับเครื่องนี้
#   ./build.sh --install  build + ติดตั้งลง /Applications + เปิดแอป
#   ./build.sh --dist     build universal (Apple Silicon + Intel) + สร้าง dist/ThaiPTT-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP="ThaiPTT.app"
MIN_OS="13.0"
BIN="$APP/Contents/MacOS/ThaiPTT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

echo "Compiling…"
if [[ "$MODE" == "--dist" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macos$MIN_OS" Sources/main.swift -o "$TMP/ThaiPTT-$arch"
    done
    lipo -create "$TMP/ThaiPTT-arm64" "$TMP/ThaiPTT-x86_64" -output "$BIN"
else
    swiftc -O -target "$(uname -m)-apple-macos$MIN_OS" Sources/main.swift -o "$BIN"
fi

echo "Signing (ad-hoc)…"
# โฟลเดอร์ที่ sync กับ iCloud จะติด extended attributes ซึ่ง codesign ไม่ยอม
xattr -cr "$APP"
codesign --force --sign - "$APP"

case "$MODE" in
--install)
    pkill -x ThaiPTT 2>/dev/null || true
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/$APP"
    open "/Applications/$APP"
    ;;
--dist)
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
    DMG="dist/ThaiPTT-$VERSION.dmg"
    STAGE="$TMP/stage"
    mkdir -p "$STAGE" dist
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp INSTALL.txt "$STAGE/READ ME FIRST.txt"
    rm -f "$DMG"
    if diskutil image create from --help >/dev/null 2>&1; then   # macOS 27+ (hdiutil deprecated)
        diskutil image create from --format UDZO --volumeName "ThaiPTT $VERSION" "$STAGE" "$DMG" >/dev/null
    else
        hdiutil create -volname "ThaiPTT $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
    fi
    echo "Created $DMG"
    lipo -archs "$BIN" | sed 's/^/Architectures: /'
    ;;
*)
    echo "Built ./$APP  (รัน: open $APP  หรือ ./build.sh --install)"
    ;;
esac
