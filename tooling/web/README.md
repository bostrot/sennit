# Files to host at weft.bostrot.com

Deep-link verification requires two static files on the domain. Until they are
served, `weft://` links work everywhere and `https://weft.bostrot.com/…` links
open the browser instead of the app.

| File | Serve at | Fill in |
|---|---|---|
| `assetlinks.json` | `https://weft.bostrot.com/.well-known/assetlinks.json` | the **release** signing key's SHA-256 (`./gradlew signingReport`) |
| `apple-app-site-association` | `https://weft.bostrot.com/.well-known/apple-app-site-association` (no extension, `application/json`) | your Apple Team ID |

The iOS side also needs the Associated Domains capability
(`applinks:weft.bostrot.com`) added to the Runner entitlements once a
development team is configured in Xcode — it cannot be enabled without one.
