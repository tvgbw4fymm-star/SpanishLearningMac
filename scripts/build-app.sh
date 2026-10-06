#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
source "$PROJECT_ROOT/scripts/app-version.sh"
# Use a stable local code-signing identity so the app's designated requirement
# (and therefore its Keychain ACL) stays the same across rebuilds. Ad-hoc
# signing ("codesign --sign -") derives the requirement from the binary's
# cdhash, which changes on every build and makes Keychain treat each rebuild
# as a different app, prompting for the system password every time.
SIGN_IDENTITY="SpanishLearningMac Local Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  SIGN_IDENTITY="-"
fi
ARCHIVE_PATH="$PROJECT_ROOT/dist/西语学习-开发预览.zip"
BUILD_ROOT="$(mktemp -d /private/tmp/spanish-learning-build.XXXXXX)"
APP_PATH="$BUILD_ROOT/西语学习-开发预览.app"
BIN_PATH="$APP_PATH/Contents/MacOS/SpanishLearningMac"
trap 'rm -rf "$BUILD_ROOT"' EXIT

swift build --package-path "$PROJECT_ROOT" --scratch-path "$BUILD_ROOT/build"
SOURCE_BIN_PATH="$BUILD_ROOT/build/debug/SpanishLearningMac"
RESOURCE_BUNDLE="$BUILD_ROOT/build/debug/SpanishLearningMac_SpanishLearningMac.bundle"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$SOURCE_BIN_PATH" "$BIN_PATH"
test -d "$RESOURCE_BUNDLE"
cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>西语学习</string>
  <key>CFBundleExecutable</key><string>SpanishLearningMac</string>
  <key>CFBundleIdentifier</key><string>com.kda.spanishlearningmac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>西语学习</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>${APP_BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSpeechRecognitionUsageDescription</key><string>用于在这台 Mac 上将导入的西语音频转成听写练习文字。</string>
</dict></plist>
PLIST

mkdir -p "$APP_PATH/Contents/Resources/Fonts"
cp "$PROJECT_ROOT/Sources/SpanishLearningMac/Resources/Fonts/LXGWWenKaiGBScreenR.ttf" "$APP_PATH/Contents/Resources/Fonts/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/LXGW-WenKai-Screen-OFL.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/swift-fsrs-LICENSE.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/swift-fsrs-NOTICE.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/argmax-oss-swift-LICENSE.txt" "$APP_PATH/Contents/Resources/"
xattr -cr "$APP_PATH"
codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict --verbose=1 "$APP_PATH"

ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
echo "Verified native app archive: $ARCHIVE_PATH"
