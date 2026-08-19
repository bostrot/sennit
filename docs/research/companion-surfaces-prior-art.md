---
type: research
title: Companion Surfaces — What Already Exists
created: 2026-08-19
tags:
  - widgets
  - watch
  - privacy
  - app-group
  - snapshot
  - deep-links
related:
  - '[[Share-Surfaces]]'
  - '[[Notifications]]'
  - '[[Notification-Decision-Layer]]'
  - '[[Attachment-Pipeline]]'
---

# Companion Surfaces — What Already Exists

Survey taken before designing `weft_snapshot`, per Phase 10 task 1. Same
question as the Phase 03 survey behind [[Notification-Decision-Layer]]: **what
must the snapshot take as input rather than re-derive**, because a widget row
that answers "which conversation is this" for itself is a second answer to a
question the app has already settled, and two answers drift.

Nothing was written in this pass. Every section below ends with the concrete
constraint it puts on `weft_snapshot`, the writer, or the platform surfaces.

---

## 1. The privacy-gate pattern — `endpoints_screen.dart` and its parts

The house style was set in `apps/weft/lib/features/settings/endpoints_screen.dart`
and then extracted, verbatim, into
`apps/weft/lib/features/settings/settings_section.dart:1-98`. Three widgets, and
the surfaces screen must use all three rather than inventing copy:

| Widget | What it is | Why it is shaped that way |
| --- | --- | --- |
| `PrivacyNotice` | Red box at the top of the screen, `errorContainer` at 50% alpha, shield glyph | Deliberately not a tooltip or an expandable — the reader cannot reach the switch without having been shown the cost. Semantics: `label: 'Privacy warning. $message'`, `excludeSemantics: true`, because the red box and the glyph are the entire signal and both are invisible to a screen reader. |
| `PrivacyGatedTitle` | The switch's `title`, carrying the one-sentence cost as a `Semantics(hint:)` | Given *as* the tile's title, not wrapped around the tile: a `SwitchListTile` forms its own semantics node, so an annotation above it becomes a separate node a reader meets independently of the switch it qualifies. A hint, not a longer label, so a reader hears name-then-state first and the sentence is short enough not to be skipped on the third visit. |
| `SettingsSectionHeader` | Title + "when to use it" subtitle, one `header: true` node | Heading navigation is how a reader skips the six sections they did not come for. |

**The copy rule**, stated in the `settings_section.dart` library comment: *state
the cost of switching the thing on, in the sentence next to the switch, in the
words the user would use.* The existing instances to match in register:

- Endpoints notice: "These endpoints receive decrypted message text or audio.
  For a remote endpoint, that undoes end-to-end encryption for whatever is sent
  to it."
- Embedding gate: "Turning this on sends the text of your messages to the
  endpoint below."

Both name the mechanism and the consequence in one sentence and stop. Neither
hedges, apologises, or says "may".

### The reusable settings shape — `LinkPreviewSettings`

`apps/weft/lib/services/links/link_preview_service.dart:14-90` is the second
gate of this shape and its comment says so explicitly: *"Weft has two of these
gates now and they behave identically, which is worth more than either of them
being individually clever."* The shape:

```dart
class LinkPreviewSettings {
  final bool enabled;                    // off by default
  final Set<String> excludedNetworks;    // ChatNetwork.id strings

  static const LinkPreviewSettings off = LinkPreviewSettings();
  factory LinkPreviewSettings.fromStore(SettingsStore settings);
  bool allows(ChatNetwork network) => enabled && !excludedNetworks.contains(network.id);
  void writeTo(SettingsStore settings);
}
```

The `off` fallback carries the load-bearing comment: *"a gate that opens when it
cannot find its own configuration is not a gate."* Exclusions are stored as
`ChatNetwork.id` strings under a `{'networks': [...]}` JSON envelope, sorted on
write so the stored value is stable.

> **Constraint on `SnapshotPolicy`.** It is the *third* gate of this shape and
> must be recognisably the same object: `enabled` false by default, an
> `excludedNetworks` set of `ChatNetwork.id`, an `allows(network)` predicate, a
> `static const off`, and `fromStore`/`writeTo`. Its two extra axes —
> `includePreviews` and `includeSenderNames` — are additions to the shape, not
> a departure from it. See §3 for why they are two flags and not one.

---

## 2. Phase 04's staging codec and App Group plumbing

### Container constants — `apps/weft/ios/Shared/ShareContainer.swift`

`WeftShareContainer` is the single spelling of every path both processes touch.
Facts that carry straight over:

- App Group is `group.com.bostrot.weft`, declared in `Runner/Runner.entitlements`
  and `ShareExtension/ShareExtension.entitlements` and registered on the
  developer portal (see `docs/decisions/adr-002-ios-signing-handoff.md`).
- **The file is a member of both targets.** That is why it imports `Foundation`
  and nothing else — an extension cannot link Flutter, and the host app must not
  need a second copy of the constants to talk to it.
- `containerURL(forSecurityApplicationGroupIdentifier:)` returns a *different
  absolute path* to each process for the same group. Nothing absolute may cross
  the boundary; `StagedFile.relativePath` is container-relative for exactly this
  reason, and `relativePath(of:)` resolves symlinks on both sides first because
  the container lives under `/var`, itself a symlink to `/private/var`.
- **Every accessor is optional rather than throwing.** A build signed without
  the App Group entitlement — unsigned CI, a stale profile — returns `nil`, and
  both sides survive it: the extension by saying it cannot stage, the app by
  draining nothing.
- Everything share-related sits under one `share/` directory "so a drain that
  wants to clear the lot does not have to know the container's other tenants."

> **Constraint.** The snapshot gets its own sibling directory (`snapshot/`) and
> its own Foundation-only constants file in the same shape, joined to the same
> App Group. "The container's other tenants" was written in anticipation of
> exactly this. Every accessor optional; an unentitled build writes nothing and
> the widget shows its disabled state rather than an error.

### Tolerant decode — `packages/weft_share/lib/src/staging.dart:209-373`

`ShareStagingCodec`'s doc comment is the discipline, and it is worth quoting
because the reasoning transfers with one inversion:

> **Every decode is total.** Not as a nicety: the writer is a process the system
> can kill at any instant, including between the first byte of the file and the
> last […] A decoder that throws on a truncated blob turns a share the user has
> already forgotten about into an app that will not start.

Mechanics to copy:

- `decode` returns `null` for every refusal and enumerates them in the doc
  comment. Refusal is *documented behaviour*, not a consequence of a stray `try`.
- `_listOrEmpty(Object?)` instead of a cast, because a cast throws `TypeError`
  and no `catch` upstream is looking for one.
- `_parseTimestamp` accepts ISO-8601 strings *and* epoch milliseconds, "a number
  is what a hand-written Swift encoder reaches for first."
- Unrecognised top-level keys are carried in `extras` and re-emitted on encode,
  so a blob written by a newer build and re-staged by an older one loses nothing
  it had not already lost.
- The key names are **a cross-language contract**: `ShareViewController.swift`
  writes that JSON by hand with no Dart on the other side. Renaming a key is a
  silent break.

**The one inversion — and it is the reason `weft_snapshot` needs a real version
check where `weft_share` does not.** `kStagedShareFormatVersion` is explicitly
*"present for diagnosis, not for gating: the extension ships inside the app
bundle, so a reader older than its writer cannot exist."* That premise fails for
widgets. An OS can hold a stale widget or watch process across an app update, so
the snapshot's reader **can** be older than its writer, and that is the ordinary
case rather than the pathological one.

> **Constraint on `SnapshotCodec`.** Version is load-bearing, not decorative. A
> reader meeting a `version` above its own must degrade to something renderable
> (or to a "open Weft on your phone" state) rather than refuse or throw — a
> widget extension that crashes is a widget the OS stops scheduling. Truncated
> payload → `null`, unknown fields ignored, and the size cap enforced *at decode
> as well as encode*, since the reader is the memory-constrained side.

### Dart-side channel shape — `staged_share_reader.dart`

- `StagedShareGateway` is an `abstract interface class` — the test seam. Behind
  it is a method channel and a filesystem the app does not own; every decision
  the reader makes is testable against a map.
- `WeftStagedShares._invoke<T>` swallows two exceptions as *ordinary*:
  `MissingPluginException` (every platform that is not iOS) and
  `PlatformException` (a container the build is not entitled to reach). Neither
  is a reason to throw out of a launch-path call.
- The drain never throws; it catches `Object` deliberately, with the reason
  written down.

> **Constraint on `SnapshotWriter`.** Same seam (`SnapshotGateway` or equivalent
> interface), same `_invoke` tolerance over `com.bostrot.weft/snapshot`, same
> never-throws posture. A snapshot that cannot be written is a widget showing
> stale content, never a failed send or a crashed app.

---

## 3. `weft_notify` content rendering — the degradation to match

`packages/weft_notify/lib/src/content.dart`:

- `kHiddenPreviewBody = 'New message'` — with previews off the body degrades to
  this; the notification is still posted. The comment is the whole policy:
  *"the user asked not to have their messages readable over their shoulder, not
  to stop being told they have any."*
- **Previews-off keeps the title and the sender.** This deliberately matches
  Android's "hide sensitive content" rather than iOS's "hide previews", and the
  doc says a caller wanting the stricter reading degrades `title` and
  `senderName` too, via `copyWith`.

> **Constraint.** That is precisely why `SnapshotPolicy` has *two* flags,
> `includePreviews` and `includeSenderNames`, rather than one. The stricter
> reading is a second, separate step in the notification layer and it must be a
> second, separate switch here. Previews off with names on must render exactly
> like a hidden-preview notification does.

- `notificationGroupKey(Chat chat) => chat.id`, "unchanged and unprefixed,
  because the app has already answered the question this key asks." The comment
  spells out both failure modes: key on `roomId` and a merged contact's WhatsApp
  and Signal legs become two rows counting half the messages each; key on
  `contactId` and every group chat collapses into one, since `contactId` is null
  for anything that is not a DM.
- `notificationLinkFor` delegates to `chatDeepLink`
  (`packages/weft_domain/lib/src/link.dart`), which is
  `'weft://chat/${Uri.encodeComponent(chatId)}'`. The encoding is load-bearing:
  the **whole id must be one path segment**, or a merged id's colon reads as a
  second segment and the link resolves to nothing. The comment already names
  three callers that must produce a byte-identical string and cannot afford to
  disagree.
- Truncation: `kMaxNotificationBodyLength = 240`, justified not by taste but by
  Android's notification parcel size limit, *shared with every other
  notification the app has posted*. `_truncate` cuts at the last space in the
  tail when one is within 24 characters of the cap, else hard-cuts, then appends
  `…`.
- No emoji in notification bodies, "deliberately, which is where this parts
  company with `ChatTile._preview` (📷 Photo)" — a notification body is read
  aloud by TalkBack and VoiceOver.

> **Constraints.**
> 1. A `SnapshotRow` keys on `Chat.id`. It does not re-derive, re-hash, or
>    re-prefix. Same for the watch's conversation identity.
> 2. `SnapshotRow.link` is produced by calling `chatDeepLink`, never by
>    string-building `'weft://chat/$id'` in Dart, Swift or Kotlin. Glance's
>    intent and WidgetKit's `widgetURL` both consume the Dart-produced string
>    out of the payload.
> 3. The snapshot's size cap earns its place the same way 240 does — a stated
>    mechanism (extension memory ceiling, WidgetKit payload budget), not a round
>    number.
> 4. **Divergence, taken knowingly:** `_truncate` operates on UTF-16 code units
>    via `substring`, so it can split an emoji or a combining sequence. Phase 10
>    asks `weft_snapshot` for truncation *at a grapheme boundary*. That is a
>    deliberate improvement, not a copy — a widget row renders in a fixed box
>    where a lone surrogate shows as a replacement glyph, and it is worth noting
>    in the new package's comment that it does not match `weft_notify` here.
> 5. Emoji in a snapshot preview is an open decision: the widget row is closer
>    to `ChatTile` (looked at) than to a notification (read aloud) — but a
>    WidgetKit view *is* read by VoiceOver. Lean to `weft_notify`'s no-emoji
>    rule, since the snapshot is the strictly more constrained surface.

---

## 4. `weft_design` tokens — and why they cannot cross the boundary

`packages/weft_design/lib/src/tokens.dart` and `theme.dart` hold:

- `WeftSpace` — a 4pt grid, `xxs 2 … huge 48`.
- `WeftRadius` — `xs 6` through `xl 28`, plus `pill`.
- `WeftMotion` / `WeftMotionTokens` — irrelevant to a widget; the system draws
  these surfaces and does not animate them.
- `WeftShadow`, `WeftPalette` (a `ThemeExtension`), `WeftTheme.defaultSeed =
  0xFF6C5CE7`.

**The problem the phase brief names.** Every one of these is a Flutter type —
`Color`, `BorderRadius`, `Curve`, `ThemeExtension`. A Glance composable and a
SwiftUI `TimelineProvider` cannot import `weft_design`, cannot import Flutter at
all, and are rendered by the system in a process with no Flutter engine.

The codebase already has the precedent for carrying a design value across that
boundary: `ChatNetwork.brandColor` is *"held as an `int` so this package stays
Flutter-free; `weft_design` converts it to a `Color`."* Same trick, one step
further out.

> **Constraint.** The spacing, radius and colour values the widgets use are
> duplicated as Kotlin `object` / Swift `enum` constants, and the duplication is
> *documented as deliberate* with `weft_design` named as the source of truth —
> the same treatment `ShareContainer.swift` gives to path constants. Network
> brand colours travel in the snapshot payload as ints rather than being
> re-tabled on each platform. Android's dynamic colour takes precedence where
> available, per the phase brief, with the tokens as fallback.

Two component conventions worth carrying:

- `UnreadBadge` caps its label at `99+` above 99
  (`components/unread_badge.dart:92`). A widget's unread count must cap the same
  way or the same conversation reads differently on two surfaces.
- `ChatTile` signals a merged chat **three ways so it never depends on colour
  alone**: the avatar's gradient ring, a row of network glyphs, and a "Merged"
  label in the accessibility description. A widget row with less room still owes
  at least two of those.

---

## 5. `weft_merge` and the merged chat id

**`weft_merge` does not mint the id.** The package holds the identity graph, the
scorer and `MergedTimeline`; the id is minted in the app layer at
`apps/weft/lib/data/matrix_chat_repository.dart:994` as `'merged:${contact.id}'`,
and `ChatRepository`'s comment (`chat_repository.dart:27`) is the contract: a
WhatsApp room and a Signal room both resolve to the same `merged:<contactId>`.

What a snapshot row and a watch conversation therefore read off `Chat`
(`packages/weft_domain/lib/src/chat.dart`):

| Field | Use |
| --- | --- |
| `id` | The row key and the deep-link target. `merged:<contactId>` or a bare room id. |
| `title`, `avatarUrl`, `unreadCount` | Rendered directly. |
| `networks` | Sources' networks **in stable enum order** — the same batch always renders the same way round. |
| `isMerged` | `sources.length > 1`. |
| `sendNetwork` | Explicit user choice, else the last inbound message's network, else the first source. **This is what a watch reply must send on.** |
| `lastMessage` | The preview source, subject to the policy. |

**The instability, already documented in `weft_notify` and now a second
surface's problem.** A merged chat reverts to a plain room id when a leg is left
or forgotten, because `_applyMerges` needs two resolvable legs. For notifications
that means stale shade entries that are untidy and not wrong. For a widget it
means **a snapshot row can carry a deep link naming a chat that no longer
exists**, and the widget process may hold it for hours.

> **Constraints.**
> 1. Tapping a stale row must land somewhere sane — the existing deep-link
>    handling has to tolerate an unresolvable chat id rather than dead-ending.
>    Verify this before authoring the widgets; do not add a second code path.
> 2. `WatchReplyHandler` rejecting an unknown chat id (already in the Phase 10
>    brief) is not defensive padding — it is this exact case, and it is reachable
>    without anything going wrong.

---

## 6. Settings persistence — one discrepancy to resolve

- `WeftSettings` keys are namespaced by feature; the privacy family already has
  `privacy.remote_excluded` and `privacy.link_preview_excluded`. Snapshot keys
  belong under `privacy.*` alongside them, not under a new namespace.
- `packages/weft_store/lib/src/migrations.dart` is an append-only
  `List<String> weftMigrations` (currently 4 entries). `migrate()` reads
  `PRAGMA user_version`, applies each unseen entry in its own transaction, and
  sets `user_version = index + 1`. It is idempotent. **Editing an existing entry
  changes what a fresh install gets without changing what an existing install
  has** — hence the phase brief's "append, never edit".

> **Discrepancy to flag before task 4 is implemented.** Phase 10 task 4 asks for
> the snapshot settings to be persisted "with a newly appended migration". But
> `SettingsStore` (`settings_store.dart:11-60`) is a generic key/value store over
> a single `settings (key, value)` table with `getBool` / `setBool` /
> `getJson` / `setJson`, and `LinkPreviewSettings` — the gate this one is being
> modelled on — added its keys with **no migration at all**. A migration is only
> warranted here if the snapshot needs a table of its own, which on this design
> it does not: the policy is three booleans, a network-id set and an int.
> Recommendation: follow `LinkPreviewSettings` and add no migration, and record
> that choice rather than appending an empty one to satisfy the letter of the
> brief. Raise it at task 4 rather than silently doing either.

---

## Summary — the inputs `weft_snapshot` must not re-derive

1. `Chat.id` as the row key (`merged:<contactId>` or room id) — from the app,
   never recomputed.
2. `chatDeepLink(chatId)` for the link — one segment, percent-encoded, produced
   in Dart and carried in the payload.
3. `ChatNetwork.id` for exclusions and `ChatNetwork.brandColor` as an int for
   rendering.
4. `Chat.networks` order (stable enum order) and `Chat.sendNetwork` for the
   watch reply.
5. `kHiddenPreviewBody`'s degradation semantics — body hidden, title and sender
   independently switchable.
6. `group.com.bostrot.weft` and the `WeftShareContainer` path discipline —
   relative paths only, every accessor optional.
7. `PrivacyNotice` / `PrivacyGatedTitle` / `SettingsSectionHeader` and the
   `LinkPreviewSettings` gate shape — the third instance, not a new design.

And the two places Phase 10 **departs** from prior art, both on purpose and both
needing a comment in the new code:

- **Version gating is real.** A stale widget process outliving an app update
  inverts `weft_share`'s "a reader older than its writer cannot exist".
- **Truncation is grapheme-aware**, where `weft_notify._truncate` is not.
