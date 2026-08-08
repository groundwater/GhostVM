#!/bin/sh
set -eu

GHOSTBOX=${GHOSTBOX:-ghostbox}
MANAGER=${MANAGER:-@manager/ephemeral}
IMAGE=${IMAGE:-docker.io/library/alpine:latest}

name="volume-test-$(date +%s)-$$"
volume="@volume/$name"
mount="@mount/$name"
container=
process=

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$container" ]; then
        "$GHOSTBOX" cn:container:stop "$container" >/dev/null 2>&1 || true
        "$GHOSTBOX" cn:manager:delete "$MANAGER" "$container" >/dev/null 2>&1 || true
    fi
    if [ -n "$process" ]; then
        "$GHOSTBOX" cn:process-config:delete "$process" >/dev/null 2>&1 || true
    fi
    "$GHOSTBOX" cn:mount:delete "$mount" >/dev/null 2>&1 || true
    "$GHOSTBOX" cr:volume:delete "$volume" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$GHOSTBOX" cr:volume:create "$name" --size 67108864 >/dev/null
"$GHOSTBOX" cr:volume:mount "$volume" "$name" --destination /data >/dev/null

run_container() {
    run_name=$1
    command=$2
    process="@process-config/$run_name-process"
    container="@container/$run_name"
    "$GHOSTBOX" cn:process-config:create "$run_name-process" -- /bin/sh -c "$command" >/dev/null

    set -- cn:manager:create-container "$MANAGER" "$run_name" \
        --reference "$IMAGE" --process "$process" --networking false
    for default_mount in $("$GHOSTBOX" cn:container:default-mounts); do
        set -- "$@" --mounts "$default_mount"
    done
    set -- "$@" --mounts "$mount"
    "$GHOSTBOX" "$@" >/dev/null
    "$GHOSTBOX" cn:container:create "$container"
    "$GHOSTBOX" cn:container:start "$container"
    status_json=$("$GHOSTBOX" cn:container:wait "$container")
    exit_code=$(printf '%s' "$status_json" | plutil -extract exitCode raw -o - -)
    [ "$exit_code" -eq 0 ]
    "$GHOSTBOX" cn:manager:delete "$MANAGER" "$container" >/dev/null
    "$GHOSTBOX" cn:process-config:delete "$process" >/dev/null
    container=
    process=
}

run_container "$name-write" 'printf persistent > /data/marker'
run_container "$name-read" 'test "$(cat /data/marker)" = persistent'

"$GHOSTBOX" cn:mount:delete "$mount"
"$GHOSTBOX" cr:volume:delete "$volume"
echo "persistent volume lifecycle passed"
