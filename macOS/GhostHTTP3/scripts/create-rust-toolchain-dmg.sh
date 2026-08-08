#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
build_dir=${GHOST_HTTP3_BUILD_DIR:-${project_dir}/.build}
image_dir=${build_dir}/toolchains
image_path=${GHOST_HTTP3_RUST_IMAGE:-${image_dir}/Rust-1.88.0-macOS-arm64.sparseimage}
mount_point=${GHOST_HTTP3_RUST_MOUNT:-${build_dir}/mount/GhostHTTP3Rust188}
volume_name=GhostHTTP3Rust188
rust_version=1.88.0

mkdir -p "${image_dir}"

if [[ ! -f ${image_path} ]]; then
    hdiutil create \
        -size 4g \
        -fs APFS \
        -volname "${volume_name}" \
        -type SPARSE \
        "${image_path}"
fi

if ! mount | grep -Fq " on ${mount_point} ("; then
    mkdir -p "${mount_point}"
    hdiutil attach -nobrowse -mountpoint "${mount_point}" "${image_path}"
fi

mkdir -p "${mount_point}/cargo" "${mount_point}/rustup" "${mount_point}/bootstrap"

rustup_init=${mount_point}/bootstrap/rustup-init
if [[ ! -x ${rustup_init} ]]; then
    curl --fail --location --show-error \
        https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init \
        -o "${rustup_init}"
    chmod 755 "${rustup_init}"
fi

if [[ ! -x ${mount_point}/cargo/bin/rustc ]]; then
    CARGO_HOME="${mount_point}/cargo" \
    RUSTUP_HOME="${mount_point}/rustup" \
        "${rustup_init}" \
            -y \
            --no-modify-path \
            --profile minimal \
            --default-toolchain "${rust_version}"
fi

CARGO_HOME="${mount_point}/cargo" \
RUSTUP_HOME="${mount_point}/rustup" \
    "${mount_point}/cargo/bin/rustup" target add \
        aarch64-apple-darwin

print "Rust toolchain image: ${image_path}"
print "Mounted at: ${mount_point}"
CARGO_HOME="${mount_point}/cargo" \
RUSTUP_HOME="${mount_point}/rustup" \
    "${mount_point}/cargo/bin/rustc" --version
