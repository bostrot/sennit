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

It reads at most the first 64 KiB of the file and prints the sniffed mime type,
the `MessageKind`, the dimensions it could read from the header, the thumbnail
decision, and the pretty-printed `m.room.message` content — with the mxc URI and
key material stubbed, since neither exists until the homeserver and the crypto
layer have run. `--mime=<type>` simulates a share intent's claim, `--voice` and
`--duration-ms` stand in for the recorder, `--max-bytes` for the homeserver's
`m.upload.size`, and `--json` prints the content alone for piping into `jq`.
It exits 0 when it planned, 1 on a usage or read error, and 2 when the file was
rejected.
