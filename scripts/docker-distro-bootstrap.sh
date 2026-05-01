#!/usr/bin/env bash
# Wrapper around scripts/distro-bootstrap.sh that runs the bootstrap inside
# a docker container — so the user doesn't have to install debootstrap,
# qemu-user-static, mksquashfs, etc on their host.
#
# Usage: identical to distro-bootstrap.sh — args are passed through verbatim.
#   docker-distro-bootstrap.sh --distro debian --suite trixie
#   docker-distro-bootstrap.sh --distro ubuntu --packages "neovim htop"
#
# Builds the container image on demand (tagged from the Dockerfile's content
# hash so it auto-rebuilds when the Dockerfile changes; otherwise reuses).
#
# Why --privileged: debootstrap chroot + bind mounts (/dev, /proc, /sys)
# need CAP_SYS_ADMIN + CAP_SYS_CHROOT + CAP_MKNOD + access to /dev/loop*
# and /proc/sys/fs/binfmt_misc. --privileged is the lazy-but-portable way;
# a more surgical --cap-add list works too if you'd rather lock it down.
#
# Host binfmt_misc requirement: aarch64 must already be registered on the
# host kernel (the container inherits the host's binfmt). On most distros,
# installing qemu-user-static (or qemu-binfmt) does this automatically.
# Verify with `cat /proc/sys/fs/binfmt_misc/qemu-aarch64`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="$ROOT/docker/Dockerfile.distro-bootstrap"
IMAGE="panicos-distro-bootstrap"
TAG="$(sha1sum "$DOCKERFILE" 2>/dev/null | cut -c1-12)"
[ -n "$TAG" ] || TAG="dev"

# Pre-flight: host must have aarch64 binfmt registered, otherwise the
# container can't execute aarch64 binaries during the chroot second-stage.
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    cat >&2 <<EOF
ERROR: host kernel doesn't have aarch64 binfmt_misc registered.
       Install your distro's qemu-user-static package (and on some
       systems, run \`update-binfmts --enable qemu-aarch64\` once).

Verify with:
       cat /proc/sys/fs/binfmt_misc/qemu-aarch64
EOF
    exit 1
fi

# Build image if missing or stale.
if ! docker image inspect "$IMAGE:$TAG" >/dev/null 2>&1; then
    echo ">>> docker-distro-bootstrap: building $IMAGE:$TAG"
    docker build -t "$IMAGE:$TAG" -f "$DOCKERFILE" "$ROOT"
fi

# Cache dir on the host, surfaced into the container so debootstrap's
# bootstrap stage gets reused across runs (the script otherwise re-fetches
# all .deb files every time).
CACHE_HOST="${PANICOS_DISTRO_CACHE:-$HOME/.cache/panicos-distro-bootstrap}"
mkdir -p "$CACHE_HOST"

# Output dir — distro-bootstrap.sh defaults to $ROOT/output/distro/ inside
# the container. We mount the host's $ROOT at /work so output lands on the
# host filesystem.

# binfmt_misc registration is in /proc on the host kernel; the container
# inherits it via /proc but only if /proc is mounted, which docker does
# by default. No special bind needed.

DOCKER_TTY=""
[ -t 1 ] && DOCKER_TTY="-t"

exec docker run --rm -i $DOCKER_TTY \
    --privileged \
    -v "$ROOT:/work" \
    -v "$CACHE_HOST:/root/.cache/panicos-distro-bootstrap" \
    -e PANICOS_DISTRO_CACHE=/root/.cache/panicos-distro-bootstrap \
    -w /work \
    "$IMAGE:$TAG" \
    /work/scripts/distro-bootstrap.sh "$@"
