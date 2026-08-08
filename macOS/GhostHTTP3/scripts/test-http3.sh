#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
build_dir=${GHOST_HTTP3_BUILD_DIR:-${project_dir}/.build}
framework_dir=${build_dir}/artifacts/GhostHTTP3.framework
examples_dir=${build_dir}/upstream/quiche/quiche/examples
test_dir=${build_dir}/tests
port=${GHOST_HTTP3_TEST_PORT:-$((30000 + ($$ % 20000)))}

if [[ ! -f /opt/homebrew/include/ev.h || ! -f /opt/homebrew/include/uthash.h ]]; then
    print -u2 "error: HTTP/3 integration test requires: brew install libev uthash"
    exit 1
fi

mkdir -p "${test_dir}"

common_flags=(
    -O2
    -I"${framework_dir}/Headers"
    -I/opt/homebrew/include
    -L/opt/homebrew/lib
    -F"${build_dir}/artifacts"
    -framework GhostHTTP3
    -Wl,-rpath,@executable_path/../artifacts
    -lev
)

xcrun clang "${common_flags[@]}" \
    "${examples_dir}/http3-server.c" \
    -o "${test_dir}/http3-server"

xcrun clang "${common_flags[@]}" \
    "${examples_dir}/http3-client.c" \
    -o "${test_dir}/http3-client"

server_log=${test_dir}/http3-server.log
client_log=${test_dir}/http3-client.log

(
    cd "${examples_dir}"
    exec "${test_dir}/http3-server" 127.0.0.1 "${port}"
) >"${server_log}" 2>&1 &
server_pid=$!

cleanup() {
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP

sleep 0.2
kill -0 "${server_pid}" 2>/dev/null || {
    print -u2 "error: HTTP/3 server failed to start on 127.0.0.1:${port}"
    tail -30 "${server_log}" >&2
    exit 1
}

(
    cd "${examples_dir}"
    exec "${test_dir}/http3-client" 127.0.0.1 "${port}"
) >"${client_log}" 2>&1

rg -q "connection established: h3" "${client_log}"
rg -q "got HTTP header: :status=200" "${client_log}"
rg -q "got HTTP header: content-length=5" "${client_log}"
rg -q "^byez" "${client_log}"
rg -q 'proto=Ok\("h3"\)' "${server_log}"

print "HTTP/3 interoperability passed: GET / -> 200, 5-byte body, ALPN h3"
rg "connection established: h3|got HTTP header: :status|got HTTP header: content-length|^byez" "${client_log}"
