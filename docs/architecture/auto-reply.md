---
type: reference
title: LLM Auto-Reply
created: 2026-08-28
tags:
  - llm
  - automation
  - messaging
related:
  - '[[notifications]]'
  - '[[multi-device]]'
---

# LLM Auto-Reply

Braid already talks to the user's own model for reply chips. This turns that
into an auto-responder: a prompt the user wrote, a rule deciding which
conversations it covers, and a reply sent by itself when a matching message
arrives — **while leaving the conversation unread**.

That last clause is the interesting part of the design and the reason this
document exists. Replying marks a chat read on essentially every network, and in
Braid it does so *without any receipt at all*. Making a reply that does not is a
property of one specific code path, and the rest of this file is about which one
and why.

Three layers, and the split is the usual one:

| package | owns | knows nothing about |
| --- | --- | --- |
| `weft_autoreply` | the rules, the precedence, the guards, the ledger | HTTP, Flutter, Matrix, read receipts |
| `apps/weft/lib/services/ai/` | the model call and the orchestration | how a room's badge is computed |
| `apps/weft/lib/data/` | the send that keeps the badge | why it is being sent |

`weft_autoreply` is pure Dart, so every guard and every schedule boundary is
decided in one `dart test` file rather than on a device.

## The rule model

An `AutoReplyRule` is five things the user chose and one they did not.

```dart
AutoReplyRule(
  id: 'holiday',                     // stable across edits
  name: 'Out of office',             // may be empty; the list falls back to the audience
  prompt: 'Say I am away until Monday.',
  audience: EveryoneAudience(),      // or Network / Label / Contact
  enabled: false,                    // false unless explicitly set
  window: ReplyWindow(...),          // null = any time
  cooldown: Duration(minutes: 30),
)
```

The whole list lives as one JSON blob under `ai.auto_reply_rules`, exactly like
`notify.policy` and for the same reasons: it is read as a unit on every incoming
message, written as a unit by the editor, and `AutoReplyRule.listFromJson`
degrades rule by rule — a blob written by a newer build drops what this one
cannot read and keeps the rest.

`enabled` defaults to **false** in the constructor, in `fromJson`, and in the
editor. A rule that started replying to people the moment it was saved would be
a message sent by a half-finished form. `id` is stable across edits so that
rewriting a prompt does not reset the ledger — which is precisely the moment
someone is experimenting and least wants a surprise message going out.

### Audiences and precedence

Four kinds, ranked by `autoReplyAudiencePrecedence`:

| audience | matches | precedence |
| --- | --- | --- |
| `ContactAudience` | the chat's `contactId`, or its `id` for a group | 3 |
| `LabelAudience` | a label the app filed the chat under | 2 |
| `NetworkAudience` | **the message's** network, not the chat's | 1 |
| `EveryoneAudience` | anything not refused by a guard | 0 |

Higher wins; ties go to the earlier rule in the list, which is the user's own
order on the settings screen. A rule aimed at one person has to beat the blanket
holiday responder, or switching the blanket rule on makes every other rule
unreachable.

`NetworkAudience` matching the *message's* network is what makes a merged
conversation behave. One contact reaches the user on WhatsApp, Signal and SMS;
a rule scoped to SMS must fire on the SMS leg and nowhere else.

Selection is deliberately two steps — audience, then window — rather than one:

```dart
final covering = rules.where(usable && audienceMatches);   // else noRuleMatched
final open     = covering.where(windowActive);             // else outsideSchedule
final winner   = pickAutoReplyRule(open);                  // most specific first
```

Picking the winner first and *then* checking its window would leave the user
with silence at ten at night, instead of the wider rule they also wrote. It also
gives two different diagnoses — "nothing is set up for this chat" versus "come
back at nine" — which is what the settings screen shows.

### Schedule windows

`ReplyWindow` is the same shape as `QuietHours` in `weft_notify`: minutes since
midnight plus a fixed UTC offset, because the window is a *time of day* that
recurs and storing 09:00 as an instant makes it wrong tomorrow. The offset
travels with the window so a decision taken in a background isolate — which has
no reason to share the UI isolate's timezone, and on iOS may not have the user's
at all — reaches the same verdict as the foreground path.

Two things worth stating because they are easy to get wrong:

- **A zero-length window means always**, the opposite of the same case in
  `QuietHours`. There, a half-finished settings screen must not start
  suppressing notifications; here, it must not start withholding a reply the
  user asked for. Both fail towards the behaviour of having no window at all.
- **A wrapping window belongs to the day it opened on.** Friday 22:00 → 07:00 is
  *the Friday window* at two in the morning on Saturday. Checking Saturday
  instead would get it wrong every week.

## The guards

Baked into `shouldReply`, not into the UI, and applied in this order. The first
one that fires wins and is reported as *the* reason, so a stranger's message
inside a matching rule's window reads as `pendingRequest` — the fact that
decides it — rather than as whatever a later check would have said.

| # | refusal | why |
| --- | --- | --- |
| 1 | `ownMessage` | The shortest loop there is. `isOwn` plus the account's own ids, because a bridge echo often arrives with `isOwn` unset. |
| 2 | `redacted` | Nothing left to answer. |
| 3 | `nonMessageEvent` | A call or state event is not something a person said. |
| 4 | `autoReplyEcho` | The incoming message is itself machine-written. |
| 5 | `emptyMessage` | A captionless photo. A model handed no words invents some. |
| 6 | `pendingRequest` | **A chat request from an unknown sender is never answered.** |
| 7 | `serviceChat` | A bridge's management room. Its bot parses what it is sent. |
| 8 | `broadcast` | A status conversation. Nobody is being spoken to. |
| 9 | `noRuleMatched` / `outsideSchedule` | Nothing covers this, or nothing is open. |
| 10 | `conversationCap` | Three replies per conversation per hour, always. |
| 11 | `cooling` | The winning rule's cooldown has not elapsed. |

Rule 6 deserves its own paragraph. `MatrixChatRepository.markRead` already
refuses a pending request outright, and `answerChatRequest` is documented as
sending no receipt and no typing notification, because the whole promise of
holding a stranger's message is that they learn nothing. A machine-written
answer would tell them the handle is live, that it is read, and that it is worth
trying again — worse than any of the three individually. It is refused in the
engine *and* again in `sendAutoReply`, which is the last place it can be stopped.

Rule 10 is the anti-loop guard and is deliberately **not a setting**. Every other
limit here is the user tuning a feature; this one is the feature refusing to be
turned into a machine that talks to another machine for ever. A cooldown a user
could set to zero would be a loop with a slow clock, so the cap sits underneath
every rule and cannot be raised from the UI. Three rather than one because a real
exchange has turns in it.

The cooldown counts **any** auto-reply in the conversation, not only the winning
rule's own. Two rules taking turns would otherwise halve the interval the user
asked for.

### The ledger

`AutoReplyLedger` holds what has been auto-replied to, per conversation, in
memory. Held rather than derived, because deriving it would mean scanning every
conversation's timeline for the marker on every incoming message — and that
answer would be wrong anyway on a bridged leg, where the marker does not survive
the round trip. Bounded twice: entries older than the cap window are pruned on
every write, and a conversation is forgotten when its last entry expires.

## The unread guarantee

This is the crux. It is **not** about receipts.

`MatrixChatRepository.markRead` is the only thing in Braid that writes an
`m.read`, and every one of its callers is a user gesture — opening a chat,
swiping a row, the notification action. Nothing in the auto-reply path calls it.
That part is easy.

The hard part is `isReadLocally`, whose first clause is:

```dart
if (ownUserId != null && lastEventSenderId == ownUserId) return true;
```

Its own doc comment says why: writing a message moves `lastEvent` past every
receipt the room holds, so a chat the user had just caught up on went unread
again the moment they replied. That is right for a message they typed. It means
**the send itself clears the badge**, with no receipt anywhere, and every surface
built on `Chat.unreadCount` goes quiet with it: the inbox row, the rail badge,
`weft_snapshot` and therefore the Android widget and the Wear companion.

The mechanism that survives it is the order of the two clauses in
`roomUnreadCount`:

```dart
if (markedUnread) return notificationCount > 0 ? notificationCount : 1;
return readLocally ? 0 : notificationCount;
```

`markedUnread` is MSC2867 (`com.famedly.marked_unread`), and it is checked
*first*. So `sendAutoReply`:

1. records, per leg, whether the room was unread **before** the send — using the
   same `_unreadCountFor` the inbox row reads, so the two cannot disagree;
2. sends through the ordinary path (`sendEvent`, or the SMS gateway);
3. re-asserts `room.markUnread(true)` on every leg that was unread, dropping
   `_readUpTo` for it so an earlier optimistic marker cannot zero the badge back
   out on the next rebuild.

Restoring rather than unconditionally setting matters: auto-reply fires on an
incoming message, so the chat is normally unread already — but if the user has
the conversation open and caught up, flagging it unread would be the feature
inventing a badge nobody asked for.

**This is also the multi-device half.** `markUnread` writes *room account data*,
which syncs, so a reply sent from the phone leaves the laptop's badge standing
too. A purely local flag could not do that, and the counterfactual is pinned in
`auto_reply_unread_test.dart`.

The SMS leg needs nothing. `SmsChatRepository._ingest` leaves an existing
thread's unread count alone for an outgoing message, and `markRead` — the only
thing that touches the provider's read state — is a separate method nothing here
calls.

### The call sites it bypasses, exactly

| call site | what it would have done | why it is not called |
| --- | --- | --- |
| `MatrixChatRepository.markRead` | `m.read` per leg, `markUnread(false)`, `_readUpTo` | the only receipt writer; every caller is a gesture |
| `SmsChatRepository.markRead` | marks the thread read in the *provider* | same, for SMS |
| `ConversationClearer.clear` | cancels the shade row, republishes the snapshot | only reached from `chat_view._readConversation` and the notification actions |
| `setTyping` | a "the user is here" signal | the user is not here |

## The marker

An auto-reply carries `com.bostrot.weft.auto_reply: true` on its
`m.room.message` content, alongside the ordinary `body` — exactly the way
`kCalendarInviteKey` rides an invitation. Every other client shows the text and
ignores the key. `mapEvent` reads it back into `WeftMessage.isAutoReply` with a
strict `== true`, so a sender who put a string there means something this build
does not understand, and reading that as machine-written would suppress a real
person's reply.

It buys two things:

- **In the transcript**, the small robot glyph beside the clock. Six months
  later, "did I say that or did the model" is not a question a transcript should
  leave open. Drawn for a peer's auto-reply as well as the user's own.
- **In the engine**, the `autoReplyEcho` guard: two Braid users who have both
  switched this on would otherwise answer each other.

**It survives no bridge.** A reply relayed to WhatsApp arrives there as plain
text with no custom keys and comes back the same way. That is not a defect to be
fixed with a cleverer marker — no network but Matrix has anywhere to put one —
and it is exactly why the loop guard that actually holds is the hard cap, which
needs no cooperation from the far side.

## What is sent to the model, and what is not

The endpoint is the user's own: `ai.llm_base_url` and `ai.llm_model`, with the
key in the platform keychain. The same endpoint the reply chips use. Braid hosts
nothing and there is no service in the middle.

Per reply, one POST to `<base>/chat/completions` carrying:

- **the user's prompt, verbatim.** Not templated, not sanitised, not wrapped in
  advice. It is the whole feature, and a client that quietly edited it would be
  answering for something nobody wrote.
- **the conversation's title**, so the model can address the right person.
- **at most `kAiContextMessages` (24) recent messages**, each as
  `Name: what they said`.

What is **not** sent: any other conversation, the user's contacts, message ids,
timestamps, the rule list, anything about the account, anything about the other
networks. The context bound lives in `services/ai/conversation_context.dart`
rather than at the call site because it is a privacy quantity, not a tuning one
— it is how much of the conversation leaves the device per reply — and
`auto_reply_service_test.dart` asserts it.

It is **one** number for every AI feature, and that is the point of its living
there. The reply chips used to be handed whatever was still posted in the
notification shade, which is capped at five rows and is emptied when the chat is
read — so in the common case a chip was suggested from a single line, and the
two features disclosed different amounts of different things. Both now read a
`ConversationContext`, so raising or lowering the bound moves both.

The buffer those messages come from is built from the incoming stream, not
paginated out of the homeserver: what is sent is what the app has *seen arrive*
this session. The chips' buffer is not cleared when the conversation is read —
reading clears the rows in the shade, not the fact that the conversation
happened — but it is bounded, in memory only, and dropped with the service.

## Failure

Every failure sends nothing, throws nothing, and is **not retried**. A model
that timed out once will time out again while the same message is the newest
one, and a retry loop against someone else's Ollama is a way to make a phone
hot.

`AutoReplyOutcome` names them: `notConfigured`, `unreachable`, `timedOut`,
`refused` (the model answered with nothing sendable), `sendFailed`. Each becomes
its own sentence through `l10n_labels.dart`, on the auto-reply screen's
"Recent replies" list — a feature that speaks for someone must be able to say
what it said, and must not fail where only a developer can see it. The log is in
memory and bounded at 20; persisting it would mean writing a copy of the
conversation into the settings table.

`parseAutoReply` is stricter than `parseSmartReplies` and deliberately so. A chip
nobody taps costs nothing; this text is *sent*, to a person, on WhatsApp, and
cannot be unsent. So reasoning that never closed its `<think>`, a heading, a
bulleted analysis, and a 600-character run-on with no sentence to cut at are all
refused rather than best-efforted into a message.

## Where it is wired

| piece | file |
| --- | --- |
| rules, precedence, guards, ledger | `packages/weft_autoreply/lib/src/` |
| the model call and the parser | `apps/weft/lib/services/ai/auto_reply_writer.dart` |
| the subscription and orchestration | `apps/weft/lib/services/ai/auto_reply_service.dart` |
| the send that keeps the badge | `apps/weft/lib/data/matrix_chat_repository.dart` (`sendAutoReply`) |
| the narrow interface it goes through | `apps/weft/lib/data/auto_reply_transport.dart` |
| providers and persistence | `apps/weft/lib/app/auto_reply_providers.dart` |
| the screens | `apps/weft/lib/features/settings/auto_reply_screen.dart` |
| the transcript marker | `apps/weft/lib/features/chat/chat_view.dart` (`_AutoReplyMarker`) |

`AutoReplyTransport` is a one-method interface rather than a method on
`ChatRepository`, and that is not fussiness. Everything on that interface is
something a person did — a tap, a Return, a share sheet. This is the one send
nobody performed, it has a different postcondition, and the twelve fakes that
`implements ChatRepository` would each have to grow an implementation of a method
whose whole point is a guarantee a fake cannot make. As a narrow interface,
nothing under `features/` can reach it by accident, and
`autoReplyServiceProvider` returns null when the repository is not one — so demo
mode has no auto-reply rather than an auto-reply with no guarantee.
