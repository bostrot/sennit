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
| Merge engine — identity graph, scoring, merged timeline | **Done**, persisted, 54 tests |
| Matrix session — login, E2EE, device verification, media upload transport | **Done**, 82 unit + 5 integration tests |
| Attachments — sniffing, upload plan, bounded queue, Matrix upload transport, repository send path with ordered event sends | **Done**, 149 + 37 tests |
| Attachment UI — attach button, source sheet, pre-send preview, image/video/audio/file bubbles, upload progress with cancel and retry | **Done**, 21 widget tests. The full-screen viewer is not built. |
| App shell — rail, inbox, chat, composer, live or demo data | **Done** |
| Hybrid search — FTS5 + vectors + RRF, **wired**: search screen, ingest-on-read, backfill | **Done**, 63 tests |
| Transcription — **wired**: Transcribe action on voice bubbles, endpoint settings, privacy gate | **Done**, 15 tests |
| Bridges — **wired**: bridges screen, health probes, generic GUI login flows | **Done**, 21 tests. QR flows show a copyable code, not yet a rendered QR image. |
| MCP — **wired**: HTTP server (loopback), keys UI, scopes, audit view, tunnel toggle | **Done**, 36 tests |
| Deep links — weft:// + App Links parsing/routing, Android filters, Apple scheme | **Done**, 12 tests. Domain verification needs the files in `tooling/web` hosted. |
| Share-in — Android SEND/SEND_MULTIPLE, cold-start replay, share-target sheet | **Done** for text; file upload awaits the attachment pipeline |
| Merge management UI — suggestions with evidence, accept/reject, unmerge | **Done**, 4 widget tests |
| Bridge QR login — rendered QR + copyable payload, re-transcribe language picker, auto-transcribe | **Done** |
| iOS Share Extension, Direct Share/People API, notifications, widgets, watch | **Not built** — needs Xcode targets and signing |
| Calling, SMS/default-app, rich content, multi-device extras (M9) | **Not built** |
| Patrol device matrix, a11y/RTL passes (M10) | **Not built** — needs devices; the logic under it is unit-tested |

**513 tests pass** (plus 5 integration tests against a live Synapse). Verified builds: macOS app and Android APK (all four ABIs, including the vodozemac Rust cross-compile), and the app has been run on a physical Galaxy S25 (One UI, Android 16) with deep-link and share intents fired at it over adb.

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
> pinned to 37 for `flutter_secure_storage`.

## Testing

```bash
cd packages/weft_merge && dart test
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

Regenerate goldens after an intentional visual change:

```bash
cd apps/weft && flutter test test/goldens --update-goldens
```

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
  weft_matrix/              Matrix SDK wrapper: session, E2EE, verification
  weft_store/               SQLite: identity graph, settings, FTS5 + vectors
  weft_mcp/                 MCP server + cloudflared supervisor
  weft_design/              tokens, themes, components
docs/architecture/          design notes for the subsystems worth explaining
tooling/docker/             disposable Synapse for tests
```

`weft_attachments`, `weft_domain`, `weft_merge`, `weft_search`, `weft_bridges`,
`weft_transcribe` and `weft_mcp` are **pure Dart** — no Flutter, no I/O. That is deliberate: the
subtle logic lives there and runs under `dart test` in about a second, with no
device and no homeserver.

Longer-form design notes live in `docs/architecture/` —
[the attachment pipeline](docs/architecture/attachment-pipeline.md) covers
sniff-first detection, the plain-vs-encrypted event shapes, and why the upload
queue bounds concurrency.

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
