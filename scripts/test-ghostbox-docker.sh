#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
WRAPPER=$ROOT/scripts/ghostbox-docker

sh -n "$WRAPPER"

help=$($WRAPPER --help)
case "$help" in
    *'Usage: ghostbox-docker COMMAND'*) ;;
    *)
        printf '%s\n' 'ghostbox-docker help does not use the packaged command name' >&2
        exit 1
        ;;
esac

case "$help" in
    *'compose'*)
        printf '%s\n' 'ghostbox-docker help advertises unsupported Compose functionality' >&2
        exit 1
        ;;
esac

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghostbox-docker-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

fake_ghostbox=$test_dir/ghostbox
packaged_wrapper=$test_dir/ghostbox-docker
log=$test_dir/invocations
cp "$WRAPPER" "$packaged_wrapper"
cat >"$fake_ghostbox" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GHOSTBOX_DOCKER_TEST_LOG"
case "$1" in
    cn:image-store:default) printf '%s\n' '@image-store/default' ;;
    cn:image-store:pull) printf '%s\n' '@image/pulled' ;;
    *) exit 99 ;;
esac
EOF
chmod 755 "$fake_ghostbox"

output=$(GHOSTBOX_DOCKER_TEST_LOG="$log" "$packaged_wrapper" pull alpine)
if [ "$output" != 'Pulled docker.io/library/alpine:latest (@image/pulled)' ]; then
    printf 'unexpected pull output: %s\n' "$output" >&2
    exit 1
fi

expected=$(printf '%s\n%s' \
    'cn:image-store:default' \
    'cn:image-store:pull @image-store/default docker.io/library/alpine:latest --platform linux/arm64')
actual=$(cat "$log")
if [ "$actual" != "$expected" ]; then
    printf 'unexpected Ghostbox invocations:\n%s\n' "$actual" >&2
    exit 1
fi

printf '%s\n' 'ghostbox-docker tests passed'
