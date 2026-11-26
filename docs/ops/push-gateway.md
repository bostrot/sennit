# Sennit push gateway

The published apps wake a phone through Sennit's own
[sygnal](https://github.com/matrix-org/sygnal): the user's homeserver posts
an `event_id_only` notification to it, sygnal turns it into an FCM message
(Android) or an APNs push (iOS), and the app fetches and decrypts the
message itself. Why it exists, and what it leaks, is in
`docs/research/push-notifications-investigation.md` (branch
`bostrot/push-investigation`).

| | |
| --- | --- |
| Public URL | `https://push.bostrot.com/_matrix/push/v1/notify` (`kSennitPushGateway`) |
| Host | LXC 113 `push-01` on minis-server, Debian 12, 1 core, 512 MB |
| Address | `192.168.3.111` (DHCP; reserve it in UniFi) |
| Software | sygnal 0.17.0 in `/opt/sygnal` (venv), systemd unit `sygnal` |
| Path in | Cloudflare tunnel → edge-02 Traefik (`sennit-push` router) → `:5000` |
| Metrics | Prometheus on `:8000`, LAN only |

Only `POST /_matrix/push/v1/notify` is public. Traefik routes nothing else
for the host, Cloudflare blocks everything else and rate-limits per IP, and
`nftables` on push-01 accepts `:5000` from edge-02 and itself only.

## App ids

| App id | Pushkin | Used by |
| --- | --- | --- |
| `com.bostrot.weft.android` | FCM HTTP v1, project `sennit-push` | Android store builds |
| `com.bostrot.weft.ios` | APNs production, topic `com.bostrot.weft` | TestFlight and App Store |
| `com.bostrot.weft.ios.dev` | APNs sandbox | Xcode runs (development profile) |

## Files

The configuration is in `tooling/push-gateway/` and is not secret:

| Repo file | On push-01 |
| --- | --- |
| `sygnal.yaml` | `/etc/sygnal/sygnal.yaml` |
| `sygnal.service` | `/etc/systemd/system/sygnal.service` |
| `sygnal-health.sh` | `/usr/local/bin/sygnal-health` |
| `sygnal-health.{service,timer}` | `/etc/systemd/system/` |
| `nftables.conf` | `/etc/nftables.conf` |
| `journald.conf` | `/etc/systemd/journald.conf.d/retention.conf` |
| `requirements.txt` | the venv in `/opt/sygnal` (`pip freeze`) |

The credentials live only on push-01, under `/etc/sygnal/secrets` (mount
point `mp0`, `backup=0`, readable by the `sygnal` user only):

- `fcm-service-account.json`: service account in Firebase project
  `sennit-push` with only the *Firebase Cloud Messaging API Admin* role.
- `apns-authkey.p8`: APNs auth key `QUAY8B6RYW`, team `D4U2L824A5`.

The Android app gets its Firebase client config from the
`GOOGLE_SERVICES_JSON` repository secret, which
`tooling/scripts/firebase_android_config.py` turns into
`res/values/firebase.xml` at build time. A build without it has no FCM
and still notifies through sync, the built-in connection or UnifiedPush.
iOS uses no Firebase: `AppDelegate.swift` hands the APNs token to Dart.

## Privacy

- No access log (`sygnal.access` is silenced) and only warnings from the
  pushkins, so no log line joins a push key to a room or event.
- journald keeps 7 days, 200 MB at most.
- Pushers are `event_id_only`: no message text or sender reaches the
  gateway, Google or Apple.

## Operating it

```sh
ssh root@minis-server            # Proton Pass SSH agent
pct enter 113
systemctl status sygnal          # Restart=always
systemctl list-timers sygnal-health.timer
journalctl -u sygnal -n 50       # warnings only
curl -s localhost:8000/metrics | grep sygnal_
```

`sygnal-health` runs every minute: it posts a notification for an app id
the gateway does not serve (answered locally, nothing goes to Google or
Apple) and restarts sygnal when that fails.

A config change: edit the repo file, copy it over, `systemctl restart
sygnal`. Snapshot first (`pct snapshot 113 <name>`).

Upgrading sygnal: `pct snapshot 113 pre-upgrade`, then
`/opt/sygnal/bin/pip install -U matrix-sygnal==<version>` and restart.
Keep Twisted at 24.11 unless a test send to FCM still answers afterwards:
with Twisted 26, sygnal 0.17's FCM requests hang after connecting while
APNs keeps working, so only Android goes quiet. A send with a made-up
Android token must come back as a 502 ("Invalid request" from FCM) within
a second, not time out.

Backups: the container is tagged `production`, so the weekly Kopia job
copies it off-site. The secrets mount is excluded; after a restore, put
the two files back from Firebase (new key for the service account) and
the Apple developer account (new APNs key; update `key_id` in
`sygnal.yaml`).

Rotating a credential: create the new key, copy it to
`/etc/sygnal/secrets` (`chown sygnal:sygnal`, `chmod 400`), update
`sygnal.yaml` if the APNs key id changed, restart, then revoke the old one.

## Checking it end to end

From the LAN, through the edge:

```sh
curl -s -H 'Host: push.bostrot.com' -H 'Content-Type: application/json' \
  -d '{"notification":{"devices":[{"app_id":"health.check","pushkey":"x"}]}}' \
  http://192.168.3.163/_matrix/push/v1/notify      # {"rejected": ["x"]}
```

From outside: the same against `https://push.bostrot.com`. In the app,
Settings → Notifications shows "Registered with your homeserver." once the
pusher is on the account.
