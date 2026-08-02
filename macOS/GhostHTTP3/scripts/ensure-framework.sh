#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
framework=${project_dir}/.build/artifacts/GhostHTTP3.framework
binary=${framework}/Versions/A/GhostHTTP3
fingerprint_file=${project_dir}/.build/artifacts/.source-fingerprint
source_fingerprint=$(
    shasum -a 256 \
        "${project_dir}/Sources/GhostHTTP3.c" \
        "${project_dir}/include/GhostHTTP3/GhostHTTP3.h" \
        "${project_dir}/include/module.modulemap" \
        "${project_dir}/quiche-0.29.3.Cargo.lock" \
        "${project_dir}/Patches/quiche-darwin-send-time.patch" \
        "${project_dir}/scripts/build-framework.sh" \
        "${project_dir}/scripts/ensure-framework.sh" | \
        shasum -a 256 | awk '{ print $1 }'
)

if [[ -f ${binary} ]] && \
   [[ $(lipo -archs "${binary}" 2>/dev/null) == arm64 ]] && \
   [[ -f ${fingerprint_file} ]] && \
   [[ $(<"${fingerprint_file}") == ${source_fingerprint} ]]; then
    print "GhostHTTP3 framework already built; skipping."
    exit 0
fi

if command -v cargo >/dev/null 2>&1 && command -v rustup >/dev/null 2>&1; then
    exec "${script_dir}/build-framework.sh"
fi

# Keep the Rust installation out of the host environment. The mounted image
# is reusable by later Xcode and Make builds.
build_dir=${GHOST_HTTP3_BUILD_DIR:-${project_dir}/.build}
mount_point=${GHOST_HTTP3_RUST_MOUNT:-${build_dir}/mount/GhostHTTP3Rust188}
"${script_dir}/create-rust-toolchain-dmg.sh"
export CARGO_HOME=${mount_point}/cargo
export RUSTUP_HOME=${mount_point}/rustup
export PATH=${CARGO_HOME}/bin:${PATH}
exec "${script_dir}/build-framework.sh"
