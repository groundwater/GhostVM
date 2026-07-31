#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
build_dir=${GHOST_HTTP3_BUILD_DIR:-${project_dir}/.build}
mount_point=${GHOST_HTTP3_RUST_MOUNT:-${build_dir}/mount/GhostHTTP3Rust188}

"${script_dir}/create-rust-toolchain-dmg.sh"

export CARGO_HOME=${mount_point}/cargo
export RUSTUP_HOME=${mount_point}/rustup
export PATH=${CARGO_HOME}/bin:${PATH}

"${script_dir}/build-framework.sh"
"${script_dir}/test-framework.sh"
"${script_dir}/test-stress.sh"
"${script_dir}/test-http3.sh"
"${script_dir}/test-chaos.sh"

# Optional, bounded seed-progression soak. Off by default to keep CI builds
# under the framework build budget; enable with GHOST_HTTP3_SOAK=1 (and see
# the soak-chaos.sh env knobs for further tuning).
if [[ ${GHOST_HTTP3_SOAK:-0} == 1 ]]; then
    "${script_dir}/soak-chaos.sh"
fi

print "To detach the reusable toolchain: hdiutil detach ${mount_point}"
