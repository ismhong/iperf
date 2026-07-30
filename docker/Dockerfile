FROM alpine:3.21

# Install build dependencies for static iperf3 builds
#   build-base       — gcc, musl-dev, make, etc.
#   autoconf         — autoreconf for bootstrapping
#   automake         — aclocal, automake
#   libtool          — libtoolize for LT_INIT support
#   linux-headers    — kernel headers for AF_XDP, TCP_ULP, etc.
#   openssl-dev      — static .a for libssl/libcrypto (full auth support)
#   zstd-dev         — optional: zstd compression (if iperf3 links it)
RUN apk add --no-cache \
    build-base \
    autoconf \
    automake \
    libtool \
    linux-headers \
    openssl-dev

WORKDIR /app

CMD ["/app/docker/build.sh"]
