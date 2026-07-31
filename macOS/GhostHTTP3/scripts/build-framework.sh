#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
build_dir=${GHOST_HTTP3_BUILD_DIR:-${project_dir}/.build}
source_dir=${build_dir}/upstream/quiche
output_dir=${build_dir}/artifacts
deployment_target=${MACOSX_DEPLOYMENT_TARGET:-15.0}
lock_file=${project_dir}/quiche-0.29.3.Cargo.lock

# quiche 0.29.3. Keep this immutable so the framework is reproducible.
quiche_revision=55886df3be579579207104c8e645825b6347a209
quiche_repository=https://github.com/cloudflare/quiche.git

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustup >/dev/null 2>&1; then
    print -u2 "error: Rust 1.88 or newer installed with rustup is required"
    exit 1
fi

rust_version=$(rustc --version | awk '{ print $2 }')
version_parts=(${(s:.:)rust_version})
if (( ${#version_parts} < 2 )) || \
   (( version_parts[1] < 1 )) || \
   (( version_parts[1] == 1 && version_parts[2] < 88 )); then
    print -u2 "error: could not determine the Rust compiler version"
    exit 1
fi

mkdir -p "${build_dir}/upstream" "${build_dir}/dylib" "${output_dir}"

if [[ ! -d ${source_dir}/.git ]]; then
    git clone --filter=blob:none --no-checkout "${quiche_repository}" "${source_dir}"
fi

git -C "${source_dir}" fetch --depth 1 origin "${quiche_revision}"
git -C "${source_dir}" checkout --detach --force "${quiche_revision}"
cp "${lock_file}" "${source_dir}/Cargo.lock"

actual_revision=$(git -C "${source_dir}" rev-parse HEAD)
if [[ ${actual_revision} != ${quiche_revision} ]]; then
    print -u2 "error: expected quiche ${quiche_revision}, got ${actual_revision}"
    exit 1
fi

target=aarch64-apple-darwin
cargo_target_dir=${build_dir}/cargo-dylib
wrapper_object=${build_dir}/dylib/GhostHTTP3.o

rustup target add "${target}" >/dev/null

xcrun clang \
    -arch arm64 \
    -fPIC \
    -mmacosx-version-min="${deployment_target}" \
    -I"${project_dir}/include" \
    -I"${source_dir}/quiche/include" \
    -c "${project_dir}/Sources/GhostHTTP3.c" \
    -o "${wrapper_object}"

# Ask Cargo for only a cdylib. The wrapper object is linked into that same
# image, producing one dynamic library that exports both the complete quiche C
# API and the small versioned GhostHTTP3 API. The explicit export roots keep
# the C wrapper visible through rustc's cdylib export list.
(
    cd "${source_dir}"
    MACOSX_DEPLOYMENT_TARGET="${deployment_target}" \
        cargo rustc \
            --locked \
            --release \
            --package quiche \
            --features ffi \
            --target "${target}" \
            --target-dir "${cargo_target_dir}" \
            --crate-type cdylib \
            -- \
            -C "link-arg=${wrapper_object}" \
            -C 'link-arg=-Wl,-u,_ghost_http3_api_version' \
            -C 'link-arg=-Wl,-u,_ghost_http3_backend_version' \
            -C 'link-arg=-Wl,-u,_ghost_http3_application_protocol' \
            -C 'link-arg=-Wl,-u,_ghost_http3_backend_is_ready' \
            -C 'link-arg=-Wl,-exported_symbol,_ghost_http3_api_version' \
            -C 'link-arg=-Wl,-exported_symbol,_ghost_http3_backend_version' \
            -C 'link-arg=-Wl,-exported_symbol,_ghost_http3_application_protocol' \
            -C 'link-arg=-Wl,-exported_symbol,_ghost_http3_backend_is_ready'
)

dylib_path=${cargo_target_dir}/${target}/release/libquiche.dylib
if [[ ! -f ${dylib_path} ]]; then
    print -u2 "error: Cargo did not produce the arm64 quiche dylib"
    exit 1
fi

framework_dir=${output_dir}/GhostHTTP3.framework
rm -rf "${framework_dir}" "${output_dir}/GhostHTTP3.xcframework"
mkdir -p \
    "${framework_dir}/Versions/A/Headers" \
    "${framework_dir}/Versions/A/Modules" \
    "${framework_dir}/Versions/A/Resources"

cp "${dylib_path}" "${framework_dir}/Versions/A/GhostHTTP3"

cp "${project_dir}/include/GhostHTTP3/GhostHTTP3.h" "${framework_dir}/Versions/A/Headers/GhostHTTP3.h"
cp "${source_dir}/quiche/include/quiche.h" "${framework_dir}/Versions/A/Headers/quiche.h"
cp "${project_dir}/include/module.modulemap" "${framework_dir}/Versions/A/Modules/module.modulemap"

info_plist=${framework_dir}/Versions/A/Resources/Info.plist
plutil -create xml1 "${info_plist}"
plutil -insert CFBundleDevelopmentRegion -string en "${info_plist}"
plutil -insert CFBundleExecutable -string GhostHTTP3 "${info_plist}"
plutil -insert CFBundleIdentifier -string com.ghostvm.GhostHTTP3 "${info_plist}"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "${info_plist}"
plutil -insert CFBundleName -string GhostHTTP3 "${info_plist}"
plutil -insert CFBundlePackageType -string FMWK "${info_plist}"
plutil -insert CFBundleShortVersionString -string 0.1.0 "${info_plist}"
plutil -insert CFBundleVersion -string 1 "${info_plist}"
plutil -insert MinimumOSVersion -string "${deployment_target}" "${info_plist}"

ln -s A "${framework_dir}/Versions/Current"
ln -s Versions/Current/GhostHTTP3 "${framework_dir}/GhostHTTP3"
ln -s Versions/Current/Headers "${framework_dir}/Headers"
ln -s Versions/Current/Modules "${framework_dir}/Modules"
ln -s Versions/Current/Resources "${framework_dir}/Resources"

xcrun install_name_tool \
    -id '@rpath/GhostHTTP3.framework/Versions/A/GhostHTTP3' \
    "${framework_dir}/Versions/A/GhostHTTP3"
codesign --force --sign - --timestamp=none "${framework_dir}"

file "${framework_dir}/GhostHTTP3" | rg -q 'Mach-O 64-bit dynamically linked shared library arm64'
[[ $(lipo -archs "${framework_dir}/GhostHTTP3") == arm64 ]]
otool -D "${framework_dir}/GhostHTTP3" | \
    rg -q '^@rpath/GhostHTTP3\.framework/Versions/A/GhostHTTP3$'

print "Built arm64 dynamic framework ${output_dir}/GhostHTTP3.framework"
