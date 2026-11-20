# Signing and installing Sable

CI produces an **unsigned** IPA (`Sable-<sha>-unsigned.ipa`, published as `Sable-unsigned.ipa`),
because the repository has no signing secrets. iOS installs only signed apps, so the IPA has to be
signed before it can go on an iPhone: with your Apple ID through AltStore, SideStore or Sideloadly
(option 1), or with your own certificate and provisioning profile (option 2). There is no simulator
IPA. To run Sable in the simulator, build it from source (see the README).

The IPA has not yet been installed on a physical iPhone by the developers, so treat the steps below
as the documented procedure rather than a tested one.

Check the download first. The `.sha256` file next to every IPA (and the release notes) gives its
checksum:

```sh
shasum -a 256 Sable-unsigned.ipa
```

## Option 1: AltStore / SideStore / Sideloadly (free Apple ID)

These tools re-sign the IPA with a certificate tied to your Apple ID and install it:

- **AltStore** (<https://altstore.io>) or **SideStore** (<https://sidestore.io>): add the IPA from
  Files. With a free Apple ID the app expires after 7 days and must be refreshed, and you can have
  only 3 sideloaded apps at a time.
- **Sideloadly** (<https://sideloadly.io>), macOS/Windows: drag the IPA in, sign in with your Apple ID
  and install over USB or Wi-Fi.

These tools usually change the bundle identifier (`com.murisixz.sable`) to one your account can
use. This is expected. Sable stores its data per bundle identifier, so a re-signed copy with a
different identifier starts with an empty library.

iOS 16 and later also require **Developer Mode** for apps signed this way
(Settings › Privacy & Security › Developer Mode, then restart).

## Option 2: your own certificate and provisioning profile

You need an Apple Developer certificate (`Apple Development` or `Apple Distribution`) in your
keychain and a provisioning profile (development or ad hoc) that lists your device. Its App ID
must be `com.murisixz.sable`, a wildcard, or an identifier you set below.

```sh
mkdir sable && cd sable
unzip -q ../Sable-unsigned.ipa
APP=Payload/Sable.app
cp ~/Downloads/MyProfile.mobileprovision "$APP/embedded.mobileprovision"
security cms -D -i "$APP/embedded.mobileprovision" > profile.plist
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' profile.plist > entitlements.plist
# Only if your profile is for another App ID:
# /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.sable" "$APP/Info.plist"
IDENTITY="Apple Development: Your Name (TEAMID)"   # see: security find-identity -v -p codesigning
codesign --force --sign "$IDENTITY" "$APP/Frameworks/MobileVLCKit.framework"
codesign --force --sign "$IDENTITY" --entitlements entitlements.plist "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
zip -qry ../Sable-signed.ipa Payload
```

Install the result in either of these ways:

- **Xcode:** Window › Devices and Simulators, select the iPhone, click `+` under Installed Apps and
  choose `Payload/Sable.app` or the IPA.
- **Command line:** `xcrun devicectl device install app --device <device-id> Payload/Sable.app`.

Sign the embedded framework **before** the app. The app's signature covers the framework's
signature, so signing in the other order invalidates the app.

## Option 3: let CI sign it (repository secrets)

When these repository secrets exist, the `ios` job also archives a signed build
(`xcodebuild archive` + `-exportArchive`). It uploads the result as the workflow artifact
`Sable-signed-<development|adhoc>-ipa-<sha>`:

| Secret | Content |
|---|---|
| `IOS_CERTIFICATE_P12_BASE64` | `base64 -i Certificates.p12`: the certificate **and** its private key |
| `IOS_CERTIFICATE_PASSWORD` | the password you chose when exporting the `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | `base64 -i MyProfile.mobileprovision` |
| `IOS_TEAM_ID` | optional. Defaults to the profile's team |
| `IOS_EXPORT_METHOD` | optional: `development` or `ad-hoc`. Defaults to `development` when the profile allows debugging (`get-task-allow`), otherwise `ad-hoc` |

Set them with `gh secret set IOS_CERTIFICATE_P12_BASE64 < cert.b64` (etc.) or in the repository
settings. Notes:

- The workflow imports the certificate into a **temporary keychain** that has a random password.
  It deletes the keychain and the installed profile in an `always()` step. Secret values are
  passed only through environment variables and are never printed.
- If the profile names an explicit App ID (for example `TEAMID.com.example.sable`), CI signs the
  app with that bundle identifier. A fork can therefore use its own App ID without editing the
  project. A wildcard profile keeps `com.murisixz.sable`. This works through two build variables
  in `project.yml`, `SABLE_BUNDLE_ID` and `SABLE_PROVISIONING_PROFILE`, so Swift package targets
  are never given a provisioning profile.
- **The signed IPA is not published to the release page.** It contains your provisioning profile,
  which includes your team ID and the UDIDs of the devices it lists. On a public repository,
  workflow artifacts can be downloaded by any signed-in GitHub user, so use a private fork if that
  matters. The artifact is kept for 7 days.
- When the secrets are absent, the steps are skipped and the job summary says only the unsigned
  IPA was produced.

To sign locally the same way CI does, run `tools/ci/signing.sh` (`import`, `build`, `cleanup`) on
macOS with the same environment variables set.
