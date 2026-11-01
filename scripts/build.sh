#!/bin/bash
# quark-mount 一键构建：编译 Swift → 组装 .app → ad-hoc 签名 → dmg + zip
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
APP="夸克网盘.app"
DIST="dist"
SWIFT_FILES=(app/*.swift)

echo "==> 清理"
rm -rf "$DIST" "$APP" QuarkMount icon.iconset AppIcon.icns
mkdir -p "$DIST"

echo "==> 编译 Swift（-swift-version 5，规避 Swift 6 严格并发）"
xcrun swiftc -swift-version 5 -O -o QuarkMount "${SWIFT_FILES[@]}"

echo "==> 生成图标"
python3 scripts/make_icon.py
iconutil -c icns icon.iconset -o AppIcon.icns

echo "==> 组装 App Bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp QuarkMount "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"
cp app/Info.plist "$APP/Contents/"

echo "==> ad-hoc 签名（未买开发者证书时本机/分发可用；Gatekeeper 首次需右键打开）"
codesign --force --sign - "$APP"

echo "==> 打包 dmg + zip"
mkdir -p "$DIST/stage"
cp -R "$APP" "$DIST/stage/"
ln -s /Applications "$DIST/stage/Applications"
cp README.md "$DIST/stage/安装说明.md"
hdiutil create -volname "夸克网盘" -srcfolder "$DIST/stage" -ov -format UDZO \
    "$DIST/夸克网盘-$VERSION.dmg" >/dev/null
( cd "$DIST/stage" && zip -qr "../夸克网盘-$VERSION.zip" "$APP" 安装说明.md )
rm -rf "$DIST/stage" "$APP" QuarkMount icon.iconset AppIcon.icns

echo ""
echo "构建完成："
ls -lh "$DIST" | tail -n +2 | awk '{print "  ", $5, $9}'
