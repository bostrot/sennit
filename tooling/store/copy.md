# Store listing copy

The single source for both stores. Character limits are per store; counts
noted where they matter. Trademarked network names appear only in
descriptions (nominative use), never in the Apple keyword field — Apple
rejects other brands as keywords outright.

## Names

| Field | Value | Limit |
|---|---|---|
| Apple app name | `Sennit Messenger` | 30 |
| Apple subtitle | `Self-hosted unified inbox` | 30 |
| Play title | `Sennit — Self-hosted Messenger` | 30 |
| Play short description | `One private inbox for every chat, on your own Matrix server and bridges.` | 80 |

## Apple keywords (100 chars max, comma-separated)

```
matrix,unified,inbox,bridge,self-hosted,private,chat,messaging,encrypted,federated,transcribe
```

## Description (both stores)

**One inbox. Your server. Nobody in between.**

Sennit weaves every conversation you have — across networks like WhatsApp,
Signal, Telegram, Google Messages, Mattermost, SMS and Matrix — into a
single private inbox. It connects to a Matrix homeserver that you run,
through bridges that you control. No hosted middleman, no account with us,
no message that ever touches our infrastructure. We couldn't read your
messages if we wanted to: there is no "us" in the loop.

MERGED CONVERSATIONS
The same person on three networks becomes one thread. Replies go out on the
network the last message arrived on — or the one you pin. Automatic merging
only happens for exact matches; everything else is a suggestion you decide.

PRIVATE BY ARCHITECTURE
• End-to-end encryption via Matrix, with device verification and key backup
• On-device voice transcription — audio never leaves your hardware
• On-device semantic search across your whole history
• Optional AI reply suggestions from a language model you host yourself
• No analytics, no telemetry, no tracking. None.

BUILT FOR REAL LIFE
• Reliable notifications without Google, through your own sync connection
  or UnifiedPush
• Calendar invites you can accept, decline or counter-propose inside chats
• Voice messages, polls, location sharing, scheduled sending, reminders
• Home screen widgets and a watch companion
• Desktop-class experience on tablets

BRING YOUR OWN SERVER
Sennit is the client. You bring a Matrix homeserver and the bridges for the
networks you use (mautrix bridges are the reference setup). The app
discovers your bridges and walks you through connecting each network, QR
logins included. Setting up a homeserver takes some technical comfort —
that independence is the entire point.

Sennit is open source under the AGPL-3.0 license.

*Sennit is not affiliated with the third-party networks reachable through
bridges. Bridging automates your own accounts on those networks; whether
their terms permit it is between you and them.*

## Promotional text (Apple, 170 chars, changeable without review)

```
Self-hosted, open source, and yours: every chat network in one encrypted
inbox on your own Matrix server. No cloud between you and your messages.
```

## URLs

| Field | Value |
|---|---|
| Support URL | https://github.com/bostrot/sennit |
| Marketing URL | https://github.com/bostrot/sennit |
| Privacy policy | https://erictrenkel.com/apps/braid/privacy.html |

## Categories

- Apple: primary `SOCIAL_NETWORKING`, secondary `PRODUCTIVITY`
- Play: `Communication`

## Data collection

Both questionnaires: **no data collected** — no analytics or crash SDKs;
the app only talks to user-configured servers. See PRIVACY.md.
