# Sennit Privacy Policy

*Published at <https://erictrenkel.com/apps/braid/privacy.html> — that
hosted copy is the one the app stores link to.*

*Effective: 16 November 2026*

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
  **Link previews** are fetched by that homeserver, never by your device, so
  the linked site does not see your IP address. They are on for chats that
  are not end-to-end encrypted (the homeserver already holds those messages)
  and off for encrypted chats unless you turn them on in Settings → Link
  previews, because asking tells the homeserver a link it could not otherwise
  read. Previews a bridge attached to a message are shown without asking
  anyone. You can switch previews off entirely.
- **Bridges you install** on your own infrastructure relay messages to
  third-party networks (for example WhatsApp or Telegram). Those networks
  see what any client on them sees; the bridge runs under your control.
- **Optional AI endpoints.** Voice transcription, semantic search
  embeddings, reply suggestions, quick messages and auto-reply only run if you
  configure an endpoint for them. A quick message sends the last twelve
  messages of the chat you picked it in, only when you pick it, and its
  draft lands in the composer — nothing is sent to the chat until you do. On-device models never send audio or text anywhere. If
  you point Sennit at a remote endpoint, the content you asked it to process
  is sent to that endpoint — which, again, you chose and control.
- **Personal memory.** Notes you write about a chat ("This chat") or a
  person ("About …", on the contact screen), and the facts Sennit learns for
  them, stay on your device, encrypted in the platform keychain, and are not
  synced to your other devices. Nothing is sent to your AI endpoint until you
  turn on "Use personal memory in AI" — then every AI feature (reply
  suggestions, quick messages, auto-replies, to-dos and calendar titles)
  sends a shortened memory of the chat and its people with its request. With
  "Learn automatically" on (the default once memory is on), Sennit sends an
  active chat's recent messages to the same endpoint after about 30 new
  messages or once a day, only while the app is open, and writes what it
  learns into the memory, marked with when it was learned, for you to edit,
  pin, delete or undo. "Learn now" does the same on request. Both skip
  end-to-end encrypted chats unless you allow them. What is learned includes
  a short description of how you write in each chat and how the other person
  writes; reply suggestions, quick messages and auto-replies send it along
  with up to ten of your own recent messages in that chat as examples — from
  an encrypted chat only if you allow learning from those.

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

## SMS (Android only)

On Android, Sennit can be your default messaging app. This is optional and
off until you choose Sennit in Android's own "Default SMS app" dialog; until
then Sennit cannot read or send text messages at all.

- **What it reads.** While it holds that role, Sennit reads, receives and
  sends the SMS and MMS on your phone so they appear in the same inbox as
  your other conversations.
- **Where they go.** Nowhere new. Text messages stay in Android's message
  store on your device and travel over your carrier, as they do with any
  SMS app. Sennit does not upload them to your Matrix homeserver, to a
  bridge, or to the developer.
- **On-device use.** Their text is added to the local search index, and a
  number that also has a chat on another network can be shown as one
  conversation. Both happen on the device.
- **Features you switch on.** If you configure a remote AI endpoint and use
  it on a text conversation — an auto-reply rule that covers SMS, for
  example — the content you asked it to process goes to that endpoint, as
  described above. A backup file you create may include your text messages;
  it is encrypted on your device as described under *Backups*.
- **SMS is not encrypted.** Your carrier and the recipient's carrier can
  read every text message. Sennit cannot change that, and says so above the
  composer whenever a message will go out as SMS.
- Choosing another default messaging app in Android's settings ends
  Sennit's access immediately.

## What stays on your device

- Message history, search indexes and media caches, stored locally.
- Encryption keys, held in the platform keystore/keychain.
- Notes about chats and people (personal memory), held in the same keychain.
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
it into a chat, notifications, and — on Android, only if you make Sennit
your default messaging app — SMS. Denying a permission disables only the
feature that wanted it.

## Your rights

Your data lives on your homeserver and your device. Deleting the app
removes its local data; your homeserver's data is managed through your
homeserver. There is nothing held by the developer to request, export, or
delete.

**Deleting your account.** Settings → Account → *Delete account* signs
every bridge out, asks your homeserver to deactivate the account and erase
what it can, and then deletes everything Sennit stored on the device. How
that works, and how to ask for deletion without the app, is at
<https://erictrenkel.com/apps/sennit/delete-account.html>.

## Changes and contact

Changes to this policy are published in this repository with the app's
release notes. Questions: **eric@bostrot.com**.
