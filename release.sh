#!/bin/zsh
# Signs Tagwright.app with Developer ID, notarizes, staples and zips it into build/.
#   ./release.sh 0.5.0
# Notarization credentials: App Store Connect API key from ~/.appstoreconnect/config.json {keyID, issuerID, keyPath},
# else the notarytool keychain profile NOTARY_PROFILE (default Tagwright).
set -e
cd "${0:A:h}"
VERSION=${1:?usage: release.sh <version>}
CFG=~/.appstoreconnect/config.json
if [ -f $CFG ]; then
  AUTH=(--key "$(python3 -c "import json,os;print(os.path.expanduser(json.load(open('$CFG'))['keyPath']))")" \
        --key-id "$(python3 -c "import json;print(json.load(open('$CFG'))['keyID'])")" \
        --issuer "$(python3 -c "import json;print(json.load(open('$CFG'))['issuerID'])")")
else
  AUTH=(--keychain-profile ${NOTARY_PROFILE:-Tagwright})
fi
ID=${SIGN_ID:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | awk 'NR==1{print $2}')}
[ -n "$ID" ] || { echo "No Developer ID Application identity found"; exit 1 }

VERSION=$VERSION SIGN_ID=$ID CODESIGN_FLAGS="--options runtime --timestamp" ./build-app.sh
APP=build/Tagwright.app
codesign --verify --strict --verbose=2 $APP
ZIP=build/Tagwright-$VERSION.zip
rm -f $ZIP
ditto -c -k --keepParent $APP $ZIP
xcrun notarytool submit $ZIP $AUTH --wait
xcrun stapler staple $APP
rm -f $ZIP
ditto -c -k --keepParent $APP $ZIP   # again, with the stapled ticket
spctl --assess --type execute --verbose=2 $APP
echo "Release artifact: $PWD/$ZIP"
