# Releasing Sennit

## Cutting a release

```bash
$EDITOR docs/release-notes/1.2.0.md      # the release notes; see below
git commit -am "Write the 1.2.0 release notes"
tooling/scripts/release.sh 1.2.0
git push && git push origin v1.2.0
```

The script writes `1.2.0+<commit count>` into `apps/weft/pubspec.yaml`,
commits, and tags `v1.2.0`. The version bump reaching `main` — or the pushed
tag, whichever comes first — triggers the
[Release workflow](../.github/workflows/release.yml), which:

1. verifies a pushed tag matches the pubspec version (and fails the release if
   someone tags without bumping), and skips everything when `v1.2.0` is
   already released, so the second of the two pushes builds nothing,
2. builds Android (APK + AAB), Linux (tar.gz), Windows (zip), macOS (zip,
   Apple silicon, signed and notarized when secrets are configured) and iOS (IPA — signed
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
| `release.yml` (version bump on `main`, or tag `v*`) | the release body (`--github`); the app asset, into every platform build |
| `deploy_internal.yml` (version bump on `main`) | Play's `whatsnew-en-US`, cut to 500 characters at a whole line; the app asset |
| `deploy_testflight.yml` (version bump on `main`) | the app asset; after the upload, "What to Test" and "What's New" through `tooling/store/build_notes.py` |
| `promote_to_stores.yml` (nightly, 03:00 Berlin) | nothing new: Play open testing gets the internal release's "What's new"; the App Store version gets "What's New" from the script, run on the build's commit |

The app asset is `apps/weft/assets/release_notes.json`. The committed copy is
empty, so a local build or a fork shows no sheet; CI overwrites it before
building and never commits it. The app reads it from the bundle and makes no
request for it.

Pushing `main` and pushing the tag can happen in either order, and forgetting
the tag costs nothing: the stores and the GitHub release both start from the
`main` push, and both take their notes from the same file in the same commit.
A release that never made it to the release page is published by hand with
`gh workflow run release.yml --ref main -f publish=true`. `deploy_prebuilt.yml` uploads a
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
Application** certificate + private key from Keychain Access as a `.p12` —
the same one WSL Manager signs with (its `MACOS_SIGNING_CERT_P12`).

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_BASE64` | the `.p12`, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |

Notarization reuses the App Store Connect API key from the TestFlight section
below (`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`APP_STORE_CONNECT_KEY_P8_BASE64`); no Apple ID or app-specific password.
The app is signed with `macos/Runner/Release.entitlements`, so the release
runs in the same sandbox as a debug build.

Without the certificate, the app is ad-hoc signed: it runs, but Gatekeeper
makes the user right-click → Open on first launch, and the Homebrew cask in
`bostrot/homebrew-tap` is not bumped to it.

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
(`gh workflow run deploy_testflight.yml -f app_store=true`). It signs
manually, with one Apple Distribution certificate kept as a secret and an
App Store profile per target that it fetches from the portal by name; both
come from `ios_signing.yml`, and nothing in a TestFlight run creates or
revokes a certificate. The certificate lasts a year: runs warn 30 days ahead,
and `tooling/store/renew_ios_signing.sh` renews it — see "Renewal" in
[[adr-002-ios-signing-handoff]].

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
| `IOS_DISTRIBUTION_P12_BASE64` | the Distribution certificate and key, set by `renew_ios_signing.sh` |
| `IOS_DISTRIBUTION_P12_PASSWORD` | its random password, set by the same |

The build number is the commit count, the same number the Play upload uses.

It runs on a GitHub-hosted `macos-26` runner, which carries Xcode,
CocoaPods and rustup; the job imports the stored certificate into a keychain
of its own. A manual run with **dry_run** ticked archives and
exports a signed IPA without uploading it. Every workflow here runs on
GitHub-hosted runners — free for a public repository — and none needs a
self-hosted one.

App Store Connect only accepts builds made with a current SDK: the iOS 26
SDK (Xcode 26) since 2026-11-19, and the iOS 27 SDK (Xcode 27) from April
2027. The workflow selects the newest installed Xcode 26 and fails before
archiving without one. Before April 2027, move that step, and its check in
`testflight_workflow_test.dart`, to Xcode 27 once the runner image has it as a
release rather than a preview.

#### Export compliance, per build

Every uploaded build waits in TestFlight as "Missing Compliance" until its
encryption questions are answered: open the build, choose **Provide Export
Compliance Documentation**, and answer:

1. *Which type of encryption algorithms does your app use?* **Standard
   encryption algorithms instead of, or in addition to, using or accessing the
   encryption within Apple's operating system.** End-to-end encryption runs
   in the app, in vodozemac (Olm and Megolm: AES-256, Curve25519, Ed25519,
   HMAC-SHA256), not only through iOS. These are standard, published
   algorithms; nothing is proprietary.
2. *Will your app be available for distribution in France?* **No.** France
   requires an encryption declaration for such apps, so Sennit is not offered
   there: in App Store Connect, Pricing and Availability lists France (and
   mainland China) as not available. Keep it that way, or the answer above
   becomes wrong.

Save; the build turns "Ready to Test" for the internal group.

`ITSAppUsesNonExemptEncryption` is deliberately not in `Info.plist`. Setting it
to false would skip these questions by declaring that the app uses no
encryption beyond what is exempt, which is not the answer above.

### Going public, every night

`promote_to_stores.yml` runs at 03:00 Berlin time and takes the newest build
testers have to the public: Play's internal-track release to the **open
testing** track, and the newest eligible TestFlight build to **App Review**,
released automatically once approved. A build goes only when it is newer than
what the store has, reached testers within the last 26 hours, and CI and its
deploy passed on its commit. Apple reviews one version at a time, so a build
that finds another in review waits for the next night. The rules, and why:
[[adr-005-daily-store-promotion]].

It is **off** until the repository variable `STORE_PROMOTION_ENABLED` is
`true`. Until then the schedule does nothing, and a manual run is a dry run
that prints what it would promote and, with **audit**, what each store still
wants:

```bash
gh workflow run promote_to_stores.yml                     # dry run + audit
gh variable set STORE_PROMOTION_ENABLED --body true       # on
gh workflow run promote_to_stores.yml -f dry_run=false -f max_age_hours=0   # promote now
gh variable delete STORE_PROMOTION_ENABLED                # off
```

With the switch on, `deploy_testflight.yml` uploads builds that may go to
the App Store rather than internal-only ones; they still reach only the
internal tester group until a promotion submits them. Optional variables:
`PLAY_PROMOTION_TRACK=production` to promote to Play production instead of
open testing, `PLAY_PRODUCTION_ROLLOUT` (for example `0.2`) for a staged
rollout, `PLAY_CHANGES_NOT_SENT_FOR_REVIEW=true` when Play asks for it.

Export compliance is copied from the newest build a person answered (see
above), so answer one build by hand first and keep the answer the same.

### Windows / Linux

Ship unsigned. Windows SmartScreen will warn until the binary earns
reputation or you add an Authenticode certificate — if you get one later,
extend the `windows` job with `signtool`.
