# Weft

**Every conversation, one thread.**

A self-hosted, Beeper-style unified messenger. One Flutter app across Android,
iOS, macOS, Linux and Windows, talking to **your own** Matrix homeserver and
**your own** mautrix bridges. Weft hosts nothing and bridges nothing on your
behalf — you bring the server, Weft brings the client.

The three features that justify building this rather than using an existing
Matrix client:

1. **Merged chats** — one person's WhatsApp, Signal and Telegram threads
   collapsed into a single correctly-ordered conversation, where you choose
   which network each outgoing message rides.
2. **Voice transcription** against an STT endpoint and credentials you supply.
3. **Semantic search** over every message, backed by an on-device vector index.

Plus an **MCP server** so agents can drive the whole thing over an
authenticated Cloudflare tunnel.

---

## Status

Weft is early. This is what is actually built and tested today, and what is not.

| Area | State |
|---|---|
| Workspace, CI, test homeserver, design system, goldens | **Done** |
| Merge engine — identity graph, scoring, merged timeline | **Done**, persisted, 63 tests |
| Matrix session — login, E2EE, device verification, media upload transport | **Done**, 221 unit + 5 integration tests |
| Attachments — sniffing, upload plan, bounded queue, Matrix upload transport, repository send path with ordered event sends | **Done**, 156 + 40 tests |
| Attachment UI — attach button, source sheet, pre-send preview, image/video/audio/file bubbles, upload progress with cancel and retry, full-screen viewer with save and share | **Done**, 57 widget tests |
| App shell — rail, inbox, chat, composer, live or demo data | **Done** |
| Hybrid search — FTS5 + vectors + RRF, **wired**: search screen, ingest-on-read, backfill | **Done**, 63 tests |
| Transcription — **wired**: Transcribe action on voice bubbles, endpoint settings, privacy gate | **Done**, 15 tests |
| Bridges — **wired**: bridges screen, health probes, generic GUI login flows | **Done**, 21 tests. QR flows show a copyable code, not yet a rendered QR image. |
| MCP — **wired**: HTTP server (loopback), keys UI, scopes, audit view, tunnel toggle | **Done**, 36 tests |
| Deep links — weft:// + App Links parsing/routing, Android filters, Apple scheme | **Done**, 15 tests. Domain verification needs the files in `tooling/web` hosted. |
| Share-in — Android SEND/SEND_MULTIPLE, cold-start replay, share-target sheet | **Done** for text and files; shared URIs are streamed to a staged copy and sent through the same upload path as the composer, 15 tests |
| Merge management UI — suggestions with evidence, accept/reject, unmerge | **Done**, 4 widget tests |
| Bridge QR login — rendered QR + copyable payload, re-transcribe language picker, auto-transcribe | **Done** |
| Notification decisions — suppression rules, merged-chat grouping, body rendering, summaries | **Done**, pure Dart, 171 tests |
| Notification delivery — pusher registration, sync + push pipeline, channels per network, `MessagingStyle`, conversation shortcuts, tap routing | **Done**, 61 + 78 tests, and **verified on an Android device**: channels, shortcut, `MessagingStyle`, actions, and a tap that opens the right chat both warm and from a killed process. Needs a push gateway URL and a Firebase config to receive a push; without them Weft notifies while it is running. |
| Notification actions — direct reply, mark read, mute for an hour, on Android and iOS | **Done**, wired to `ChatRepository`; a reply typed in the Android shade has been sent as a real encrypted event. All three bring Weft to the foreground on Android: an action handled without doing so runs in a background isolate with no Matrix client. |
| Notification settings — master switch, per-network on/muted/off, mentions-only, quiet hours, lock-screen previews, muted-chat list, push gateway, test notification | **Done**, 25 widget tests. The test button runs a synthetic message through the real `evaluateNotification` path and reports the rule that suppressed it. No per-chat notification screen yet: the policy has per-chat `mentionsOnly` and `bypassQuietHours` and nothing writes them. |
| iOS Share Extension, notification service extension, Direct Share/People API, widgets, watch | **Not built** — the notification service extension is authored at `apps/weft/ios/NotificationService/` but needs Xcode targets and signing |
| SMS/MMS logic — phone normalisation, GSM-7/UCS-2 segment counting, MMS size limits, identity evidence that merges a number with its bridged handle | **Done**, pure Dart, 94 tests |
| SMS Android surface — default-SMS-app role via `RoleManager`, `SMS_DELIVER`/`WAP_PUSH_DELIVER` receivers, respond-via-message service, system-provider reads and writes, delivery reports, `sms:`/`smsto:` composer links | **Done** and **wired into the merged inbox**: threads, messages, delivery reports and sending go through `SmsChatRepository`, an SMS number merges with the bridged chat for the same number, bodies are indexed for search, and the composer shows the segment count and a plaintext indicator. Kotlin + a `com.bostrot.weft/sms` channel, 66 tests and 4 goldens. The role is asked for from Settings → SMS, and **the dialog has been raised and declined on a device**: Weft stays fully functional as a non-default app, with the SMS network simply absent. **Incoming MMS are not downloaded**: Android exposes the transport but not the PDU parser, so retrieval means vendoring AOSP's. |
| Multi-device — device manager (rename, sign out, sign out others with re-auth), unverified-device banner in encrypted chats, cross-signing and key-backup setup, recovery key with show-once and confirm steps, restore from key or passphrase, verification QR | **Done**, 86 tests and 6 goldens. The QR is rendered for the other device to scan, and the scanning end is a `QrScanner` seam with no camera behind it: the Matrix payload is binary, and a decoder that returns raw bytes on every platform is a dependency this has not taken yet. Emoji comparison covers Weft-to-Weft, and an Element on the other side can scan. |
| Rich content — formatted-body allowlist, reactions, replies, edits, link previews | **Done**, see [rich content](docs/architecture/rich-content.md) |
| Calling — 1:1 voice and video over Matrix WebRTC, CallKit, `ConnectionService`, TURN handling | **Done**, 122 + 57 + 105 tests and 10 goldens, and **a real call between two accounts on the local Synapse**: invite, ring, answer, candidates both ways, connected, hangup, in an encrypted room. Matrix-native conversations only — the button is disabled with a reason for a bridged chat. **No media has been proven on a device**: the peer connection is a fake in every test, and iOS needs a VoIP APNs certificate before a call can ring a suspended app. See [calling](docs/architecture/calling.md). |
| Patrol device matrix, a11y/RTL passes (M10) | **Not built**, but **audited**: [`docs/quality/a11y-audit.md`](docs/quality/a11y-audit.md) is a per-screen, per-line inventory of 229 findings across all 50 UI files. Today the app has 6 `Semantics` widgets, no live regions, no directional layout APIs, no keyboard traversal or shortcuts, and no locale declaration at all — so `Directionality` is unconditionally LTR and Weft cannot be put into RTL on a device or in a test. `packages/weft_design/` has no contrast test. Nothing has been run against a real screen reader yet. |

**2064 tests pass** (plus 9 integration tests on a real engine: 8 against a live Synapse, and one that drives the whole attachment loop). Verified builds: macOS app and Android APK (all four ABIs, including the vodozemac Rust cross-compile), and the app has been run on a physical Galaxy S25 (One UI, Android 16) with deep-link and share intents fired at it over adb. The attachment path has been run end to end on macOS in demo mode — pick, preview, upload with progress, settled bubble, full-screen viewer. The macOS build was re-verified after Firebase and `flutter_local_notifications` were added, and the Android APK after core library desugaring was enabled for the same plugin — the whole notification loop was then driven on an Android 16 emulator against the local Synapse. Both builds were re-verified again after `flutter_webrtc`, CallKit and `ConnectionService` landed, and a call was placed between two accounts on that Synapse — signalling end to end, media faked, and the homeserver's answer to "do you have a TURN server?" was no.

The app signs in to a real homeserver, syncs over E2EE, and renders live rooms
through the same UI as the fixtures. `--dart-define=WEFT_DEMO=true` swaps in
`DemoChatRepository` for UI work and golden tests without credentials.

## Running it

```bash
flutter pub get
```

```bash
cd apps/weft && flutter run -d macos
```

Also valid: `-d linux`, `-d windows`, `-d ios`, `-d android`.

> **macOS note.** Swift Package Manager is disabled for this project
> (`flutter config --no-enable-swift-package-manager`). `flutter_vodozemac`'s
> xcframework loses its `Versions/Current` symlink through the SPM path, which
> breaks code signing; CocoaPods handles it correctly. The macOS deployment
> target is 11.0, and the app declares `com.apple.security.network.client` —
> without it the sandbox rejects every outbound connection.

> **Android note.** E2EE is Rust, cross-compiled by cargokit during the Gradle
> build. Two prerequisites: `rustup target add aarch64-linux-android
> armv7-linux-androideabi i686-linux-android x86_64-linux-android`, and — if
> Homebrew's Rust is installed — build with
> `RUSTC=$HOME/.rustup/toolchains/<toolchain>/bin/rustc flutter build apk`.
> Homebrew puts its own `rustc` (no Android std) ahead of rustup's on PATH, and
> cargo resolves `rustc` from PATH, so without the pin every Android target
> fails with a misleading `E0463: can't find crate for core`. `compileSdk` is
> pinned to 37 for `flutter_secure_storage`, and **core library desugaring is
> on** because `flutter_local_notifications` requires it — without it every
> Android build fails at `checkDebugAarMetadata`, before a line of Weft is
> compiled.

> **Push note.** Weft notifies out of the box while it is running — that path
> needs nothing configured. Being notified while it is *closed* needs two things
> Weft cannot host for you:
>
> 1. **A push gateway.** Run your own [sygnal](https://github.com/matrix-org/sygnal)
>    and put its `/_matrix/push/v1/notify` URL in Notification settings, or build
>    with `--dart-define=WEFT_PUSH_GATEWAY=https://…`. The app ids it must be
>    configured for are `com.bostrot.weft.android` and `com.bostrot.weft.ios`.
> 2. **A Firebase project**, for `google-services.json` (Android) or
>    `GoogleService-Info.plist` (iOS). Without one the app starts normally and
>    logs that push is unavailable; it does not fail.
>
> Weft registers its pusher with `format: event_id_only`, so the homeserver
> tells the gateway *that* something happened and never *what* — the body is
> fetched and decrypted on the device. On iOS that makes a notification service
> extension necessary; one is authored at `apps/weft/ios/NotificationService/`
> and is not yet part of the Xcode project. See the README in that directory.
>
> Firebase's CocoaPods distribution is deprecated after October 2026 and this
> project has Swift Package Manager disabled (see the macOS note above), so the
> Apple side of push will need that resolved before then.

## Testing

The runner depends on the package, not on the kind of test in it. The pure Dart
packages take `dart test`:

```bash
cd packages/weft_merge && dart test
```

`weft_matrix` and `weft_store` depend on the Flutter SDK — `compute` and the
Matrix SDK's bindings in one, sqflite in the other — so they take `flutter test`
even though nothing in them draws:

```bash
cd packages/weft_matrix && flutter test
```

```bash
cd apps/weft && flutter test
```

Against the local homeserver (see [tooling/docker](tooling/docker/README.md)):

```bash
cd apps/weft && flutter test integration_test -d macos
```

These cover a real login, a real encrypted round trip between two accounts, and
the mapping of decrypted events onto Weft's domain model.

`integration_test/call_test.dart` runs there too, and places a real call between
`@alice` and `@bob` in an encrypted room: invite, ring, answer, ICE candidates in
both directions, connected on both sides, hangup. The *signalling* is entirely
real, including the encryption; the media is not — both peer connections are
fakes, because opening a microphone needs a permission grant no test can give
itself. It also asks the homeserver for a TURN server and asserts that the answer
becomes a sentence a user can read.

The attachment flow needs no homeserver, only a real engine:

```bash
cd apps/weft && flutter test integration_test/attachment_flow_test.dart \
  -d macos --dart-define=WEFT_DEMO=true
```

It picks a photo, watches it upload, opens the settled bubble full screen — a
sequence `flutter test` cannot perform at all, because its `FakeAsync` zone
never decodes an image and an undecoded picture has nothing to tap. Add
`--dart-define=WEFT_SHOT_DIR=/some/dir` to write a PNG of each step; on macOS
the app is sandboxed, so the run prints where the images actually landed.

Regenerate goldens after an intentional visual change:

```bash
cd apps/weft && flutter test test/goldens --update-goldens
```

Then re-run without the flag before committing: a golden that only passes in the
run that wrote it is carrying something that moves — a wall clock, an animation,
an undecoded image — and is worth less than no golden at all. The attachment
goldens capture their bubbles inside a real `ChatView` rather than on a bare
Scaffold, because a bubble's colour, corner and timestamp row live in
`chat_view.dart`; and they pin an in-flight upload's clock with `withClock`, so
the image does not disagree with itself a minute later.

### Verifying Direct Share on a device

Android's Direct Share row — Weft's conversations as faces in *another* app's
share sheet — is the one part of the share surfaces no `flutter test` reaches.
It needs a real launcher, a real `ShortcutManager` and a real share sheet. Demo
mode supplies the conversations, so no account is needed:

```bash
cd apps/weft && flutter build apk --debug --dart-define=WEFT_DEMO=true
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell pm clear com.bostrot.weft   # shortcuts outlive an install; start empty
adb shell am start -n com.bostrot.weft/.MainActivity
```

Give the app a moment to reach a ready session — publishing is driven by the
first chat list, not by launch — then ask the system what it was told:

```bash
adb shell cmd shortcut get-shortcuts com.bostrot.weft
```

Each entry should carry **both** categories
(`android.shortcut.conversation` and `com.bostrot.weft.category.SHARE_TARGET`),
a `bitmapPath` for its avatar, and its ranker position in `rank`. A shortcut
with only the conversation category bubbles notifications but is never offered
as a share target, and that is a silent failure — the app still shares fine.

Tapping a face sends an `ACTION_SEND` carrying the shortcut's id, which is the
whole of Direct Share's return path. Fire one directly rather than hunting for
a share sheet, and **quote the whole remote command** — `adb shell` re-splits on
the device, so an unquoted `--es` value with a space silently becomes the next
argument:

```bash
adb shell "am start -n com.bostrot.weft/.MainActivity \
  -a android.intent.action.SEND -t text/plain \
  --es android.intent.extra.TEXT 'Hello from adb' \
  --es android.intent.extra.shortcut.ID chat_merged_anna"
```

That should land on the share sheet's *confirm* step with the conversation
already chosen, not on the target list. The id → chat id map it resolves
through lives in the app's own preferences and can be read back with
`adb shell run-as com.bostrot.weft cat
shared_prefs/weft.share.shortcuts.xml`.

For the sheet itself, share a file from an app that raises one — the Files app
needs nothing installed:

```bash
adb push some.png /sdcard/Download/
adb shell am start -n com.google.android.documentsui/com.android.documentsui.ViewDownloadsActivity
```

Long-press the file, tap share, and the conversations appear above the app row.
Give the sheet a second before screenshotting: the icons load asynchronously and
arrive after the captions, so a screenshot taken immediately shows names with
nothing above them and reads exactly like the icon bug it is not.

The attachment pipeline also has a runnable prototype. It reads only the leading
bytes of a real file and prints what Weft would send for it — sniffed mime type,
`MessageKind`, dimensions, thumbnail decision, and the `m.room.message` content,
with the URI under `url` for a plain room and under `file.url` for an encrypted
one:

```bash
dart run weft_attachments:plan path/to/file.png --encrypted
```

## Layout

```
apps/weft/                  Flutter app, all five platforms
packages/
  weft_attachments/         mime sniffing, upload plans, upload queue state machine
  weft_domain/              entities: Chat, WeftMessage, NetworkHandle, ChatNetwork
  weft_merge/               identity graph + merged timeline   ← the hard part
  weft_search/              BM25 + vector kNN + RRF
  weft_bridges/             provisioning API v3 + admin-room fallback
  weft_transcribe/          pluggable STT adapters
  weft_notify/              notification rules, content, dedupe ledger
  weft_share/               share-target ranking, network capability, App Group staging
  weft_richtext/            formatted-body allowlist, reply fallbacks, reactions, edits
  weft_sms/                 phone identity, GSM-7/UCS-2 segments, MMS part planning
  weft_call/                call state machine, glare resolution, ICE candidate buffering
  weft_matrix/              Matrix SDK wrapper: session, E2EE, verification, call signalling
  weft_store/               SQLite: identity graph, settings, FTS5 + vectors
  weft_mcp/                 MCP server + cloudflared supervisor
  weft_design/              tokens, themes, components
docs/architecture/          design notes for the subsystems worth explaining
docs/decisions/             ADRs, including what needs your Apple developer account
tooling/docker/             disposable Synapse for tests
```

`weft_attachments`, `weft_domain`, `weft_merge`, `weft_search`, `weft_bridges`,
`weft_transcribe`, `weft_notify`, `weft_share`, `weft_richtext`, `weft_sms`, `weft_call` and `weft_mcp` are **pure Dart** —
no Flutter, no I/O. That is deliberate: the subtle logic lives there and runs under `dart test` in about a
second, with no device and no homeserver.

Longer-form design notes live in `docs/architecture/` —
[notifications](docs/architecture/notifications.md) covers the `event_id_only`
pusher, merged-chat grouping and the read-receipt dismissal loop,
[the attachment pipeline](docs/architecture/attachment-pipeline.md) covers
sniff-first detection, the plain-vs-encrypted event shapes, and why the upload
queue bounds concurrency, and
[share surfaces](docs/architecture/share-surfaces.md) covers Android Direct
Share, the iOS Share Extension's App Group contract, and the publish diff that
keeps the launcher from thrashing, and
[rich content](docs/architecture/rich-content.md) covers the formatted-body
allowlist as a security boundary, cross-network reaction dedupe, and why link
previews are fetched by the homeserver rather than by the app, and
[SMS integration](docs/architecture/sms-integration.md) covers why the
default-SMS role obliges Weft to write to the system provider, phone-number
normalisation as merge evidence, GSM-7 segment counting, and the explicit
no-encryption indicator, and
[multi-device](docs/architecture/multi-device.md) covers the recovery-key flow,
what is lost with no backup and no second device, and how the session-transfer
QR reuses the bridge login's card, and
[calling](docs/architecture/calling.md) covers glare resolution, ICE candidate
buffering, why the media engine is injected, and why a homeserver with no TURN
server has to say so rather than place a call that never connects.

Decisions that need something this repository cannot hold live in
`docs/decisions/` —
[ADR-002](docs/decisions/adr-002-ios-signing-handoff.md) is the iOS signing
handoff: the App Group, the three bundle ids and the profiles that have to exist
before iOS share-in works, and the VoIP Services certificate — a second
credential an APNs auth key cannot substitute for — that has to exist before an
incoming call can ring a suspended iPhone.

## Two things worth knowing before contributing

### The merged timeline's watermark

Interleaving several rooms into one conversation is not a sort. If WhatsApp has
paginated back to 14:00 and Signal only to 16:00, sorting what is loaded puts a
Signal message at 16:05 directly above a WhatsApp message at 15:30 — and Signal
may well have a message at 15:45 that simply hasn't been fetched. When it
arrives it must be inserted *between two messages the user has already read*.

So `MergedTimeline` exposes only messages strictly newer than
`W = max(oldestLoaded(s))` across sources that still have history, and
paginates only the sources holding `W` up. The invariant — *the visible list
only ever extends, never reorders* — is enforced by a randomised test over 200
synthetic interleavings, checked against an independently-written reference
merge. Read the doc comment on `MergedTimeline` before changing any of it.

### There is no ORM and no vector database

Both were tried and both were dropped.

**ObjectBox** was the original vector store, for its on-device HNSW index. But
`objectbox_generator` pins `analyzer <11` on every published version, while
`build_runner` itself requires analyzer ≥13.3 — and a pub workspace is a single
resolution unit. They can never coexist. **Drift** went too: FTS5 and the vector
table need hand-written SQL regardless, so it was paying a codegen step for
little.

`weft_store` therefore talks to `package:sqlite3` directly, with a plain
ordered-migration list in `migrations.dart`. Vectors are L2-normalised and
int8-quantised into BLOBs, and `FlatVectorIndex` scans them exactly, streaming
in pages so memory stays flat. That is fast enough well past 100k messages and
has no recall loss; past roughly half a million it should become an approximate
index (IVF over k-means centroids). Everything above depends only on the
`VectorIndex` interface, so that swap touches one file.

## Privacy

E2EE is the point of using Matrix, and it is easy to undo by accident. Sending
decrypted message text to a remote embedding or transcription endpoint hands
your plaintext to that endpoint. So:

- Remote embedding and remote STT are **off by default**.
- Enabling either requires explicit opt-in with a plain-language warning.
- Both support per-network exclusion.
- An on-device embedding model is the intended private default.
- `HashingEmbeddingProvider` gives working (non-semantic) vectors with no
  network at all, so search degrades rather than breaking when nothing is
  configured.

## Licence

Not yet chosen.
