#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
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

if [[ ! -d "$SDK_PATH" ]]; then
  echo "Missing macOS 26.5 SDK: $SDK_PATH" >&2
  exit 1
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
CLANG_MODULE_CACHE_PATH=/private/tmp/spanish-learning-clang-cache \
  swiftc -sdk "$SDK_PATH" \
  -module-cache-path /private/tmp/spanish-learning-swift-cache \
  -parse-as-library \
  "$PROJECT_ROOT"/Sources/SpanishLearningMac/*.swift \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Speech \
  -o "$BIN_PATH"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
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
  <key>CFBundleShortVersionString</key><string>0.6.0</string>
  <key>CFBundleVersion</key><string>1</string>
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
xattr -cr "$APP_PATH"
codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict --verbose=1 "$APP_PATH"

ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
echo "Verified native app archive: $ARCHIVE_PATH"
