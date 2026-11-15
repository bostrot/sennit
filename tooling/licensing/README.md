# The licence service

A build from the release page (`BRAID_EDITION=direct`) unlocks Sennit Pro with
a licence key bought on the web. This directory is the server side of that:
one [n8n](https://n8n.io) workflow, `braid-licensing.workflow.json`.

```
Stripe Payment Link ──checkout.session.completed──▶ POST /webhook/braid/stripe-events
                                                      re-fetch the session from Stripe
                                                      paid, and metadata app=braid?
                                                      mint BRAID-XXXXX-XXXXX-XXXXX-XXXXX
                                                      save the row, email the key

Sennit ──GET /webhook/braid/validate?license=BRAID-…──▶ {"valid": true|false}
```

The app asks once when a key is entered and about once a month after that.
The request carries the key and nothing else. Only a definite `valid: false`
ever takes Pro away; an unreachable server changes nothing.

## What it needs

| Thing | Where |
|---|---|
| A data table `braid-licenses` with `email`, `license_key`, `active` (boolean), `plan`, `session_id`, `stripe_id` | n8n → Data tables |
| A Stripe credential that can read Checkout Sessions | the "Re-fetch session" node |
| An SMTP credential | the "Send licence email" node |
| A Stripe product with a one-time price and a **Payment Link whose metadata is `app=braid`** | Stripe |
| A Stripe webhook endpoint → `https://<n8n>/webhook/braid/stripe-events`, events `checkout.session.completed` and `checkout.session.async_payment_succeeded` | Stripe → Developers → Webhooks |

The `app=braid` metadata is what tells a Sennit sale from anything else sold
on the same Stripe account. Stripe copies a Payment Link's metadata onto each
session it creates; a session without it gets no licence.

The posted event is not signature-checked. It does not need to be: nothing in
it is used except the session id, and the session is then fetched from Stripe
with our own key. A forged event names a session that does not exist or is
not paid.

## Pointing the app at it

Two build-time values, both set by `release.yml`:

- `BRAID_CHECKOUT_URL` — the Payment Link. Comes from the repository variable
  of the same name; while it is unset, release-page builds are the community
  edition.
- `BRAID_LICENSE_API` — the base of the two webhooks. Defaults to
  `https://n8n.aachen.dev/webhook/braid` in
  `apps/weft/lib/services/billing/license_client.dart`.

## Day to day

- **Refund:** untick `active` on the row. The app locks at its next monthly
  check.
- **Lost key:** look the row up by email and send the key again.
- **A key by hand** (a gift, a tester): add a row with a key of the same
  shape, lower-case, `active` ticked, and any unique `session_id`.

## Changing the code nodes

`build_licence.js` and `compose_email.js` are the bodies of the two Code
nodes, verbatim. Edit the file, paste it into the node, export the workflow
over the JSON here, and run:

```bash
node --test tooling/licensing/licence_test.js
```

The last test fails if the files and the workflow have drifted apart.
