---
type: architecture
title: Rich Content
created: 2026-08-18
tags:
  - richtext
  - matrix
  - reactions
  - privacy
related:
  - '[[Merged-Timeline]]'
  - '[[Notifications]]'
  - '[[Attachment-Pipeline]]'
---

# Rich Content

Replies, reactions, edits, mentions, formatted bodies and link previews are the
furniture of a conversation — the parts nobody notices until they are missing.
They are also, taken together, the largest surface in Weft where **text written
by a stranger becomes something the app interprets**: a formatted body is HTML
from a bridge or a client nobody has audited, a reaction is an event from an
account whose identity has to be resolved before it can be counted, and a link
is a url the reader never asked to fetch.

So the shape is the one [the attachment pipeline](attachment-pipeline.md) takes
and [notifications](notifications.md) take: everything that can be decided
without a device is decided in a pure-Dart package that runs under `dart test`
in about a second. `weft_richtext` owns the allowlist, the reply fallback, the
mention resolution, the reaction tally, the edit ordering and the url
extraction — 201 tests, no widget tree — and the app above it owns pixels,
plugins and the homeserver.

| Layer | Where | What it owns |
|---|---|---|
| Parse | `packages/weft_richtext/lib/src/parse.dart`, `url_policy.dart` | `parseFormattedBody`, the tag and scheme allowlists |
| Strip | `packages/weft_richtext/lib/src/fallback.dart` | `stripReplyFallback`, `hasReplyFallback` |
| Resolve | `packages/weft_richtext/lib/src/mentions.dart` | `matrix.to` permalinks and `@room` |
| Aggregate | `packages/weft_richtext/lib/src/relations.dart` | `aggregateReactions`, `applyEdits`, `resolveReplyTarget` |
| Extract | `packages/weft_richtext/lib/src/links.dart` | Urls worth previewing, and the ones that are not |
| Map | `packages/weft_matrix/lib/src/mapping.dart` | Relations off the SDK timeline into `WeftMessage` |
| Route | `apps/weft/lib/data/matrix_chat_repository.dart` | Which *room* a relation is sent to |
| Render | `apps/weft/lib/features/chat/rich_text_view.dart` and neighbours | `RichSpan` → `TextSpan`, chips, bars, sheets |
| Proxy | `packages/weft_matrix/lib/src/link_preview.dart`, `apps/weft/lib/services/links/` | Asking the homeserver, and caching what it said |

## The allowlist is the security boundary

`parseFormattedBody` is the one function in Weft that reads untrusted markup,
and it is written as a boundary rather than as a filter. A filter has to
anticipate every payload; this anticipates none of them, because **`RichSpan`
has no field an arbitrary attribute could survive in**. There is nowhere for an
`onerror=`, a `style=` or a `srcdoc=` to land even if the walk overlooks it.
The tree carries six boolean style flags, seven block kinds, a mention target, a
link url and an image alt — and nothing else.

On top of that structural guarantee, four rules:

* **Unrecognised tags are unwrapped, not dropped.** `<font>`, `<marquee>`, some
  bridge's private wrapper: the tag's meaning goes, the text inside it stays,
  because that text is the message.
* **Some tags are dropped with their contents.** `<script>`, `<style>`,
  `<svg>`, `<iframe>`, `<form>`, `<object>` — their contents are a program, a
  stylesheet or a nested document, not prose. Unwrapping them would show the
  reader source they were never meant to see, and would put it into the search
  index.
* **`href` goes through `sanitizeUrl`**, which permits http, https, mailto and
  matrix and refuses everything else. A refused anchor keeps its text as an
  inert run: the words the sender wrote are still the message. The consequence
  the renderer leans on is that **a `RichLink` is tappable because it exists** —
  the parser is the only thing that constructs one, so there is exactly one
  place the scheme check can be got wrong.
* **`<img src>` goes through `sanitizeMxcUrl`**, so a remote tracking pixel is
  dropped rather than fetched when the timeline scrolls past it. The renderer
  draws an image's alt text and never issues a request.

Two boundaries inside the boundary are worth naming because both were bugs
before they were rules. A `<pre>` is where markup stops being *honoured*, not
where the allowlist stops *applying*: reading its content with `element.text`
concatenated every descendant, which let `<pre><code>safe();<script>alert(1)
</script></code></pre>` put the payload in the bubble and the index through the
one path that never asked. And `extractLinkUrls` skips anchors under a spoiler
and inside code: a link the sender covered must not be previewed by the reader's
homeserver in the frame it arrives, and a url in a code sample is being quoted,
not shared.

### One projection, three consumers

The tree has three consumers and only one of them draws anything. The chat
bubble renders it; the MCP server serialises it; the search index and
[notification](notifications.md) bodies take `RichDocument.plainText` off it.
All of them go through one composition — `parseMessageDocument`, and
`plainMessageText` / `plainTextOf` for the text form — for a reason that is
about the boundary rather than about tidiness: **a second "turn a body into
text" path would be a second allowlist to keep in step, and the one that skipped
`parseFormattedBody` would be the one that put `<script>` into the index.**

That is why `SearchStore.indexMessage` projects rather than its callers. It is
the single door into the index, and both the FTS row and the queued embedding
come off the column it writes. Indexing a formatted body raw is wrong twice
over: it makes `<b>fire</b>` unfindable by "fire" while making every formatted
message a hit for "strong" and "href", and it puts text the reader was never
shown into the column the search screen prints back as a snippet.

The same projection is what reaches the shade, so a notification says "the roof
is on fire" and never its tags — which matters more than it looks, because a
notification body is read aloud by TalkBack and VoiceOver. It also drops a
reply's quoted-context fallback, so a notification announces the answer instead
of the message being answered. The one place the *raw* body is still read is
`mentionsUser`: that fallback is the only trace a reply to you leaves in a body
Weft can see — `m.mentions` is dropped at mapping time and a bridged reply never
had it — and losing it would silence replies inside a muted conversation.

## Cross-network reaction dedupe

In a merged chat (see [[Merged-Timeline]]) one conversation is several rooms.
Anna reaching the user on WhatsApp and on Signal is one person with two bridge
ghosts, and if she thumbs-up a message on each leg, **that is one person
reacting once**. A tally that counted ghosts would render `👍 2` for one thumb,
and the reader would have no way to discover the second one is not a colleague
agreeing.

So `aggregateReactions` folds over annotations through a
`MergedIdentityResolver` — `String Function(String senderId)` — and counts
distinct *people*, not distinct senders. Three deliberate choices:

* **It is a parameter, not a dependency.** `weft_richtext` must not import
  `weft_merge`; the aggregation is a pure fold and the identity question belongs
  to whoever owns the graph. The app wires it to
  `IdentityGraph.contactIdForUser`; `senderIsIdentity` is the no-merge resolver
  for unmerged chats and tests.
* **Recorded merge decisions only.** `networkFromUserId`-style heuristics guess
  a network from the shape of a localpart, which is fine for choosing a glyph
  and disqualifying here. A wrong merge does not show a bad suggestion — it
  silently deletes someone's reaction.
* **The local user is resolved the same way**, so they are recognised on
  whichever leg they reacted from, and `ReactionTally.localEventId` carries
  their own annotation id, which is what un-reacting redacts.

Keys are normalised before grouping: variation selectors and skin-tone modifiers
are stripped so `👍` and `👍️` tally together. ZWJ sequences are *not* — a ZWJ
sequence is a different emoji, not a decorated one. Order is by first reaction
and never by count, because a bar that re-sorts itself moves a chip out from
under a thumb already travelling towards it.

## Relations go to the room the event is in

Sending a message in a merged chat is a choice: `sendSourceFor` picks a leg,
usually whichever one last spoke. Reacting, editing, redacting or replying is
**not a choice at all**. An annotation names an event id, and an event id that
is not in the room the annotation lands in is a relation pointing at nothing —
so every relation resolves its room from the *target event*, through a private
`_findEvent` that walks the chat's rooms, and never through `sendSourceFor`.

The failure this prevents is specific to merged chats and invisible in a
single-network one: the reader reacts to a message on the Telegram leg, the
chat's default send network is Signal, and the reaction is sent to a Signal room
that has never heard of that event. Nothing errors. The chip simply never
appears, for anyone.

Two consequences of the same rule. `unreact` takes the **annotation's** event id
rather than the message's, because that is the event being redacted and there is
no way to recover it from a tally afterwards. And `redact` passes
`redactAllEdits: true`: edits are separate events carrying the same words, so
redacting only the original would leave every version of a deleted message
readable to anyone who looks at the relations.

`sendReply` is the one relation that degrades instead of throwing. A target
nobody can find — scrolled out of every loaded timeline, in a leg the account
has left — sends a plain message rather than losing what the user typed. The
composer has already shown them the quote they were answering.

## The ticks say only what is actually known

One tick sent, two ticks delivered, two blue ticks read. The vocabulary is a
decade of WhatsApp and is not Sennit's to reinvent; what *is* Sennit's is being
honest with it, because the ticks are the most-read four pixels in a messenger
and a client that is casually wrong about them is one whose ticks stop meaning
anything.

`resolveDeliveryState` in `weft_domain` is where every rule lives, as one
function rather than a chain of conditions at the bubble: each of them is a way
of *not* claiming more than is known, and a rule that lives at a call site is a
rule the next call site will not have.

- **Matrix has no delivery receipts.** `_deliveryFor` stops at `delivered` — the
  server having echoed the event, which is the strongest guarantee at send time.
  Read is derived from `m.read` receipts, never reported.
- **The group semantic is *everyone*.** Blue ticks appear only when receipts
  cover every other participant, matching WhatsApp. A group where one person of
  nine has opened the message is not a message that has been read, and a client
  that said so would make the mark useless in exactly the conversations it is
  most looked at. This is why `ChatRepository.peerReadUpTo` returns **one entry
  per reader** rather than one per room — a list collapsed to a room's newest
  receipt cannot tell one out of nine from nine out of nine — and why the bridge
  bot is excluded from it: it is a member of every bridged room, it will never
  read anything, and counted it would satisfy a two-person group on its own.
- **An unknown group size stops at delivered.** `Chat.peerCount` is null when the
  membership has not loaded, which is ordinary for a bridged group, and one
  receipt out of nine looks exactly like one out of one. A DM is 1 by definition
  — that is what "not a group" means — so this only ever costs a group.
- **A network can only say what it has.** `deliveryCeilingFor` caps SMS and email
  at `delivered`; SMS carries a real delivery report and has no read receipts at
  all, which is what `smsDeliveryState` says from the other side. The cap is
  applied last so it can never promote a `failed` into a success.
- **Receipts switched off is not "they have not read it".** Bridges relay the
  public receipt to the remote network as its own read marker and nearly all of
  them stop relaying the other direction in return, so the user who turned the
  switch off is also the user whose blue ticks will never arrive.
  `deliveryStateIsComplete` is false there, and the bubble says so in words on
  the tooltip and in the screen-reader label rather than leaving two grey ticks
  to be misread.

The read tick's colour is corrected **per surface**, through
`WeftPalette.readReceiptOn`. It is drawn on two backgrounds that could hardly be
further apart — the inbox row's page and the own bubble's fill — and in a dark
theme those are a near-black and a pale lavender, so no single blue clears 3:1
against both. Corrected once for the page, it came out very nearly invisible on
the bubble: the most important of the five marks, and the least legible. Found by
the high-contrast golden in `delivery_golden_test`, which is also where
`colorScheme.error` turned out to be a near-white pink drawn on a near-white
bubble at 1.05:1.

## Threads are a place, and most networks do not have one

A Telegram forum topic arrives over the bridge as an `m.thread` relation, which
is why threads exist in Sennit at all: a forum group with forty topics flattened
into one stream is not a conversation anybody can read. The domain shape is
`ThreadSummary` and `ThreadGrouping` in `weft_domain`; the verb that produces
them is `groupThreads` in `weft_richtext`, beside the other relation
aggregations. `ChatView` renders both halves — the room with replies folded away
behind their roots' indicators, and, with `threadRootId` set, one thread — from
the same widget, because everything a thread needs is the machinery already
there.

### `m.thread` is not `m.in_reply_to`, and reading them as one breaks the room

Nearly every thread reply carries **both**: the spec has the sender add a reply
fallback so a client with no thread support renders the exchange as a chain
rather than losing it. `threadRootEventId` therefore reads `rel_type`, and
`replyTargetEventId` reads the nested `m.in_reply_to`, and they are separate
functions over separate keys. Read the fallback as a thread relation and every
answer in a group chat becomes a thread of its own.

The same distinction on the way out is `is_falling_back`, which is why
`sendThreadReply` takes `replyToEventId` and `threadLatestEventId` apart rather
than as one argument. An explicit reply is a quote the reader should see; a
fallback is one a thread-aware client must hide. Collapse them and every message
in a thread quotes the one directly above it, in a view where they are already
one under the other.

### Degrading is about not losing messages

Only Telegram, Discord, Slack, Mattermost and Matrix itself have somewhere to
map a thread onto — `networkSupportsThreads`. **Signal and WhatsApp have no
equivalent, and there a thread is a Matrix-side construct the remote network
never sees.** A Signal room's events can still carry `m.thread` relations: a
Matrix user in the room threaded a reply, and the bridge relayed the text
without the relation ever meaning anything on Signal's side.

So for those networks `ChatView` calls `ThreadGrouping.flatten` and every
message stays in the timeline. This is a named constructor rather than a
caller's `if` because the requirement is not "no indicator" but **no message
hidden**: an indicator nobody on that network can open, over replies nobody can
see, is worse than a flat conversation.

The same rule governs the case that has nothing to do with networks. A reply
whose root has not been paginated in **stays in the flat timeline**. Scrolling
back through a forum group reaches replies long before it reaches the roots they
hang off, and taking those out on the strength of a relation to an event nobody
can see hides them behind an indicator that does not exist. They fold in when
the root arrives.

### Naming a thread

A Matrix thread has no name — only the message it hangs off, which is what
`threadTitleFromRoot` shows in its place. A Telegram forum topic *does*, and
there is no spec key for one, so the bridges invent one; `kThreadNameKeys` lists
the spellings mautrix-telegram and the Beeper fork use, in preference order, and
`WeftMessage.threadName` carries whichever turned up. Per message rather than
only on the root, because the bridges disagree about which event they stamp.

An announced name always beats the root's words. A topic called "Bugs" labelled
with the first thing anyone said in it is a topic nobody can find again.

### Unread is counted per thread, which is the whole point

A room's badge is one number, and in a forum group it answers nothing: "68
unread" over forty topics is not something anyone can act on, where "Bugs has 3
new" is. Counting per thread needs to know where *this account* stopped reading,
which is what `ChatRepository.ownReadUpTo` is for — the other half of
`peerReadUpTo`, and a different question.

**No read marker means nothing unread, not everything.** A freshly-synced
account whose receipt has not arrived would otherwise light up every topic in
the room at once, which is indistinguishable from noise and trains the badge
away within a day. Own replies never count either, whichever device they were
sent from.

## Link previews are asked of the homeserver, never of the site

A link in a message is a thing *received*. A client that fetched the url itself
to build a preview card would hand every site named in every message the
reader's IP address, their user agent, and the moment the message arrived — from
a request they never made, triggered by a link a stranger chose to send them.
That is a disclosure the reader cannot decline by not tapping.

So previews go through the homeserver's authenticated
`/_matrix/client/v1/media/preview_url`, falling back to the legacy
`/_matrix/media/v3/preview_url` only when the first is not routed (404 or
`M_UNRECOGNIZED`; a refusal is not retried). The homeserver fetches the page and
returns the OpenGraph tags, and the thumbnail is an `mxc://` it re-hosted,
loaded through authenticated media.

The cost depends on the room. In a room that is not end-to-end encrypted the
homeserver already holds every message, link included, so asking it about one
tells it nothing new — previews there are **on by default**. In an encrypted
room it does: **the homeserver learns a url it could otherwise never read.** So
encrypted rooms have their own switch, **off by default** and carrying the same
red warning as the remote-embedding and remote-STT gates — the split Element
makes, and the one the spec's own note on `preview_url` asks for. The
per-network exclusion stays, consistent with the other privacy gates.

### Previews the sender attached

The mautrix bridges relay the preview the remote app showed as
`com.beeper.linkpreviews` (MSC4095 names the same list `m.url_previews`). When an
event carries one, the card is drawn from it and the homeserver is never asked —
in an encrypted room too, since showing it discloses nothing. An image the
bridge attached encrypted (`beeper:image:encryption`) is dropped, keeping the
words, because the thumbnail path does not decrypt. An *empty* list is the
sender saying "no card" and is honoured. The master switch and the network
exclusion still apply; the encrypted-rooms switch does not, because it is only
about asking.

Rules the implementation holds to:

* **Absence is the default and absence is not an error.** Gate off, network
  excluded, encrypted room not opted into, no homeserver, request refused, no
  tags on the page, fetch still in flight — seven cases, one appearance. A card
  that announced its own failure would turn a setting the user chose into a row
  of apologies down the conversation, and would leak which links the homeserver
  declined to look at.
* **The gate is asked before the document is walked**, and the network and the
  room's encryption are part of the provider key: the same article forwarded
  from Signal and from Slack is two questions when Signal is excluded.
* **A miss is a real answer**, cached with a shorter TTL — seven days for a hit,
  six hours for a miss. `preview IS NULL` records that the homeserver was asked
  and had nothing; treating it as "not cached" would re-ask on every scroll,
  which is both a request the reader never made and a fresh disclosure. A miss
  is also what a rate-limited homeserver says, and pinning that for a week makes
  a bad minute look permanent.
* **Two caches, one record.** `LinkPreviewMemoryCache` lives for the run, in
  front of the sqlite cache, and holds the requests in flight. It outlives the
  service, which is rebuilt whenever a setting changes, so a rebuild neither
  re-reads disk nor re-asks. `LinkPreviewService.peek` answers from either
  synchronously, which is what lets a card scrolled back into view draw in its
  first frame. A card that has to wait for the homeserver grows in with
  `AnimatedSize` rather than shoving the bubbles below it in one frame.
* **Switching a setting off clears the cache**, the master switch and the
  encrypted-rooms one alike: rows left behind would keep drawing cards from
  consent just withdrawn.

The cache is `link_preview` in `weft_store`, appended as the last migration —
the list is append-only and gated on `PRAGMA user_version`, and entries are
never edited or reordered.

## Where the model lives, and which way the dependencies run

`weft_richtext` depends on `weft_domain` and never the reverse, which decided
where the value types live: `ReactionTally`, `EditRecord` and `ReplyPreview` are
in `weft_domain` (nouns) and the folds over them are in `weft_richtext` (verbs).
A type this package owned could never be a field on `WeftMessage`, and the
alternative — primitive shapes on the message with every renderer re-deriving
meaning — buys one fewer import in exchange for three places to get the
derivation wrong.

`WeftMessage` therefore carries `formattedBody` (raw and unsanitised: parse it
at your edge), `replyPreview`, `reactions` and `editHistory`. Two details that
bite:

* `copyWith` re-lists every field by hand, and takes a **sentinel** for
  `formattedBody` and `replyPreview` so that passing null *clears* them — which
  is what an edit that drops formatting needs.
* Equality is `(eventId, roomId)` **plus** every field that can change for that
  event, so a list diff redraws when a reaction lands. It used to be the pair
  alone, which meant two messages differing only in their tally compared equal.

A null `replyPreview` on a reply means "unresolved", not "not a reply": the
mapper fills it only for targets inside its own room, and the chat view resolves
across legs with `resolveReplyTarget` over the merged view before falling back
to `ReplyPreview.stub`. A stub written by the mapper would render "not loaded"
over a message that is on screen two bubbles up on another leg.

Ordering is untouched by any of this. `MergedTimeline` reads only `timestamp`,
`eventId` and `roomId` — see [[Merged-Timeline]] — so the new fields are
additive and the merge suite needed no changes.

## Tests

| Suite | Covers |
|---|---|
| `packages/weft_richtext/test/parse_test.dart` | Every permitted tag, malformed and 400-deep HTML, the injection battery, the plain-text projection |
| `packages/weft_richtext/test/fallback_test.dart` | Reply-fallback stripping, and the near-miss bodies that must survive it |
| `packages/weft_richtext/test/relations_test.dart` | Tallying, cross-network dedupe, emoji normalisation, edit ordering and rejection, reply resolution |
| `packages/weft_richtext/test/links_test.dart` | Which urls are worth previewing — and that code and spoilers are not |
| `apps/weft/test/rich_text_view_test.dart` | The renderer, and the injection battery re-asserted inside a real bubble |
| `apps/weft/test/reactions_test.dart` | Chips, toggling, and that a reaction names an event on the leg it lives on |
| `apps/weft/test/reply_edit_test.dart` | Composer reply and edit modes, the edited marker, the stub chip |
| `apps/weft/test/link_preview_test.dart` | The absences, encrypted-room gating, attached previews, switching off, the settings screen |
| `apps/weft/test/link_preview_service_test.dart` | Request counting: the gate, both caches, `peek` |
| `apps/weft/test/goldens/link_preview_golden_test.dart` | Thumbnail, long title, own side, right to left, a bridge's card in an encrypted chat |
| `apps/weft/test/search_index_test.dart` | That the index stores words and not markup |
| `apps/weft/test/goldens/rich_content_golden_test.dart` | Four scenes, light and dark, captured inside `ChatView` |

The app-level assertion worth stating plainly: hostile HTML never produces a
tappable `javascript:` link is checked as **no link recogniser anywhere on
screen**, not as a string comparison. Because the parser is the only thing that
builds a `RichLink`, that assertion is much harder to satisfy by accident than
one that inspects the url it ended up with.
