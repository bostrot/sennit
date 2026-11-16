# Sennit Privacy Policy

*Published at <https://erictrenkel.com/apps/braid/privacy.html> — that
hosted copy is the one the app stores link to.*

*Effective: 15 November 2026*

Sennit is a self-hosted messenger. It is designed so that the developer of
Sennit **cannot** see your data — there is no Sennit cloud, no account with us,
and no telemetry.

## What Sennit collects

Nothing. The app contains no analytics, no crash reporting service, no
advertising SDKs, and no tracking of any kind. The developer operates no
server that your messages or contacts ever reach. The one exception, licence
checks in builds downloaded outside the app stores, is described under
*Sennit Pro* below.

## Sennit Pro

Sennit Pro is an optional one-time purchase.

- **From the App Store or Google Play:** Apple or Google handle the payment
  and tell the app whether you own Pro. The developer receives the store's
  usual sales reports, which contain no messages, contacts or other content
  from the app.
- **Builds downloaded from the project's release page:** you buy a licence
  key through Stripe. Stripe processes the payment, and the developer keeps
  your email address and licence key to deliver and support the licence.
  When you enter the key, the app sends **the key and nothing else** — no
  device id, account or app data — to the developer's licence service to
  check that it is valid.

## Where your data goes

Sennit talks exclusively to servers **you** configure:

- **Your Matrix homeserver.** Messages, media, contacts and encryption keys
  sync with the homeserver you sign in to. That server is operated by you or
  by whoever you chose — its privacy practices are its operator's.
- **Bridges you install** on your own infrastructure relay messages to
  third-party networks (for example WhatsApp or Telegram). Those networks
  see what any client on them sees; the bridge runs under your control.
- **Optional AI endpoints.** Voice transcription, semantic search
  embeddings, reply suggestions and auto-reply only run if you configure an
  endpoint for them. On-device models never send audio or text anywhere. If
  you point Sennit at a remote endpoint, the content you asked it to process
  is sent to that endpoint — which, again, you chose and control.

## Auto-reply

Sennit can answer messages for you, using the same model endpoint you
configured above and no other. Nothing about this feature reaches the
developer, and there is no service in the middle.

- It is **off until you write a rule and switch that rule on**. A rule you
  have saved but not enabled sends nothing.
- When a rule fires, Sennit sends your prompt and **the last few messages of
  that conversation** to your endpoint, and sends what comes back as a
  message from you. Nothing else about the conversation is included.
- The reply is marked as machine-written, so you and anyone using a client
  that understands the marker can tell it apart from something you typed.
- **The conversation stays unread.** Sennit does not send a read receipt for
  an auto-reply and does not clear the badge — on this device or on your
  others. The other side is told a message arrived, not that theirs was
  read.
- Sennit never auto-replies to a message request from someone you have not
  answered. Replying would confirm your handle is live and being read, and
  that is a decision only you make.
- No conversation receives more than three automatic replies an hour,
  whatever your rules say. This limit is not adjustable.

## What stays on your device

- Message history, search indexes and media caches, stored locally.
- Encryption keys, held in the platform keystore/keychain.
- Contact names, if you enable address-book matching. Matching happens
  entirely on the device; your address book is never uploaded.
- Notifications are decrypted on the device.

## Backups

Sennit can write your history to a single `.sennit` file. That file is
**created on your device, encrypted on your device, and never uploaded**.
There is no Sennit cloud to upload it to.

- The file is encrypted with a passphrase you choose, using Argon2id and
  XChaCha20-Poly1305. The passphrase is not stored anywhere and is not
  recoverable — if you lose it, nobody can open the backup, including us.
- Where the file goes is entirely your choice: the system save dialog on
  desktop, the share sheet on mobile. If you put it somewhere that syncs to
  a cloud drive, that is your decision and that provider's terms apply to
  the encrypted file.
- A backup deliberately **excludes your encryption keys, your sign-in token
  and your bridge credentials**. Restoring history is not the same as
  signing in, and a file that could do both would be an account takeover in
  an attachment.
- Restoring reads only the file you pick. Nothing is contacted, and nothing
  is written until you have seen what the file contains.

## Permissions

Sennit asks for permissions only when a feature needs them: microphone for
voice messages and calls, camera for photos and QR device verification,
contacts for local name matching, location only when you explicitly share
it into a chat, and notifications. Denying a permission disables only the
feature that wanted it.

## Your rights

Your data lives on your homeserver and your device. Deleting the app
removes its local data; your homeserver's data is managed through your
homeserver. There is nothing held by the developer to request, export, or
delete.

## Changes and contact

Changes to this policy are published in this repository with the app's
release notes. Questions: **eric@bostrot.com**.
