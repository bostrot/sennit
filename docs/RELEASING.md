# Releasing Sennit

## Cutting a release

```bash
$EDITOR docs/release-notes/1.2.0.md      # the release notes; see below
git commit -am "Write the 1.2.0 release notes"
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
3. publishes a GitHub release whose body is the [release notes](#release-notes),
   with all six artifacts attached.

The Play Store upload is a separate workflow, `deploy_internal.yml` — see
[Google Play](#google-play) below.

Run the workflow manually (workflow_dispatch) for a dry run: everything
builds, nothing is published.

`pubspec.yaml` stays the single source of truth for the version. The build
number after the `+` is the commit count, so Android's `versionCode` and
iOS's `CFBundleVersion` rise monotonically on their own.

## Release notes

One text per version reaches four places: the GitHub release body, Play's
"What's new" on the internal track, TestFlight's "What to Test" (and the App
Store "What's New" when that version is open for editing), and the sheet the
app shows once after it updates. All four come from
`tooling/scripts/release_notes.py <version>`, which reads:

1. `docs/release-notes/<version>.md` when it exists — write one for every
   release, for people who use the app, as a short Markdown list;
2. otherwise the first-parent history of `main` since the previous
   `Release x.y.z` commit: pull request titles, and the subjects of commits
   pushed directly. It works without tags and without pull requests, and it
   reads like a changelog for developers — the fallback, not the plan.

Each workflow runs the script on the commit it builds, so the text is the
same everywhere and no workflow waits for another:

| Workflow | Writes |
|---|---|
| `release.yml` (tag `v*`) | the release body (`--github`); the app asset, into every platform build |
| `deploy_internal.yml` (version bump on `main`) | Play's `whatsnew-en-US`, cut to 500 characters at a whole line; the app asset |
| `deploy_testflight.yml` (version bump on `main`) | the app asset; after the upload, "What to Test" and "What's New" through `tooling/store/build_notes.py` |

The app asset is `apps/weft/assets/release_notes.json`. The committed copy is
empty, so a local build or a fork shows no sheet; CI overwrites it before
building and never commits it. The app reads it from the bundle and makes no
request for it.

Pushing `main` and pushing the tag can happen in either order: the stores get
their notes from the `main` push, the GitHub release from the tag push, and
both from the same file in the same commit. `deploy_prebuilt.yml` uploads a
bundle built elsewhere and sets no notes.

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
It runs on a GitHub-hosted `ubuntu-latest` runner and needs no tag or any
other platform. A manual run with **dry_run** ticked builds and signs the
bundle without uploading it.

The app itself has to exist first — the Play API cannot create one, so
`com.bostrot.weft` is a one-time **Create app** in the Console. Then create a
service account under **Setup → API access**, grant it *Manage releases*
(plus *Manage store presence* if you also want to push listing changes), and
download its JSON key. Papervault's service account works too once it is
granted access to Sennit.

| Secret | Value |
|---|---|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | the service-account key, as plain JSON |

That secret **and** the four Android signing secrets above are required: the
workflow fails on its first step when any is missing, rather than building a
debug-signed bundle Play would refuse.

The `versionCode` is the number of commits on `main` (`--build-number`), which
rises with every commit, so a manual run of a newer `main` needs neither a
version bump nor a tag. Running it twice on the same commit is refused by
Play, as the same build uploaded twice should be. Internal testing is the one track
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

### iOS — TestFlight

`deploy_testflight.yml` archives `main` and uploads it to App Store Connect as
an internal-only TestFlight build, on the same trigger as the Play upload: a
version bump on `main`, or a manual run. An internal-only build cannot be
attached to an App Store version; for the build that goes to review, run the
workflow by hand with `app_store` ticked
(`gh workflow run deploy_testflight.yml -f app_store=true`). It signs with an **App Store Connect API key** rather than a
checked-in certificate and profiles: with the key, `xcodebuild` registers the
App IDs and creates the certificate and the profiles for all seven targets
itself.

Before the first run, once:

1. An app record for `com.bostrot.weft` in App Store Connect (My Apps → +).
2. The App Group `group.com.bostrot.weft` on the developer portal — see
   [[adr-002-ios-signing-handoff]].
3. A team API key with the **App Manager** role (Users and Access →
   Integrations → App Store Connect API).
4. An internal tester group in TestFlight; builds reach it once Apple has
   processed them.

| Secret | Value |
|---|---|
| `APP_STORE_CONNECT_KEY_ID` | the key's 10-character id |
| `APP_STORE_CONNECT_ISSUER_ID` | the issuer id shown above the key list |
| `APP_STORE_CONNECT_KEY_P8_BASE64` | the downloaded `AuthKey_….p8`, base64 |
| `APPLE_TEAM_ID` | 10-char team id |

The build number is the commit count, the same number the Play upload uses.

It runs on a GitHub-hosted `macos-15` runner, which carries Xcode,
CocoaPods and rustup; the job makes a keychain of its own for the signing
certificate Xcode creates. A manual run with **dry_run** ticked archives and
exports a signed IPA without uploading it. Every workflow here runs on
GitHub-hosted runners — free for a public repository — and none needs a
self-hosted one.

### Windows / Linux

Ship unsigned. Windows SmartScreen will warn until the binary earns
reputation or you add an Authenticode certificate — if you get one later,
extend the `windows` job with `signtool`.
