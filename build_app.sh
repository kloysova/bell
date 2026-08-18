#!/bin/zsh
# チャイム.app をこのフォルダに作り直す。Xcode（swiftc）が要る。
set -e
cd "$(dirname "$0")"

APP="チャイム.app"
BUILD="build"
TARGET="$(uname -m)-apple-macos14.0"

# ./build_app.sh --test で、画面を出さずに動作確認だけする
if [[ "$1" == "--test" ]]; then
  mkdir -p "$BUILD"
  swiftc -target "$TARGET" -o "$BUILD/selftest" app/Chime.swift app/selftest/main.swift
  set +e
  "$BUILD/selftest"
  rc=$?
  rm -rf "$BUILD"
  exit $rc
fi

rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

echo "本体をビルド中..."
swiftc -O -target "$TARGET" -o "$APP/Contents/MacOS/chime-app" app/Chime.swift app/main.swift

echo "アイコンを作成中..."
swiftc -O -target "$TARGET" -o "$BUILD/makeicon" app/makeicon.swift
"$BUILD/makeicon" "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>chime-app</string>
	<key>CFBundleIdentifier</key>
	<string>local.gakushu.chime</string>
	<key>CFBundleName</key>
	<string>チャイム</string>
	<key>CFBundleDisplayName</key>
	<string>チャイム</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || \
  echo "（署名なしでビルドした。動作に支障はない）"

rm -rf "$BUILD"
touch "$APP"
echo "できた: $(pwd)/$APP"
