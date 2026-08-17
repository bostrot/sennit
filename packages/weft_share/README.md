# weft_share

The pure-Dart core of Weft's share surfaces.

Android publishes conversation shortcuts through the People API. iOS runs a
Share Extension in a separate process that has no Matrix session and a hard
memory ceiling. The two have nothing in common as mechanisms — and exactly two
questions in common as *products*: which conversations do we offer and in what
order, and what shape does a captured share take while it waits for the app.
Both are decisions rather than platform calls, so both live here and are tested
without a device.

- **Ranking** — `ShareTargetRanker` orders chats by pinned state (a tier, not a
  bonus), decayed recency, and a decayed-then-saturated send count, with a
  deterministic tie-break so an inbox where everything scores zero does not
  reshuffle on every tick.
- **Capability** — `NetworkShareCapabilities` is the per-network table of what a
  remote network will actually take. It removes targets; it never reorders them.
  A Bluesky-only chat is not a target for a 90 MB video. Unknown networks are
  permissive: knowing nothing is not a reason to hide someone's conversation.
- **Slots** — `ShareTargetSlot` is the published shape shared by the Android
  shortcut, the iOS picker row and the in-app sheet. Its id is the same string
  Phase 03's notification `MessagingStyle` names, so a bubble and a share target
  are one shortcut.
- **Staging** — `StagedShare` and `ShareStagingCodec` are the App Group
  container's contract, with a decoder that is total by construction.

No Flutter, no `dart:io`, no method channels. The publishers that do live in
`apps/weft/lib/services/share/`.

## Three caps, three layers

A shared file passes three independent size limits, and none of them replaces
the others:

| Limit | Who enforces it | What it protects |
| --- | --- | --- |
| `kMaxSharedFileBytes` (100 MiB) | `WeftIntents` in the app | the device — a share has to be *copied* out of its `content://` grant |
| `NetworkShareCapability.maxAttachmentBytes` | this package | the user's time — a Signal leg that will refuse the file |
| the homeserver's `m.upload.size` | `planUpload` in `weft_attachments` | the upload itself |

## Why the decoder never throws

The writer of a staged share is a process the system can kill at any instant,
including between the first byte of the file and the last. The reader runs on
the host app's launch path. A decoder that throws on a truncated blob turns a
share the user has already forgotten about into an app that will not start —
and will not start again, because the blob that killed it is still sitting in
the container. So an unreadable share is dropped, and dropping is the documented
contract rather than a side effect of a `try` somewhere. The caller deletes what
`decode` refused.

Truncation is only half of it. The writer is hand-written Swift with no
compiler checking these key names, so a value can arrive with the wrong *type*
as easily as with the wrong length — a `files` that is a string, a `targets`
that is a number. Those are read through a guard rather than a cast, because a
cast raises a `TypeError`, which is not a `FormatException` and so is not
caught by the parse guard that surrounds it. `staging_test.dart` pins this by
decoding **every prefix** of a valid blob and asserting each one is dropped.

The JSON key names are a cross-language contract: `ShareViewController.swift`
writes them by hand, with no Dart on the other side. Renaming one here is a
silent break there.
