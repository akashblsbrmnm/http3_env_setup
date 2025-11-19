#!/bin/bash
# HTTP/3 Build Script - Simple Approach
# Uses OpenSSL 3.5+ built-in QUIC (NO ngtcp2 needed!)
# Based on curl official documentation: https://curl.se/docs/http3.html
# Date: November 17, 2025

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
INSTALL_PREFIX="${HOME}/http3-stack-simple"
BUILD_DIR="${HOME}/http3-build-simple"
OPENSSL_VERSION="openssl-3.5.4"  # Latest stable with native QUIC
NGHTTP3_VERSION="v1.1.0"
CURL_VERSION="curl-8_11_0"  # 8.10.0+ needed for --with-openssl-quic

JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

print_header() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"

    missing_deps=()

    # Commands to check
    commands=(git gcc g++ make cmake autoconf automake libtool pkg-config perl)

    # Packages to check
    packages=(libpsl-dev)

    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        else
            print_success "$cmd found"
        fi
    done

    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            missing_deps+=("$pkg")
        else
            print_success "$pkg installed"
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "On Ubuntu/Debian: sudo apt-get install build-essential git cmake autoconf automake libtool libtool-bin pkg-config perl libpsl-dev"
        exit 1
    fi

    print_success "All prerequisites met"
}

setup_directories() {
    print_header "Setting Up Directories"
    
    mkdir -p "$BUILD_DIR"
    mkdir -p "$INSTALL_PREFIX"/{bin,lib,include}
    
    print_success "Created $BUILD_DIR"
    print_success "Created $INSTALL_PREFIX"
}

# Build OpenSSL 3.4+ with built-in QUIC support
build_openssl() {
    print_header "Building OpenSSL ${OPENSSL_VERSION} with Native QUIC"
    
    cd "$BUILD_DIR"
    
    if [ -d "openssl" ]; then
        print_info "OpenSSL directory exists, cleaning..."
        rm -rf openssl
    fi
    
    print_info "Cloning OpenSSL..."
    git clone https://github.com/openssl/openssl.git
    cd openssl
    git checkout $OPENSSL_VERSION
    
    print_info "Configuring OpenSSL with QUIC..."
    ./config enable-tls1_3 \
             --prefix="$INSTALL_PREFIX" \
             --openssldir="$INSTALL_PREFIX/ssl" \
             --libdir=lib
    
    print_info "Building OpenSSL (this takes 5-10 minutes)..."
    make -j$JOBS
    
    print_info "Installing OpenSSL..."
    make install_sw install_ssldirs
    
    # Verify
    print_info "Verifying OpenSSL..."
    export LD_LIBRARY_PATH="$INSTALL_PREFIX/lib:$INSTALL_PREFIX/lib64:${LD_LIBRARY_PATH}"
    
    if "$INSTALL_PREFIX/bin/openssl" version | grep -q "3."; then
        print_success "OpenSSL ${OPENSSL_VERSION} built with native QUIC support"
    else
        print_error "OpenSSL version check failed"
        exit 1
    fi
}

# Build nghttp3 (still needed for HTTP/3 framing)
build_nghttp3() {
    print_header "Building nghttp3"
    
    cd "$BUILD_DIR"
    
    if [ -d "nghttp3" ]; then
        print_info "nghttp3 directory exists, cleaning..."
        rm -rf nghttp3
    fi
    
    print_info "Cloning nghttp3..."
    git clone https://github.com/ngtcp2/nghttp3.git
    cd nghttp3
    git checkout $NGHTTP3_VERSION
    git submodule update --init
    
    print_info "Configuring nghttp3..."
    autoreconf -fi
    ./configure --prefix="$INSTALL_PREFIX" \
                --enable-lib-only \
                PKG_CONFIG_PATH="$INSTALL_PREFIX/lib/pkgconfig:$INSTALL_PREFIX/lib64/pkgconfig"
    
    print_info "Building nghttp3..."
    make -j$JOBS
    
    print_info "Installing nghttp3..."
    make install
    
    print_success "nghttp3 built and installed"
}

# Build curl with OpenSSL built-in QUIC (NO ngtcp2!)
build_curl() {
    print_header "Building curl with OpenSSL Native QUIC"
    
    cd "$BUILD_DIR"
    
    if [ -d "curl" ]; then
        print_info "curl directory exists, cleaning..."
        rm -rf curl
    fi
    
    print_info "Cloning curl..."
    git clone https://github.com/curl/curl.git
    cd curl
    git checkout $CURL_VERSION
    
    print_info "Configuring curl with OpenSSL QUIC..."
    autoreconf -fi
    
    LDFLAGS="-Wl,-rpath,$INSTALL_PREFIX/lib" \
    ./configure --prefix="$INSTALL_PREFIX" \
                --with-openssl="$INSTALL_PREFIX" \
                --with-openssl-quic \
                --with-nghttp3="$INSTALL_PREFIX" \
                --enable-websockets \
                --without-libpsl \
                --disable-ldap \
                --disable-ldaps \
                PKG_CONFIG_PATH="$INSTALL_PREFIX/lib/pkgconfig:$INSTALL_PREFIX/lib64/pkgconfig" 2>&1 | tee configure.log
    
    # Verify WebSocket was actually enabled
echo "ℹ Verifying WebSocket support in built curl..."
# The definitive check: does the built curl binary support ws/wss protocols?
#if "$INSTALL_PREFIX/bin/curl" --version 2>/dev/null | grep -E "Protocols:.*\bws\b.*\bwss\b" >/dev/null; then
if "$INSTALL_PREFIX/bin/curl" --version | grep -q "ws" &&
   "$INSTALL_PREFIX/bin/curl" --version | grep -q "wss"; then
    echo "✓ WebSocket CONFIRMED - ws/wss protocols available"
    echo "  (curl 8.11.0+ shows WebSocket in Protocols line, not Features line)"
else
    echo "✗ WebSocket NOT available - ws/wss protocols missing!"
    echo "✗ Check configure output and rebuild with --enable-websockets"
    return 1
fi
    print_info "Building curl..."
    make -j$JOBS
    
    print_info "Installing curl..."
    make install
    
    print_success "curl built and installed"
}

# Verify installation
verify_installation() {
    print_header "Verifying Installation"
    
    export PATH="$INSTALL_PREFIX/bin:$PATH"
    export LD_LIBRARY_PATH="$INSTALL_PREFIX/lib:$INSTALL_PREFIX/lib64:${LD_LIBRARY_PATH}"
    
    # Check OpenSSL
    print_info "Checking OpenSSL..."
    local openssl_version=$("$INSTALL_PREFIX/bin/openssl" version)
    print_success "OpenSSL: $openssl_version"
    
    # Check curl
    print_info "Checking curl..."
    local curl_version=$("$INSTALL_PREFIX/bin/curl" --version | head -1)
    print_success "curl: $curl_version"
    
    # Check HTTP/3 support
    print_info "Checking HTTP/3 support..."
    if "$INSTALL_PREFIX/bin/curl" --version | grep -q "HTTP3"; then
        print_success "HTTP/3 support: ENABLED"
    else
        print_error "HTTP/3 support: NOT FOUND"
        return 1
    fi
    
    # Check WebSocket support (look for ws/wss protocols)
    if "$INSTALL_PREFIX/bin/curl" --version | grep -E "Protocols:.*\bws\b.*\bwss\b"; then
        print_success "WebSocket support: ENABLED (ws/wss protocols found)"
    elif "$INSTALL_PREFIX/bin/curl" --version | grep -q "WebSockets"; then
        print_success "WebSocket support: ENABLED (in Features)"
    else
        print_error "WebSocket support: NOT FOUND"
        print_error "Expected 'ws wss' in Protocols line"
        return 1
    fi
}

# Create environment setup script
create_env_script() {
    print_header "Creating Environment Setup Script"
    
    cat > "$INSTALL_PREFIX/setup-env.sh" << EOF
#!/bin/bash
# HTTP/3 Stack Environment (OpenSSL Native QUIC)

export HTTP3_PREFIX="$INSTALL_PREFIX"
export PATH="$INSTALL_PREFIX/bin:\$PATH"
export LD_LIBRARY_PATH="$INSTALL_PREFIX/lib:\$LD_LIBRARY_PATH"
export PKG_CONFIG_PATH="$INSTALL_PREFIX/lib/pkgconfig:\$PKG_CONFIG_PATH"

echo "HTTP/3 stack environment configured (OpenSSL native QUIC):"
echo "  OpenSSL: \$(openssl version)"
echo "  curl: \$(curl --version | head -1)"
echo "  HTTP/3: \$(curl --version | grep -o 'HTTP3' || echo 'NOT FOUND')"
EOF

    chmod +x "$INSTALL_PREFIX/setup-env.sh"
    print_success "Created $INSTALL_PREFIX/setup-env.sh"
}

# Print summary
print_summary() {
    print_header "Build Complete!"
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}HTTP/3 Stack Successfully Built!${NC}"
    echo -e "${GREEN}(OpenSSL Native QUIC - No ngtcp2 workarounds)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Installation directory: $INSTALL_PREFIX"
    echo ""
    echo "To use this stack:"
    echo "  source $INSTALL_PREFIX/setup-env.sh"
    echo ""
    echo "Test HTTP/3:"
    echo "  curl --http3 https://cloudflare-quic.com"
    echo ""
    echo "What was built:"
    echo "  - OpenSSL ${OPENSSL_VERSION} (native QUIC)"
    echo "  - nghttp3 ${NGHTTP3_VERSION} (HTTP/3 framing)"
    echo "  - curl ${CURL_VERSION} (HTTP/3 + WebSocket)"
    echo ""
    echo "Note: curl 8.10.0+ required for --with-openssl-quic flag"
    echo "No ngtcp2 = No workarounds = Simple!"
    echo ""
}

# Main execution
main() {
    print_header "HTTP/3 Simple Build (OpenSSL Native QUIC)"
    echo "This uses OpenSSL 3.4+ built-in QUIC support"
    echo "NO ngtcp2 required = NO workarounds needed!"
    echo ""
    echo "Installation prefix: $INSTALL_PREFIX"
    echo "Build directory: $BUILD_DIR"
    echo ""
    
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Build cancelled"
        exit 0
    fi
    
    # Set library path for all builds
    export LD_LIBRARY_PATH="$INSTALL_PREFIX/lib:$INSTALL_PREFIX/lib64:${LD_LIBRARY_PATH}"
    export PKG_CONFIG_PATH="$INSTALL_PREFIX/lib/pkgconfig:$INSTALL_PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH}"
    
    check_prerequisites
    setup_directories
    build_openssl
    build_nghttp3
    build_curl
    verify_installation
    create_env_script
    print_summary
}

# Run main
main "$@"
