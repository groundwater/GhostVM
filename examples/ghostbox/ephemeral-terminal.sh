#!/bin/sh
set -eu

usage() {
    status=${1:-64}
    echo "usage: $0 [IMAGE [COMMAND [ARG ...]]]" >&2
    echo "environment: GHOSTBOX, MANAGER, CONTAINER_CPUS, CONTAINER_MEMORY, CONTAINER_NETWORKING" >&2
    exit "$status"
}

case ${1:-} in
    -h|--help) usage 0 ;;
esac

if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "$0: an interactive terminal is required" >&2
    exit 125
fi

GHOSTBOX=${GHOSTBOX:-ghostbox}
MANAGER=${MANAGER:-@manager/ephemeral}
CONTAINER_NETWORKING=${CONTAINER_NETWORKING:-false}
IMAGE=${1:-docker.io/library/alpine:latest}
if [ "$#" -gt 0 ]; then shift; fi
if [ "$#" -eq 0 ]; then set -- /bin/sh; fi

name="terminal-$(date +%s)-$$"
container="@container/$name"
terminal="@terminal/$name"
process="@process-config/$name-process"
controller_pid=

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$controller_pid" ]; then kill "$controller_pid" 2>/dev/null || true; fi
    "$GHOSTBOX" cn:terminal:close "$terminal" >/dev/null 2>&1 || true
    if [ -n "$controller_pid" ]; then wait "$controller_pid" 2>/dev/null || true; fi
    "$GHOSTBOX" cn:container:stop "$container" >/dev/null 2>&1 || true
    "$GHOSTBOX" cn:manager:delete "$MANAGER" "$container" >/dev/null 2>&1 || true
    "$GHOSTBOX" cn:process-config:delete "$process" >/dev/null 2>&1 || true
    exit "$status"
}

controller_cleanup() {
    "$GHOSTBOX" cn:terminal:close "$terminal" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$GHOSTBOX" cn:terminal:create "$name" >/dev/null
process=$("$GHOSTBOX" cn:process-config:create "$name-process" --terminal true -- "$@")
"$GHOSTBOX" cn:process-config:set-terminal-io "$process" "$terminal"

set -- cn:manager:create-container "$MANAGER" "$name" \
    --reference "$IMAGE" --process "$process" --networking "$CONTAINER_NETWORKING"
if [ -n "${CONTAINER_CPUS:-}" ]; then
    set -- "$@" --cpus "$CONTAINER_CPUS"
fi
if [ -n "${CONTAINER_MEMORY:-}" ]; then
    set -- "$@" --memory "$CONTAINER_MEMORY"
fi
"$GHOSTBOX" "$@" >/dev/null

controller() {
    trap controller_cleanup EXIT
    "$GHOSTBOX" cn:terminal:wait-attached "$terminal"
    "$GHOSTBOX" cn:container:create "$container"
    "$GHOSTBOX" cn:container:start "$container"

    status_json=$("$GHOSTBOX" cn:container:wait "$container")
    exit_code=$(printf '%s' "$status_json" | plutil -extract exitCode raw -o - -)
    return "$exit_code"
}

controller &
controller_pid=$!
"$GHOSTBOX" cn:terminal:attach "$terminal" --resize-target "$container"

set +e
wait "$controller_pid"
exit_code=$?
set -e
controller_pid=
exit "$exit_code"
