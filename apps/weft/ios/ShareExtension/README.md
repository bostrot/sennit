# Weft Share Extension

The iOS half of Phase 04's share surfaces. Registered in `Runner.xcodeproj` and
built by `flutter build ios`; what it still needs from you is signing material,
and only that.

| File | What it is |
| --- | --- |
| `ShareViewController.swift` | The whole extension: capture, picker, staging write |
| `Info.plist` | `com.apple.share-services`, and the activation rule that decides when iOS offers Weft |
| `ShareExtension.entitlements` | The App Group, `group.com.bostrot.weft` |
| `ShareExtension-{Debug,Release}.xcconfig` | Optional CocoaPods include + the Flutter version pair |
| `../Shared/ShareContainer.swift` | Container layout and the filename sanitiser, compiled into **both** this target and Runner |
| `../Runner/ShareChannel.swift` | The other side: the host app's drain, over `com.bostrot.weft/share` |

## What it does, and the one thing it does not

It copies the shared items into the App Group container, optionally asks which
conversation, writes one `StagedShare` JSON blob beside the files, and completes.
It never talks to Matrix. It cannot: the session lives in the host app's keychain
and its sync loop in the host app's process, and an extension runs under a memory
ceiling well below what decrypting a room costs. The host app drains the blob on
next launch or resume and sends from there.

The wire format is `ShareStagingCodec` in `packages/weft_share` — **hand-written
on this side**, with no compiler checking the key names against the Dart class.
Renaming a key there is a silent break here.

## Container layout

```
group.com.bostrot.weft/
  share/
    targets.json          written by the host app, read by the picker
    staged/
      <id>.json           one StagedShare
      <id>/               its files, named "<index>-<name>"
```

`StagedFile.relativePath` is relative to the container root, never absolute:
`containerURL(forSecurityApplicationGroupIdentifier:)` returns a *different*
absolute path in each process, so a path written here is not one the app can
open.

## Ordering, and what a kill leaves behind

The system can kill an extension between any two writes. Two rules cover it:

- **Files first, blob last.** A blob that exists names files that are already
  there. The reverse is the only shape the reader could not tell from a valid
  share, so it is made unreachable rather than handled.
- **The blob is written atomically.** `ShareStagingCodec.decode` tolerates a
  truncated blob and that tolerance is tested against every prefix — it is not
  weakened by this, it is simply not the case that is left to it. What is left to
  it is the kill *between* the two steps: an orphaned `<id>/` directory with no
  blob, invisible to the decoder and swept by the drain.

## The drain

`Runner/ShareChannel.swift` is the reading side, driven by
`lib/services/share/staged_share_reader.dart` on launch and on every resume. It
hands the blobs over **unparsed**: `ShareStagingCodec` is the only decoder,
it is total by construction and exhaustively tested, and a second hand-written
parse in Swift would be a second thing to keep in step with a format neither
language checks.

Ingesting a share moves its files out of the container and into the app's own
caches (`weft-share/<id>/`, matching Android's `SHARE_CACHE_DIR`) under the
names the blob gave them — a same-volume move is a rename, so a shared video
costs nothing to take ownership of, and the `<index>-` prefix the container
needed for uniqueness does not reach the room as a filename.

**The blob is deleted before anything moves.** That ordering is what makes the
drain idempotent: once the app has committed to a share, a resume racing a
launch must not find it again. A kill in between leaves an orphaned `<id>/`
directory, which the next drain's sweep collects once it is past the 24-hour
TTL — and only past it, because a capture happening *right now* while the app
is being resumed looks identical from the reading side.

## Signing

Nothing here is signed and nothing here can be. Two bundle ids need provisioning
profiles and one App Group needs creating on the developer portal:

- `com.bostrot.weft` — Runner, now carrying `Runner/Runner.entitlements`
- `com.bostrot.weft.ShareExtension` — this target
- `group.com.bostrot.weft` — the group both must be entitled to

`docs/decisions/adr-002-ios-signing-handoff.md` spells out the steps. Until they
are done, `flutter build ios --no-codesign` builds this target and a device build
does not.
