---
type: reference
title: Encrypted Backup and Restore
created: 2026-08-28
tags:
  - backup
  - encryption
  - storage
related:
  - '[[multi-device]]'
  - '[[attachment-pipeline]]'
---

# Encrypted Backup and Restore

Braid holds conversations from every network in one local store. That is the
product, and it is also the exposure: the unified view — which handles are the
same person, what a bridge relayed before it was shut down, a voice note
transcribed once and paid for once — exists nowhere but on the device. A
homeserver can hand back Matrix rooms. It cannot hand back the merges.

This document describes the `.braid` archive: one encrypted file, all networks,
media optional, key derived from a passphrase, written and read through the
share sheet and the file picker with no cloud dependency anywhere in it.

Three packages, and the split is deliberate:

| package | owns | knows nothing about |
| --- | --- | --- |
| `weft_backup` | the container, the crypto, the merge rules | SQL, Flutter, disks |
| `weft_store` | the adapters onto Braid's actual tables | the container's bytes |
| `apps/weft` | the screens, the file dialogs, the share sheet | either of the above's internals |

`weft_backup` is pure Dart with no Flutter dependency, which is what lets the
format be decided in one `dart test` file rather than on a device. The SQL lives
next to the migrations that define the schema. Nothing in the app layer parses a
byte.

## The container, byte by byte

Big-endian throughout, so a hex dump reads left to right and a hand-written
reader on another platform does not have to guess.

```text
┌─ plaintext header ────────────────────────────────────────────────┐
│ magic          8 bytes    "BRAIDBAK"                              │
│ headerLength   4 bytes    uint32                                  │
│ headerJson     headerLength bytes, UTF-8                          │
└───────────────────────────────────────────────────────────────────┘
┌─ body: one or more frames ────────────────────────────────────────┐
│ frameLength    4 bytes    uint32, ciphertext ‖ tag                │
│ finalFlag      1 byte     0 = more frames, 1 = the last one       │
│ frame          frameLength bytes                                  │
│ …repeated…                                                        │
└───────────────────────────────────────────────────────────────────┘
```

`headerJson`:

```json
{
  "format":  {"major": 1, "minor": 0},
  "kdf":     {"id": "argon2id", "salt": "<b64, 16 bytes>",
              "memoryKiB": 65536, "iterations": 3,
              "parallelism": 1, "keyLength": 32},
  "cipher":  {"id": "xchacha20-poly1305",
              "noncePrefix": "<b64, 16 bytes>", "frameSize": 1048576},
  "preview": {"createdAt": 1756374600000, "appVersion": "1.0.0",
              "chatCount": 12, "messageCount": 4300,
              "mediaIncluded": true, "totalBytes": 128000000}
}
```

The concatenated *plaintexts* of every frame form one byte stream, chunked by
size alone and without regard to record boundaries — a 400 MB video spans four
hundred frames and no frame ever holds more than its size. That stream is:

```text
manifestLength  uint32
manifestJson    …                 ← the manifest, encrypted
recordLength    uint32            ← 0 terminates the stream
recordJson      recordLength bytes
blobLength      uint32            ← 0 for everything but media
blob            blobLength bytes
…repeated…
0               uint32            ← the terminator, inside the ciphertext
```

The terminator is encrypted rather than implied by end-of-file, so a truncated
archive fails on content as well as on the final-frame flag. Two independent
checks for the same attack, because the cost is four bytes.

## The crypto, and why each piece

### Argon2id from the passphrase

Memory-hard, because the threat is an offline guessing attack against a file the
user has deliberately put somewhere durable. Parameters: **64 MiB, 3 passes, 1
lane** — RFC 9106's second recommended option. Chosen against the weakest device
Braid supports rather than the fastest: this runs on a mid-range Android phone,
in a foreground isolate, while the user watches a spinner. The first recommended
option's 2 GiB would make export impossible on the devices that most need a
backup.

**Every parameter is in the header, not in a constant.** That is the whole point
of serialising them: the cost should climb as phones get faster, and an archive
written in 2026 must still open on the build that climbed. A constant here would
mean either never raising the cost or silently failing to open old files.

The passphrase is **not** Unicode-normalised. Normalising is the kind of
helpfulness that turns into a locked archive: a passphrase typed on one keyboard
and normalised by one build, then typed identically on another whose Unicode
tables have moved, derives a different key with nothing to say why. The bytes
the user typed are the bytes that are hashed.

### XChaCha20-Poly1305 over frames

XChaCha20 rather than ChaCha20 or AES-GCM for one reason: its 24-byte nonce is
long enough that **16 random bytes plus an 8-byte counter** is safe. One derived
key can then encrypt 2^64 frames with no nonce ever repeating, and there is no
sequence number to persist and no birthday bound to reason about.

Per frame:

- **nonce** = `noncePrefix ‖ uint64BE(frameIndex)`
- **associated data** = `headerBytes ‖ uint64BE(frameIndex) ‖ finalFlag`

Each part of the AAD buys something specific:

- **`headerBytes`.** The header has no MAC of its own. Binding it here is what
  makes tampering with it fail — including the attack the whole scheme turns on,
  which is rewriting `memoryKiB` down to nothing so the passphrase can be
  brute-forced cheaply. It fails twice over: a different key, and a header that
  no longer matches the AAD. The bytes are kept *verbatim* from disk rather than
  re-encoded, because re-encoding could not reproduce a future writer's key
  order and would fail every frame of exactly the archives the version policy
  promises still open.
- **`frameIndex`.** Frames cannot be reordered or replayed, so an attacker
  cannot rearrange a conversation without the key.
- **`finalFlag`.** Truncation is the one attack an AEAD does not catch by
  itself: every frame of a shortened archive authenticates perfectly, the file
  is simply missing its end. The last frame is sealed with a flag of 1 and every
  other with 0, and a reader that reaches end-of-file without having opened a
  final frame reports a truncated archive. Cutting an archive short and
  re-flagging the new last frame requires the key.

### The library

`package:cryptography` 2.9, both primitives in pure Dart. A new dependency,
taken deliberately: the workspace had no crypto library to reuse — the Matrix
SDK does its own in Rust behind `flutter_vodozemac`, which is a Flutter plugin
and therefore unreachable from a package that must run under plain `dart test`.
The alternative was a hand-written memory-hard KDF and a hand-written AEAD,
which is not a thing to do to hold someone's entire message history.

### Neither the passphrase nor the derived key is ever written down

Not to logs, not to settings, not to a crash report. `ArchiveKey.toString()`
returns `ArchiveKey(<redacted>)` — overridden while the class holds nothing
sensitive to print, so that a future field cannot start leaking through every
log line that interpolated one.

## What is public, and what is not

The restore screen has to show something before it asks for a passphrase: a file
picker hands back a name and nothing else, and asking someone to unlock a file
to find out whether it is the one they meant is how they unlock the wrong one.
So a few facts sit outside the ciphertext, and the boundary is drawn on one
question — **is this already inferable from the file's size?**

| fact | where | why |
| --- | --- | --- |
| created-at, app version | plaintext header | Identifies the file. Neither says anything about the person. |
| chat count, message count, total size | plaintext header | Approximately readable off the byte count already. |
| media included | plaintext header | Same — a media-bearing archive is orders of magnitude larger. |
| **network list** | **encrypted manifest** | **Not recoverable from size.** "This person has a Signal account" is a fact worth protecting on its own. |
| media count, media bytes | encrypted manifest | Kept with the network list rather than split out for one field. |

The consequence for the UI is that a restore reveals in two steps: the header
before the passphrase, the manifest after it and before anything is written.
That is a better flow anyway — the second step is the last chance to back out,
and it should be the one with the detail in it.

## Versioning: degrade, don't refuse

`kBraidArchiveFormatVersion` is a **major/minor** pair, and the two halves have
opposite policies because they deserve opposite advice.

- **A higher minor is read normally.** Minor is bumped for additions only: a new
  record type, a new field on an existing record, a new manifest entry. Readers
  skip record types they do not know and ignore fields they do not know, exactly
  as `SnapshotCodec.decode` ignores unknown keys. An archive is never rejected
  for containing more than the reader was taught. "Update Braid and try again"
  would be a lie here — the restore already worked.
- **A higher major is refused**, with a typed failure naming the version. Major
  is reserved for a change to the *container* — the framing, the AEAD
  construction, the order of the header — which a reader cannot skip past
  because it cannot find where the next thing starts. Refusing loudly is the
  honest answer; the alternative is a half-decoded restore that looks like it
  worked.

Skipped records are **counted and reported**, not swallowed. The restore summary
says "12 entries were written by a newer version of Braid and could not be
read". A user who believes they have a complete copy when they do not is exactly
who this feature exists to protect.

Every number that arrives from an unauthenticated header is bounds-checked
before it sizes an allocation. A `memoryKiB` of 2^31 is an out-of-memory kill
dressed up as a backup file, and the reader is the process that dies of it —
which is the reason `SnapshotCodec` caps its payload on both sides too.

## What an archive holds

Braid's own database, table by table:

| table | in an archive | why |
| --- | --- | --- |
| `unified_contact` | yes | the identity graph |
| `network_handle` | yes | the identity graph |
| `merge_decision` | yes | irreplaceable; exists nowhere else |
| `chat_prefs` | yes | a user decision |
| `settings` | yes, filtered | minus the device-scoped keys below |
| `search_message` | yes | **the message history itself** |
| `transcript` | yes | paid for once, in inference or in money |
| `search_fts` | no | rebuilt by triggers on insert |
| `search_embedding` | no | derived, model-specific, larger than everything else |
| `embedding_queue` | no | re-queued on restore |
| `link_preview` | no | a cache, and a log of which links you were sent |

Plus, on disk, the staged attachments under `<support>/media/<event>/<name>`.

**`search_message` is the history.** That deserves saying plainly, because the
name suggests an index. Braid keeps no second copy of the Matrix timeline — the
SDK's database has that — but the SDK's database holds *rooms*, not the
cross-network view, and it is protocol state full of device keys. `search_message`
is where Braid's own answer to "what was said, by whom, on which network, in
which unified chat" lives, and that answer is what stops existing once a bridge
is gone.

Two settings keys are excluded by name, in `kSettingsExcludedFromBackup`. Not
secrets — those live in the platform keychain via `SecretStore` and were never in
this table — but facts true of *one device*:

- `notify.push_key`, because restoring it onto a second phone makes that phone
  believe it owns a pusher registered by the first, and the rotation logic then
  deletes a live pusher belonging to a device still using it. The user sees
  notifications stop.
- `notify.permission_asked`, because both platforms give an app exactly one
  prompt and restoring a `true` onto a fresh install spends that chance without
  ever showing the rationale sheet.

## What an archive deliberately does not hold

**No E2EE device keys. No access tokens. No bridge credentials.**

This is the design, not a limitation, and it is the line between the two things
people mean by "backup":

- *Restoring history* is getting your conversations back onto a device. That is
  what this archive does.
- *Cloning a session* is becoming your account on a new device. That needs
  device keys and an access token, and an archive carrying them would be a file
  that logs anyone who opens it into your Matrix account, reads your encrypted
  rooms, and appears on your device list — protected by whatever passphrase
  someone chose while impatient to finish a settings screen.

Matrix already answers the second question properly, with cross-signing and
server-side key backup, where losing the recovery key does not also lose the
history. See [[multi-device]]. Duplicating it here, in a file the user emails to
themselves, would undo it.

Stated plainly because the restore screen has to say it: a restored archive
gives back what Braid knew — the messages, who said them, which network they
arrived on, the merges, the settings, the media — and does **not** give back the
ability to decrypt anything new from the homeserver. That still comes from
Matrix key backup.

## Merge versus replace

**Merge is the default, and it is `INSERT … ON CONFLICT DO NOTHING` everywhere.**
An existing row wins over the archive's. That is the only choice that makes
importing the same file twice a no-op *and* makes importing an old backup into a
live store safe: the alternative — the archive overwriting — would make
restoring a six-month-old backup silently roll back six months of display names,
merge verdicts and settings.

Messages are keyed on **`(roomId, eventId)`**, not `eventId` alone. That is the
pair the `search_message` unique index uses and the pair a bridge can repeat: the
same remote message backfilled into two rooms is two rows, and collapsing them
would delete one of them on every restore.

**Replace** empties the tables the archive covers and then inserts. It is the
only mode that can lose data, which is why the UI asks twice and the second
dialog spells out what goes. It clears only what the archive carries —
`link_preview` is not the archive's to clear.

The whole import runs inside one SQLite transaction, opened before the first
record and rolled back on any failure including cancellation. An interrupted
restore leaves the store exactly as it was, rather than in the half-populated
state that would be indistinguishable from a successful restore of a truncated
archive.

Files are the one thing not in the transaction, unavoidably. Media is written to
a content-addressed staging directory and only copied into place once its bytes
are complete, so a rollback leaves orphaned *content* that nothing references
rather than a half-written photo that something does. The staging directory is
swept on both commit and rollback.

### Media

Content-addressed by SHA-256 and deduplicated at export: the same photo
forwarded into four chats is stored once. A `media` record carries the bytes; a
`media_ref` record says which event folder and file name they belong to, and
four refs can point at one blob. A `media_ref` naming a hash the archive did not
carry — because media was excluded, or because the sink already had those bytes
— is skipped without touching the message that references it. The attachment
simply is not on disk, and the viewer re-downloads it the way it would for any
attachment it has not staged yet.

File names from an archive are re-sanitised on the way in. The writer sanitised
them, but an archive is an untrusted file and `../../` in either the folder or
the name would otherwise decide where a restore writes.

### After a restore

Restored messages get an FTS row for free — the `search_message_ai` trigger sees
to that — but no embedding, because nothing called `SearchStore.indexMessage`.
The sink therefore re-queues every unembedded row on commit. Without it, semantic
search would have a hole in it exactly where the restored history is, and nothing
would ever notice.

## Failure taxonomy

Typed, and the types are the point. Every one gets a different sentence and a
different next action; collapsing them — which is what happens if the only
signal is an exception from the cipher — produces the single worst message this
feature could show: *"could not restore"*, to someone holding the only copy of
their history.

| failure | what happened | what the user should do |
| --- | --- | --- |
| `NotAnArchiveFailure` | no magic bytes | pick a different file |
| `MalformedArchiveFailure` | header does not parse | the file is damaged near its start |
| `UnsupportedVersionFailure` | major above this build's | update Braid |
| `WrongPassphraseFailure` | first frame failed to authenticate | check the passphrase |
| `TruncatedArchiveFailure` | file ends before its final frame | let a cloud download finish, then retry |
| `DamagedArchiveFailure` | a later frame failed to authenticate | try another copy |

The split between the last three is worth dwelling on. **Frame zero is the
passphrase check**: a failure there is reported as a wrong passphrase, which is
overwhelmingly what it is, and the alternative — an edited header — is not
something the user can act on differently. A failure at any *later* frame means
the key already opened a frame, so the passphrase was right and the file is not.
Reporting that as "wrong passphrase" would send someone to retype a passphrase
they already have correct, over and over, on the day they most need it to work.

## Test coverage

- `packages/weft_backup/test/format_test.dart` — the header: round trip, the
  version policy in both directions, and every out-of-range parameter that would
  otherwise be an allocation.
- `packages/weft_backup/test/crypto_test.dart` — key derivation, the three
  things the associated data buys, and that two frames of identical plaintext
  never produce identical bytes.
- `packages/weft_backup/test/round_trip_test.dart` — full fidelity across every
  record type, merge idempotence, media dedup, each typed failure, forward
  compatibility, and a 32 MB streaming case that would blow memory if the
  archive were loaded whole.
- `packages/weft_store/test/backup_adapter_test.dart` — the SQL: every table in
  or deliberately out, merge as `DO NOTHING`, rollback, and that a hostile file
  name cannot escape the media root.
- `apps/weft/test/backup_screen_test.dart` — the flows, and that each typed
  failure surfaces as its own localized sentence.
- `apps/weft/test/goldens/backup_golden_test.dart` — the screen in both themes
  under the Phase 04 accessibility variants, plus the passphrase dialog and the
  replace confirmation, which are claims about ink rather than about strings.
