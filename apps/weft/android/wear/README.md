# Weft for Wear OS

Phase 10's Android wrist surface: a conversation list, a quick reply, a tile and
a complication. **A separate Gradle module producing a separate APK for a
separate device** — `./gradlew :wear:assembleDebug`, never `flutter build apk`,
which only ever asks for `:app`.

| File | What it is |
| --- | --- |
| `WeftWearActivity.kt` | The activity, the two-screen nav host, and how state stays current |
| `WeftWearScreens.kt` | The inbox list, the row, the empty states, the reply screen |
| `WeftWearStore.kt` | The `SharedPreferences` cache of the `DataItem`, and the five states |
| `WeftWearDataService.kt` | `WearableListenerService`: the snapshot in, reply results in |
| `WeftWearOutbox.kt` | Replies out, and what became of them |
| `WeftWearTileService.kt` | The tile. ProtoLayout, not Compose — see below |
| `WeftWearComplicationService.kt` | Total unread, on a watch face |
| `WeftWearTheme.kt` | `weft_design`, duplicated for a device with no Flutter in it |
| `WeftWearStrings.kt` | State copy and failure sentences, out of `res/values/strings.xml` |
| `../shared/…/SnapshotPayload.kt` | The hand-written reader for `SnapshotCodec`'s JSON. **Compiled into `:app` too** |
| `../shared/…/WearProtocol.kt` | The Data Layer paths and keys both modules agree on |
| `../app/…/wear/WearBridge.kt` | The other side: the phone's `DataClient` and `MessageClient` |

## Why a module and not a source set

`:app` is driven by the Flutter Gradle Plugin and carries a Flutter engine, an
NDK, a WebRTC stack and sixty plugins. None of that belongs on a watch. This
module applies no Flutter plugin, contains no Dart, and **declares no `INTERNET`
permission** — which is the architectural claim of the whole phase stated as a
manifest entry: there is no Matrix session here and nothing to fetch.

`android/shared/` is the seam. `SnapshotPayload.kt` and `WearProtocol.kt` are
added to both modules' source sets rather than either depending on the other,
because these are two APKs that ship separately and neither is a library for the
other. It is the same arrangement `ios/Shared/` has, where
`SnapshotContainer.swift` is a member of six Xcode targets — and the reason is
the one the parser's own doc gives: no compiler checks these key names against
the Dart class, so a second copy is a second place for them to be wrong.

**The `applicationId` is `com.bostrot.weft`, the same as the phone's.** Wear OS
pairs a watch app to a phone app by package name and signing certificate — that
is the entire mechanism — and a watch APK with an id of its own is an app the
Data Layer will happily deliver nothing to, silently, forever.

## The five states

The same five as the phone widgets and the Apple surfaces, case for case.

| State | How it is reached | What it says |
| --- | --- | --- |
| `SignedOut` | No `DataItem`. The phone deletes on logout | "Sign in to Weft" |
| `SwitchedOff` | The item's `watch` flag is false, or `enabled` is | "Watch is off", and names the setting |
| `Unavailable` | Older than `kSnapshotStaleAfter`, or undecodable | "Open Weft on your phone" |
| `Ready`, no rows | Empty inbox, or every chat on an excluded network | "No conversations" |
| `Ready`, rows | — | The rows |

The fifth is a **widgets-only user**: the phone has a payload this wrist may not
be given, so it publishes the item with the flag off and *withholds* the payload
rather than sending it and trusting the watch not to draw it. Fail-closed at the
transport as well as at the renderer.

## Two transports, two shapes

- **The snapshot is a `DataItem`**, because it is *state*. It is stored on both
  nodes, it survives the watch being out of range, and a watch that reconnects
  after an hour is handed the current value with the phone doing nothing.
- **A reply is a message**, because it is an *event*. It happens once, it must not
  be replayed onto a node that reconnects tomorrow, and a phone out of range is a
  fact the wearer needs now rather than a state to sync later.

`KEY_UPDATED_AT` exists because the Data Layer deduplicates by content: a
byte-identical `DataMap` put twice never reaches `onDataChanged`. `SnapshotWriter`
rewrites an unchanged payload every three hours precisely so a surface does not
drift into its stale state, and without the stamp that rewrite would be swallowed
and the watch would go stale anyway. `updateApplicationContext` on the Apple side
has the identical trap and the identical fix.

## The reply round trip

```
watch: WeftWearOutbox.send()          → MessageClient → /weft/reply
phone: WeftWearReplyService           → WeftWatchChannel.deliver()
Dart:  WatchReplyHandler              → resolve chat, pick leg, ChatRepository.send
Dart:  reportReply                    → MessageClient → /weft/reply-result
watch: WeftWearDataService            → WeftWearOutbox.onResult()
```

A `WearableListenerService` is started by the system whether or not Weft is
running, so it can be the component that starts the app's *process* — with no
Flutter engine in it and no Matrix session. `WeftWatchChannel` answers the watch
with `app_not_running` there rather than pretending. The alternative — starting an
engine and a session from a background broadcast to send one line of text — is a
cost every reply pays for a case the wearer resolves in a tap.

`WeftWearStrings.replyFailure` **falls through rather than switching
exhaustively**, which is the one place this module is defensive on purpose: the
failure ids are a contract shared with a phone app that updates on its own
schedule, and a watch is updated late and sometimes never.

## The tile is ProtoLayout, not Compose

A tile is rendered by the *system's* process from a serialised description this
service hands over. There is no Compose runtime on the other side of that
boundary — exactly as there is no Flutter engine on the other side of a Glance
widget's, and no Flutter engine in a WidgetKit extension. Same constraint, three
platforms, one conclusion: the phone decides what may be shown, the surface
decides how it is laid out, and neither can ask the other a question.

It shows three rows, not sixteen. A tile's height is fixed, and rows past the
third would be laid out and clipped at the same cost to the renderer as drawing
them. It drops the preview for the reason `systemSmall` does on WidgetKit: three
words and an ellipsis is worse than the title alone.

`res/drawable/tile_preview.xml` is a **shape study, not a screenshot**. It is
compiled into the APK and shipped to everyone, so it cannot show real rows; and
drawing plausible invented ones would have the tile picker teaching a wearer to
expect names on this surface before they had agreed to any leaving the encrypted
store on the phone. The same rule the Glance preview images follow and the same
one `WeftWatchComplicationProvider.placeholder` follows in Swift.

## Colours

`WeftWearTokens` is the `values-night` half of `res/values-night/colors.xml` and
nothing else, because **Wear OS has no light mode**. The reason is hardware: an
OLED pixel showing black is a pixel that is off, on a device whose battery is
measured in hours. `WeftWidgetTokens.dynamic` reaches the same conclusion under
`#if os(watchOS)`, where the dynamic-colour APIs are simply unavailable.

Network brand colours are **not** duplicated here. They arrive in the payload as
`InboxSnapshot.palette`, for the reason both other platforms give: the table
changes whenever a network is added, and a stale copy would render a new one in
the fallback grey with nothing to say it had gone wrong.

## Build state

| Check | Result |
| --- | --- |
| `./gradlew :wear:compileDebugKotlin` | Passes |
| `./gradlew :wear:assembleDebug` | Passes; produces `build/wear/outputs/apk/debug/wear-debug.apk` |
| Merged manifest | All four components present — activity, data service, tile, complication |
| `./gradlew :app:compileDebugKotlin` | Still passes after the parser moved to `android/shared/` |
| `./gradlew :app:processDebugResources` | Still passes; `WeftWearReplyService` appears in the phone's merged manifest |

There is no JDK on the PATH; the builds above run under Android Studio's bundled
JBR — `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`.

**Not verified:** no install, no paired-emulator run, no on-device reply. The
Data Layer cannot be exercised without two devices (or a paired phone and watch
emulator), which is on-device work Phase 10's task 8 owns.
