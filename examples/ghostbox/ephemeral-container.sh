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

GHOSTBOX=${GHOSTBOX:-ghostbox}
MANAGER=${MANAGER:-@manager/ephemeral}
CONTAINER_NETWORKING=${CONTAINER_NETWORKING:-false}
IMAGE=${1:-docker.io/library/alpine:latest}
if [ "$#" -gt 0 ]; then shift; fi
if [ "$#" -eq 0 ]; then
    # Expanded by the container's shell, not this script.
    set -- /bin/sh -c 'echo "hello from $(uname -s) $(uname -m)"'
fi

name="ephemeral-$(date +%s)-$$"
container="@container/$name"
stdout="@writer/$name-stdout"
stderr="@writer/$name-stderr"
process="@process-config/$name-process"
stdout_pid=
stderr_pid=

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    "$GHOSTBOX" cn:container:stop "$container" >/dev/null 2>&1 || true
    "$GHOSTBOX" cn:writer:close "$stdout" >/dev/null 2>&1 || true
    "$GHOSTBOX" cn:writer:close "$stderr" >/dev/null 2>&1 || true
    if [ -n "$stdout_pid" ]; then wait "$stdout_pid" 2>/dev/null || true; fi
    if [ -n "$stderr_pid" ]; then wait "$stderr_pid" 2>/dev/null || true; fi
    "$GHOSTBOX" cn:manager:delete "$MANAGER" "$container" >/dev/null 2>&1 || true
    "$GHOSTBOX" cn:process-config:delete "$process" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$GHOSTBOX" cn:writer:create "$name-stdout" >/dev/null
"$GHOSTBOX" cn:writer:create "$name-stderr" >/dev/null
process=$("$GHOSTBOX" cn:process-config:create "$name-process" \
    --stdout "$stdout" --stderr "$stderr" -- "$@")

set -- cn:manager:create-container "$MANAGER" "$name" \
    --reference "$IMAGE" --process "$process" --networking "$CONTAINER_NETWORKING"
if [ -n "${CONTAINER_CPUS:-}" ]; then
    set -- "$@" --cpus "$CONTAINER_CPUS"
fi
if [ -n "${CONTAINER_MEMORY:-}" ]; then
    set -- "$@" --memory "$CONTAINER_MEMORY"
fi
"$GHOSTBOX" "$@" >/dev/null

"$GHOSTBOX" cn:writer:attach "$stdout" &
stdout_pid=$!
"$GHOSTBOX" cn:writer:attach "$stderr" >&2 &
stderr_pid=$!

"$GHOSTBOX" cn:container:create "$container"
"$GHOSTBOX" cn:container:start "$container"
status_json=$("$GHOSTBOX" cn:container:wait "$container")
exit_code=$(printf '%s' "$status_json" | plutil -extract exitCode raw -o - -)
exit "$exit_code"
