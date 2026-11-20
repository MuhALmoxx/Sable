#!/usr/bin/env bash
# Downloads the official MobileVLCKit binary (LGPL-2.1, VideoLAN) pinned by version + SHA-256 and
# unpacks MobileVLCKit.xcframework into Vendor/. Idempotent. Source URL/checksum are the ones
# published in the official CocoaPods spec for this version.
set -euo pipefail
VERSION="3.7.5"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.5-a213fd11-6de05adc.tar.xz"
SHA256="a76f7a6cfcde4209b56f943e6e18400659d8a7a93ff482f8b1d059468d11e6be"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor"
MARKER="$DEST/.mobilevlckit-${VERSION}"

if [ -f "$MARKER" ] && [ -d "$DEST/MobileVLCKit.xcframework" ]; then
  echo "MobileVLCKit ${VERSION} already present"
  exit 0
fi
mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading MobileVLCKit ${VERSION}..."
curl -fsSL --retry 3 -o "$TMP/vlckit.tar.xz" "$URL"
if command -v shasum >/dev/null 2>&1; then
  echo "$SHA256  $TMP/vlckit.tar.xz" | shasum -a 256 -c -
else
  echo "$SHA256  $TMP/vlckit.tar.xz" | sha256sum -c -
fi
tar -xJf "$TMP/vlckit.tar.xz" -C "$TMP"
rm -rf "$DEST/MobileVLCKit.xcframework"
mv "$TMP/MobileVLCKit-binary/MobileVLCKit.xcframework" "$DEST/"
cp "$TMP/MobileVLCKit-binary/COPYING.txt" "$DEST/MobileVLCKit-COPYING.txt"
touch "$MARKER"
echo "MobileVLCKit ${VERSION} ready in Vendor/"
