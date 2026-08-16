#!/usr/bin/env bash
# Seeds the local test homeserver with the accounts Weft's integration tests
# expect. Idempotent: re-running it on existing users is a no-op.
#
#   ./tooling/docker/seed.sh
set -euo pipefail

CONTAINER="${WEFT_SYNAPSE_CONTAINER:-weft-synapse}"
HOMESERVER="${WEFT_HOMESERVER:-http://localhost:8008}"
PASSWORD="${WEFT_TEST_PASSWORD:-weft-test-password}"

register() {
  local user="$1"
  if docker exec "$CONTAINER" register_new_matrix_user \
      -u "$user" -p "$PASSWORD" --no-admin \
      -c /data/homeserver.yaml "$HOMESERVER" >/dev/null 2>&1; then
    echo "created @$user:localhost"
  else
    # Almost always "user already exists", which is fine for a seed script.
    echo "@$user:localhost already exists (or registration failed)"
  fi
}

echo "Seeding $HOMESERVER"
register alice
register bob

cat <<EOF

Done. Sign in to Weft with:
  Server:   localhost:8008
  Username: alice
  Password: $PASSWORD

Note the server field accepts a bare host; Weft resolves http for localhost.
EOF
