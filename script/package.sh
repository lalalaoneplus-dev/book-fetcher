#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP="$DIST_DIR/Book Fetcher.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
MACOS="$CONTENTS/MacOS"
STAGING="$DIST_DIR/dmg-stage"
BUILD_ROOT="${TMPDIR:-/private/tmp}/book-fetcher-package-build"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/macOS-Info.plist")"
DMG="$DIST_DIR/BookFetcher-$VERSION.dmg"
HYBRID="$DIST_DIR/BookFetcher-$VERSION-hybrid.dmg"
SIGNING_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
trap 'rm -rf "$STAGING"; rm -f "$HYBRID"' EXIT

mkdir -p "$DIST_DIR" "$ROOT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
swiftpm_options=(--disable-sandbox --cache-path "$ROOT_DIR/.build/swiftpm-cache" --config-path "$ROOT_DIR/.build/swiftpm-config" --security-path "$ROOT_DIR/.build/swiftpm-security")

for arch in arm64 x86_64; do
  scratch="$BUILD_ROOT/$arch"
  # Keep build-machine paths out of the shipped binaries.
  swiftpm_options+=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=." -Xswiftc -file-prefix-map -Xswiftc "$scratch=build")
  swift build "${swiftpm_options[@]}" --configuration release --triple "$arch-apple-macosx14.0" --scratch-path "$scratch" --product BookFetcher
  swift build "${swiftpm_options[@]}" --configuration release --triple "$arch-apple-macosx14.0" --scratch-path "$scratch" --product BookFetcherServer
done

rm -rf "$APP" "$STAGING"
mkdir -p "$MACOS" "$RESOURCES" "$STAGING"
lipo -create \
  "$BUILD_ROOT/arm64/arm64-apple-macosx/release/BookFetcher" \
  "$BUILD_ROOT/x86_64/x86_64-apple-macosx/release/BookFetcher" \
  -output "$MACOS/BookFetcher"
lipo -create \
  "$BUILD_ROOT/arm64/arm64-apple-macosx/release/BookFetcherServer" \
  "$BUILD_ROOT/x86_64/x86_64-apple-macosx/release/BookFetcherServer" \
  -output "$RESOURCES/BookFetcherServer"
strip -S -x "$MACOS/BookFetcher" "$RESOURCES/BookFetcherServer"
cp "$ROOT_DIR/Resources/macOS-Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
for resource in book-library.html start-intake.sh start-calibre-lan.sh intake-launch-agent.plist calibre-launch-agent.plist; do
  cp "$ROOT_DIR/Resources/$resource" "$RESOURCES/$resource"
done
chmod 755 "$MACOS/BookFetcher" "$RESOURCES/BookFetcherServer"

codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$RESOURCES/BookFetcherServer"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"

ditto "$APP" "$STAGING/Book Fetcher.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG" "$HYBRID"
hdiutil makehybrid -hfs -hfs-volume-name "Book Fetcher" -o "$HYBRID" "$STAGING"
hdiutil convert "$HYBRID" -format UDZO -o "$DMG"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
  result="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  printf '%s\n' "$result"
  status="$(printf '%s' "$result" | /usr/bin/plutil -extract status raw -o - -)"
  if [[ "$status" != "Accepted" ]]; then
    printf '%s\n' "Notarization failed: $status" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG"
fi

printf 'Created %s\n' "$DMG"
