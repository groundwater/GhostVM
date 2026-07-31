#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
build_dir=${GHOST_HTTP3_BUILD_DIR:-${project_dir}/.build}
framework_dir=${build_dir}/artifacts/GhostHTTP3.framework
examples_dir=${build_dir}/upstream/quiche/quiche/examples
test_dir=${build_dir}/tests
test_binary=${test_dir}/ghost-http3-stress

if [[ ! -d ${framework_dir} ]]; then
    print -u2 "error: GhostHTTP3.framework is missing; run build-framework.sh first"
    exit 1
fi

if [[ ! -f ${examples_dir}/cert.crt || ! -f ${examples_dir}/cert.key ]]; then
    print -u2 "error: quiche example TLS identity is missing; run build-framework.sh first"
    exit 1
fi

mkdir -p "${test_dir}"

sanitize_flags=()
if [[ ${GHOST_HTTP3_TEST_SANITIZERS:-0} == 1 ]]; then
    sanitize_flags=(
        -O1
        -fno-omit-frame-pointer
        -fsanitize=address,undefined
    )
fi

xcrun clang \
    -std=c17 \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -Wno-unused-parameter \
    "${sanitize_flags[@]}" \
    -F"${build_dir}/artifacts" \
    -framework GhostHTTP3 \
    -Wl,-rpath,@executable_path/../artifacts \
    "${project_dir}/Tests/stress.c" \
    -o "${test_binary}"

"${test_binary}" "${examples_dir}/cert.crt" "${examples_dir}/cert.key"
