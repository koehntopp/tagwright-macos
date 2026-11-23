#!/bin/zsh
# Builds Tagwright.app (release) into ./build.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")"
swift build -c release
APP=build/Tagwright.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Tagwright $APP/Contents/MacOS/
cp Resources/AppIcon.icns Resources/unidecode.bin $APP/Contents/Resources/   # from the web app's static/icon.svg (scripts/make-icon.swift)
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Tagwright</string>
<key>CFBundleIdentifier</key><string>com.koehntopp.tagwright</string>
<key>CFBundleExecutable</key><string>Tagwright</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>${VERSION:-0.1}</string>
<key>CFBundleShortVersionString</key><string>${VERSION:-0.1}</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
# A stable identity keeps the Keychain "Always Allow" valid across rebuilds; ad-hoc signing changes it every build.
# release.sh passes SIGN_ID (Developer ID) and CODESIGN_FLAGS (hardened runtime, timestamp).
ID=${SIGN_ID:-$(security find-identity -v -p codesigning | grep "Apple Development" | grep -v REVOKED | head -1 | awk '{print $2}')}
codesign --force ${=CODESIGN_FLAGS} --sign "${ID:--}" $APP
echo $APP
