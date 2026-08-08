#!/bin/sh
set -eu

GHOSTBOX=${GHOSTBOX:-ghostbox}
MANAGER_NAME=${MANAGER_NAME:-ephemeral}
INITFS_REFERENCE=${INITFS_REFERENCE:-ghcr.io/apple/containerization/vminit@sha256:a69ff331d77997042afc3c7389969be176dfb657ec9ed46366c0e057ec40a297}

kernel=$("$GHOSTBOX" cn:kernel:install-recommended)
image_store=$("$GHOSTBOX" cn:image-store:default)

"$GHOSTBOX" cn:manager:create-from-reference "$MANAGER_NAME" \
    --kernel "$kernel" \
    --initfs-reference "$INITFS_REFERENCE" \
    --image-store "$image_store"
