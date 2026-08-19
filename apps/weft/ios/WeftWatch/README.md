# Weft for Apple Watch

Phase 10's wrist surface: a conversation list, a quick reply, and a complication.
**Two targets from one directory** — `WeftWatch` (the app) and
`WeftWatchComplication` (the WidgetKit extension it embeds) — registered in
`ios/Runner.xcodeproj` and embedded into `Runner.app/Watch/` by
`flutter build ios`. What it still needs from you is signing material.

| File | What it is |
| --- | --- |
| `WeftWatchApp.swift` | The `@main` SwiftUI `App`. Activates the `WCSession` on the launch path |
| `WeftWatchViews.swift` | The inbox list, the row, the empty states, the reply screen |
| `WeftWatchStore.swift` | `WCSessionDelegate`: receives the snapshot, sends replies, holds their outcomes |
| `WeftWatchState.swift` | The five states this device can be in, and every sentence it can say |
| `WeftWatchComplication.swift` | The complication. `@main` `WidgetBundle`, four accessory families |
| `Info.plist` | `WKApplication`, and the companion bundle id that pairs the two sessions |
| `Complication-Info.plist` | `com.apple.widgetkit-extension` |
| `WeftWatch.entitlements` | The App Group — **the watch's own**, see below |
| `WeftWatchComplication.entitlements` | The same group, so the extension reads what the app wrote |
| `WeftWatch-{Debug,Release}.xcconfig` | The Flutter version pair. No CocoaPods include — see below |
| `../Shared/WatchProtocol.swift` | The dictionary keys the phone and this device agree on |
| `../Shared/SnapshotContainer.swift` | Container layout, compiled into six targets |
| `../WeftWidget/SnapshotPayload.swift` | The hand-written reader for `SnapshotCodec`'s JSON |
| `../WeftWidget/SnapshotViews.swift` | The badge and the network dots, shared with the Home Screen widget |
| `../Runner/WatchChannel.swift` | The other side: the phone's `WCSession`, over `com.bostrot.weft/watch` |

## What it does, and the two things it cannot

It renders one JSON payload the phone sent it, and it asks the phone to send
messages. It never decrypts, never fetches, and never talks to a homeserver.

**It cannot hold a Matrix session.** The session lives in the phone's keychain
and its sync loop in the phone's process. This device has neither, and a watch
that did would be a second device to verify, a second set of keys to back up and
a second thing to sign out of.

**It cannot reach the phone's App Group.** An App Group does not span devices —
the group named in `WeftWatch.entitlements` is a container *on the watch*, shared
between the app and the complication, holding a cache of what the phone last sent
over `WatchConnectivity`. The phase brief's "reading the same App Group snapshot"
is true of the format and not of the container. See `WeftWatchStore` for why the
cache is on disk rather than in memory; the short version is that the
complication is a separate process the system wakes on its own schedule.

## The five states

The same five as `WeftWidget` and as the Glance widgets, case for case. Four
hand-written renderers of one payload is already three more than anyone wants;
four that disagreed about *which* states exist would be worse than any of them.

| State | How it is reached | What it says |
| --- | --- | --- |
| `signedOut` | No payload. The phone publishes a cleared context on logout | "Sign in to Weft" |
| `switchedOff` | `enabled` false, **or** `watchEnabled` false | "Watch is off", and names the setting |
| `unavailable` | Older than `kSnapshotStaleAfter`, or undecodable | "Open Weft on your phone" |
| `ready`, no rows | Empty inbox, or every chat on an excluded network | "No conversations" |
| `ready`, rows | — | The rows |

The fifth is `watchEnabled` false with a perfectly good payload on the phone: a
**widgets-only user**. `SnapshotPolicy.enabled` is `widgets || watch`, so the
payload exists and this wrist must not be given it — which is why the phone
*withholds* the payload rather than sending it with the flag down. Fail-closed at
the transport as well as at the renderer.

## The reply round trip

```
watch: WeftWatchStore.send()          → WCSession.sendMessage / transferUserInfo
phone: WeftWatchChannel.deliver()     → com.bostrot.weft/watch → onWatchReply
Dart:  WatchReplyHandler              → resolve chat, pick leg, ChatRepository.send
Dart:  reportReply                    → WeftWatchChannel.sendReplyResult
watch: WeftWatchStore.receive(result) → the reply screen stops saying "Sending…"
```

Three properties this shape exists for:

- **Every accepted reply produces exactly one result**, including the ones where
  nothing was sent. The watch shows "Sending…" until it hears back, and nothing
  else on the phone will ever tell it otherwise — so a reply the handler quietly
  dropped is a message the user believes they sent.
- **A duplicate delivery is not a second message.** `sendMessage` fails when the
  phone is unreachable and the watch retries through `transferUserInfo`, which is
  queued and *will* arrive; both roads carry the same reply id, and
  `WatchReplyHandler` answers the second with the first's result.
- **An unknown chat id is rejected rather than guessed at.** A merged chat
  reverts to a bare room id when one of its legs is left, and this device may
  hold a snapshot for hours afterwards — so a well-formed row can name a
  conversation that no longer exists. The alternative to rejecting is picking
  some other conversation to send a private message into.

Two failures the phone cannot report, because it is not there: the process the
system woke has no Flutter engine (`app_not_running`, produced in Swift), and the
phone never answered at all (the watch's own three-minute timeout, which reports
a nil failure because it genuinely does not know why).

## What is different from the Home Screen widget, and why

- **`NavigationLink`, not `Link`.** A widget taps *out* of itself into the phone
  app through `weft://chat/<id>`; this taps *into* a screen on the same device.
  The watch row therefore does not use `SnapshotRow.link` at all — a watch that
  opened a deep link would be asking a phone in another room to show something
  nobody is looking at.
- **No `privacySensitive()`.** There is no locked-screen redacted rendering on a
  watch: the screen is off or the wrist is up. The complication makes the same
  split a different way — it has no variant that can carry a name.
- **Dark only.** `WeftWidgetTokens.dynamic` resolves to the dark value under
  `#if os(watchOS)`, and that is a platform fact rather than a shortcut:
  `UIColor(dynamicProvider:)` and `userInterfaceStyle` are both unavailable on
  watchOS, because there is no light mode. The wear module says the same thing.
- **No CocoaPods include in the xcconfig.** A watch app cannot link Runner's pods
  — they are built for iOS — so there is no `Pods-WeftWatch.debug.xcconfig` for
  `pod install` to look for, and including one would be a path that is never
  satisfied rather than an option.

## The complication

Total unread, and nothing else, in four accessory families. **No names, ever**: a
complication sits on a face that is on whenever the wrist is up — in a meeting,
on a table, in front of whoever is sitting opposite. A count identifies nobody.

The number is `InboxSnapshot.totalUnread` and never a sum over the visible rows,
because `totalUnread` counts the conversations past the row cap and the
seventeenth conversation's unread messages are still unread.

Its timeline is two entries and `.never`: now, and the exact instant
`generatedAt + kSnapshotStaleAfter` falls, carrying `unavailable`. The stale flip
is *exact* here for the same reason it is in `WeftSnapshotProvider` and cannot be
on a Wear tile — WidgetKit takes a timeline rather than polling. Refreshes are
pushed by `WeftWatchStore.reloadComplications()`, so there is no interval.

## Deployment target

watchOS **11.0**. Above the earliest that would work (`TextFieldLink` and
`NavigationStack` are watchOS 9, `containerBackground` is watchOS 10) because a
watch app is installed from a phone that is already on a recent iOS, and the
floor buys nothing that is not already covered by the empty states.

## Build state

| Check | Result |
| --- | --- |
| `xcodebuild -target WeftWatch -sdk watchsimulator` | Builds; `WeftWatch.app` with `PlugIns/WeftWatchComplication.appex` embedded |
| `xcodebuild -target WeftWatchComplication -sdk watchsimulator` | Builds, links, produces the appex |
| Bundle ids | `com.bostrot.weft.watchkitapp` and `…watchkitapp.WeftWatchComplication`, verified in the built `Info.plist`s |
| `flutter build macos --debug` | Succeeds — `WatchChannel.swift` compiles to a no-op there, which is what keeps `SnapshotChannel.swift` one file for both platforms |
| iOS `Runner` typecheck | `swiftc -typecheck` against `Flutter.xcframework` (arm64-ios13) is clean for `WatchChannel.swift`, `SnapshotChannel.swift` and the three `Shared/` files |
| `flutter build ios --no-codesign` | **Still blocked, and still not by this target** — `pod install` fails on `whisper_ggml`'s deployment target against Runner's `IPHONEOS_DEPLOYMENT_TARGET = 13.0`, exactly as `../WeftWidget/README.md` records |

The iOS *embed* step — `WeftWatch.app` landing in `Runner.app/Watch/` — is
therefore the one thing here not exercised end to end, for the same reason the
widget's is: no iOS build reaches Xcode on this machine at all. No on-device
pairing, placement or reply test either.

## Signing

Both targets carry the real App Group and need a certificate and a provisioning
profile. `docs/decisions/adr-002-ios-signing-handoff.md` has the bundle ids.
Without the group, `WeftSnapshotContainer.containerURL` returns nil on both
processes — a state the code already survives: the app draws its signed-out state
and the complication shows zero.
