# weft_attachments

The pure-Dart core of Weft's attachment pipeline.

- **Detection** — magic-byte mime sniffing and header-only dimension probing.
  The sniffed type wins over the declared one, because share intents routinely
  claim `*/*`. Every function is total: truncated input returns a fallback, not
  an exception.
- **Planning** — one `UploadPlan` per attachment, resolving `MessageKind`,
  msgtype, thumbnail decision, and the exact `m.room.message` content map. Plain
  and encrypted rooms produce deliberately different shapes.
- **Queue** — bounded concurrency, FIFO within a chat, exponential backoff, and a
  broadcast stream of task state. A failed upload stays in the queue with its
  plan intact so the UI can offer a retry.

No Flutter, no `dart:io`, no codegen. Transport is injected through
`AttachmentTransport`; the only thing that touches the disk is
`bin/plan.dart`, the CLI that prints what Weft would send for a real file.

```sh
dart run weft_attachments:plan path/to/file.png --encrypted
```
