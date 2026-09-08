#!/bin/bash
#
# fractalsql-mariadb Docker build (pure-C, vendored core archive).
#
# Drives docker/Dockerfile to produce dist/<arch>/fractalsql.so for one
# architecture per invocation:
#   dist/amd64/fractalsql.so              # glibc 2.34 (rockylinux:9)
#   dist/arm64/fractalsql.so              # glibc 2.34 (rockylinux:9)
#
# One glibc profile, matching the vendored core drop: modern
# glibc-2.34 only (RHEL 9+, Ubuntu 22.04+, Debian 12+, SLES 15 SP5+).
#
# Usage:
#   ./build.sh [amd64|arm64]

set -euo pipefail

ARCH="${1:-amd64}"
case "${ARCH}" in
    amd64) ;;
    arm64) ;;  # Native build on ubuntu-24.04-arm runners.
    *) echo "unknown arch '${ARCH}': expected amd64 or arm64" >&2; exit 2 ;;
esac

BASE_IMAGE="rockylinux:9"
GLIBC_CEILING="34"
SIZE_CEILING_BYTES="3145728"   # 3 MB
CORE_VARIANT="community-sovereign-c"

DIST_DIR="${DIST_DIR:-./dist}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
PLATFORM="linux/${ARCH}"
OUT_DIR="${DIST_DIR}/${ARCH}"

mkdir -p "${OUT_DIR}"

echo "------------------------------------------"
echo "Building fractalsql-mariadb"
echo "  arch:     ${PLATFORM}"
echo "  base:     ${BASE_IMAGE}"
echo "  output:   ${OUT_DIR}/fractalsql.so"
echo "  glibc<=:  2.${GLIBC_CEILING}"
echo "------------------------------------------"

DOCKER_BUILDKIT=1 docker buildx build \
    --platform "${PLATFORM}" \
    --target export \
    --output "type=local,dest=${OUT_DIR}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "GLIBC_CEILING=${GLIBC_CEILING}" \
    --build-arg "SIZE_CEILING_BYTES=${SIZE_CEILING_BYTES}" \
    --build-arg "CORE_VARIANT=${CORE_VARIANT}" \
    -f "${DOCKERFILE}" \
    .

echo
echo "Built artifact for ${ARCH}:"
ls -l "${OUT_DIR}/fractalsql.so"
file "${OUT_DIR}/fractalsql.so" 2>/dev/null || true
