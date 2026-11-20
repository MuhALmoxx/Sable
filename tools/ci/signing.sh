#!/usr/bin/env bash
# Optional code signing for CI (macOS). Never prints secret values.
#
#   tools/ci/signing.sh import    decode the certificate + profile from env into a temporary keychain
#   tools/ci/signing.sh build     xcodebuild archive + -exportArchive -> dist/Sable-<sha>-<method>.ipa
#   tools/ci/signing.sh cleanup   delete the temporary keychain, profile copies and decoded files
#
# Inputs (environment, normally repository secrets):
#   IOS_CERTIFICATE_P12_BASE64       base64 of a .p12 holding the signing certificate + private key
#   IOS_CERTIFICATE_PASSWORD         its export password (may be empty)
#   IOS_PROVISIONING_PROFILE_BASE64  base64 of the .mobileprovision (development or ad-hoc)
#   IOS_TEAM_ID                      optional; defaults to the profile's TeamIdentifier
#   IOS_EXPORT_METHOD                optional: ad-hoc | development (also release-testing | debugging);
#                                    defaults to development when the profile allows get-task-allow,
#                                    otherwise ad-hoc
# The bundle identifier comes from the profile when it names an explicit App ID (so a fork can sign
# with its own App ID); a wildcard profile keeps com.murisixz.sable.
# State shared between the steps goes to $GITHUB_ENV (non-secret values only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sable-signing"
KEYCHAIN="$TMP_DIR/sable-signing.keychain-db"
DEFAULT_BUNDLE_ID="com.murisixz.sable"
PROFILE_DIRS=("$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles")

export_env() {
  if [ -n "${GITHUB_ENV:-}" ]; then echo "$1=$2" >> "$GITHUB_ENV"; fi
  export "$1=$2"
}

plist_get() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }

cmd_import() {
  : "${IOS_CERTIFICATE_P12_BASE64:?IOS_CERTIFICATE_P12_BASE64 is not set}"
  : "${IOS_PROVISIONING_PROFILE_BASE64:?IOS_PROVISIONING_PROFILE_BASE64 is not set}"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  chmod 700 "$TMP_DIR"

  printf '%s' "$IOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$TMP_DIR/cert.p12"
  printf '%s' "$IOS_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$TMP_DIR/profile.mobileprovision"

  local keychain_password
  keychain_password="$(openssl rand -hex 24)"
  echo "::add-mask::$keychain_password"
  security create-keychain -p "$keychain_password" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$keychain_password" "$KEYCHAIN"
  security import "$TMP_DIR/cert.p12" -k "$KEYCHAIN" -f pkcs12 -P "${IOS_CERTIFICATE_PASSWORD:-}" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$KEYCHAIN" >/dev/null
  # Put the temporary keychain first in the user search list (keep the existing ones).
  local existing
  existing="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN" $existing
  rm -f "$TMP_DIR/cert.p12"

  local identity
  identity="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/[0-9]+\)/ {print $2; exit}')"
  if [ -z "$identity" ]; then
    echo "::error title=Signing::the certificate in IOS_CERTIFICATE_P12_BASE64 holds no valid code-signing identity"
    exit 1
  fi

  security cms -D -i "$TMP_DIR/profile.mobileprovision" -o "$TMP_DIR/profile.plist" 2>/dev/null
  local uuid profile_team app_identifier get_task_allow expiration
  uuid="$(plist_get UUID "$TMP_DIR/profile.plist")"
  profile_team="$(plist_get TeamIdentifier.0 "$TMP_DIR/profile.plist")"
  app_identifier="$(plist_get Entitlements.application-identifier "$TMP_DIR/profile.plist")"
  get_task_allow="$(plist_get Entitlements.get-task-allow "$TMP_DIR/profile.plist")"
  expiration="$(plist_get ExpirationDate "$TMP_DIR/profile.plist")"
  if [ -z "$uuid" ]; then
    echo "::error title=Signing::IOS_PROVISIONING_PROFILE_BASE64 is not a readable provisioning profile"
    exit 1
  fi
  for dir in "${PROFILE_DIRS[@]}"; do
    mkdir -p "$dir"
    cp "$TMP_DIR/profile.mobileprovision" "$dir/$uuid.mobileprovision"
  done

  local team="${IOS_TEAM_ID:-$profile_team}"
  if [ -n "$profile_team" ] && [ "$team" != "$profile_team" ]; then
    echo "::warning title=Signing::IOS_TEAM_ID differs from the provisioning profile's team; using the profile's team"
    team="$profile_team"
  fi

  local bundle_id="$DEFAULT_BUNDLE_ID"
  local app_suffix="${app_identifier#*.}"
  if [ -n "$app_identifier" ] && [ "$app_suffix" != "*" ] && [[ "$app_suffix" != *"*"* ]]; then
    bundle_id="$app_suffix"
  elif [[ "$app_suffix" == *"*"* ]] && [ "$app_suffix" != "*" ]; then
    local prefix="${app_suffix%\*}"
    if [[ "$DEFAULT_BUNDLE_ID" != "$prefix"* ]]; then
      echo "::error title=Signing::the profile's wildcard App ID does not cover $DEFAULT_BUNDLE_ID"
      exit 1
    fi
  fi

  local method="${IOS_EXPORT_METHOD:-}"
  if [ -z "$method" ]; then
    if [ "$get_task_allow" = "true" ]; then method="development"; else method="ad-hoc"; fi
  fi
  case "$method" in
    ad-hoc|release-testing) method="release-testing"; label="adhoc" ;;
    development|debugging) method="debugging"; label="development" ;;
    *) echo "::error title=Signing::IOS_EXPORT_METHOD must be ad-hoc or development"; exit 1 ;;
  esac

  export_env SIGN_KEYCHAIN "$KEYCHAIN"
  export_env SIGN_IDENTITY "$identity"
  export_env SIGN_PROFILE_UUID "$uuid"
  export_env SIGN_TEAM_ID "$team"
  export_env SIGN_BUNDLE_ID "$bundle_id"
  export_env SIGN_EXPORT_METHOD "$method"
  export_env SIGN_LABEL "$label"
  echo "Signing assets imported: identity …${identity: -6}, profile $uuid (expires $expiration), bundle $bundle_id, export method $method"
}

cmd_build() {
  : "${SIGN_KEYCHAIN:?run 'signing.sh import' first}"
  local short_sha="${SHORT_SHA:-$(git -C "$ROOT" rev-parse --short=7 HEAD)}"
  local out="$ROOT/build/signed"
  rm -rf "$out"
  mkdir -p "$out" "$ROOT/dist"

  set -o pipefail
  xcodebuild -project "$ROOT/Sable.xcodeproj" -scheme Sable -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$out/Sable.xcarchive" -derivedDataPath "$ROOT/build/DDSign" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$SIGN_TEAM_ID" CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    SABLE_PROVISIONING_PROFILE="$SIGN_PROFILE_UUID" SABLE_BUNDLE_ID="$SIGN_BUNDLE_ID" \
    OTHER_CODE_SIGN_FLAGS="--keychain $SIGN_KEYCHAIN" \
    archive 2>&1 | tee "$ROOT/build/signed-archive.log" | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
  grep -q "ARCHIVE SUCCEEDED" "$ROOT/build/signed-archive.log"

  cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>${SIGN_EXPORT_METHOD}</string>
  <key>teamID</key><string>${SIGN_TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${SIGN_IDENTITY}</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${SIGN_BUNDLE_ID}</key><string>${SIGN_PROFILE_UUID}</string>
  </dict>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
PLIST
  plutil -lint "$out/ExportOptions.plist" >/dev/null

  xcodebuild -exportArchive -archivePath "$out/Sable.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" 2>&1 | tee "$ROOT/build/signed-export.log" \
    | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
  grep -q "EXPORT SUCCEEDED" "$ROOT/build/signed-export.log"

  local ipa
  ipa="$(find "$out/export" -maxdepth 1 -name "*.ipa" -print -quit)"
  [ -n "$ipa" ] || { echo "::error title=Signing::export produced no IPA"; exit 1; }
  local dest="$ROOT/dist/Sable-${short_sha}-${SIGN_LABEL}.ipa"
  mv "$ipa" "$dest"
  (cd "$ROOT/dist" && shasum -a 256 "$(basename "$dest")" > "$(basename "$dest").sha256")
  export_env SIGNED_IPA "$dest"
  echo "Signed IPA: $(basename "$dest")"
}

cmd_cleanup() {
  if [ -f "$KEYCHAIN" ]; then security delete-keychain "$KEYCHAIN" 2>/dev/null || true; fi
  if [ -f "$TMP_DIR/profile.plist" ]; then
    local uuid
    uuid="$(plist_get UUID "$TMP_DIR/profile.plist")"
    if [ -n "$uuid" ]; then
      for dir in "${PROFILE_DIRS[@]}"; do rm -f "$dir/$uuid.mobileprovision"; done
    fi
  fi
  rm -rf "$TMP_DIR"
  echo "Signing material removed"
}

case "${1:-}" in
  import) cmd_import ;;
  build) cmd_build ;;
  cleanup) cmd_cleanup ;;
  *) echo "usage: $0 import|build|cleanup" >&2; exit 2 ;;
esac
