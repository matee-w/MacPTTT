#!/bin/bash
# Build MacPTTT.app — ต้องมี Xcode หรือ Command Line Tools (xcode-select --install)
#   ./build.sh            build สำหรับเครื่องนี้
#   ./build.sh --install  build + ติดตั้งลง /Applications + เปิดแอป
#   ./build.sh --dist     build universal (Apple Silicon + Intel) + สร้าง dist/MacPTTT-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
NAME="MacPTTT"
MIN_OS="13.0"

# build และเซ็นในโฟลเดอร์ชั่วคราว: โฟลเดอร์ที่ sync กับ iCloud จะใส่ extended attributes
# (FinderInfo) กลับเข้ามาที่ bundle ระหว่างเซ็น ทำให้ codesign ล้มเป็นบางครั้ง
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/$NAME.app"
BIN="$APP/Contents/MacOS/$NAME"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # สร้างใหม่ได้ด้วย: swift Tools/make-icon.swift

echo "Compiling…"
if [[ "$MODE" == "--dist" ]]; then
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macos$MIN_OS" Sources/main.swift -o "$TMP/$NAME-$arch"
    done
    lipo -create "$TMP/$NAME-arm64" "$TMP/$NAME-x86_64" -output "$BIN"
else
    swiftc -O -target "$(uname -m)-apple-macos$MIN_OS" Sources/main.swift -o "$BIN"
fi

echo "Signing (ad-hoc)…"
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify "$APP"

# สำเนาไว้ในโฟลเดอร์โปรเจกต์ด้วย (การติดตั้ง/แจกจ่ายใช้ตัวที่เซ็นในโฟลเดอร์ชั่วคราว)
rm -rf "./$NAME.app"
ditto "$APP" "./$NAME.app"

case "$MODE" in
--install)
    pkill -x "$NAME" 2>/dev/null || true
    rm -rf "/Applications/$NAME.app"
    ditto "$APP" "/Applications/$NAME.app"
    echo "Installed to /Applications/$NAME.app"
    open "/Applications/$NAME.app"
    ;;
--dist)
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
    DMG="dist/$NAME-$VERSION.dmg"
    STAGE="$TMP/stage"
    mkdir -p "$STAGE" dist
    ditto "$APP" "$STAGE/$NAME.app"
    ln -s /Applications "$STAGE/Applications"
    cp INSTALL.txt "$STAGE/READ ME FIRST.txt"
    rm -f "$DMG"
    if diskutil image create from --help >/dev/null 2>&1; then   # macOS 27+ (hdiutil deprecated)
        diskutil image create from --format UDZO --volumeName "$NAME $VERSION" "$STAGE" "$DMG" >/dev/null
    else
        hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
    fi
    echo "Created $DMG"
    lipo -archs "$BIN" | sed 's/^/Architectures: /'
    ;;
*)
    echo "Built ./$NAME.app  (รัน: open $NAME.app  หรือ ./build.sh --install)"
    ;;
esac
