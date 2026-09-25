#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
BUILD_ROOT="$(mktemp -d /private/tmp/spanish-learning-design.XXXXXX)"
APP_PATH="$BUILD_ROOT/西语学习-精读交互修复预览.app"
ARCHIVE_PATH="$PROJECT_ROOT/dist/西语学习-精读交互修复预览.zip"
INSTALLED_APP_PATH="$PROJECT_ROOT/dist/西语学习-精读交互修复预览.app"
trap 'rm -rf "$BUILD_ROOT"' EXIT

swift build --package-path "$PROJECT_ROOT" --scratch-path "$BUILD_ROOT/build" -c release
BIN_PATH="$BUILD_ROOT/build/release/SpanishLearningMac"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/SpanishLearningMac"
RESOURCE_BUNDLE="$BUILD_ROOT/build/release/SpanishLearningMac_SpanishLearningMac.bundle"
test -d "$RESOURCE_BUNDLE"
cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>西语学习 · 精读交互修复预览</string>
  <key>CFBundleExecutable</key><string>SpanishLearningMac</string>
  <key>CFBundleIdentifier</key><string>com.kda.spanishlearningmac.readinginteraction</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>西语学习</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.9.10</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSpeechRecognitionUsageDescription</key><string>用于在这台 Mac 上将导入的西语音频转成听写练习文字。</string>
</dict></plist>
PLIST
cp "$PROJECT_ROOT/ThirdPartyLicenses/LXGW-WenKai-Screen-OFL.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/swift-fsrs-LICENSE.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/swift-fsrs-NOTICE.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/Flaticon-Stickers-ATTRIBUTION.md" "$APP_PATH/Contents/Resources/"
xattr -cr "$APP_PATH"
codesign --force --sign - "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
rm -rf "$INSTALLED_APP_PATH"
ditto "$APP_PATH" "$INSTALLED_APP_PATH"
xattr -cr "$INSTALLED_APP_PATH"
# File Provider can restore Finder metadata on copied bundle directories.
for bundle in "$INSTALLED_APP_PATH" "$INSTALLED_APP_PATH/Contents/Resources/SpanishLearningMac_SpanishLearningMac.bundle"; do
  xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
done
codesign --force --sign - "$INSTALLED_APP_PATH"
codesign --verify --deep --strict "$INSTALLED_APP_PATH"
plutil -extract NSSpeechRecognitionUsageDescription raw -o - "$INSTALLED_APP_PATH/Contents/Info.plist" >/dev/null
print "已生成：$INSTALLED_APP_PATH"
print "已生成：$ARCHIVE_PATH"
