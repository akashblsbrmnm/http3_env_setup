# Single-stage Dockerfile that mirrors your HTTP/3 build script (non-interactive)
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG OPENSSL_VERSION="openssl-3.5.4"
ARG NGHTTP3_VERSION="v1.1.0"
ARG CURL_VERSION="curl-8_11_0"
ARG JOBS=4

# Where your stack will be installed (script used $HOME/http3-stack-simple; we use /opt)
ENV INSTALL_PREFIX=/opt/http3-stack-simple
ENV PATH="${INSTALL_PREFIX}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib:${INSTALL_PREFIX}/lib64:${LD_LIBRARY_PATH}"
ENV PKG_CONFIG_PATH="${INSTALL_PREFIX}/lib/pkgconfig:${INSTALL_PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH}"
ENV HTTP3_PREFIX="${INSTALL_PREFIX}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install build-time dependencies (single layer)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    build-essential gcc g++ make cmake autoconf automake libtool pkg-config perl \
    git curl wget ca-certificates python3 python3-pip gettext m4 libpsl-dev libwebsockets-dev \
 && rm -rf /var/lib/apt/lists/*

# Create dirs
RUN mkdir -p "${INSTALL_PREFIX}" /root/http3-build-simple

WORKDIR /root/http3-build-simple

# Build OpenSSL (native QUIC) — mirrors build_openssl()
RUN set -e; \
    echo "=== Building OpenSSL ${OPENSSL_VERSION} ==="; \
    if [ -d openssl ]; then rm -rf openssl; fi; \
    git clone https://github.com/openssl/openssl.git openssl; \
    cd openssl; git checkout ${OPENSSL_VERSION}; \
    ./config enable-tls1_3 --prefix="${INSTALL_PREFIX}" --openssldir="${INSTALL_PREFIX}/ssl" --libdir=lib; \
    make -j${JOBS}; make install_sw install_ssldirs; \
    echo "OpenSSL built and installed to ${INSTALL_PREFIX}"

# Build nghttp3 — mirrors build_nghttp3()
RUN set -e; \
    echo "=== Building nghttp3 ${NGHTTP3_VERSION} ==="; \
    if [ -d nghttp3 ]; then rm -rf nghttp3; fi; \
    git clone https://github.com/ngtcp2/nghttp3.git nghttp3; \
    cd nghttp3; git checkout ${NGHTTP3_VERSION}; git submodule update --init --recursive || true; \
    autoreconf -fi; \
    PKG_CONFIG_PATH="${INSTALL_PREFIX}/lib/pkgconfig:${INSTALL_PREFIX}/lib64/pkgconfig" ./configure --prefix="${INSTALL_PREFIX}" --enable-lib-only; \
    make -j${JOBS}; make install; \
    echo "nghttp3 built and installed to ${INSTALL_PREFIX}"

# Build curl with OpenSSL QUIC — mirrors build_curl()
RUN set -e; \
    echo "=== Building curl ${CURL_VERSION} ==="; \
    if [ -d curl ]; then rm -rf curl; fi; \
    git clone https://github.com/curl/curl.git curl; \
    cd curl; git checkout ${CURL_VERSION}; \
    autoreconf -fi; \
    export PKG_CONFIG_PATH="${INSTALL_PREFIX}/lib/pkgconfig:${INSTALL_PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH}"; \
    LDFLAGS="-Wl,-rpath,${INSTALL_PREFIX}/lib" ./configure --prefix="${INSTALL_PREFIX}" \
        --with-openssl="${INSTALL_PREFIX}" --with-openssl-quic --with-nghttp3="${INSTALL_PREFIX}" \
        --enable-websockets PKG_CONFIG_PATH="${PKG_CONFIG_PATH}"; \
    make -j${JOBS}; make install; \
    echo "curl built and installed to ${INSTALL_PREFIX}"

# Verify installation like verify_installation()
RUN set -e; \
    echo "=== Verifying installation ==="; \
    export PATH="${INSTALL_PREFIX}/bin:${PATH}"; \
    export LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib:${INSTALL_PREFIX}/lib64:${LD_LIBRARY_PATH}"; \
    if [ -x "${INSTALL_PREFIX}/bin/openssl" ]; then ${INSTALL_PREFIX}/bin/openssl version; else echo "openssl not found" && false; fi; \
    if [ -x "${INSTALL_PREFIX}/bin/curl" ]; then ${INSTALL_PREFIX}/bin/curl --version | head -1; else echo "curl not found" && false; fi; \
    if ${INSTALL_PREFIX}/bin/curl --version | grep -q "HTTP3"; then echo "HTTP/3 support: ENABLED"; else echo "ERROR: HTTP/3 support: NOT FOUND" && false; fi; \
    if ${INSTALL_PREFIX}/bin/curl --version | grep -q "WebSockets"; then echo "WebSocket support: ENABLED"; else echo "ERROR: WebSocket support: NOT FOUND"; fi

# Create setup-env.sh (same as original script) — combined into one RUN
RUN mkdir -p "${INSTALL_PREFIX}" \
 && cat > "${INSTALL_PREFIX}/setup-env.sh" <<'EOF'
#!/bin/bash
export HTTP3_PREFIX="/opt/http3-stack-simple"
export PATH="/opt/http3-stack-simple/bin:$PATH"
export LD_LIBRARY_PATH="/opt/http3-stack-simple/lib:$LD_LIBRARY_PATH"
export PKG_CONFIG_PATH="/opt/http3-stack-simple/lib/pkgconfig:$PKG_CONFIG_PATH"

echo "HTTP/3 stack activated"
echo "  OpenSSL: $(openssl version 2>/dev/null)"
echo "  curl: $(curl --version 2>/dev/null | head -1)"
echo "  HTTP/3: $(curl --version 2>/dev/null | grep -o 'HTTP3')"
EOF
RUN chmod +x "${INSTALL_PREFIX}/setup-env.sh"


WORKDIR /workspace
VOLUME ["/workspace"]
CMD ["/bin/bash"]
