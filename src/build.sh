#!/bin/zsh
# Builds Swap.app (universal) into ../build/. Does not install or launch it.
# Ad-hoc signed by default. SWAP_SIGN="<certificate name>" signs with a stable identity instead, so
# macOS keeps the Accessibility permission across rebuilds.
# Built in a temp folder because synced folders add Finder metadata that codesign rejects.
set -e
cd "$(dirname "$0")/.."
STAGE="$(mktemp -d)"
APP="$STAGE/Swap.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp src/Info.plist "$APP/Contents/Info.plist"
[ -f src/Swap.icns ] && cp src/Swap.icns "$APP/Contents/Resources/Swap.icns"
swiftc -O -swift-version 5 -target arm64-apple-macos13 src/*.swift -o "$STAGE/arm"
swiftc -O -swift-version 5 -target x86_64-apple-macos13 src/*.swift -o "$STAGE/x86"
lipo -create "$STAGE/arm" "$STAGE/x86" -output "$APP/Contents/MacOS/Swap"
rm "$STAGE/arm" "$STAGE/x86"
xattr -cr "$APP"; find "$APP" -name "._*" -delete
# Hardened runtime: nothing can inject code into Swap and borrow its Accessibility permission.
codesign --force --options runtime --entitlements src/Swap.entitlements --sign "${SWAP_SIGN:--}" --identifier com.davidmolina.swap "$APP"
codesign --verify --strict "$APP"
rm -rf build; mkdir -p build
ditto --norsrc --noextattr "$APP" build/Swap.app
rm -rf "$STAGE"
xattr -cr build/Swap.app   # synced folders can re-add Finder metadata
codesign --verify build/Swap.app   # not --strict: the folder may hold Finder metadata; installs are checked strictly
echo "built build/Swap.app"
