# Braid Privacy Policy

*Published at <https://erictrenkel.com/apps/braid/privacy.html> — that
hosted copy is the one the app stores link to.*

*Effective: 25 August 2026*

Braid is a self-hosted messenger. It is designed so that the developer of
Braid **cannot** see your data — there is no Braid cloud, no account with us,
and no telemetry.

## What Braid collects

Nothing. The app contains no analytics, no crash reporting service, no
advertising SDKs, and no tracking of any kind. The developer operates no
server that the app talks to.

## Where your data goes

Braid talks exclusively to servers **you** configure:

- **Your Matrix homeserver.** Messages, media, contacts and encryption keys
  sync with the homeserver you sign in to. That server is operated by you or
  by whoever you chose — its privacy practices are its operator's.
- **Bridges you install** on your own infrastructure relay messages to
  third-party networks (for example WhatsApp or Telegram). Those networks
  see what any client on them sees; the bridge runs under your control.
- **Optional AI endpoints.** Voice transcription, semantic search
  embeddings and reply suggestions only run if you configure an endpoint
  for them. On-device models never send audio or text anywhere. If you
  point Braid at a remote endpoint, the content you asked it to process is
  sent to that endpoint — which, again, you chose and control.

## What stays on your device

- Message history, search indexes and media caches, stored locally.
- Encryption keys, held in the platform keystore/keychain.
- Contact names, if you enable address-book matching. Matching happens
  entirely on the device; your address book is never uploaded.
- Notifications are decrypted on the device.

## Permissions

Braid asks for permissions only when a feature needs them: microphone for
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
