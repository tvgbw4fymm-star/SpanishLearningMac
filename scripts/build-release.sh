#!/bin/zsh
set -euo pipefail

# Official Release build + packaging for Desktop distribution.
# Produces:
#   ~/Desktop/西语学习.app
#   ~/Desktop/西语学习.zip
# Does not touch dist/, does not commit, does not touch user data.

PROJECT_ROOT="${0:A:h:h}"
APP_DISPLAY_NAME="西语学习"
BUNDLE_ID="com.kda.spanishlearningmac"
APP_VERSION="0.6.0"
DESKTOP="$HOME/Desktop"

# Use a stable local code-signing identity so the app's designated requirement
# (and therefore its Keychain ACL) stays the same across rebuilds. Ad-hoc
# signing ("codesign --sign -") derives the requirement from the binary's
# cdhash, which changes on every build and makes Keychain treat each rebuild
# as a different app, prompting for the system password every time.
SIGN_IDENTITY="SpanishLearningMac Local Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  SIGN_IDENTITY="-"
fi

BUILD_ROOT="$(mktemp -d /private/tmp/spanish-learning-release.XXXXXX)"
APP_PATH="$BUILD_ROOT/${APP_DISPLAY_NAME}.app"
trap 'rm -rf "$BUILD_ROOT"' EXIT

swift build --package-path "$PROJECT_ROOT" --scratch-path "$BUILD_ROOT/build" -c release

BIN_PATH="$BUILD_ROOT/build/release/SpanishLearningMac"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/SpanishLearningMac"

RESOURCE_BUNDLE="$BUILD_ROOT/build/release/SpanishLearningMac_SpanishLearningMac.bundle"
test -d "$RESOURCE_BUNDLE"
cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"

cp "$PROJECT_ROOT/Design/AppIcon/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>${APP_DISPLAY_NAME}</string>
  <key>CFBundleExecutable</key><string>SpanishLearningMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_DISPLAY_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSpeechRecognitionUsageDescription</key><string>用于在这台 Mac 上将导入的西语音频转成听写练习文字。</string>
</dict></plist>
PLIST

cp "$PROJECT_ROOT/ThirdPartyLicenses/LXGW-WenKai-Screen-OFL.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/swift-fsrs-LICENSE.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/swift-fsrs-NOTICE.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/argmax-oss-swift-LICENSE.txt" "$APP_PATH/Contents/Resources/"
cp "$PROJECT_ROOT/ThirdPartyLicenses/Flaticon-Stickers-ATTRIBUTION.md" "$APP_PATH/Contents/Resources/"

xattr -cr "$APP_PATH"
codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict --verbose=1 "$APP_PATH"
plutil -extract NSSpeechRecognitionUsageDescription raw -o - "$APP_PATH/Contents/Info.plist" >/dev/null

# Copy to Desktop with ditto (preserves code signature, avoids raw cp of
# extended attributes/resource forks that break codesign verification when
# operated on in place afterwards by Finder).
DESKTOP_APP="$DESKTOP/${APP_DISPLAY_NAME}.app"
rm -rf "$DESKTOP_APP"
ditto "$APP_PATH" "$DESKTOP_APP"
xattr -cr "$DESKTOP_APP"
codesign --verify --deep --strict "$DESKTOP_APP"

DESKTOP_ZIP="$DESKTOP/${APP_DISPLAY_NAME}.zip"
rm -f "$DESKTOP_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$DESKTOP_ZIP"

echo "已生成：$DESKTOP_APP"
echo "已生成：$DESKTOP_ZIP"
