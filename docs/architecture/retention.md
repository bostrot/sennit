---
type: reference
title: Disappearing Messages
created: 2026-09-07
tags:
  - privacy
  - storage
  - messaging
related:
  - '[[backup-restore]]'
  - '[[attachment-pipeline]]'
---

# Disappearing Messages

A conversation can be set to erase its own messages after a while — an hour, a
day, ninety days — counted either from when a message arrived or from when the
user read the chat past it. Off for every chat until somebody turns it on.

## What "delete" means, and where it stops

Two different things, and the interface says so before it offers a window,
because assuming the stronger one is a privacy mistake a user cannot undo:

| whose message | what happens | reaches |
| --- | --- | --- |
| the user's own | redacted | everyone on the homeserver, and onward through each bridge as that network's own delete-for-everyone |
| anybody else's | forgotten locally | this device only |

Nobody else's copy is Braid's to delete. A client that claimed otherwise would
be lying about the one thing a disappearing message is asked to do.

**Incoming disappearing messages already work and are not this feature.**
WhatsApp's own timer is enforced by WhatsApp; when a message expires there,
mautrix-whatsapp redacts it in the Matrix room and Braid renders the redaction
like any other. What is *not* implemented is setting a remote network's native
timer from Braid — the bridges expose no such control over the Matrix API, only
through bot commands that differ per bridge and per version.

## The pieces

| where | what |
| --- | --- |
| `weft_domain/src/retention.dart` | `RetentionPolicy` — a window, an anchor, and the arithmetic of when a message falls due. Pure. |
| `settings` key `privacy.retention` | every chat with a policy, as one JSON blob. In `settings` rather than in a table so a backup carries it — see [[backup-restore]]. |
| `chat_read_mark` (v6) | one row per read: at `read_at`, the chat had been read as far as `up_to_ms`. |
| `purged_event` (v6) | one row per deleted event. Device-local, never in an archive. |
| `weft_store/src/retention_store.dart` | the queries over both, including the one that turns the read anchor into a single cutoff. |
| `services/retention/retention_sweeper.dart` | the pass that redacts, forgets and prunes. |
| `features/chat/retention_sheet.dart` | the picker, reached from the contact profile. |

## The sweep

Runs a minute after sign-in and every minute after that, and again whenever a
chat is opened — the clock does not stop when the app does, so a chat set to
erase after an hour has a night's worth of messages due before its first bubble
draws. A dormant install returns before it touches the database.

Candidates come from `search_message`, which is Braid's own record of what was
said — not from a Matrix timeline, which is an async SDK object that exists only
for a chat somebody has looked at. That is what lets one pass cover every chat
at startup. The cost is the record's own boundary: a message Braid never indexed
is not swept, which in practice means a message with no text at all.

For each due message: the user's own is redacted first, and only then dropped
locally. That order is load-bearing — purging first would throw away the only
record that a redaction still has to happen, and the message would stay on the
peer's phone forever with nothing left here to notice. A redaction that fails
for a reason that might not recur defers the whole message to the next pass; one
the room no longer holds does not, because it will never hold it again.

Forgetting a message means, in order: a tombstone in `purged_event`, the event
out of the Matrix SDK's database, the row out of `search_message`, and the
staged bytes out of `<support>/media/<event>/`. Tombstone first, so a pass that
dies halfway leaves a message hidden rather than half-deleted.

## Why a tombstone at all

Because deleting the local copy does not stop the homeserver from serving it
back. The next backfill of that room would hand Braid the event again, the
mapper would turn it into a message, and the indexer would re-file the words the
user was told had gone. `MatrixTimelineSource` reads the room's tombstones when
the timeline opens and skips those events at the *mapper*, so a purged event
never becomes a `WeftMessage` — and therefore cannot be indexed, notified on, or
quoted in a reply preview either.

Tombstones are deliberately absent from a backup. They are a fact about one
device's copy of a room, and a restore onto a fresh device re-syncs from the
server regardless.

## The read anchor

"Delete an hour after I read it" needs to know when each message was read, which
a single moving watermark cannot answer: a message read a week ago would restart
its hour every time the chat was opened. Hence a row per read.

The query does not join message against mark. A read mark whose own `read_at` is
already older than the window has *ripened* — everything it covers is due,
because a message's read stamp is the earliest mark covering it and so is no
later than that one's. The largest `up_to_ms` among ripened marks is therefore a
single timestamp cutoff, which the existing `(chat_id, timestamp)` index answers
directly.

A message nobody has read never expires. That is not a gap: a messenger that
deleted mail before it was read would be losing it.
