// Turns a *verified* Stripe Checkout session into a licence row.
//
// This file is the body of the "Build licence" Code node in
// braid-licensing.workflow.json, verbatim — licence_test.js fails if the two
// drift. It also loads as a CommonJS module so the logic runs under
// `node --test`.
//
// The event body that reached the webhook is not trusted. The node before
// this one re-fetched the session straight from the Stripe API with our own
// key, and the IF after it dropped anything that is not paid or is not a
// Braid sale. So everything below reads from the re-fetched session, never
// from the posted payload. "Existing licence" then looked the session up in
// the licence table: a row that is already there means Stripe delivered this
// event before (it retries on anything but a 2xx) and the customer may
// already hold that key — so it is kept, never rotated.

// Crockford-ish alphabet: no I, O, 0 or 1, so a key read off a screen and
// typed into the app cannot be ambiguous.
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

function block(n) {
  let bytes = null;
  try {
    bytes = globalThis.crypto.getRandomValues(new Uint8Array(n));
  } catch (e) {
    bytes = null;
  }
  let out = '';
  for (let i = 0; i < n; i++) {
    const v = bytes ? bytes[i] : Math.floor(Math.random() * 256);
    out += ALPHABET[v % ALPHABET.length];
  }
  return out;
}

// The shape the app accepts: see `normalizeLicenseKey` in
// apps/weft/lib/services/billing/license_client.dart.
function newKey() {
  return ['BRAID', block(5), block(5), block(5), block(5)].join('-');
}

function sessionLicence(session, existing) {
  const kept = existing && existing.license_key;
  const details = session.customer_details || {};
  return {
    // Stored lower-case so lookups are case-insensitive; the email and the
    // app upper-case it.
    license_key: String(kept || newKey()).toLowerCase(),
    // Whether this event had been seen before; the email is only sent once.
    resent: !!kept,
    email: session.customer_email || details.email || '',
    stripe_id: session.customer || '',
    session_id: session.id,
    plan: 'pro',
  };
}

// --- n8n Code node entry point -------------------------------------------
// Present only inside n8n; under `node` this falls through to the export.
if (typeof $input !== 'undefined') {
  const session = $('Re-fetch session').item.json;
  return [{ json: sessionLicence(session, $input.first().json || {}) }];
}

module.exports = { sessionLicence, newKey, ALPHABET };
