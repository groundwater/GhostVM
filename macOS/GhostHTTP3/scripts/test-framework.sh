#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
build_dir=${GHOST_HTTP3_BUILD_DIR:-${project_dir}/.build}
framework_dir=${build_dir}/artifacts/GhostHTTP3.framework
test_binary=${build_dir}/tests/ghost-http3-smoke
swift_test_binary=${build_dir}/tests/ghost-http3-swift-smoke

if [[ ! -d ${framework_dir} ]]; then
    print -u2 "error: GhostHTTP3.framework is missing; run build-framework.sh first"
    exit 1
fi

mkdir -p "${test_binary:h}"

xcrun clang \
    -F"${build_dir}/artifacts" \
    -framework GhostHTTP3 \
    -Wl,-rpath,@executable_path/../artifacts \
    "${project_dir}/Tests/smoke.c" \
    -o "${test_binary}"

"${test_binary}"

xcrun swiftc \
    -F"${build_dir}/artifacts" \
    -framework GhostHTTP3 \
    -Xlinker -rpath \
    -Xlinker @executable_path/../artifacts \
    "${project_dir}/Tests/smoke.swift" \
    -o "${swift_test_binary}"

"${swift_test_binary}"

file "${framework_dir}/GhostHTTP3"
[[ $(lipo -archs "${framework_dir}/GhostHTTP3") == arm64 ]]
otool -D "${framework_dir}/GhostHTTP3"
otool -L "${test_binary}" | \
    rg -q '@rpath/GhostHTTP3\.framework/Versions/A/GhostHTTP3'
codesign --verify --strict "${framework_dir}"
