# weft_snapshot

What a home screen widget, a Lock Screen accessory and a watch app are allowed
to know about the inbox.

None of those surfaces can decrypt a Matrix room. Not "does not" — *cannot*: a
WidgetKit extension has no Matrix session, a Glance provider has no Flutter
engine, and a watch app has neither and no keys either. So all three render the
same thing: a small, deliberately minimal snapshot the host app writes into a
shared container, and nothing else.

That makes the interesting question a privacy one rather than a layout one. A
widget row is message content sitting outside the encrypted store, on a home
screen, in a file the OS and any device-level backup can read. It gets the same
treatment as remote transcription and remote embedding — off by default, one
plain sentence saying what turning it on costs, per-network exclusion, and
*separate* switches for what was said and who said it.

Pure Dart, so the decision is made once and tested once instead of three times
in three languages none of which can run a test.

- **`SnapshotPolicy`** — the gate. The third instance of a shape the codebase
  settled on with `TranscriptionSettings` and `LinkPreviewSettings`: `enabled`
  false until someone turns it on, `excludedNetworks` of `ChatNetwork.id`,
  `allows(network)`, and an `off` fallback, because a gate that opens when it
  cannot find its own configuration is not a gate.
- **`InboxSnapshot` / `SnapshotRow`** — the payload. Every string already
  filtered, rendered, truncated and linked, because there is no second filter on
  the far side of the process boundary and there cannot be one.
- **`buildSnapshot`** — the whole privacy decision in one function.
- **`SnapshotCodec`** — the wire format: versioned, size-capped on both sides,
  and total on decode.

No Flutter, no `dart:io`, no method channels. The writer, the platform channels
and the surfaces live in `apps/weft/lib/services/snapshot/`,
`apps/weft/android/` and `apps/weft/ios/`.

## Two flags, because it is two worries

`weft_notify` renders previews-off as hiding the message body while keeping the
conversation title and the sender — Android's "hide sensitive content", not
iOS's "hide previews" — and documents the stricter reading as a second,
separate step. So this package has two switches rather than one:

| Flag | Off means |
| --- | --- |
| `includePreviews` | no `preview`. The title, the unread count and the timestamp stay. |
| `includeSenderNames` | the title reads `Conversation`, the sender is dropped, and so is the avatar. |

The avatar travels under `includeSenderNames` rather than under a flag of its
own because for a DM the avatar *is* the other person's face, and a row showing
it beside a redacted title has not redacted anything.

An excluded network drops the whole conversation, merged ones included. There is
no way to render "the Signal half" of a merged row — it has one title and one
preview for several networks — and excluding a network has to mean its messages
do not leave the encrypted store.

## Three empty states, and how a surface tells them apart

| What the surface finds | What it means | What it should say |
| --- | --- | --- |
| no payload | signed out — the writer deletes on logout | sign in on your phone |
| `enabled: false`, no rows | switched off in Settings | where the switch is |
| `enabled: true`, no rows | nothing to show | you're all caught up |
| anything, `isStaleAt(now)` | the app has not run in 12 hours | open Weft on your phone |

The switched-off state is *written* rather than deleted precisely so it can be
told from the signed-out one. Showing a sign-in prompt to someone who is signed
in is the failure this avoids.

## Where this departs from `weft_share`, and why

Two inversions, both because the reader is a different kind of process.

**Version gating is real here.** `kStagedShareFormatVersion` is documented as
being "present for diagnosis, not for gating: the extension ships *inside* the
app bundle, so a reader older than its writer cannot exist." A widget or watch
process is started and kept by the OS on its own schedule, and can be held
across an app update — so a reader older than its writer is the ordinary case.
`decode` therefore accepts a higher version, reads what it recognises, and flags
it as `isFutureVersion`. It does not refuse: an unread count and a chat id mean
the same thing in every version this format will have, and a widget extension
that crashes is one the OS stops scheduling and the user eventually deletes.

**Truncation is grapheme-aware.** `weft_notify._truncate` cuts on UTF-16 code
units, which can split a surrogate pair, a combining sequence or a ZWJ emoji. In
a notification shade that is a momentary broken glyph in a row that scrolls
away; in a widget it is a fixed box that renders it on every refresh for as long
as that message is the newest one.

And one thing deliberately *not* carried over: `StagedShare.extras`. That exists
because its reader also writes — the drain re-stages a share it could not
finish. Nothing here writes the payload back, so unknown keys are ignored rather
than round-tripped, and nothing is lost by ignoring them.

## The size cap has a mechanism behind it

`kMaxSnapshotBytes` is 64 KiB because every reader is the memory-constrained
side of its own boundary: Wear OS rejects a `DataItem` above 100 KB outright,
Android widget updates cross a Binder transaction with a ~1 MB budget *shared
with every other transaction in flight*, and a WidgetKit extension that decodes
megabytes stops being scheduled. `encode` drops rows from the end until it fits
rather than emitting a payload the reader will refuse — half a list is a widget,
a rejected payload is a blank rectangle — and `decode` enforces the cap again,
because the writer is the process with memory to spare.

## What it must not re-derive

Four facts belong to the app and are carried, never recomputed:

1. `Chat.id` as the row key — `merged:<contactId>` or a room id. Re-deriving it
   splits a merged conversation into two rows counting half the unread each.
2. `chatDeepLink(chatId)` for the tap target, built in Dart and consumed by
   Glance's intent and WidgetKit's `widgetURL`. One escape apart and the link
   opens nothing.
3. `ChatNetwork.id` for exclusions, and `brandColor` as an int in the payload's
   `palette` so no platform keeps a second colour table.
4. `Chat.sendNetwork` — which is what a watch reply sends on, and the reason the
   phone-side reply handler must reject a chat id it does not recognise. A
   merged chat reverts to a plain room id when a leg is left, and a widget
   process can hold the old id for hours.
