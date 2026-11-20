#!/usr/bin/env bash
# Verifies that an IPA is a real iPhone (device) build of Sable and writes a summary.
#
#   tools/ci/verify_ipa.sh <path/to/Sable.ipa> [--signed]
#
# Checks: Payload/Sable.app exists and is the only app; Info.plist present with
# DTPlatformName == iphoneos, CFBundleSupportedPlatforms == iPhoneOS and MinimumOSVersion >= 18.0;
# the main executable is an arm64 Mach-O executable built for the iOS (device) platform, with no
# simulator slices; MobileVLCKit.framework is embedded (arm64 dylib) and dynamically linked from
# the executable (@rpath); the bundled fonts are present; no UI-test fixtures or .xctest bundles
# leaked in. With --signed, also verifies the code signature and the embedded provisioning profile.
# Appends a Markdown table (size, SHA-256, …) to $GITHUB_STEP_SUMMARY when set. macOS only.
set -euo pipefail

IPA="${1:?usage: verify_ipa.sh <ipa> [--signed]}"
MODE="${2:-unsigned}"
FAILURES=0
fail() { echo "::error title=IPA verification::$*"; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok  $*"; }
plist_get() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }

[ -f "$IPA" ] || { echo "::error::IPA not found: $IPA"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"

echo "Verifying $(basename "$IPA") ($MODE)"
APP="$WORK/Payload/Sable.app"
if [ ! -d "$APP" ]; then
  echo "::error title=IPA verification::Payload/Sable.app is missing"
  exit 1
fi
ok "Payload/Sable.app present"
APP_COUNT=$(find "$WORK/Payload" -maxdepth 1 -name "*.app" | wc -l | tr -d ' ')
[ "$APP_COUNT" = "1" ] && ok "exactly one app in Payload" || fail "Payload contains $APP_COUNT apps"

PLIST="$APP/Info.plist"
if [ -f "$PLIST" ]; then ok "Info.plist present"; else fail "Info.plist missing"; fi
EXE_NAME="$(plist_get CFBundleExecutable "$PLIST")"
BUNDLE_ID="$(plist_get CFBundleIdentifier "$PLIST")"
VERSION="$(plist_get CFBundleShortVersionString "$PLIST")"
BUILD="$(plist_get CFBundleVersion "$PLIST")"
PLATFORM="$(plist_get DTPlatformName "$PLIST")"
SUPPORTED="$(plist_get CFBundleSupportedPlatforms.0 "$PLIST")"
MIN_OS="$(plist_get MinimumOSVersion "$PLIST")"
SDK="$(plist_get DTSDKName "$PLIST")"
[ "$PLATFORM" = "iphoneos" ] && ok "DTPlatformName = iphoneos" || fail "DTPlatformName is '$PLATFORM' (expected iphoneos)"
[ "$SUPPORTED" = "iPhoneOS" ] && ok "CFBundleSupportedPlatforms = iPhoneOS" || fail "CFBundleSupportedPlatforms[0] is '$SUPPORTED'"
MIN_MAJOR="${MIN_OS%%.*}"
if [ -n "$MIN_MAJOR" ] && [ "$MIN_MAJOR" -ge 18 ] 2>/dev/null; then ok "MinimumOSVersion = $MIN_OS"; else fail "MinimumOSVersion is '$MIN_OS'"; fi
[ -n "$EXE_NAME" ] || fail "CFBundleExecutable missing"

EXE="$APP/${EXE_NAME:-Sable}"
EXE_ARCHS="missing"
if [ -f "$EXE" ]; then
  FILE_OUT="$(file -b "$EXE")"
  EXE_ARCHS="$(lipo -archs "$EXE" 2>/dev/null || echo unknown)"
  echo "  file: $FILE_OUT"
  echo "  lipo: $(lipo -info "$EXE" 2>&1)"
  grep -q "Mach-O 64-bit executable arm64" <<< "$FILE_OUT" && ok "executable is an arm64 Mach-O executable" \
    || fail "executable is not an arm64 Mach-O executable: $FILE_OUT"
  case " $EXE_ARCHS " in *" arm64 "*) ok "lipo archs: $EXE_ARCHS" ;; *) fail "arm64 slice missing (archs: $EXE_ARCHS)" ;; esac
  case " $EXE_ARCHS " in *" x86_64 "*|*" i386 "*) fail "simulator architecture in executable ($EXE_ARCHS)" ;; esac
  BUILD_INFO="$(xcrun vtool -show-build "$EXE" 2>/dev/null || otool -l "$EXE" 2>/dev/null || true)"
  if grep -Eq "platform[[:space:]]+(IOSSIMULATOR|7)[[:space:]]*$" <<< "$BUILD_INFO"; then
    fail "executable was built for the iOS Simulator"
  elif grep -Eq "platform[[:space:]]+(IOS|2)[[:space:]]*$" <<< "$BUILD_INFO"; then
    ok "LC_BUILD_VERSION platform = iOS (device)"
  else
    fail "could not find an iOS LC_BUILD_VERSION platform in the executable"
  fi
  LINKED="$(otool -L "$EXE" 2>/dev/null || true)"
  if grep -q "@rpath/MobileVLCKit.framework/MobileVLCKit" <<< "$LINKED"; then
    ok "executable dynamically links @rpath/MobileVLCKit.framework"
  else
    fail "executable does not link MobileVLCKit.framework dynamically"
  fi
else
  fail "main executable '$EXE_NAME' missing"
fi

FW="$APP/Frameworks/MobileVLCKit.framework"
VLC_ARCHS="missing"
VLC_VERSION="?"
if [ -d "$FW" ]; then
  ok "Frameworks/MobileVLCKit.framework embedded"
  FW_EXE="$FW/$(plist_get CFBundleExecutable "$FW/Info.plist")"
  [ -f "$FW_EXE" ] || FW_EXE="$FW/MobileVLCKit"
  VLC_VERSION="$(plist_get CFBundleShortVersionString "$FW/Info.plist")"
  if [ -f "$FW_EXE" ]; then
    VLC_ARCHS="$(lipo -archs "$FW_EXE" 2>/dev/null || echo unknown)"
    case " $VLC_ARCHS " in *" arm64 "*) ok "MobileVLCKit archs: $VLC_ARCHS" ;; *) fail "MobileVLCKit has no arm64 slice ($VLC_ARCHS)" ;; esac
    case " $VLC_ARCHS " in *" x86_64 "*|*" i386 "*) fail "simulator slice embedded in MobileVLCKit ($VLC_ARCHS)" ;; esac
    grep -q "dynamically linked shared library" <<< "$(file -b "$FW_EXE")" && ok "MobileVLCKit is a dynamic library" \
      || fail "MobileVLCKit binary is not a dynamic library"
  else
    fail "MobileVLCKit binary missing"
  fi
else
  fail "Frameworks/MobileVLCKit.framework is not embedded"
fi

for font in IBMPlexSansArabic-Regular IBMPlexSansArabic-Medium PixelifySans-Regular Silkscreen-Regular; do
  if [ -n "$(find "$APP" -name "$font.ttf" -print)" ]; then ok "font $font.ttf bundled"; else fail "font $font.ttf missing"; fi
done

LEAKS="$(find "$APP" \( -iname "UITestFixtures" -o -iname "night-roof*" -o -iname "reference-translations*" -o -name "*.xctest" \) -print)"
if [ -n "$LEAKS" ]; then
  fail "test-only content leaked into the app: $(echo "$LEAKS" | sed "s|$APP/||" | tr '\n' ' ')"
else
  ok "no UI-test fixtures or test bundles"
fi

SIGNATURE="unsigned"
if [ "$MODE" = "--signed" ]; then
  if codesign --verify --deep --strict --verbose=2 "$APP" 2>&1; then
    ok "code signature valid"
  else
    fail "code signature invalid"
  fi
  [ -f "$APP/embedded.mobileprovision" ] && ok "embedded.mobileprovision present" || fail "embedded.mobileprovision missing"
  SIGNATURE="$( (codesign -dv "$APP" 2>&1 || true) | sed -n 's/^TeamIdentifier=//p')"
  SIGNATURE="signed (team ${SIGNATURE:-?})"
else
  if codesign -dv "$APP" >/dev/null 2>&1; then
    echo "  note: the app carries a signature although this is the unsigned build"
  else
    ok "unsigned (as expected; sign before installing)"
  fi
fi

SIZE_BYTES=$(stat -f%z "$IPA")
SIZE_MIB=$(awk "BEGIN { printf \"%.1f\", $SIZE_BYTES / 1048576 }")
SHA256=$(shasum -a 256 "$IPA" | awk '{print $1}')
echo "IPA: $(basename "$IPA")  size: $SIZE_BYTES bytes ($SIZE_MIB MiB)  sha256: $SHA256"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### $(basename "$IPA")"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| Size | $SIZE_MIB MiB ($SIZE_BYTES bytes) |"
    echo "| SHA-256 | \`$SHA256\` |"
    echo "| Commit | \`${GITHUB_SHA:-local}\` |"
    echo "| Bundle | \`$BUNDLE_ID\` $VERSION ($BUILD) |"
    echo "| Platform | $PLATFORM · $SUPPORTED · SDK $SDK · min iOS $MIN_OS |"
    echo "| Executable archs | $EXE_ARCHS |"
    echo "| MobileVLCKit | $VLC_VERSION · $VLC_ARCHS · dynamically linked |"
    echo "| Signature | $SIGNATURE |"
    echo "| Verification | $([ "$FAILURES" -eq 0 ] && echo "passed" || echo "**$FAILURES check(s) failed**") |"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "IPA verification failed ($FAILURES problem(s))"
  exit 1
fi
echo "IPA verification passed"
