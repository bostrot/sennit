#!/usr/bin/env bash
# Runs Weft's Patrol device suite end to end: homeserver up, accounts seeded,
# `patrol test` on a device, homeserver down.
#
#   ./tooling/scripts/e2e.sh
#   ./tooling/scripts/e2e.sh --device emulator-5554 --keep
#   ./tooling/scripts/e2e.sh --target integration_test/patrol/harness_test.dart
#
# One command, because a device run has five prerequisites that each fail in a
# way that looks like a test failure: a homeserver that is up *and* healthy,
# accounts that exist, a login rate limit raised high enough to survive two
# logins per test, an address the *device* can reach, and `patrol_cli` on PATH.
# Getting any of them wrong produces a red suite and a wrong diagnosis.
#
# The matrix, and what each row can actually run, is docs/quality/e2e-matrix.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/tooling/docker/compose.yaml"
SYNAPSE_DATA="$REPO_ROOT/tooling/docker/synapse-data"
HOMESERVER_CONFIG="$SYNAPSE_DATA/homeserver.yaml"
APP_DIR="$REPO_ROOT/apps/weft"

DEVICE=""
TARGET=""
HOMESERVER=""
PASSWORD="${WEFT_TEST_PASSWORD:-weft-test-password}"
KEEP=0
PATROL_ARGS=()

usage() {
  cat <<'EOF'
Usage: tooling/scripts/e2e.sh [options] [-- <extra patrol test args>]

  -d, --device <id>       Device to run on. Defaults to the only attached
                          Android device, if there is exactly one.
  -t, --target <path>     One test file instead of the whole suite. Relative to
                          apps/weft.
      --homeserver <h:p>  Override the address the *device* reaches Synapse on.
                          Inferred from the device when not given.
      --keep              Leave the homeserver running afterwards.
      --no-seed           Skip account provisioning (they already exist).
  -h, --help              This.

Requires `patrol_cli` on PATH:  dart pub global activate patrol_cli
EOF
}

SEED=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device) DEVICE="$2"; shift 2 ;;
    -t|--target) TARGET="$2"; shift 2 ;;
    --homeserver) HOMESERVER="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --no-seed) SEED=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; PATROL_ARGS=("$@"); break ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- prerequisites ---------------------------------------------------------
#
# Checked before anything is started, so a missing tool costs no container.

command -v docker >/dev/null || fail "docker is not on PATH"
command -v patrol >/dev/null || fail \
  "patrol_cli is not on PATH. Install it with:
    dart pub global activate patrol_cli
  It is a global tool on purpose and must never be a pubspec dependency —
  the workspace is a single resolution unit and has already lost packages to
  analyzer conflicts."

# --- the homeserver --------------------------------------------------------

# synapse-data/ is gitignored (it holds a signing key and a config with
# registration wide open), so a fresh clone has no homeserver.yaml at all and
# `compose up` on a missing config fails with a message about the wrong thing.
if [[ ! -f "$HOMESERVER_CONFIG" ]]; then
  step "Generating Synapse config (first run)"
  mkdir -p "$SYNAPSE_DATA"
  docker run --rm -v "$SYNAPSE_DATA:/data" \
    -e SYNAPSE_SERVER_NAME=localhost -e SYNAPSE_REPORT_STATS=no \
    matrixdotorg/synapse:latest generate
fi

# Two separate appends, each guarded, because the two halves are needed for
# different reasons and a config may already have one.
if ! grep -q '^enable_registration:' "$HOMESERVER_CONFIG"; then
  step "Opening registration for the test stack"
  cat >>"$HOMESERVER_CONFIG" <<'EOF'

enable_registration: true
enable_registration_without_verification: true
registration_shared_secret: "weft-test-shared-secret"
EOF
fi

# The one that bites mid-matrix rather than at startup. Thirteen scenarios that
# log two accounts in each is 26 calls to /login in a few minutes; Synapse's
# default limiter starts returning 429 partway through, and a 429 on login is
# surfaced by the app as a failed sign-in. It reads exactly like a wrong
# password, on a different test each run. `.github/workflows/ci.yaml` raises the
# same limits for the same reason.
if ! grep -q '^rc_login:' "$HOMESERVER_CONFIG"; then
  step "Raising the login rate limit"
  cat >>"$HOMESERVER_CONFIG" <<'EOF'

rc_login:
  address: { per_second: 100, burst_count: 100 }
  account: { per_second: 100, burst_count: 100 }
EOF
fi

teardown() {
  local status=$?
  if [[ $KEEP -eq 1 ]]; then
    printf '\n(homeserver left running: docker compose -f %s down)\n' "$COMPOSE_FILE"
  else
    step "Stopping the homeserver"
    docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1 || true
  fi
  exit $status
}

step "Starting the homeserver"
# `--wait` blocks on the healthcheck in compose.yaml rather than sleeping, so a
# slow first boot is slow rather than flaky.
docker compose -f "$COMPOSE_FILE" up -d --wait
trap teardown EXIT

if [[ $SEED -eq 1 ]]; then
  step "Seeding @alice and @bob"
  # Idempotent: a second run prints "already exists" and returns 0.
  WEFT_TEST_PASSWORD="$PASSWORD" "$REPO_ROOT/tooling/docker/seed.sh"
fi

# --- the device, and the address it can reach the homeserver on ------------
#
# `localhost:8008` is the *device's* loopback, not this machine's, and getting
# it wrong produces a connection error that looks like a homeserver that never
# came up. Weft resolves a bare host to http only for loopback, so 10.0.2.2 is
# passed with its scheme rather than bare.

if [[ -z "$DEVICE" ]] && command -v adb >/dev/null; then
  # A read loop rather than `mapfile`: macOS ships bash 3.2, where `mapfile`
  # does not exist, and this script's first user is a Mac.
  attached=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && attached+=("$line")
  done < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  if [[ ${#attached[@]} -eq 1 ]]; then
    DEVICE="${attached[0]}"
    echo "using the only attached Android device: $DEVICE"
  fi
fi

if [[ -z "$HOMESERVER" ]]; then
  case "$DEVICE" in
    emulator-*)
      # The emulator's fixed alias for the host's loopback. Not loopback by
      # Weft's own rule, hence the explicit scheme.
      HOMESERVER="http://10.0.2.2:8008"
      ;;
    "")
      HOMESERVER="localhost:8008"
      ;;
    *)
      if command -v adb >/dev/null && adb -s "$DEVICE" get-state >/dev/null 2>&1; then
        # A physical Android device. `adb reverse` makes the device's own
        # loopback point back here, which keeps the address identical to every
        # other row instead of depending on this machine's LAN address.
        step "Reversing tcp:8008 onto $DEVICE"
        adb -s "$DEVICE" reverse tcp:8008 tcp:8008
        HOMESERVER="localhost:8008"
      else
        # iOS simulator and macOS share this machine's network stack.
        HOMESERVER="localhost:8008"
      fi
      ;;
  esac
fi

# --- the run ---------------------------------------------------------------

cmd=(patrol test)
[[ -n "$TARGET" ]] && cmd+=(--target "$TARGET")
[[ -n "$DEVICE" ]] && cmd+=(--device "$DEVICE")
# Configuration reaches a compiled test binary as `String.fromEnvironment`;
# there is no shell on a device for `Platform.environment` to read.
cmd+=(--dart-define "WEFT_HOMESERVER=$HOMESERVER")
cmd+=(--dart-define "WEFT_TEST_PASSWORD=$PASSWORD")
cmd+=("${PATROL_ARGS[@]+"${PATROL_ARGS[@]}"}")

step "patrol test  (homeserver: $HOMESERVER)"
cd "$APP_DIR"
"${cmd[@]}"
