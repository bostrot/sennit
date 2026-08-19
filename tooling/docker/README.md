# Local test homeserver

A disposable Synapse for Weft's integration and e2e tests. **Not** a deployment
template: registration is open, there is no TLS, and the config is regenerated
from scratch on demand.

## First run

Generate the Synapse config (once), then start it:

```bash
docker run --rm -v "$PWD/tooling/docker/synapse-data:/data" -e SYNAPSE_SERVER_NAME=localhost -e SYNAPSE_REPORT_STATS=no matrixdotorg/synapse:latest generate
```

```bash
docker compose -f tooling/docker/compose.yaml up -d
```

Synapse listens on `http://localhost:8008`.

## Seeding test users

```bash
./tooling/docker/seed.sh
```

Creates `@alice:localhost` and `@bob:localhost` (password `weft-test-password`).
No room: every test creates and cleans up its own, because a test that shares a
fixture room with the next one cannot leave the homeserver as it found it.

## Running the device suite

`tooling/scripts/e2e.sh` does all of the above and then runs Patrol on a device
— generating the config if it is missing, raising `rc_login` so a suite that
logs two accounts in per test does not trip the limiter, and tearing the
container down afterwards. See
[`docs/quality/e2e-matrix.md`](../../docs/quality/e2e-matrix.md).

## Resetting

```bash
docker compose -f tooling/docker/compose.yaml down -v && rm -rf tooling/docker/synapse-data
```

## Bridges

No bridge runs here yet. The bridge layer targets the **mautrix bridgev2
provisioning API v3**, and the mock bridge that serves it — enough to drive the
GUI login flows end to end without any real network account — arrives with the
bridge GUI in M6. Until then `weft_bridges` is exercised by unit tests against a
mocked HTTP client.
