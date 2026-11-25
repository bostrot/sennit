#!/bin/sh
# /usr/local/bin/sygnal-health on push-01, run every minute by
# sygnal-health.timer. Restarts sygnal when it stops answering — systemd's
# Restart= only covers a process that exits, not one that hangs.
#
# The probe is a notification for an app id the gateway does not serve: sygnal
# answers 200 with the key listed in `rejected` and contacts neither Google nor
# Apple.
body='{"notification":{"event_id":"$health","room_id":"!health:localhost","counts":{"unread":0},"devices":[{"app_id":"health.check","pushkey":"health","pushkey_ts":0}]}}'
if curl -fsS -m 5 http://127.0.0.1:5000/health >/dev/null &&
   curl -fsS -m 5 -H 'Content-Type: application/json' -d "$body" \
     http://127.0.0.1:5000/_matrix/push/v1/notify | grep -q '"rejected"'; then
  exit 0
fi
echo "sygnal health check failed; restarting" >&2
systemctl restart sygnal
