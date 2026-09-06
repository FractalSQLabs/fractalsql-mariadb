#!/bin/bash
#
# fractalsql-mariadb Docker build (v1: pure-C, vendored core archive).
#
# Drives docker/Dockerfile to produce fractalsql.so for one (arch, profile)
# combination per invocation:
#   dist/amd64/fractalsql.so              # modern (glibc 2.34)
#   dist/amd64/fractalsql-legacy.so       # legacy (glibc 2.28)
#
# Usage:
#   ./build.sh [amd64] [--profile=modern|legacy]
#   PROFILE=legacy ./build.sh amd64
#
# Profiles:
#   modern (default)  base rockylinux:9, glibc 2.34, GCC 11, no suffix
#   legacy            base manylinux_2_28_x86_64, glibc 2.28, GCC 8,
#                     -legacy suffix; uses the -legacy.a vendored variant
#
# v1 architecture limitation:
#   The vendored libfractalsql-community-minimal-c.a in include/ is
#   single-arch (matches the host that ran core's `make
#   validated-drop-native`). v1 supports amd64 only. Multi-arch
#   tracking issue lives at the fleet level.
#
# Refresh the vendored archive from the foundry:
#   cd ../fractalsql-core && make validated-drop-native
#   ./scripts/deploy.sh --git fractalsql-mariadb

set -euo pipefail

ARCH="${1:-amd64}"
case "${ARCH}" in
    amd64) ;;
    arm64) ;;  # Native build on ubuntu-24.04-arm runners.
    *) echo "unknown arch '${ARCH}': expected amd64 or arm64" >&2; exit 2 ;;
esac

PROFILE="${PROFILE:-modern}"
for arg in "$@"; do
    case "$arg" in
        --profile=*) PROFILE="${arg#--profile=}" ;;
    esac
done
case "${PROFILE}" in
    modern|legacy) ;;
    *) echo "unknown profile '${PROFILE}': expected modern or legacy" >&2; exit 2 ;;
esac

if [[ "${PROFILE}" = "legacy" ]]; then
    BASE_IMAGE="quay.io/pypa/manylinux_2_28_x86_64"
    OUTPUT_SUFFIX="-legacy"
    GLIBC_CEILING="28"
    SIZE_CEILING_BYTES="4194304"   # 4 MB
    CORE_VARIANT="community-sovereign-c-legacy"
else
    BASE_IMAGE="rockylinux:9"
    OUTPUT_SUFFIX=""
    GLIBC_CEILING="34"
    SIZE_CEILING_BYTES="3145728"   # 3 MB
    CORE_VARIANT="community-sovereign-c"
fi

DIST_DIR="${DIST_DIR:-./dist}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
PLATFORM="linux/${ARCH}"
OUT_DIR="${DIST_DIR}/${ARCH}"

mkdir -p "${OUT_DIR}"

echo "------------------------------------------"
echo "Building fractalsql-mariadb"
echo "  arch:     ${PLATFORM}"
echo "  profile:  ${PROFILE}"
echo "  base:     ${BASE_IMAGE}"
echo "  output:   ${OUT_DIR}/fractalsql${OUTPUT_SUFFIX}.so"
echo "  glibc<=:  2.${GLIBC_CEILING}"
echo "------------------------------------------"

DOCKER_BUILDKIT=1 docker buildx build \
    --platform "${PLATFORM}" \
    --target export \
    --output "type=local,dest=${OUT_DIR}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "OUTPUT_SUFFIX=${OUTPUT_SUFFIX}" \
    --build-arg "GLIBC_CEILING=${GLIBC_CEILING}" \
    --build-arg "SIZE_CEILING_BYTES=${SIZE_CEILING_BYTES}" \
    --build-arg "CORE_VARIANT=${CORE_VARIANT}" \
    -f "${DOCKERFILE}" \
    .

echo
echo "Built artifact for ${ARCH}/${PROFILE}:"
ls -l "${OUT_DIR}/fractalsql${OUTPUT_SUFFIX}.so"
file "${OUT_DIR}/fractalsql${OUTPUT_SUFFIX}.so" 2>/dev/null || true
