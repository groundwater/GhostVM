#!/bin/zsh

set -u
set -o pipefail

mount_point=${1:-}
source_root=${2:-}
workers=${GHOSTFILE_STRESS_WORKERS:-8}
iterations=${GHOSTFILE_STRESS_ITERATIONS:-25}
mode=${GHOSTFILE_STRESS_MODE:-readonly}

if [[ -z "$mount_point" || -z "$source_root" ]]; then
    print -u2 "usage: $0 MOUNT_POINT SOURCE_ROOT"
    exit 64
fi

large_file="$mount_point/stress/alpha/large-image.png"
source_large="$source_root/stress/alpha/large-image.png"
small_file="$mount_point/probe.txt"
source_small="$source_root/probe.txt"
space_file="$mount_point/stress/beta/space name.txt"
unicode_file="$mount_point/stress/beta/unicode-π-世界.txt"
symlink_file="$mount_point/stress/beta/link-to-large"
broken_symlink="$mount_point/stress/beta/broken-link"
write_probe="$mount_point/__ghostfile_write_probe__.$$"
source_write_probe="$source_root/__ghostfile_write_probe__.$$"
directory_probe="$mount_point/__ghostfile_directory_probe__.$$"
source_directory_probe="$source_root/__ghostfile_directory_probe__.$$"
renamed_probe="$directory_probe/renamed-probe"
source_renamed_probe="$source_directory_probe/renamed-probe"

failures=0
checks=0

check() {
    local label=$1
    shift
    checks=$((checks + 1))
    if "$@"; then
        print "PASS $label"
    else
        print -u2 "FAIL $label"
        failures=$((failures + 1))
    fi
}

expect_failure() {
    local label=$1
    shift
    checks=$((checks + 1))
    if "$@" >/dev/null 2>&1; then
        print -u2 "FAIL $label unexpectedly succeeded"
        failures=$((failures + 1))
    else
        print "PASS $label rejected"
    fi
}

worker() {
    local worker_number=$1
    local loop_number
    local skip_blocks
    for ((loop_number = 0; loop_number < iterations; loop_number++)); do
        /usr/bin/stat -f '%z:%m:%i' "$large_file" >/dev/null || return 1
        /usr/bin/shasum -a 256 "$large_file" >/dev/null || return 1
        /bin/ls -la "$mount_point/stress/alpha" "$mount_point/stress/beta" >/dev/null || return 1
        /usr/bin/readlink "$symlink_file" >/dev/null || return 1
        /bin/cat "$small_file" "$space_file" "$unicode_file" >/dev/null || return 1
        skip_blocks=$(((worker_number * 97 + loop_number * 31) % 400))
        /bin/dd if="$large_file" of=/dev/null bs=4096 skip=$skip_blocks count=16 2>/dev/null || return 1
    done
}

mount_is_fskit() {
    local resolved_mount_point
    local volume_mount_point
    resolved_mount_point=$(cd "$mount_point" && /bin/pwd -P) || return 1
    # `mount_point` may intentionally target a subdirectory of the volume so a
    # self-test can stay inside a disposable fixture. Resolve its enclosing
    # filesystem before checking the FSKit mount flags.
    volume_mount_point=$(/bin/df -P "$resolved_mount_point" | /usr/bin/sed -n '2s/^.*%  *//p') || return 1
    [[ -n "$volume_mount_point" ]] || return 1
    /sbin/mount | /usr/bin/grep -F " on $volume_mount_point " | /usr/bin/grep -F "fskit" >/dev/null
}

print "GhostFile stress target: $mount_point"
print "workers=$workers iterations=$iterations mode=$mode"

if [[ "$mode" != "readonly" && "$mode" != "writable" ]]; then
    print -u2 "GHOSTFILE_STRESS_MODE must be readonly or writable"
    exit 64
fi

check "mount is FSKit" mount_is_fskit
check "source and mounted large file match" /usr/bin/cmp -s "$source_large" "$large_file"
check "source and mounted small file match" /usr/bin/cmp -s "$source_small" "$small_file"
check "space-containing filename" /usr/bin/cmp -s "$source_small" "$space_file"
check "UTF-8 filename" /usr/bin/cmp -s "$source_small" "$unicode_file"
check "symlink target" test "$(/usr/bin/readlink "$symlink_file")" = "../../alpha/large-image.png"
check "broken symlink remains a symlink" test -L "$broken_symlink"
expect_failure "broken symlink content read" /bin/cat "$broken_symlink"

for ((enumeration = 0; enumeration < 100; enumeration++)); do
    /usr/bin/find "$mount_point" -maxdepth 5 -print >/dev/null || {
        print -u2 "FAIL recursive enumeration at iteration $enumeration"
        failures=$((failures + 1))
        break
    }
done
checks=$((checks + 1))
if ((failures == 0)); then
    print "PASS 100 recursive enumerations"
fi

typeset -a worker_pids
for ((worker_number = 0; worker_number < workers; worker_number++)); do
    worker "$worker_number" &
    worker_pids+=("$!")
done

parallel_failure=0
for worker_pid in $worker_pids; do
    if ! wait "$worker_pid"; then
        parallel_failure=1
    fi
done
checks=$((checks + 1))
if ((parallel_failure == 0)); then
    print "PASS $((workers * iterations)) parallel operation batches"
else
    print -u2 "FAIL parallel operation batches"
    failures=$((failures + 1))
fi

if [[ "$mode" == "readonly" ]]; then
    expect_failure "file creation on read-only mount" /usr/bin/touch "$write_probe"
    expect_failure "directory creation on read-only mount" /bin/mkdir "$directory_probe"
    expect_failure "hard-link creation on read-only mount" /bin/ln "$small_file" "$write_probe"
    expect_failure "metadata mutation on read-only mount" /bin/chmod u+x "$small_file"
    check "failed mutations left no file" test ! -e "$write_probe"
    check "failed mutations left no directory" test ! -e "$directory_probe"
else
    cleanup_writable_probes() {
        /bin/rm -f "$renamed_probe" "$write_probe" >/dev/null 2>&1 || true
        /bin/rmdir "$directory_probe" >/dev/null 2>&1 || true
    }
    trap cleanup_writable_probes EXIT

    check "file creation through writable mount" /bin/sh -c \
        'printf "ghostfile writable stress\n" > "$1"' sh "$write_probe"
    check "created file is source-visible" /usr/bin/cmp -s "$write_probe" "$source_write_probe"
    check "directory creation through writable mount" /bin/mkdir "$directory_probe"
    check "created directory is source-visible" test -d "$source_directory_probe"
    check "metadata mutation through writable mount" /bin/chmod 640 "$write_probe"
    check "metadata mutation is source-visible" test "$(/usr/bin/stat -f %Lp "$source_write_probe")" = 640
    check "rename through writable mount" /bin/mv "$write_probe" "$renamed_probe"
    check "rename is source-visible" test -f "$source_renamed_probe"
    check "truncate through writable mount" /usr/bin/truncate -s 7 "$renamed_probe"
    check "truncate is source-visible" test "$(/usr/bin/stat -f %z "$source_renamed_probe")" = 7
    expect_failure "unsupported hard-link creation" /bin/ln "$small_file" "$write_probe"
    check "file deletion through writable mount" /bin/rm "$renamed_probe"
    check "file deletion is source-visible" test ! -e "$source_renamed_probe"
    check "directory deletion through writable mount" /bin/rmdir "$directory_probe"
    check "directory deletion is source-visible" test ! -e "$source_directory_probe"
    trap - EXIT
fi

print "checks=$checks failures=$failures"
exit "$failures"
