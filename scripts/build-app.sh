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
OUTPUT_ROOT="$PROJECT_ROOT/dist-ui-lab"
APP_DISPLAY_NAME="西语喵 UI实验版"
ARCHIVE_PATH="$OUTPUT_ROOT/$APP_DISPLAY_NAME.zip"
BUILD_ROOT="$(mktemp -d /private/tmp/spanish-learning-build.XXXXXX)"
APP_PATH="$BUILD_ROOT/$APP_DISPLAY_NAME.app"
FINAL_APP_PATH="$OUTPUT_ROOT/$APP_DISPLAY_NAME.app"
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
  <key>CFBundleDisplayName</key><string>${APP_DISPLAY_NAME}</string>
  <key>CFBundleExecutable</key><string>SpanishLearningMac</string>
  <key>CFBundleIdentifier</key><string>com.kda.spanishlearningmac.uilab</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_DISPLAY_NAME}</string>
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

mkdir -p "$OUTPUT_ROOT"
rm -rf "$FINAL_APP_PATH" "$ARCHIVE_PATH"
ditto "$APP_PATH" "$FINAL_APP_PATH"
xattr -cr "$FINAL_APP_PATH"
codesign --force --sign "$SIGN_IDENTITY" "$FINAL_APP_PATH"
for bundle in "$FINAL_APP_PATH" "$FINAL_APP_PATH/Contents/Resources/SpanishLearningMac_SpanishLearningMac.bundle"; do
  xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
done
plutil -lint "$FINAL_APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict --verbose=1 "$FINAL_APP_PATH"
ditto -c -k --keepParent "$FINAL_APP_PATH" "$ARCHIVE_PATH"
echo "Verified UI Lab app: $FINAL_APP_PATH"
echo "Verified UI Lab app archive: $ARCHIVE_PATH"
