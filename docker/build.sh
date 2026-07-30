#!/bin/sh
#
# iperf3, Copyright (c) 2014-2026, The Regents of the University of
# California, through Lawrence Berkeley National Laboratory (subject
# to receipt of any required approvals from the U.S. Dept. of
# Energy).  All rights reserved.
#
# build.sh — In-container build script for static iperf3 binaries.
# Designed to run inside the iperf3-builder Docker container.
#
# Environment variables read:
#   BUILD_CLEAN    — "true" ⇒ make distclean before building
#   NO_PLATFORM_CHECK — "true" ⇒ skip platform guard (not used by iperf3,
#                       kept for interface compatibility)
#   UID, GID       — chown output to this uid:gid
#

set -e

echo "=== iperf3 static build ==="
echo "  Host arch : $(uname -m)"
echo "  Clean     : ${BUILD_CLEAN:-false}"

cd /app

# ---------------------------------------------------------------------------
# 1. Bootstrap autotools (generate configure from configure.ac)
#    The pre-generated configure in the repo may carry assumptions from the
#    host system.  Regenerating inside the container ensures it matches the
#    Alpine/musl toolchain and target arch.
# ---------------------------------------------------------------------------
echo "=== Bootstrapping autotools ==="
if [ -f "./bootstrap.sh" ]; then
    ./bootstrap.sh
else
    echo "WARN: bootstrap.sh not found, attempting autoreconf directly"
    autoreconf -fvi
fi

# ---------------------------------------------------------------------------
# 2. Configure for static binary
# ---------------------------------------------------------------------------
echo "=== Configuring for static build ==="

# Remove any stale config.cache from previous archs
rm -f config.cache

# iperf3_config_static_bin.m4 maps --enable-static-bin to:
#   enable_static=yes enable_shared=no LDFLAGS="$LDFLAGS --static"
./configure \
    --enable-static-bin \
    --with-openssl=no \
    CFLAGS="-O2 -Wall" \
    LDFLAGS="-static" \
    2>&1 | tee /tmp/configure.log

# Verify that LDFLAGS includes -static
if grep -q "LDFLAGS.*-static" /tmp/configure.log 2>/dev/null; then
    echo "OK: LDFLAGS includes -static"
else
    # Double-check config.log
    if grep "LDFLAGS" config.log | grep -q -- "-static"; then
        echo "OK: LDFLAGS includes -static (confirmed in config.log)"
    else
        echo "WARN: Could not verify -static in LDFLAGS.  Check config.log for details."
    fi
fi

# ---------------------------------------------------------------------------
# 3. Clean previous build artifacts (only when BUILD_CLEAN=true)
# ---------------------------------------------------------------------------
if [ "$BUILD_CLEAN" = "true" ]; then
    echo "=== Cleaning previous build ==="
    make clean 2>/dev/null || true
else
    echo "=== Incremental build — skipping make clean ==="
fi

# ---------------------------------------------------------------------------
# 4. Build
# ---------------------------------------------------------------------------
echo "=== Building iperf3 ==="
make -j$(nproc) 2>&1 | tee /tmp/build.log

# ---------------------------------------------------------------------------
# 5. Verify the binary is statically linked
# ---------------------------------------------------------------------------
echo "=== Verifying binary ==="
if [ -f "src/iperf3" ] && [ -x "src/iperf3" ]; then
    file src/iperf3

    # Check for dynamic linking.
    # musl's ldd says "Not a valid dynamic program" for static binaries;
    # glibc's ldd says "statically linked" or "not a dynamic executable".
    # We also check `file` output which is more reliable.
    LDD_OUTPUT=$(ldd src/iperf3 2>&1 || true)
    FILE_OUTPUT=$(file src/iperf3)

    if echo "$FILE_OUTPUT" | grep -q "statically linked"; then
        echo "OK: iperf3 is statically linked (confirmed by 'file')"
    elif echo "$LDD_OUTPUT" | grep -qi "not a dynamic executable\|statically linked"; then
        echo "OK: iperf3 is statically linked"
    else
        # On Alpine/musl, ldd exits non-zero for static binaries with
        # "Not a valid dynamic program", which is actually correct behavior.
        if echo "$LDD_OUTPUT" | grep -qi "not a valid dynamic"; then
            echo "OK: iperf3 is statically linked (musl confirms not a dynamic program)"
        else
            echo "WARN: unexpected ldd output — check manually:"
            echo "  file: $FILE_OUTPUT"
            echo "  ldd:  $LDD_OUTPUT"
        fi
    fi
else
    echo "ERROR: src/iperf3 not found or not executable!"
    ls -la src/iperf3 2>/dev/null || echo "  (binary not built)"
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Copy output and strip
# ---------------------------------------------------------------------------
echo "=== Copying output ==="
mkdir -p /app/out/stripped
mkdir -p /app/out/debug

# Debug copy (unstripped, with symbols)
cp src/iperf3 /app/out/debug/iperf3

# Stripped copy
strip -s src/iperf3 -o /app/out/stripped/iperf3 2>/dev/null || {
    echo "WARN: strip failed, copying unstripped binary"
    cp src/iperf3 /app/out/stripped/iperf3
}

# Show sizes
echo "Output sizes:"
ls -lh /app/out/debug/iperf3 /app/out/stripped/iperf3

echo "=== Static build complete ==="

# ---------------------------------------------------------------------------
# 7. Fix ownership (so files aren't root-owned on the host)
# ---------------------------------------------------------------------------
if [ -n "$UID" ] && [ -n "$GID" ]; then
    chown -R "$UID:$GID" /app/out
fi
