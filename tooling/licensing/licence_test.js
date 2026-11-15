// Run with `node --test tooling/licensing/`.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const { sessionLicence, newKey } = require('./build_licence.js');
const { compose } = require('./compose_email.js');

// What the app accepts; keep in step with `normalizeLicenseKey`.
const KEY = /^BRAID(-[A-HJ-NP-Z2-9]{5}){4}$/;

const session = {
  id: 'cs_test_1',
  customer: 'cus_1',
  customer_details: { email: 'anna@example.org' },
  payment_status: 'paid',
  metadata: { app: 'braid' },
};

test('a new key has the shape the app accepts', () => {
  for (let i = 0; i < 200; i++) assert.match(newKey(), KEY);
});

test('a first delivery mints a key and asks for the email', () => {
  const licence = sessionLicence(session, {});
  assert.match(licence.license_key.toUpperCase(), KEY);
  assert.equal(licence.license_key, licence.license_key.toLowerCase());
  assert.equal(licence.email, 'anna@example.org');
  assert.equal(licence.session_id, 'cs_test_1');
  assert.equal(licence.resent, false);
  assert.equal(compose(licence).skip, false);
});

test('a redelivery keeps the key and sends nothing', () => {
  const first = sessionLicence(session, {});
  const again = sessionLicence(session, { license_key: first.license_key });
  assert.equal(again.license_key, first.license_key);
  assert.equal(again.resent, true);
  assert.equal(compose(again).skip, true);
});

test('the email shows the key upper-cased, escaped, in both parts', () => {
  const mail = compose({ license_key: 'braid-aaaaa-bbbbb-ccccc-ddddd', email: ' a@example.org ' });
  assert.equal(mail.to, 'a@example.org');
  assert.ok(mail.html.includes('BRAID-AAAAA-BBBBB-CCCCC-DDDDD'));
  assert.ok(mail.text.includes('BRAID-AAAAA-BBBBB-CCCCC-DDDDD'));
  assert.equal(compose({ license_key: 'x', email: '' }).skip, true);
});

test('the workflow carries these files verbatim', () => {
  const workflow = JSON.parse(
    fs.readFileSync(path.join(__dirname, 'braid-licensing.workflow.json'), 'utf8'),
  );
  const code = (name) => workflow.nodes.find((n) => n.name === name).parameters.jsCode;
  const file = (name) => fs.readFileSync(path.join(__dirname, name), 'utf8');
  assert.equal(code('Build licence'), file('build_licence.js'));
  assert.equal(code('Compose licence email'), file('compose_email.js'));
});
