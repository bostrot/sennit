---
type: research
title: Notification Decision Layer — What Already Exists
created: 2026-08-17
tags:
  - notifications
  - push
  - merge
  - settings
  - deep-links
related:
  - '[[Attachment-Pipeline]]'
  - '[[Merged-Timeline]]'
---

# Notification Decision Layer — What Already Exists

Survey taken before designing `weft_notify`, per Phase 03 task 1. The question
behind every section is the same one: **what must the new package take as input
rather than re-derive**, because every re-derivation is a second answer to a
question the app has already answered, and the two will drift.

Five conclusions up front, each argued below:

1. The notification group key is `Chat.id`, handed in. It is never computed from
   a room id.
2. `NotificationPolicy` is a value object in `weft_notify` with a JSON codec;
   `SettingsStore` persistence and the Riverpod notifier stay in the app.
3. A notification tap emits `weft://chat/<encoded id>` and goes through
   `WeftLink.parse` and the *existing* intent channel — no second route.
4. Mute already round-trips to the homeserver through `setPushRuleState`. Weft's
   local policy is a second opinion on the same fact and must be reconciled, not
   invented.
5. `lastReadAt` does not exist anywhere today. `evaluate` takes it as a
   parameter; something has to start producing it.

---

## 1. Merged chats: where a conversation id actually comes from

`packages/weft_merge/lib/src/identity_graph.dart` is a partition, not a lookup
table. Every `NetworkHandle` belongs to exactly one contact, and an unmerged
handle is simply a contact of size one — `IdentityGraph.contacts()` materialises
that partition as `UnifiedContact`s. The graph knows about *people*, not chats.

The chat-level fold lives one layer up, in
`apps/weft/lib/data/matrix_chat_repository.dart`:

- `_chatFromRoom` (line 717) → `Chat(id: room.id, …)`, one `ChatSource`.
- `_applyMerges` (line 742) → for each merged contact with **≥ 2 resolvable
  legs**, one `Chat` with `id: 'merged:${contact.id}'` and one `ChatSource` per
  leg. Everything not consumed passes through as its single-room chat.

So the resolution Phase 03 is told to reuse is already a single value:
`Chat.id`. `weft_notify` must accept a `Chat` and read `chat.id` for the group
key.

**What it looks like when this is wrong.** Key on `WeftMessage.roomId` and a
merged contact's WhatsApp leg and Signal leg get separate notification threads,
separate summaries ("2 new messages" twice), and separate taps that open two
different single-source chats — neither of which is the conversation the user
reads. Key on `Chat.contactId` instead and every group chat collapses into one
thread, because `contactId` is null for anything that is not a DM
(`_chatFromRoom` sets it only from `room.directChatMatrixID`).

Two edges worth designing for:

- **The group key is not stable forever.** `if (legs.length < 2) continue;` means
  a merged chat reverts to a plain room id when a leg is left or forgotten. Live
  notifications keyed on the old `merged:` key will not be regrouped by the
  platform. Acceptable, but it should be a documented consequence rather than a
  surprise.
- **`sources` is ordered by recency of last inbound message**, not by network
  enum order (`_applyMerges` sorts legs before building). Anything in
  `weft_notify` that wants a deterministic ordering must sort for itself;
  `Chat.networks` does return stable enum order and is the safe accessor.

## 2. Settings: the persistence pattern the policy must follow

`packages/weft_store/lib/src/settings_store.dart` is a typed key/value façade
over the v1 `settings` table (`key TEXT PRIMARY KEY, value TEXT NOT NULL`), with
`getString/getBool/getInt/getDouble/getJson` and upsert setters. Two properties
matter for a notification policy:

- **Keys are centralised** in `abstract final class WeftSettings` "so a typo is a
  compile error rather than a silently missing preference". Notification keys
  belong there, under a `notify.` prefix, next to `merge.` and `transcribe.`.
- **`getJson` treats a corrupt value as unset** — it catches `FormatException`
  and returns null rather than crashing startup. A policy serialised as one JSON
  blob therefore degrades to defaults instead of bricking launch, which is the
  right failure mode for something that gates whether the user hears from anyone.

The app-side shape is in `apps/weft/lib/app/settings.dart`: an `@immutable` value
object (`WeftAppearance`) with `copyWith`, a `Notifier` exposing narrow mutators,
and a `NotifierProvider`. Note the doc comment — appearance is still *in-memory
only* ("`weft_store` persists these in M5"). So the notification settings screen
will be the first surface to actually round-trip a value object through
`SettingsStore`, and it should establish that pattern rather than borrow one.

This splits `NotificationPolicy` cleanly: the value object and its `toJson` /
`fromJson` live in `weft_notify` (pure, testable, no store dependency); the
`SettingsStore` read/write and the Riverpod notifier live in the app.

**On the migration.** The `settings` table already exists from v1, so a
whole-policy-as-JSON blob needs no schema change. What *does* need one is the
per-chat timed mute: `chat_prefs (chat_id, send_network, updated_at)` has no
column for a mute expiry. Appending a migration that adds `muted_until INTEGER`
to `chat_prefs` — never editing an existing entry, per the header comment on
`weftMigrations` — is the convention-respecting move.

## 3. Deep links: the tap path already exists end to end

`WeftLink.parse` (`apps/weft/lib/app/intents.dart:27`) accepts both `weft://…`
and `https://weft.bostrot.com/…` and normalises the scheme difference (a custom
scheme parses `chat` as the *host*, https as a path segment). `/chat/{id}` →
`OpenChatLink`, with `Uri.decodeComponent` applied because room ids contain `!`
and `:`.

That decode is the constraint on the producing side: a merged id like
`merged:contact_1723…` contains a colon, so `NotificationContent`'s link must be
built as `weft://chat/${Uri.encodeComponent(chat.id)}`. Round-tripping that
through `parse` is a one-line test worth having in `content_test.dart`.

`main.dart:45 _handleLink` then pushes `ChatView(chatId: chatId)` off the
navigator key — a merged id lands in the merged conversation because `ChatView`
takes chat ids, not room ids. Nothing new is needed for routing.

**Cold start is already solved, and solved once.** `WeftIntents` installs a
handler on `MethodChannel('com.bostrot.weft/intents')` and
`deliverInitialIntent()` pulls `getInitialIntent` after the first frame, because
"a share arriving via cold start fires before any Dart code is listening" — the
same is exactly true of a notification tap. The platform side should replay a
tapped notification as `{type: 'link', url: 'weft://chat/…'}` into that channel.
Two further reasons not to add a parallel channel: `_dispatch` already switches
on `type`, and the provider comment warns that constructing a second `WeftIntents`
steals the handler from the first.

## 4. `ChatRepository`: mute and read are not new verbs

Both required verbs exist on the interface (`apps/weft/lib/data/chat_repository.dart`)
and are implemented against Matrix:

- **`setMuted(chatId, muted:)`** → `room.setPushRuleState(dontNotify | notify)`
  for *every* source room of the chat. This is already the server-side push rule
  the phase's later task asks to "keep in sync" — meaning the risk is not that
  the homeserver is unaware of a mute, but that Weft grows a *second*, local mute
  concept that disagrees with it. The reconciliation rule wants stating in the
  package doc: the homeserver's rule suppresses the *push*, `NotificationPolicy`
  suppresses the *display*, and a timed mute is Weft-only because Matrix push
  rules have no expiry.
- **`markRead(chatId)`** → `setReadMarker(lastEvent.eventId, mRead:)` on every
  leg, with the comment that a merged chat marks all legs read. That receipt is
  precisely the mechanism the "dismiss on other devices" loop rides on.

Three gaps this survey found, all of which change what Phase 03 has to build:

1. **`ChatSource.muted` is dead today.** The field exists on the domain type, but
   `_chatFromRoom` constructs `ChatSource(roomId:, network:)` and never sets it,
   and `_applyMerges` reuses `leg.sources.single`. So per-leg mute state is not
   observable from a `Chat`.
2. **Merged mute is all-or-nothing.** `muted: legs.every((leg) => leg.muted)` — a
   chat with WhatsApp muted and Signal not reads as *unmuted*, so `evaluate` on a
   WhatsApp message would notify. Whether that is a bug or the intent is a real
   product question; either way `evaluate` should take mute state per source, not
   only `chat.muted`, once (1) is fixed.
3. **There is no `lastReadAt` anywhere.** `unreadCount` comes from
   `room.notificationCount` and nothing surfaces a read timestamp — `grep` for
   `receipt` across `apps/weft/lib` and `packages/weft_matrix/lib` finds only the
   `setReadMarker` call and a comment. `evaluate`'s `lastReadAt` parameter is
   therefore a request for something the app must start producing (from the
   room's receipt state / `m.fully_read`) before "already read elsewhere"
   suppression does anything at all.

## 5. `weft_matrix`: the session, and what a background isolate costs

`WeftMatrixSession` (`packages/weft_matrix/lib/src/session.dart`) owns one
`sdk.Client` per process, restores sessions from the SDK's own database, and
exposes `client` behind a `StateError` guard. There is no pusher surface yet;
`pusher.dart` will sit beside `homeserver.dart` and take the client, matching how
the rest of the package is organised (free functions or small classes over
`sdk.Client`, no global state).

The one finding that constrains the *architecture* rather than the file layout:

> `_ensureVodozemac` caches `vodozemac.init()` as a process-wide `Future` because
> flutter_rust_bridge throws `Should not initialize flutter_rust_bridge twice`.

Any background execution context that decrypts — an FCM background isolate, an
iOS notification service extension — is a *separate* Dart isolate with its own
statics and its own rust bridge, and it needs its own init and its own database
handle onto a store the main isolate may hold open. That is the hard part of
`event_id_only` push, and it is a design decision to make before writing the
platform layer, not after.

Also relevant, already available and not to be rebuilt:

- `importantStateEvents: {'m.bridge', 'uk.half-shot.bridge'}` — bridge state
  survives lazy loading, so the network of a room is knowable at push time.
- `mxcToThumbnailUrl(client, url, authenticatedMedia:, size:)` in
  `src/media.dart` is the avatar resolver for Android `MessagingStyle`. Its doc
  warns `authenticatedMedia` must come from `client.authenticatedMediaSupported()`
  — guessing wrong 404s every avatar and looks identical to having none.

## 6. Domain vocabulary the package can rely on — and one thing it can't

`WeftMessage` already carries everything `evaluate` needs: `eventId`, `roomId`,
`network`, `senderId`, `senderName`, `timestamp`, `kind`, `isOwn`, `body`,
`transcript`, `redacted`. `MessageKind` covers text/image/video/audio/voice/file/
location/sticker/poll/event, which is the full set body rendering must handle.
`weft_domain` is pure Dart with no Flutter and no I/O, so `weft_notify` depending
on it keeps the new package runnable under `dart test`.

`mapEvent` (`packages/weft_matrix/lib/src/mapping.dart`) sets `body: ''` for a
redacted event and `senderName` from `calcDisplayname()` — which for a bridge
ghost is the remote network's display name. That is the "bridged display name"
mention detection has to match on.

**The constraint:** `WeftMessage` has no `formatted_body` and no `m.mentions`.
Matrix's intentional-mentions field is dropped at mapping time, so mention
detection in `weft_notify` is necessarily *textual* — user id, display name,
bridged display name, `@room` — over `body`. That is the right call for bridged
messages, which genuinely arrive as plain text with no pill markup, but it means
a native Matrix mention is detected by the same fuzzy path as a bridged one, with
the same false positives. If that proves too loose, the fix is a
`mentionsOwnUser` flag set in `mapEvent` where the real event is still in hand —
worth noting, not worth doing yet.

## 7. Workspace and CI mechanics

- Root `pubspec.yaml` has a flat `workspace:` list; every member declares
  `resolution: workspace`.
- Sibling pure packages (`weft_attachments`) pin `sdk: ^3.12.0`,
  `lints: ^6.0.0`, `test: ^1.31.0`, and their `analysis_options.yaml` is one
  `include: ../../analysis_options.yaml` line.
- `.github/workflows/ci.yaml`'s `unit` job iterates a **hardcoded** package list
  (`weft_domain weft_merge weft_search weft_bridges weft_transcribe weft_mcp
  weft_attachments`) and guards on `test/` existing — a new package that is not
  added to that string is silently never tested in CI.
- Barrels export `src/` files and consumers import the barrel only.

## 8. Loose ends found while surveying

- `docs/architecture/attachment-pipeline.md` links `[[Merged-Timeline]]` and
  `[[Encrypted-Media]]`; neither file exists. Phase 03's final task links
  `[[Merged-Timeline]]` again, so it stays dangling unless someone writes it.
- `WeftAppearance` is documented as in-memory "until M5" and still is.
- `OpenUserLink` is parsed but unhandled in `main.dart` (`debugPrint`, start-chat
  flow pending) — irrelevant to notifications, which only need `/chat/`.
