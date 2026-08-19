# Weft WidgetKit Extension

Phase 10's Apple surfaces: Home Screen widgets and a Lock Screen accessory, on
iOS and macOS, from **one** source directory and two targets. Registered in
`ios/Runner.xcodeproj` and `macos/Runner.xcodeproj` and built by
`flutter build ios` / `flutter build macos`; what it still needs from you is
signing material, and — on macOS — one entitlement that cannot exist without it.

| File | What it is |
| --- | --- |
| `WeftWidget.swift` | The `@main` `WidgetBundle`: the inbox widget, the Lock Screen accessory, and their views |
| `WeftWidgetProvider.swift` | The `TimelineProvider` — the only thing here that touches the App Group |
| `WeftWidgetState.swift` | The five states a widget can be in, and every sentence it can say |
| `WeftWidgetViews.swift` | Rows, badge, network dots, empty state |
| `WeftWidgetTokens.swift` | `weft_design`, duplicated for a process with no Flutter in it |
| `SnapshotPayload.swift` | The hand-written reader for `SnapshotCodec`'s JSON |
| `Info.plist` | `com.apple.widgetkit-extension`. **One file for both targets** |
| `WeftWidget.entitlements` | The App Group, `group.com.bostrot.weft` (iOS) |
| `WeftWidget-macOS.entitlements` | Sandbox, and a comment where the group will go |
| `WeftWidget-{Debug,Release}.xcconfig` | Optional CocoaPods include + the Flutter version pair (iOS) |
| `WeftWidget-macOS.xcconfig` | The Flutter version pair, and five settings that undo an inheritance (macOS) |
| `../Shared/SnapshotContainer.swift` | Container layout, compiled into this target *and* both Runners |
| `../Shared/ShareContainer.swift` | Where the App Group identifier is spelled, once |
| `../Runner/SnapshotChannel.swift` | The other side: the host app's writer, over `com.bostrot.weft/snapshot` |

## What it does, and the one thing it cannot

It reads one JSON file out of the App Group, decides which of five states it is
in, and draws. It never decrypts, never fetches, and never writes.

It cannot talk to Matrix. The session lives in the host app's keychain and its
sync loop in the host app's process, and a widget extension runs under a memory
ceiling well below what decrypting a room costs — tighter than the Share
Extension's, because the system wakes this process on its own schedule,
repeatedly, and an extension killed often enough stops being scheduled at all.
The user sees that as a blank rectangle they eventually delete.

The wire format is `SnapshotCodec` in `packages/weft_snapshot` — **hand-written
on this side**, with no compiler checking the key names against the Dart class.
Renaming a key there is a silent break here. `SnapshotPayload.swift` spells every
key once, at the top, for exactly that reason;
`android/…/widget/SnapshotPayload.kt` is the same file in Kotlin and the two are
meant to be read side by side.

## The five states

`InboxSnapshot`'s doc names three a surface must tell apart. The codec adds a
fourth by making staleness a fact. The fifth is one the Dart side cannot express.

| State | How it is reached | What it says |
| --- | --- | --- |
| `signedOut` | No payload. The writer *deletes* on logout | "Sign in to Weft" |
| `switchedOff` | `enabled` false, **or** `widgetsEnabled` false | "Widgets are off", and names the setting |
| `unavailable` | Older than `kSnapshotStaleAfter`, or undecodable | "Open Weft on your phone" |
| `ready`, no rows | Empty inbox, or every chat on an excluded network | "No conversations" |
| `ready`, rows | — | The rows |

The fifth is `widgetsEnabled` false with a perfectly good payload in the file:
**a watch-only user**. `SnapshotPolicy.enabled` is `widgets || watch`, so the
payload exists and this Home Screen must not draw it. The surface flag is read
*before* the rows are, and every read is fail-closed.

Stale and undecodable share one message deliberately: a twelve-hour-old snapshot
and a half-written one are the same fact to the person reading them.

## What is different from the Android widgets, and why

Everything below is a place the two platforms genuinely diverge, rather than two
answers to one question.

- **The stale flip is exact.** Glance can only re-read on a wake, so it discovers
  staleness up to an hour late. WidgetKit takes a *timeline*, and the moment the
  payload expires is known — `generatedAt + kSnapshotStaleAfter` — so
  `getTimeline` schedules a second entry at exactly it. The widget flips to "Open
  Weft on your phone" on the second, with the extension never woken.
- **Preview visibility is a `switch`, not a measurement.** Glance widgets are
  resized freely, so Android checks `LocalSize` against a width threshold.
  WidgetKit families are fixed slots. Same outcome: the narrow family drops the
  preview rather than showing three words and an ellipsis.
- **The palette is mostly the system's.** The Android copy restates a whole
  twenty-four-slot Material scheme, because below Android 12 there is nothing to
  defer to. iOS has semantic colours that are already right in light, dark,
  Increase Contrast and the tinted Home Screen. Only the accent — the unread
  badge — is Weft's indigo. See `WeftWidgetTokens`.
- **`privacySensitive()` has no Android equivalent.** It is what makes the system
  redact conversation names and previews on a locked screen while leaving the
  counts. Applied to exactly the fields that are disclosures, which is the same
  split `SnapshotPolicy.includePreviews` / `includeSenderNames` makes on the
  writing side.
- **`Link` per row, `widgetURL` for the surface.** `widgetURL` is one URL for the
  whole widget: set it per row and the last one silently wins. On `systemSmall`
  the system honours *only* `widgetURL`, which is why that family is a glanceable
  summary that opens the inbox rather than a menu.
- **No avatars, same as Android.** A row's `avatar` is an `mxc://` URI and this
  process has no session to authenticate a media fetch with. Merged-ness is
  carried by the number of network dots and by the accessibility label — two
  non-colour signals, which is the floor the design notes set.

## The gallery preview, and the placeholder

Two different things, and they get opposite answers.

`placeholder(in:)` is the skeleton drawn while the entry is produced. It is built
from `Conversation` rows with no previews and no names — the same rule the
Android preview images follow, because a placeholder showing plausible invented
conversations would teach the user to expect names on this surface before they
had agreed to any leaving the encrypted store.

`getSnapshot(in:)` is the widget gallery, and it shows the **real** state. Those
Android preview images are PNGs compiled into the APK and shipped to everyone;
this is generated live, on the user's own unlocked device, while they are the one
adding the widget. "Widgets are off" is the single most useful thing the gallery
can say to someone who has not opted in.

(WidgetKit's `getSnapshot` has nothing to do with `InboxSnapshot`. Both words are
load-bearing in their own vocabulary and neither can be renamed.)

## Deployment targets

iOS **16.0**, macOS **12.0** — both above their Runner's (13.0 and 11.0). An
extension may deploy higher than its host; it simply is not installed below that.
iOS 16 is where `WidgetFamily.accessory*` exists at all, and the Lock Screen
accessory is half of what this target is for. macOS 12 is where
`privacySensitive()` does. `containerBackground` (iOS 17 / macOS 14) is applied
behind an availability check by `weftWidgetContainerBackground()` — it is *not*
cosmetic: a widget built against the iOS 17 SDK that declares none is not shown
in Lock Screen and StandBy contexts at all.

## Signing, and the macOS asterisk

The iOS target carries the real App Group and needs only a certificate.

The macOS target does **not** carry it yet, and that is deliberate rather than an
oversight — `WeftWidget-macOS.entitlements` holds the exact key to add and the
three reasons it is a comment. The short version: App Groups on macOS are
team-prefixed, an App Group entitlement cannot be ad-hoc signed, and adding it
without a provisioning profile makes `xcodebuild` refuse before it compiles —
which, since Runner depends on this target, is `flutter build macos` failing for
anyone without the team's certificate. `macos/Runner` does not request the group
either, so the writing side is equally inert today: the app reports the snapshot
write as refused and this extension draws its signed-out state. Both are states
the code already survives.

## Build state

| Check | Result |
| --- | --- |
| `xcodebuild -target WeftWidget -sdk iphonesimulator` | Builds, links, produces `WeftWidget.appex` |
| `xcodebuild -target WeftWidget` (macOS) | Builds, links, produces `WeftWidget.appex` |
| `flutter build macos --debug` | Succeeds; the appex is embedded in `weft.app/Contents/PlugIns/` |
| `flutter build ios --no-codesign` | **Blocked, and not by this target** — `pod install` fails with *"The plugin `whisper_ggml` requires a higher minimum iOS deployment version than your application is targeting … at least 15.6"* against Runner's `IPHONEOS_DEPLOYMENT_TARGET = 13.0`. Reproduced identically on a clean tree with this whole directory stashed |

The iOS *embed* step is therefore the one thing here that has not been exercised
end to end, because no iOS build reaches Xcode on this machine at all.
