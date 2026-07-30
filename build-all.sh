#!/bin/sh
#
# build-all.sh — Multi-arch Docker cross-build for static iperf3 binaries
#
# Usage:
#   ./build-all.sh                    Incremental build (arm64, skip make clean)
#   ./build-all.sh --arch x86_64      Build for a specific target arch
#   ./build-all.sh --clean            Full clean build (CI, cross-arch switch)
#   ./build-all.sh --rebuild          Force rebuild Docker images
#   ./build-all.sh --upx              Enable UPX compression of release binaries
#   ./build-all.sh -h, --help         Show this help message
#
# How Docker image caching works:
#   - The script checks if iperf3-builder-{arm64,x86_64} images exist locally.
#     If they do, it skips "docker build" entirely — just runs the container.
#   - The buildx builder is PERSISTENT (named "iperf3-multiarch-builder"), not
#     deleted on exit. Its BuildKit cache survives across runs, so even when
#     --rebuild is needed, the "RUN apk add" layer hits the cache.
#   - For CI: on a fresh node images don't exist → gets built once, then cached
#     by the Docker daemon. To optimize CI further, pre-push images to a registry.
#
# Output:
#   out/<arch>/stripped/iperf3    — Stripped static binary
#   out/<arch>/debug/iperf3       — Unstripped binary (with debug symbols)
#   out/<arch>/upx/iperf3         — UPX-compressed binary (only with --upx)
#
# Prerequisites:
#   - Docker with BuildKit (Docker 20.10+)
#   - For cross-arch builds: QEMU binfmt support (auto-installed if missing)
#

set -e

trap 'echo ""; echo "Interrupted — exiting."; exit 130' INT

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
FORCE_REBUILD=false
BUILD_CLEAN=false
TARGET_ARCHS="arm64"
DO_UPX=false

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
    cat <<'EOF'
Usage: ./build-all.sh [OPTION]

Multi-arch Docker cross-build for static iperf3 binaries (arm64, x86_64).
Default target is arm64. Use --arch to build for a different target.

Options:
  -h, --help               Show this help message and exit
  --arch <arch>            Target architecture(s). Default: arm64.
                           Examples: --arch x86_64, --arch "arm64 x86_64"
  --clean                  Full clean build (make clean before compile).
                           Default: incremental build (only recompiles changed files).
  --rebuild                Force rebuild of Docker images, even if already cached
  --upx                    Enable UPX compression of release binaries.
                           Default: UPX is skipped entirely.
  --no-rebuild             (deprecated) No-op; auto-detect now skips images if present

How it works:
  1. Builds Docker images for each target arch (auto-skipped if already present).
  2. Runs the build container for each arch via docker/build.sh.
     Build artifacts are reused across runs — only changed files are recompiled.
     Pass --clean for a pristine rebuild.
  3. Strips executables. UPX compression is optional (pass --upx to enable).

Environment:
  The build container mounts the repo root as /app, so source changes are
  picked up on every run. Build artifacts persist in the mounted out/
  directories for incremental builds.

Examples:
  ./build-all.sh                       Incremental build (arm64, fast)
  ./build-all.sh --arch x86_64         Incremental build (x86_64)
  ./build-all.sh --arch "arm64 x86_64" Build both arm64 and x86_64
  ./build-all.sh --clean               Full clean build (CI or release)
  ./build-all.sh --rebuild             Rebuild images after Dockerfile changes
  ./build-all.sh --upx                 Build with UPX compression
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        --arch)
            shift
            if [ -z "$1" ]; then
                echo "Error: --arch requires an argument (e.g., --arch x86_64)"
                exit 1
            fi
            TARGET_ARCHS="$1"
            echo "Build target(s): $TARGET_ARCHS"
            ;;
        --clean)
            BUILD_CLEAN=true
            echo "Clean build enabled — will run make clean inside container."
            ;;
        --rebuild)
            FORCE_REBUILD=true
            echo "Force rebuild enabled — will rebuild Docker images."
            ;;
        --no-rebuild)
            echo "Note: --no-rebuild is deprecated. Auto-detect handles this automatically."
            ;;
        --upx)
            DO_UPX=true
            echo "UPX compression enabled."
            ;;
        *)
            echo "Error: unknown option '$1'"
            show_help
            ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# UPX compression support — download and cache upx binary for the host arch
# ---------------------------------------------------------------------------
InstallUpx() {
    HOST_ARCH=$(uname -m)
    UPX_ARCH=""
    if [ "$HOST_ARCH" = "x86_64" ]; then
        UPX_ARCH="amd64"
    elif [ "$HOST_ARCH" = "aarch64" ]; then
        UPX_ARCH="arm64"
    else
        echo "Info: upx compression is not supported on '$HOST_ARCH'"
        return
    fi

    if [ -f "./upx" ]; then
        echo "UPX already downloaded."
        return
    fi

    UPX_VERSION="5.0.2"
    UPX_URL="https://github.com/upx/upx/releases/download/v${UPX_VERSION}/upx-${UPX_VERSION}-${UPX_ARCH}_linux.tar.xz"
    echo "Downloading UPX v${UPX_VERSION} (${UPX_ARCH})..."
    wget "${UPX_URL}" -O upx.tar.xz
    tar -xf upx.tar.xz
    mv "upx-${UPX_VERSION}-${UPX_ARCH}_linux/upx" ./upx
    rm upx.tar.xz
    rm -rf "upx-${UPX_VERSION}-${UPX_ARCH}_linux"
    chmod +x ./upx
}

if [ "$DO_UPX" = "true" ]; then
    InstallUpx
else
    echo "UPX compression not requested (use --upx to enable)."
fi

# ---------------------------------------------------------------------------
# Docker image build phase — only when needed
# ---------------------------------------------------------------------------
NEED_BUILD=false
for arch in $TARGET_ARCHS; do
    if ! docker image inspect "iperf3-builder-$arch" >/dev/null 2>&1; then
        echo "Image iperf3-builder-$arch not found locally — will build."
        NEED_BUILD=true
    fi
done

if [ "$FORCE_REBUILD" = true ] || [ "$NEED_BUILD" = true ]; then
    # Register QEMU binfmt interpreters for cross-arch Docker containers
    if ! ls /proc/sys/fs/binfmt_misc/qemu-* >/dev/null 2>&1; then
        echo "Registering QEMU binfmt interpreters..."
        docker run --rm --privileged tonistiigi/binfmt --install all
    else
        echo "QEMU binfmt interpreters already registered."
    fi

    for arch in $TARGET_ARCHS; do
        case "$arch" in
            arm64)  platform="linux/arm64" ;;
            x86_64) platform="linux/amd64" ;;
            *)      platform="linux/$arch" ;;
        esac

        echo "Building Docker image for $arch (platform: $platform)..."
        DOCKER_BUILDKIT=1 docker build \
            --platform "$platform" \
            -t "iperf3-builder-$arch" \
            -f docker/Dockerfile \
            .
    done
else
    echo "Docker images already exist — skipping image build."
fi

# ---------------------------------------------------------------------------
# Build execution phase — run build containers for each target arch
# ---------------------------------------------------------------------------
for arch in $TARGET_ARCHS; do
    case "$arch" in
        arm64)  platform="linux/arm64" ;;
        x86_64) platform="linux/amd64" ;;
        *)      platform="linux/$arch" ;;
    esac

    # Create output directory for the architecture
    mkdir -p "out/$arch"

    echo ""
    echo "================================================================="
    echo "  Building iperf3 for $arch"
    echo "================================================================="

    docker run --rm --init --platform "$platform" \
        -v "$(pwd):/app" \
        -v "$(pwd)/out/$arch:/app/out" \
        -e "UID=$(id -u)" \
        -e "GID=$(id -g)" \
        -e "BUILD_CLEAN=$BUILD_CLEAN" \
        "iperf3-builder-$arch"

    echo ""
    echo "Build for $arch complete. Verifying output..."
    file "out/$arch/stripped/iperf3"

    # -----------------------------------------------------------------------
    # UPX compression: only runs when --upx is explicitly requested
    # -----------------------------------------------------------------------
    if [ "$DO_UPX" = "true" ]; then
        UPX_DIR="out/$arch/upx"
        mkdir -p "$UPX_DIR"

        if [ -f "./upx" ]; then
            stripped_bin="out/$arch/stripped/iperf3"
            if [ -f "$stripped_bin" ] && [ -x "$stripped_bin" ]; then
                echo "Compressing iperf3 with UPX for $arch..."
                cp "$stripped_bin" "$UPX_DIR/iperf3"
                ./upx --best "$UPX_DIR/iperf3" 2>/dev/null || {
                    echo "  UPX: iperf3 (skipped — UPX may not support this arch)"
                    rm -f "$UPX_DIR/iperf3"
                }
            else
                echo "  Stripped binary not found, skipping UPX."
            fi
        else
            echo "UPX not available, skipping compression."
        fi
    else
        echo "Skipping UPX compression (use --upx to enable)."
    fi

    echo "---------------------------------"
done

# ---------------------------------------------------------------------------
# Size comparison summary (only meaningful after a clean build with UPX)
# ---------------------------------------------------------------------------
if [ "$DO_UPX" = "true" ] && [ -f "./upx" ]; then
    echo ""
    echo "=== Size comparison (stripped vs UPX) ==="
    for arch in $TARGET_ARCHS; do
        upx_dir="out/$arch/upx"
        stripped_dir="out/$arch/stripped"
        if [ -d "$upx_dir" ] && [ -d "$stripped_dir" ]; then
            echo "--- $arch ---"
            for exe in "$stripped_dir/"*; do
                bn=$(basename "$exe")
                upx_file="$upx_dir/$bn"
                if [ -f "$upx_file" ]; then
                    before=$(stat -c%s "$exe" 2>/dev/null || stat -f%z "$exe" 2>/dev/null)
                    after=$(stat -c%s "$upx_file" 2>/dev/null || stat -f%z "$upx_file" 2>/dev/null)
                    if [ "$before" -gt 0 ] 2>/dev/null; then
                        pct=$(( (before - after) * 100 / before ))
                        printf "  %-24s %s → %s (%d%% saved)\n" "$bn" \
                            "$(numfmt --to=iec $before 2>/dev/null || echo ${before}B)" \
                            "$(numfmt --to=iec $after 2>/dev/null || echo ${after}B)" \
                            "$pct"
                    fi
                fi
            done
        fi
    done
fi

echo ""
echo "All builds complete!"
