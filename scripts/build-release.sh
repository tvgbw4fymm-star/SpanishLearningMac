#!/bin/zsh
set -euo pipefail

# Official Release build + packaging for Desktop distribution.
# Produces:
#   dist/西语喵.app
#   dist/西语喵.zip
# Does not commit or touch user data.

PROJECT_ROOT="${0:A:h:h}"
if [[ "$(git -C "$PROJECT_ROOT" branch --show-current)" == "ui-redesign-next" ]]; then
  echo "Refusing to build the production app from the UI Lab worktree." >&2
  exit 1
fi
APP_DISPLAY_NAME="西语喵"
BUNDLE_ID="com.kda.spanishlearningmac"
source "$PROJECT_ROOT/scripts/app-version.sh"
DIST="$PROJECT_ROOT/dist"
FINAL_APP_PATH="$DIST/${APP_DISPLAY_NAME}.app"
FINAL_ZIP_PATH="$DIST/${APP_DISPLAY_NAME}.zip"

if [[ -e "$FINAL_APP_PATH" || -e "$FINAL_ZIP_PATH" ]]; then
  echo "Refusing to overwrite an existing release artifact in $DIST." >&2
  exit 1
fi

# Use a stable local code-signing identity so the app's designated requirement
# (and therefore its Keychain ACL) stays the same across rebuilds. Ad-hoc
# signing ("codesign --sign -") derives the requirement from the binary's
# cdhash, which changes on every build and makes Keychain treat each rebuild
# as a different app, prompting for the system password every time.
SIGN_IDENTITY="SpanishLearningMac Local Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  SIGN_IDENTITY="-"
fi

BUILD_ROOT="$(mktemp -d /tmp/SpanishLearningMac-release.XXXXXX)"
APP_PATH="$BUILD_ROOT/${APP_DISPLAY_NAME}.app"
ZIP_VERIFY_ROOT="$(mktemp -d /tmp/SpanishLearningMac-zip-verify.XXXXXX)"
RELEASE_SUCCEEDED=false
release_cleanup() {
  rm -rf "$BUILD_ROOT"
  rm -rf "$ZIP_VERIFY_ROOT"
  if [[ "$RELEASE_SUCCEEDED" != true ]]; then
    rm -rf "$FINAL_APP_PATH" "$FINAL_ZIP_PATH"
  fi
}
trap release_cleanup EXIT

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
  <key>CFBundleVersion</key><string>${APP_BUILD}</string>
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
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -extract NSSpeechRecognitionUsageDescription raw -o - "$APP_PATH/Contents/Info.plist" >/dev/null
test -f "$APP_PATH/Contents/Resources/AppIcon.icns"

STAGED_ZIP_PATH="$BUILD_ROOT/${APP_DISPLAY_NAME}.zip"
python3 - "$STAGED_ZIP_PATH" "$APP_PATH" "$APP_DISPLAY_NAME" <<'PY'
import os
import stat
import sys
import time
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

archive_path, app_path_value, app_name = sys.argv[1:]
app_path = Path(app_path_value)
prefix = f"{app_name}.app/"
with ZipFile(archive_path, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
    archive.write(app_path, prefix)
    for path in sorted(app_path.rglob("*")):
        member = path.relative_to(app_path.parent).as_posix()
        if path.is_symlink():
            info = ZipInfo(member, date_time=tuple(time.localtime(path.lstat().st_mtime)[:6]))
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | stat.S_IMODE(path.lstat().st_mode)) << 16
            archive.writestr(info, os.readlink(path).encode("utf-8"))
        else:
            archive.write(path, member)

with ZipFile(archive_path) as archive:
    members = archive.namelist()
    if not members or any(not member.startswith(prefix) for member in members):
        raise SystemExit("Release zip must contain only the final .app bundle.")
    if archive.testzip() is not None:
        raise SystemExit("Release zip contains a corrupt entry.")
    required = {
        f"{prefix}Contents/Info.plist",
        f"{prefix}Contents/Resources/AppIcon.icns",
    }
    if not required.issubset(members):
        raise SystemExit("Release zip is missing the app Info.plist or icon.")
PY

mkdir -p "$DIST"
ditto "$APP_PATH" "$FINAL_APP_PATH"
plutil -lint "$FINAL_APP_PATH/Contents/Info.plist"

test "$(plutil -extract CFBundleDisplayName raw -o - "$FINAL_APP_PATH/Contents/Info.plist")" = "$APP_DISPLAY_NAME"
test "$(plutil -extract CFBundleName raw -o - "$FINAL_APP_PATH/Contents/Info.plist")" = "$APP_DISPLAY_NAME"
test "$(plutil -extract CFBundleIdentifier raw -o - "$FINAL_APP_PATH/Contents/Info.plist")" = "$BUNDLE_ID"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$FINAL_APP_PATH/Contents/Info.plist")" = "$APP_VERSION"
test "$(plutil -extract CFBundleVersion raw -o - "$FINAL_APP_PATH/Contents/Info.plist")" = "$APP_BUILD"
test -f "$FINAL_APP_PATH/Contents/Resources/AppIcon.icns"
ditto "$STAGED_ZIP_PATH" "$FINAL_ZIP_PATH"
python3 - "$FINAL_ZIP_PATH" "$APP_DISPLAY_NAME" <<'PY'
import sys
from zipfile import ZipFile

archive_path, app_name = sys.argv[1:]
prefix = f"{app_name}.app/"
with ZipFile(archive_path) as archive:
    members = archive.namelist()
    if not members or any(not member.startswith(prefix) for member in members):
        raise SystemExit("Final zip must contain only the final .app bundle.")
    if archive.testzip() is not None:
        raise SystemExit("Final zip contains a corrupt entry.")
PY

ditto -x -k "$FINAL_ZIP_PATH" "$ZIP_VERIFY_ROOT"
ZIP_APP_PATH="$ZIP_VERIFY_ROOT/${APP_DISPLAY_NAME}.app"
plutil -lint "$ZIP_APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$ZIP_APP_PATH"
test "$(plutil -extract CFBundleDisplayName raw -o - "$ZIP_APP_PATH/Contents/Info.plist")" = "$APP_DISPLAY_NAME"
test "$(plutil -extract CFBundleIdentifier raw -o - "$ZIP_APP_PATH/Contents/Info.plist")" = "$BUNDLE_ID"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$ZIP_APP_PATH/Contents/Info.plist")" = "$APP_VERSION"
test "$(plutil -extract CFBundleVersion raw -o - "$ZIP_APP_PATH/Contents/Info.plist")" = "$APP_BUILD"

RELEASE_SUCCEEDED=true
echo "已生成：$FINAL_APP_PATH"
echo "已生成：$FINAL_ZIP_PATH"
echo "Version: $APP_VERSION ($APP_BUILD)"
echo "Staging and ZIP-extracted App signatures verified; dist App is a convenience copy."
