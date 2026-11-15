// Writes the licence email.
//
// This file is the body of the "Compose licence email" Code node in
// braid-licensing.workflow.json, verbatim — licence_test.js fails if the two
// drift. Everything comes from Build licence, which read the re-fetched,
// verified Stripe session; Save licence has just stored the same row. Plain
// HTML with inline styles so every mail client renders it.
function compose(licence) {
  const key = String(licence.license_key || '').toUpperCase();
  const to = String(licence.email || '').trim();
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Your Sennit Pro licence key</title>
</head>
<body style="margin:0;padding:0;background:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#111827;">
  <div style="display:none;max-height:0;overflow:hidden;">Your Sennit Pro licence key is inside.</div>
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f3f4f6;padding:32px 16px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:560px;background:#ffffff;border-radius:16px;border:1px solid #e5e7eb;overflow:hidden;">
        <tr><td style="padding:28px 32px 0 32px;font-size:18px;font-weight:600;color:#111827;">Sennit</td></tr>
        <tr><td style="padding:20px 32px 0 32px;">
          <h1 style="margin:0;font-size:26px;line-height:1.25;font-weight:600;letter-spacing:-0.01em;color:#111827;">You&rsquo;re all set</h1>
          <p style="margin:14px 0 0 0;font-size:16px;line-height:1.6;color:#4b5563;">Thank you for buying Sennit Pro. Your licence never expires and covers every device you use yourself. Here is your key:</p>
        </td></tr>
        <tr><td style="padding:24px 32px 0 32px;">
          <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f9fafb;border:1px solid #e5e7eb;border-radius:12px;">
            <tr><td style="padding:18px 20px;">
              <p style="margin:0 0 8px 0;font-size:11px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#6b7280;">Your licence key</p>
              <p style="margin:0;font-family:SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace;font-size:18px;line-height:1.5;letter-spacing:0.02em;color:#111827;word-break:break-all;">${esc(key)}</p>
            </td></tr>
          </table>
        </td></tr>
        <tr><td style="padding:24px 32px 0 32px;">
          <p style="margin:0 0 10px 0;font-size:15px;font-weight:600;color:#111827;">How to activate</p>
          <ol style="margin:0;padding-left:20px;font-size:15px;line-height:1.7;color:#4b5563;">
            <li>Open Sennit and go to <strong style="color:#111827;">Settings</strong>.</li>
            <li>Open <strong style="color:#111827;">Sennit Pro</strong>.</li>
            <li>Paste the key and press <strong style="color:#111827;">Activate</strong>.</li>
          </ol>
          <p style="margin:14px 0 0 0;font-size:14px;line-height:1.6;color:#6b7280;">The key is for Sennit downloaded from the release page. Sennit from Google Play or the App Store sells Pro through the store instead.</p>
        </td></tr>
        <tr><td style="padding:28px 32px 28px 32px;">
          <p style="margin:0;font-size:13px;line-height:1.6;color:#6b7280;">Keep this email — it is your proof of purchase. Questions or a lost key: reply to this email or write to <a href="mailto:license@bostrot.com" style="color:#4f46e5;text-decoration:none;">license@bostrot.com</a>.</p>
        </td></tr>
      </table>
      <p style="margin:18px 0 0 0;font-size:12px;line-height:1.6;color:#9ca3af;">Sent by Eric Trenkel &middot; Sennit</p>
    </td></tr>
  </table>
</body>
</html>`;

  const text = [
    'Thank you for buying Sennit Pro.',
    '',
    `Your licence key: ${key}`,
    '',
    'How to activate: open Sennit, go to Settings, open "Sennit Pro", paste the key and press Activate.',
    'The key is for Sennit downloaded from the release page; it never expires and covers every device you use yourself.',
    '',
    'Keep this email as your proof of purchase. Questions or a lost key: license@bostrot.com',
  ].join('\n');

  return {
    to,
    subject: 'Your Sennit Pro licence key',
    html,
    text,
    // Nothing to send to, or already sent: the row is saved either way.
    skip: !to || licence.resent === true,
  };
}

// --- n8n Code node entry point -------------------------------------------
// Present only inside n8n; under `node` this falls through to the export.
if (typeof $input !== 'undefined') {
  return [{ json: compose($('Build licence').item.json) }];
}

module.exports = { compose };
