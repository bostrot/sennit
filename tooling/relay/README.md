# Sennit Web relay

Sennit Web is the app in a browser, served by your phone. On the same network
the browser talks to the phone directly. From anywhere else it goes through
this relay: a small Cloudflare Worker that you deploy to your own account.

```
browser ──https──▶ relay (Worker + Durable Object) ◀──wss── phone (dials out)
```

The phone connects out to the relay, so nothing has to reach in to it. That
works on mobile data and behind any router.

## What the relay can see

- **Your chats: no.** The app's traffic is end-to-end encrypted between the
  browser and the phone (X25519 + ChaCha20-Poly1305). The keys come from the
  pairing QR code, in the part of the address browsers never send. The relay
  passes ciphertext along.
- **The Sennit Web files: yes.** They are the same public files as on the
  release page.
- **Metadata: yes.** When a phone is connected, when browsers connect, and how
  much traffic flows.

The relay serves the page the browser runs. Whoever runs the relay could
change that page, so run your own and don't use one you don't trust.

A phone is listed under an id derived from its own random secret. Only the
phone with that secret can connect under that id.

## Deploy

You need a Cloudflare account (the free plan is enough) and Node.js.

```sh
cd tooling/relay
npx wrangler login
npx wrangler deploy
```

Wrangler prints the address, e.g. `https://sennit-relay.<you>.workers.dev`.
To use your own domain, add a route or custom domain to the Worker in the
Cloudflare dashboard.

## Use

1. On the phone: **Settings → Sennit Web**, download the browser files.
2. Under **Reach from anywhere**, enter the relay address and turn on
   **Serve through the relay**.
3. Tap **Pair a browser** under the relay address and open the link on the
   computer.

Android keeps the connection while Sennit Web is on. iOS drops it about 30
seconds after the app goes to the background.

## Try it locally

```sh
npx wrangler dev --port 8790
```

Then enter `http://127.0.0.1:8790` as the relay address in a desktop build of
Sennit. Plain `http` is only accepted for `localhost` and `127.0.0.1`.

## Cost

One Durable Object per phone. It hibernates while idle, and the phone's
keep-alive pings are answered without waking it. A single person's use stays
inside the free plan.
