#!/bin/bash
#
# fractalsql-mariadb Docker build (pure-C, vendored core archive).
#
# Drives docker/Dockerfile to produce dist/<arch>/fractalsql.so (the
# shim) and dist/<arch>/fractalsqld (the daemon) for one architecture
# per invocation.
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

# Everything after the arch positional must be recognized: an
# unrecognized flag is rejected rather than silently ignored, because a
# build nobody asked for is worse than a build that refuses to start.
# (Counter skip instead of "${@:2}", which breaks under `set -u` with
# zero or one args on old bash -- macOS ships 3.2.)
_arg_i=0
for arg in "$@"; do
    _arg_i=$((_arg_i + 1))
    [[ ${_arg_i} -eq 1 ]] && continue
    echo "unknown argument '${arg}': this build takes only an arch (amd64|arm64)" >&2
    exit 2
done

BASE_IMAGE="rockylinux:9"
GLIBC_CEILING="34"
SIZE_CEILING_BYTES="3145728"   # 3 MB
CORE_VARIANT="community-sovereign-c"

DIST_DIR="${DIST_DIR:-./dist}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
# The arch -> platform mapping, dispatched explicitly rather than
# interpolated. The default arm is the last line of defense: an arch
# that somehow slips past the validation above must fail loudly here
# rather than produce a build for a platform nobody asked for.
case "${ARCH}" in
    amd64) PLATFORM="linux/amd64" ;;
    arm64) PLATFORM="linux/arm64" ;;
    *) echo "internal error: unhandled arch '${ARCH}' (validate it above)" >&2; exit 2 ;;
esac
OUT_DIR="${DIST_DIR}/${ARCH}"

mkdir -p "${OUT_DIR}"

echo "------------------------------------------"
echo "Building fractalsql-mariadb"
echo "  arch:     ${PLATFORM}"
echo "  base:     ${BASE_IMAGE}"
echo "  output:   ${OUT_DIR}/fractalsql.so, ${OUT_DIR}/fractalsqld"
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
ls -l "${OUT_DIR}/fractalsql.so" "${OUT_DIR}/fractalsqld" "${OUT_DIR}/fractalsql-mariadb-mcp"
file "${OUT_DIR}/fractalsql.so" "${OUT_DIR}/fractalsqld" "${OUT_DIR}/fractalsql-mariadb-mcp" 2>/dev/null || true
