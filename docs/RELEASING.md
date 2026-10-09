# Releasing Braid

## Cutting a release

```bash
tooling/scripts/release.sh 1.2.0
git push && git push origin v1.2.0
```

The script writes `1.2.0+<commit count>` into `apps/weft/pubspec.yaml`,
commits, and tags `v1.2.0`. The pushed tag triggers the
[Release workflow](../.github/workflows/release.yml), which:

1. verifies the tag matches the pubspec version (and fails the release if
   someone tags without bumping),
2. builds Android (APK + AAB), Linux (tar.gz), Windows (zip), macOS (zip,
   signed and notarized when secrets are configured) and iOS (IPA — signed
   with secrets, sideloadable-unsigned without),
3. publishes a GitHub release with **auto-generated release notes** from the
   commits since the previous tag, with all six artifacts attached.

The Play Store upload is a separate workflow, `deploy_internal.yml` — see
[Google Play](#google-play) below.

Run the workflow manually (workflow_dispatch) for a dry run: everything
builds, nothing is published.

`pubspec.yaml` stays the single source of truth for the version. The build
number after the `+` is the commit count, so Android's `versionCode` and
iOS's `CFBundleVersion` rise monotonically on their own.

## Signing secrets

All optional — every platform falls back to an unsigned/debug-signed build
so the pipeline works before any secret exists. Configure under
**Settings → Secrets and variables → Actions**.

### Android

Create a keystore once:

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA \
  -keysize 2048 -validity 10000 -alias upload
base64 -i upload-keystore.jks | pbcopy
```

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the keystore file, base64 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | e.g. `upload` |
| `ANDROID_KEY_PASSWORD` | key password (often same as store) |

Without these, release APKs are debug-signed (installable, not
Play-Store-uploadable).

### Google Play

`.github/workflows/deploy_internal.yml` uploads to the **internal test
track** and releases it there, the same way papervault does. It runs on every
push to `main` that changes the `version:` line of `apps/weft/pubspec.yaml` —
so `tooling/scripts/release.sh` triggers it — and on demand from the Actions
tab (workflow_dispatch), which ships whatever `main` is now without a bump.
It needs only the self-hosted Mac runner, not the tag or any other platform.

The app itself has to exist first — the Play API cannot create one, so
`com.bostrot.weft` is a one-time **Create app** in the Console. Then create a
service account under **Setup → API access**, grant it *Manage releases*
(plus *Manage store presence* if you also want to push listing changes), and
download its JSON key. Papervault's service account works too once it is
granted access to Braid.

| Secret | Value |
|---|---|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | the service-account key, as plain JSON |

That secret **and** the four Android signing secrets above are required: the
workflow fails on its first step when any is missing, rather than building a
debug-signed bundle Play would refuse.

The `versionCode` is the workflow's run number (`--build-number`), which rises
on every run, so manual runs never collide. Internal testing is the one track
Play accepts a build on before the store listing is complete, so this works
with `tooling/store/` still unuploaded.

**The first upload is different.** Until an app has been released on some
track, Play treats it as a *draft app* and its API rejects anything but a
draft release — `com.bostrot.weft` is in that state right now. For that one
run, set the repository variable `PLAY_RELEASE_STATUS` to `draft`
(**Settings → Secrets and variables → Actions → Variables**; it is set
today), promote the draft once in the Console, then delete the variable.
Afterwards the default, `completed`, releases straight to internal testers
with no manual step.

### macOS (signing + notarization)

Needs a paid Apple Developer account. Export your **Developer ID
Application** certificate + private key from Keychain Access as a `.p12`.

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_BASE64` | the `.p12`, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `APPLE_ID` | your Apple ID email |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password from appleid.apple.com |
| `APPLE_TEAM_ID` | 10-char team id |

Without these, the app is ad-hoc signed: it runs, but Gatekeeper makes the
user right-click → Open on first launch.

### iOS

Export an **Apple Distribution** certificate as `.p12`, and download the
matching provisioning profile for `com.bostrot.weft`.

| Secret | Value |
|---|---|
| `IOS_CERTIFICATE_BASE64` | the `.p12`, base64 |
| `IOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `IOS_PROVISIONING_PROFILE_BASE64` | the `.mobileprovision`, base64 |

Without these, the workflow produces an **unsigned** IPA for sideloading
(AltStore, Sideloadly, TrollStore — the user signs it themselves).

### Windows / Linux

Ship unsigned. Windows SmartScreen will warn until the binary earns
reputation or you add an Authenticode certificate — if you get one later,
extend the `windows` job with `signtool`.
