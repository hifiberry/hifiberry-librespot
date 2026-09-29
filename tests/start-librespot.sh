#!/bin/bash
#
# Regression tests for start-librespot.sh.
#
# The wrapper calls /usr/bin/librespot and /usr/bin/config-soundcard by
# absolute path, so the tests install mocks there and must run in a
# disposable container, never on a device:
#
#   tests/start-librespot.sh
#
# re-executes itself as root in debian:trixie through docker. The mock
# librespot prints the stderr lines it is given and exits with the given
# status, which is all the wrapper sees of the real one.

set -u

if [ "${1:-}" != "--in-container" ]; then
  repo="$(cd "$(dirname "$0")/.." && pwd)"
  exec docker run --rm -v "$repo:/src:ro" debian:trixie \
    bash /src/tests/start-librespot.sh --in-container
fi

WRAPPER=/src/start-librespot.sh
WORK=$(mktemp -d)
FAILURES=0

# Mocks. hostnamectl, pgrep, avahi-browse and curl are found through PATH,
# so they go in /usr/local/bin; the two called by absolute path replace
# nothing real in a bare container.
mock() {
  local path="$1"
  shift
  printf '#!/bin/bash\n%s\n' "$*" > "$path"
  chmod +x "$path"
}
mock /usr/bin/config-soundcard 'exit 0'
mock /usr/local/bin/hostnamectl 'echo TestPlayer'
mock /usr/local/bin/pgrep 'exit 0'
mock /usr/local/bin/avahi-browse 'exit 0'
# shellcheck disable=SC2016 # expanded by the mocks, not here
mock /usr/local/bin/curl 'case "$*" in
  *api.spotify.com*) [ -n "${MOCK_ME:-}" ] || exit 22; echo "$MOCK_ME" ;;
  *) [ -n "${MOCK_TOKEN:-}" ] || exit 22; echo "$MOCK_TOKEN" ;;
esac'
# shellcheck disable=SC2016
mock /usr/bin/librespot '
printf "%s\n" "$@" > "$MOCK_ARGS"
[ -n "${MOCK_STDERR:-}" ] && printf "%s\n" "$MOCK_STDERR" >&2
exit "${MOCK_STATUS:-0}"'

REJECTED='[2026-09-28T12:00:00Z ERROR librespot] could not initialize spirc: Permission denied { Login failed with reason: Bad credentials }'
UNAVAILABLE='[2026-09-28T12:00:00Z ERROR librespot] could not initialize spirc: Service unavailable { transport returned no data }'

FREE_ACCOUNT='[2026-09-28T12:00:00Z ERROR librespot_core::session] librespot does not support "free" accounts.'

# Runs the wrapper against a fresh cache holding credentials.json. The
# command substitution only returns once every writer of the pipe has
# exited, the stderr filter included, so its work is done when run returns.
run() {
  CACHE="$WORK/cache.$RANDOM"
  mkdir -p "$CACHE"
  echo '{"username":"test"}' > "$CACHE/credentials.json"
  OUTPUT=$(SYSTEM_CACHE="$CACHE" MOCK_ARGS="$WORK/args" "$@" bash "$WRAPPER" 2>&1)
  STATUS=$?
}

check() {
  local description="$1"
  shift
  if "$@"; then
    echo "ok - $description"
  else
    echo "not ok - $description"
    FAILURES=$((FAILURES + 1))
  fi
}

kept() { [ -f "$CACHE/credentials.json" ] && [ ! -e "$CACHE/credentials.json.rejected" ]; }
set_aside() { [ ! -e "$CACHE/credentials.json" ] && [ -f "$CACHE/credentials.json.rejected" ]; }
not() { ! "$@"; }
logged() { grep -qF -- "$1" <<< "$OUTPUT"; }
passed() { grep -qxF -- "$1" "$WORK/args"; }

run env MOCK_STDERR="$REJECTED" MOCK_STATUS=1
check "rejected credentials are set aside" set_aside
check "librespot's exit status is preserved" [ "$STATUS" -eq 1 ]
check "librespot's error still reaches the journal" logged "$REJECTED"
check "setting the credentials aside is logged" logged "moved them to $CACHE/credentials.json.rejected"

run env MOCK_STDERR="${REJECTED/Bad credentials/Could not validate credentials}" MOCK_STATUS=1
check "credentials that cannot be validated are set aside" set_aside

run env MOCK_STDERR="${REJECTED/Bad credentials/Premium account required}" MOCK_STATUS=1
check "credentials of a free account are set aside" set_aside

# What librespot prints when the cached credentials are those of a free
# account: the login itself succeeds, so this is not a "Login failed" line.
run env MOCK_STDERR="$FREE_ACCOUNT" MOCK_STATUS=1
check "cached credentials of a free account are set aside" set_aside
check "the free account error still reaches the journal" logged "$FREE_ACCOUNT"

run env MOCK_STDERR="$UNAVAILABLE" MOCK_STATUS=1
check "a network failure keeps the credentials" kept

run env MOCK_STDERR="${REJECTED/Bad credentials/Try another access point}" MOCK_STATUS=1
check "running out of access points keeps the credentials" kept

run env MOCK_STATUS=1
check "a bare nonzero exit keeps the credentials" kept

run env MOCK_STATUS=0
check "a clean exit keeps the credentials" kept
check "the cache is passed to librespot" passed "--system-cache"

run env MOCK_TOKEN=token MOCK_STDERR="$REJECTED" MOCK_STATUS=1
check "a rejected audiocontrol token keeps the cached credentials" kept
check "the audiocontrol token is passed to librespot" passed "--access-token"

FREE='{"id":"x","product":"free","type":"user"}'
PREMIUM='{"id":"x","product":"premium","type":"user"}'

# librespot refuses a free account and exits 1, which systemd restarts every
# ten seconds for ever, so a token of a free account must never reach it.
run env MOCK_TOKEN=token MOCK_ME="$FREE" MOCK_STATUS=0
check "the token of a free account is not passed to librespot" not passed "--access-token"
check "a free account is logged" logged "not a premium account"
check "the cache is still passed without the token" passed "--system-cache"

run env MOCK_TOKEN=token MOCK_ME="${FREE/free/open}" MOCK_STATUS=0
check "the token of an open account is not passed to librespot" not passed "--access-token"

run env MOCK_TOKEN=token MOCK_ME="$PREMIUM" MOCK_STATUS=0
check "the token of a premium account is passed to librespot" passed "--access-token"

run env MOCK_TOKEN=token MOCK_STATUS=0
check "a token whose account cannot be looked up is still passed" passed "--access-token"

run env MOCK_TOKEN=token MOCK_ME='{"error":"unexpected"}' MOCK_STATUS=0
check "a reply without a product is not taken for a free account" passed "--access-token"

run env MOCK_TOKEN=token MOCK_ME="$FREE" MOCK_STATUS=1 MOCK_STDERR="$REJECTED"
check "cached credentials are still watched when the token is dropped" set_aside

CACHE="$WORK/cache.missing"
mkdir -p "$CACHE"
OUTPUT=$(SYSTEM_CACHE="$CACHE" MOCK_ARGS="$WORK/args" MOCK_STDERR="$REJECTED" MOCK_STATUS=1 bash "$WRAPPER" 2>&1)
STATUS=$?
check "a missing credentials file does not break the filter" [ "$STATUS" -eq 1 ]
check "a missing credentials file is not reported as set aside" not logged "moved them"

CACHE="$WORK/cache.rotate"
mkdir -p "$CACHE"
echo old > "$CACHE/credentials.json.rejected"
echo new > "$CACHE/credentials.json"
OUTPUT=$(SYSTEM_CACHE="$CACHE" MOCK_ARGS="$WORK/args" MOCK_STDERR="$REJECTED" MOCK_STATUS=1 bash "$WRAPPER" 2>&1)
check "a newer rejection replaces an older one" [ "$(cat "$CACHE/credentials.json.rejected")" = new ]

OUTPUT=$(SYSTEM_CACHE='' MOCK_ARGS="$WORK/args" MOCK_STDERR="$REJECTED" MOCK_STATUS=1 bash "$WRAPPER" 2>&1)
STATUS=$?
check "without persistence librespot still starts" [ "$STATUS" -eq 1 ]
check "without persistence no cache is passed" not passed "--system-cache"

OUTPUT=$(CACHED_CREDENTIALS="$WORK/elsewhere" SYSTEM_CACHE='' MOCK_ARGS="$WORK/args" MOCK_STDERR="$REJECTED" MOCK_STATUS=1 bash "$WRAPPER" 2>&1)
check "the environment cannot point the filter at another file" not logged "moved them"

rm -rf "$WORK"
if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES failure(s)"
  exit 1
fi
echo "all passed"
