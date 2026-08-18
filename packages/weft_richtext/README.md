# weft_richtext

Matrix's rich content, turned into values.

A formatted body looks like a small problem and is not. The HTML is untrusted —
it arrives from bridged networks, from clients Weft has never seen, and from
anyone who can get an event into a room. The reply fallback duplicates the quote
in two places and has to be removed from both or the bubble shows it twice. A
mention arrives in four spellings. None of that is a platform call; all of it is
a decision, and decisions belong somewhere they can be tested exhaustively
without a widget tree in the way.

The other reason this is a package rather than a file in the chat feature: the
renderer is not the only consumer. `RichDocument.plainText` is the projection the
search index and the notification layer take, so a message written as
`<b>fire</b>` is findable by "fire" and notifies as "fire" rather than as markup.
Were the model Flutter's `TextSpan`, those two would have to re-parse the HTML
themselves — three allowlists to keep in step instead of one.

- **`RichSpan` / `RichDocument`** — a platform-free document tree: text runs with
  style flags, links, mentions, images, and the seven block kinds the timeline
  can actually draw.
- **`parseFormattedBody`** — `org.matrix.custom.html` behind a strict allowlist.
- **`stripReplyFallback`** — removes the `> <@alice:example.org>` lines and the
  `<mx-reply>` block.
- **`parseMentions` / `mentionTargetFromUrl`** — resolves `matrix.to` permalinks,
  `matrix:` uris and `@room`.

No Flutter, no I/O. The renderer that turns a `RichSpan` into a `TextSpan` lives
in `apps/weft/lib/features/chat/`.

## The allowlist is the security boundary

`parseFormattedBody` is the one place hostile markup is stopped, and the defence
is layered so that no single oversight is fatal:

| Layer | What it stops |
| --- | --- |
| The shape of `RichSpan` | An `onerror=`, `style=` or `srcdoc=` has **nowhere to land** — no node has a field that holds an arbitrary attribute, so an attribute the walk forgot to ignore still cannot survive. |
| `_droppedSubtrees` | `<script>`, `<style>`, `<iframe>`, `<svg>`, `<form>` and friends are removed *with their contents*, so a payload never reaches the bubble or the search index as visible text. |
| `sanitizeUrl` | An `href` outside http/https/mailto/matrix never becomes a `RichLink`. The existence of a `RichLink` is the guarantee — a renderer may make every one of them tappable without re-checking. |
| `sanitizeMxcUrl` | An `<img>` with a remote `src` is dropped rather than fetched. A remote src is a tracking pixel: it fires when the timeline scrolls past it and reports the reader's IP to a server they never chose. |

Two deliberate choices inside that:

**Unwrap, don't drop.** A tag that is merely unrecognised — `<font>`, some
bridge's private wrapper, `<sup>` — loses its meaning and keeps its text,
because that text is the message. Only the subtree list above loses its content,
because there the content is a program rather than prose.

**A refused link keeps its words.** `<a href="javascript:…">click me</a>` renders
as the inert text "click me". Dropping it would hide what the sender wrote;
keeping it un-tappable shows the reader everything and lets them act on nothing.

The scheme list is *narrower* than the spec's, which also permits `ftp` and
`magnet`. Weft hands urls to the platform launcher, where `magnet:` means "open
a torrent client with a payload chosen by whoever bridged into this room".

## Why the fallback needs a user id, not a `>`

A reply's body opens with the quoted message as `>` lines so that a client which
knows nothing about replies still shows its reader the context. Weft draws a real
reply chip, so those lines have to go — but "starts with `>`" is not the test.
`> to be or not to be` is a message, not a fallback. The header line must name a
sender (`> <@alice:example.org> …`, or `> * <@alice:example.org> …` for an
emote); once it does, the whole leading run of `>` lines goes, which takes nested
quotes with it for free.

## Whitespace

Text outside `<pre>` has its whitespace collapsed and block edges trimmed, so a
pretty-printed formatted body does not render with the sender's source
indentation baked into the bubble. Inside `<pre>` it is content and is kept
verbatim.
