---
type: decision
title: 'ADR-002: iOS signing handoff'
created: 2026-08-18
status: accepted
tags:
  - ios
  - signing
  - entitlements
  - share
  - extension
related:
  - '[[Share-Surfaces]]'
  - '[[Notifications]]'
  - '[[E2E-Matrix]]'
---

# ADR-002: iOS signing handoff

**Status:** accepted · **Date:** 2026-08-18 · **Phase:** 04

> This document is **append-only across phases**. Later phases add rows to
> [Targets and bundle ids](#targets-and-bundle-ids) and sections under
> [Added by later phases](#added-by-later-phases) — VoIP APNs (Phase 07), the
> Patrol UI-test target (Phase 09), WidgetKit and watchOS (Phase 10). Do not
> rewrite what is already here; a profile someone has already generated does not
> stop being generated.

## Context

Phase 04 registered two app extensions in `apps/weft/ios/Runner.xcodeproj` — a
Share Extension and the notification service extension Phase 03 had authored but
left out of the project. Registering them was an ordinary text edit;
`project.pbxproj` is an OpenStep plist and `xcodebuild` reads hand-written object
ids without renumbering them. Both targets build:

```sh
cd apps/weft/ios
xcodebuild -project Runner.xcodeproj -target ShareExtension \
  -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO
xcodebuild -project Runner.xcodeproj -target NotificationService \
  -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO
# ** BUILD SUCCEEDED ** for both, no source warnings
```

**Registration and signing are separable, and only signing was ever missing.**
`Runner` has been a registered *unsigned* target in this repository since it was
created: `DEVELOPMENT_TEAM` is unset in all three configurations and no
provisioning profile is checked in. The two extensions are registered on
identical terms. Nothing in this repository can produce a signed build, because
doing so requires an Apple Developer account, which is yours and not the
repository's.

What Phase 04 *added* to that pre-existing state is one thing that did not exist
before: an **App Group**. The Share Extension is a separate process, and the only
reason it can hand a captured share to the app is that both are entitled to
`group.com.bostrot.weft`. Without the group each process gets its own private
container, the extension writes staged shares into a directory nothing will ever
read, and the failure is silent — the share sheet works, the share disappears.
See [[Share-Surfaces]] for the contract itself.

An App Group is a capability that must exist **on the developer portal** before
any profile can carry it. That is the handoff.

## Decision

The repository commits the entitlements files, the bundle ids and the target
configuration. **You** provide the team, the portal registrations and the
profiles. This document is the exact list.

## Targets and bundle ids

| Target | Bundle id | Kind | Needs `group.com.bostrot.weft` | Entitlements file |
|---|---|---|---|---|
| `Runner` | `com.bostrot.weft` | Application | **Yes** | `ios/Runner/Runner.entitlements` |
| `ShareExtension` | `com.bostrot.weft.ShareExtension` | Share extension (`com.apple.share-services`) | **Yes** | `ios/ShareExtension/ShareExtension.entitlements` |
| `NotificationService` | `com.bostrot.weft.NotificationService` | Notification service extension (`com.apple.usernotifications.service`) | **No** | none, deliberately |
| `RunnerTests` | `com.bostrot.weft.RunnerTests` | Unit test bundle | No | none |
| `RunnerUITests` | `com.bostrot.weft.RunnerUITests` | UI test bundle (XCUITest), added Phase 09 | No | none |

Three App IDs and **two** profiles carrying the App Group, not three.
`NotificationService` has no entitlements file on purpose: it does not read the
Matrix store and does not need the container, and an unused entitlement is
another App ID capability to keep in sync for no behaviour. `RunnerTests` signs
against its host application and needs no profile of its own.

The App Group identifier is spelled in exactly three places, all of which must
match the portal and each other:

- `ios/Runner/Runner.entitlements`
- `ios/ShareExtension/ShareExtension.entitlements`
- `WeftShareContainer.appGroupIdentifier` in `ios/Shared/ShareContainer.swift`

## What you must do

### 1. Create the App Group on the developer portal

[developer.apple.com](https://developer.apple.com/account) →
**Certificates, Identifiers & Profiles** → **Identifiers** → **App Groups** →
**+**.

- Description: `Weft Share Container`
- Identifier: **`group.com.bostrot.weft`** — exactly this string, including the
  `group.` prefix, which Apple requires and which is part of the identifier
  rather than a namespace applied to it.

Do this first. The next two steps cannot reference a group that does not exist.

### 2. Register the three App IDs and enable the group on two of them

**Identifiers** → **App IDs** → **+** → *App*, once for each:

| Identifier | Capabilities to enable |
|---|---|
| `com.bostrot.weft` | **App Groups** → `group.com.bostrot.weft`; **Push Notifications** (see the note below) |
| `com.bostrot.weft.ShareExtension` | **App Groups** → `group.com.bostrot.weft` |
| `com.bostrot.weft.NotificationService` | nothing |

Register them in this order. An extension's App ID must be a prefixed child of
the app's, and the portal is happier when the parent already exists.

> [!NOTE]
> **Push Notifications on `com.bostrot.weft` is a Phase 03 requirement, not a
> Phase 04 one**, and it is listed here because it is the same trip to the same
> screen. Enabling it makes Xcode write an `aps-environment` key into
> `Runner/Runner.entitlements` — **beside** the App Group, not instead of it.
> That is expected and should be committed. `Runner.entitlements` did not exist
> before Phase 04, so it is now the file Xcode writes every capability into, and
> a diff that removes the `application-groups` array is a mistake rather than a
> cleanup. The file says so in a comment at the top.

### 3. Select a team in Xcode, for every target

```sh
open apps/weft/ios/Runner.xcworkspace
```

For **each** of `Runner`, `ShareExtension`, `NotificationService` and
`RunnerTests`: **Signing & Capabilities** → **Team** → your team.

Automatic signing is the right choice here and will generate the three
development profiles for you, provided steps 1 and 2 are done first. If it
offers to "fix" a missing capability, let it — but check the resulting diff to
`*.entitlements`, because "fix" occasionally means *remove the entitlement that
does not match a profile* rather than *add the capability to the profile*.

Xcode writes `DEVELOPMENT_TEAM` into `project.pbxproj` for every configuration it
touches. That is fine to commit; it is not a secret, and a repository without it
cannot build on a device.

### 4. Generate the distribution profiles

For anything beyond a local device build (TestFlight, the App Store), each of the
three App IDs needs its own distribution profile:

- `com.bostrot.weft` — *App Store* distribution, with App Groups and Push
- `com.bostrot.weft.ShareExtension` — *App Store* distribution, with App Groups
- `com.bostrot.weft.NotificationService` — *App Store* distribution

An appex is embedded in the app bundle and signed separately, so a missing
extension profile fails the **upload**, not the build — after the archive, which
is the slowest possible place to find out.

### 5. Check the version pair before uploading

An appex whose `CFBundleShortVersionString` / `CFBundleVersion` differ from the
host app's is rejected at upload. Both extension `Info.plist`s read
`$(FLUTTER_BUILD_NAME)` and `$(FLUTTER_BUILD_NUMBER)`, which reach them because
their xcconfigs `#include` `Flutter/Generated.xcconfig` — that include is the
only source of those two variables and is easy to lose while tidying an xcconfig.
Verify with:

```sh
plutil -p apps/weft/ios/build/Release-iphoneos/ShareExtension.appex/Info.plist \
  | grep -E 'CFBundleShortVersionString|CFBundleVersion'
# must match apps/weft/pubspec.yaml's `version:` (currently 0.1.0+1)
```

## What this unblocks, and how to tell

Until the App Group exists on the portal and both profiles carry it, iOS share-in
does not work — and it does not work *quietly*, which is the part worth knowing:

- `WeftShareContainer.containerURL(...)` returns `nil`.
- The Share Extension shows "Weft can't take this share" rather than crashing.
  Every accessor in `ShareContainer.swift` is optional for exactly this state,
  because an unhandled error in a share sheet takes down the **host** app's
  sheet, not ours.
- `writeShareTargets` returns `false`, `ShareShortcutService` reads the resulting
  zero as a refusal, and it retries on the next inbox tick — so a device that
  gets its entitlement at the next install starts working without a reinstall of
  its own.

After signing, the check is that a share from Photos raises Weft, and that
`share/staged/` in the group container has a blob in it.

## Outstanding: the iOS deployment target is your call

`flutter build ios --no-codesign` **fails before compiling anything**, in
`pod install`. Reproduced on 2026-08-18, verbatim:

```
[!] CocoaPods could not find compatible versions for pod "whisper_ggml":
  In Podfile:
    whisper_ggml (from `.symlinks/plugins/whisper_ggml/ios`)

Specs satisfying the `whisper_ggml (from `.symlinks/plugins/whisper_ggml/ios`)`
dependency were found, but they required a higher minimum deployment target.

Error: The plugin "whisper_ggml" requires a higher minimum iOS deployment
version than your application is targeting.
To build, increase your application's deployment target to at least 15.6 as
described at https://flutter.dev/to/ios-deploy
Error running pod install
```

`whisper_ggml-2.6.0/ios/whisper_ggml.podspec` declares
`s.ios.deployment_target = '15.6'`. The project has said
`IPHONEOS_DEPLOYMENT_TARGET = 13.0` since it was created, in all three
configurations, and no phase has changed it. There is no `Pods/` and no
`Podfile.lock` in the repository, so no iOS build has ever completed here.

**The fix was tested and it works.** Raising all three occurrences to `15.6`
makes `pod install` complete and resolve `whisper_ggml 1.0.1` along with the rest
of the pod graph. The change was then **reverted**, uncommitted, because raising
the floor drops iOS 13.0 through 15.5 and that is a product decision about who
can install Weft — not an edit a documentation task should make on your behalf.

If you want it, it is three lines plus one:

```sh
cd apps/weft/ios
sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 13.0;/IPHONEOS_DEPLOYMENT_TARGET = 15.6;/g' \
  Runner.xcodeproj/project.pbxproj
# and uncomment/set the platform line at the top of the Podfile:
#   platform :ios, '15.6'
```

The Podfile line is not cosmetic — without it CocoaPods prints
`Automatically assigning platform iOS with version 13.0 on target Runner because
no platform was specified` and infers the floor from the project, which is how
this error is worded the way it is.

Note what raising it does **not** cost: iOS 15 runs on every device iOS 13 ran
on. What it costs is users who have not updated.

The alternative is dropping `whisper_ggml`, which is
[[Attachment-Pipeline]]-adjacent work (`weft_transcribe`) and a larger decision
than this one.

### A second blocker, and it is this machine's rather than the repository's

With the deployment target raised, `pod install` succeeds and the build then
fails at destination resolution:

```
Uncategorized (Xcode): Unable to find a destination matching the provided
destination specifier: { generic:1, platform:iOS }

Ineligible destinations for the "Runner" scheme:
  { platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder,
    name:Any iOS Device,
    error:iOS 26.4 is not installed. Please download and install the platform
    from Xcode > Settings > Components. }
```

Xcode 26.4.1 (17E202) here has the **SDKs** (`xcodebuild -showsdks` lists
`iphoneos26.4` and `iphonesimulator26.4`) but not the iOS **platform
components**: `xcrun simctl list runtimes` is empty, and there is no device
support, so `flutter build ios` cannot resolve `generic/platform=iOS` in either
device or `--simulator` mode. Install them from **Xcode → Settings → Components**
before expecting any whole-app iOS build to complete on this machine.

The per-target `xcodebuild -sdk iphoneos` invocations at the top of this document
bypass destination resolution, which is why the two appexes could be proven to
compile despite all of the above.

## Added by later phases

Phase 10 still appends here — WidgetKit and watchOS. Phase 09 has appended: the
Patrol UI-test target is [below](#phase-09--the-patrol-ui-test-target-and-why-it-is-a-fourth-app-id).
Add a `### Phase NN — <capability>` section and a row to
[Targets and bundle ids](#targets-and-bundle-ids) rather than editing what is
above.

### Phase 07 — VoIP push, and why it is a second certificate

`ios/Runner/CallManager.swift` registers a `PKPushRegistry` for `.voIP` and the
`voip` background mode is declared in `Info.plist`. Neither of those makes a
push arrive. **A VoIP push is signed with its own credential, and it is not the
one Weft's message notifications already use.**

The distinction is not a formality:

| | Message notifications | VoIP pushes |
|---|---|---|
| Credential | The APNs auth key (`.p8`) `firebase_messaging` is configured with | A **VoIP Services certificate** (`.p12`), generated per app id |
| Topic | `com.bostrot.weft` | `com.bostrot.weft.voip` — the bundle id with `.voip` appended |
| Delivered to | `UNUserNotificationCenter` | `PKPushRegistry`, waking a suspended or terminated app |
| Gateway | Firebase | Sygnal, or whatever pusher the homeserver's account is registered against |

Three consequences for whoever holds the signing identity:

1. **Generate the VoIP Services certificate** at
   *Certificates, Identifiers & Profiles → Certificates → VoIP Services
   Certificate*, against the `com.bostrot.weft` app id. It is a certificate
   rather than a key: it expires annually and has to be renewed, unlike the
   `.p8`. An auth key **cannot** be substituted — APNs rejects a VoIP topic
   signed with one.
2. **Register it with the push gateway.** Matrix delivers pushes through a
   gateway (Sygnal for a self-hosted homeserver), and a VoIP push needs a
   *second* pusher on the account with its own `app_id` — conventionally
   `com.bostrot.weft.voip` — pointed at a gateway app configured with the
   `.p12`. Weft's own `Pusher` type (`packages/weft_matrix/lib/src/pusher.dart`)
   keys a pusher by `(appId, pushKey)`, so the VoIP pusher sits alongside the
   message one rather than replacing it.
3. **Until both exist, the token goes nowhere on purpose.**
   `CallPlatformBridge.voipTokens` publishes what PushKit hands over and nothing
   consumes it. That is deliberate: registering a pusher against a gateway that
   cannot sign for the topic produces a pusher the homeserver believes in and
   APNs rejects, which is worse than no pusher — the homeserver stops trying
   other routes. Wire it up in the same change that lands the certificate.

**What works without any of this.** Every call placed or received while Weft is
in the foreground, and every call on Android, where the wake-up is the existing
FCM path plus a `ConnectionService`. What is missing without the certificate is
precisely one thing: an incoming call ringing a phone whose screen is off and
whose Weft has been suspended.

`Info.plist` also gained `NSMicrophoneUsageDescription` in this phase. Its
absence is not a permission prompt that fails — it is a **termination** the first
time WebRTC opens a capture device, so a build that lost it would crash on the
first call rather than take a silent one.

#### Checklist, for whoever holds the signing identity

Nothing below is optional if an incoming call is to ring a phone whose screen is
off. All of it is on the same trip to the same portal as the rest of this
document.

- [ ] **VoIP Services certificate** (`.p12`) against `com.bostrot.weft`, at
      *Certificates, Identifiers & Profiles → Certificates → **VoIP Services
      Certificate***. Not the `.p8` auth key — APNs rejects a `.voip` topic
      signed with one — and it **expires annually**, unlike the key.
- [ ] **Background Modes → Voice over IP** is already declared in
      `Info.plist` (`UIBackgroundModes` gained `voip` in Phase 07); Xcode may
      also want it ticked under *Signing & Capabilities*. Both spellings are the
      same thing and neither is a portal capability.
- [ ] **A second pusher on the account**, `app_id` `com.bostrot.weft.voip`,
      pointed at a Sygnal app configured with the `.p12`. Weft's `Pusher` type
      keys on `(appId, pushKey)`, so it sits alongside the message pusher rather
      than replacing it.
- [ ] **Then, and only then, consume `CallPlatformBridge.voipTokens`** — one
      call site, currently absent on purpose. Wire it in the same change that
      lands the certificate.

Push Notifications on `com.bostrot.weft` (step 2 above) covers both credentials;
there is no separate App ID capability for VoIP. What is separate is the
certificate and the topic.

### Phase 07 — what was verified when the phase closed, 2026-08-19

Re-checked at the end of the phase rather than trusted from Phase 04, because
calling added Swift to `Runner` for the first time since:

- `flutter build ios --no-codesign` still **fails in `pod install`**, with the
  `whisper_ggml` 15.6 error quoted verbatim above. Unchanged, and unrelated to
  calling — it happens before a line of Swift is read.
- `ios/Runner/CallManager.swift` **type-checks against the iOS SDK**:

  ```sh
  xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios13.0 \
    -F "$(dirname "$(dirname "$(readlink -f "$(which flutter)")")")"/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64 \
    apps/weft/ios/Runner/CallManager.swift
  ```

  Exit 0, with one warning left in deliberately: `.allowBluetooth` is renamed
  `.allowBluetoothHFP` only in the newest SDK, so adopting the new spelling would
  make the file uncompilable on every earlier Xcode. This is also how it was
  found that `CXProviderConfiguration()` is iOS 14 and the deployment target is
  13 — `CXProviderConfiguration(localizedName:)` is used instead.

Both `flutter build macos` and `flutter build apk` succeed. So the one platform
without a whole-app build remains iOS, for the two reasons above this section,
neither of which is calling's.

### Phase 09 — the Patrol UI-test target, and why it is a fourth App ID

Phase 09 added a device end-to-end suite driven by [Patrol](https://patrol.leancode.co),
which needs an **XCUITest bundle** in `Runner.xcodeproj` the way `flutter test`
needs nothing at all. The target is authored, wired through the Podfile and
committed; it has **never been compiled**, because this machine has no iOS
simulator runtime and no signing identity. See
[the device matrix](../quality/e2e-matrix.md) for what it is for and
[Results](../quality/e2e-matrix.md#results) for the four iOS rows it gates.

What is in the repository:

| | |
|---|---|
| Target | `RunnerUITests`, a `com.apple.product-type.bundle.ui-testing` native target |
| Bundle id | `com.bostrot.weft.RunnerUITests` |
| Source | `ios/RunnerUITests/RunnerUITests.m` — `@import patrol;` and one macro expansion, which is the whole file |
| Host | `TEST_TARGET_NAME = Runner` |
| Deployment target | `IPHONEOS_DEPLOYMENT_TARGET = 13.0`, `TARGETED_DEVICE_FAMILY = "1,2"` — iPhone and iPad, because the matrix has tablet rows |
| Signing | `CODE_SIGN_STYLE = Automatic`, **no `DEVELOPMENT_TEAM`**, no entitlements file |
| Pods | `inherit! :complete` in the Podfile — not `:search_paths`, because unlike `RunnerTests` this target *links* patrol |
| App Group | **No.** It reads no Matrix store and shares no container. |

**Why this is a fourth App ID rather than a test bundle that rides along.** An
XCUITest bundle is not injected into the app the way a unit-test bundle is. At
run time Xcode builds and installs a *second application* —
`com.bostrot.weft.RunnerUITests.xctrunner`, generated from the bundle id above by
appending `.xctrunner` — which drives the app under test from outside its
process. That runner is an app, it installs on the device, and on a physical
device it must be signed like one. `RunnerTests` needs no profile because it
signs against its host; `RunnerUITests` cannot, because at the moment it runs it
*has* no host.

#### Checklist, for whoever holds the signing identity

Shorter than the Phase 07 one, and none of it is a distribution concern — this
bundle is never uploaded to App Store Connect and never shipped. It is a
development-signing job only.

- [ ] **Select the team on `RunnerUITests`** in Xcode, the same as
      [step 3](#3-select-a-team-in-xcode-for-every-target) does for the other
      four targets. Automatic signing will then create the App ID and the
      development profile for both `com.bostrot.weft.RunnerUITests` **and** the
      `.xctrunner` app it generates.
- [ ] **Register the test device** in *Devices* on the portal, if the rows are
      to run on a physical iPhone or iPad. Automatic signing does this from
      Xcode; a CI runner needs it done in advance.
- [ ] **Nothing on the App Group.** Do not add `group.com.bostrot.weft` to this
      App ID. An unused entitlement is one more capability to keep in sync for no
      behaviour, which is the same reason `NotificationService` has none.

**On a simulator this may all be unnecessary.** Simulator builds are not signed
against a profile — `CODE_SIGN_IDENTITY[sdk=iphoneos*]` is scoped to the device
SDK and does not apply — so `patrol test -d <simulator>` has a fair chance of
running with no team selected at all, which would make the four iOS matrix rows
a question of a *runtime* rather than of an identity. That is a reasoned
expectation and **not a verified one**: `xcrun simctl list runtimes` is empty on
the machine this was written on, so there was nothing to try it against. The
first person with a runtime settles it in one command. A physical device is not
in question — that needs the checklist above.

**Unverified for the same reason, and worth knowing before the first build:**
that `@import patrol;` resolves under `use_frameworks!` without
`use_modular_headers!`. Patrol's own iOS guide adds that directive; it is
deliberately omitted here, because `use_frameworks!` already builds every pod as
a module and turning it on would change how this project's whole verified pod
graph is built. If the first `pod install`-and-build says otherwise, that is the
line to add — and it is a Podfile change, not a signing one.

For the record, **macOS needed none of this.** Phase 09 also added a
`RunnerUITests` target to `macos/Runner.xcodeproj` with the same bundle id, and
it builds and signs *Sign to Run Locally* with no identity at all. macOS's
blocker is an interactive Accessibility grant instead, which is
[recorded with the matrix](../quality/e2e-matrix.md#results) rather than here —
it is not a signing question and this document does not own it.
