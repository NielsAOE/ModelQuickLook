#!/bin/zsh
# Builds an ad-hoc-signed Release app and zips it to dist/ModelQuickLook.zip.
# No Apple Developer account needed; see README.md for the Gatekeeper steps users must take.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate
rm -rf build/Release dist
xcodebuild -scheme ModelQuickLook -configuration Release -derivedDataPath build/Release \
  CODE_SIGN_IDENTITY="-" build | tail -3

APP=build/Release/Build/Products/Release/ModelQuickLook.app
codesign --verify --deep --strict "$APP"
mkdir -p dist
ditto -c -k --keepParent "$APP" dist/ModelQuickLook.zip
echo "Built dist/ModelQuickLook.zip"
