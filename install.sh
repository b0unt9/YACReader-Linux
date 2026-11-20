#!/bin/sh
set -eu

# ==============================================================================
# YACReader Linux Universal Installer
# Usage:
#   curl -fsSL <URL> | sudo sh
#   curl -fsSL <URL> | sudo sh -s 10.5.1
#   curl -fsSL <URL> | sudo sh -s 10.5
#   curl -fsSL <URL> | sudo sh -s 10
#   curl -fsSL <URL> | sudo sh -s build        # Arch Linux: build via PKGBUILD
#   curl -fsSL <URL> | sudo sh -s 10.5 build   # Arch Linux: build specific version
# ==============================================================================

REPO="b0unt9/YACReader-Linux"
API_BASE="https://api.github.com/repos/${REPO}/releases"
DL_BASE="https://github.com/${REPO}/releases/download"

log() {
    printf '[YACReader] %s\n' "$1"
}

err() {
    printf '[YACReader] Error: %s\n' "$1" >&2
    exit 1
}

# 1. Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (e.g. curl -fsSL <URL> | sudo sh)."
fi

# 2. Check for available HTTP download tool (curl / wget)
if command -v curl >/dev/null 2>&1; then
    HTTP_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
    HTTP_TOOL="wget"
else
    err "Neither 'curl' nor 'wget' is installed."
fi

fetch_text() {
    if [ "$HTTP_TOOL" = "curl" ]; then
        curl -fsSL "$1"
    else
        wget -qO- "$1"
    fi
}

download_file() {
    if [ "$HTTP_TOOL" = "curl" ]; then
        curl -fL --progress-bar "$1" -o "$2"
    else
        wget -q --show-progress "$1" -O "$2"
    fi
}

# 3. Parse arguments ([X | X.Y | X.Y.Z] and [build])
REQ_VERSION=""
ARCH_BUILD=0

for arg in "$@"; do
    case "$arg" in
        build|--build)
            ARCH_BUILD=1
            ;;
        *)
            if [ -n "$REQ_VERSION" ]; then
                err "Unexpected extra argument: '$arg'"
            fi
            REQ_VERSION="${arg#v}"
            ;;
    esac
done

# 4. Detect CPU architecture
RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        err "Unsupported CPU architecture: ${RAW_ARCH}"
        ;;
esac

# 5. Detect OS and distribution version (parse /etc/os-release)
[ -r /etc/os-release ] || err "Cannot read /etc/os-release to detect OS."

OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_UBUNTU_CODENAME=""
OS_DEBIAN_CODENAME=""

while IFS='=' read -r key val; do
    # Strip leading and trailing quotes
    val="${val#\"}"
    val="${val%\"}"
    val="${val#\'}"
    val="${val%\'}"
    case "$key" in
        ID) OS_ID="$val" ;;
        ID_LIKE) OS_ID_LIKE="$val" ;;
        VERSION_ID) OS_VERSION_ID="$val" ;;
        UBUNTU_CODENAME) OS_UBUNTU_CODENAME="$val" ;;
        DEBIAN_CODENAME) OS_DEBIAN_CODENAME="$val" ;;
    esac
done < /etc/os-release

DISTRO=""
PKG_EXT=""

is_like() {
    case " ${OS_ID} ${OS_ID_LIKE} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

if is_like "ubuntu"; then
    PKG_EXT="deb"
    if [ "$OS_ID" = "ubuntu" ]; then
        case "$OS_VERSION_ID" in
            26.04|26.10|27.*)
                DISTRO="ubuntu-26.04"
                ;;
            24.04|24.10|25.*)
                DISTRO="ubuntu-24.04"
                ;;
            *)
                err "Unsupported Ubuntu version '${OS_VERSION_ID}' (requires Ubuntu 24.04 or newer)."
                ;;
        esac
    else
        # Ubuntu derivatives such as Linux Mint, Pop!_OS, etc.
        case "$OS_UBUNTU_CODENAME" in
            resolute*)
                DISTRO="ubuntu-26.04"
                ;;
            noble|oracular|plucky|questing)
                DISTRO="ubuntu-24.04"
                ;;
            *)
                err "Unsupported Ubuntu derivative (${OS_ID}, codename: '${OS_UBUNTU_CODENAME}')."
                ;;
        esac
    fi
elif is_like "debian"; then
    PKG_EXT="deb"
    case "${OS_VERSION_ID%%.*}:${OS_DEBIAN_CODENAME}" in
        12:*|*:bookworm)
            DISTRO="debian-12"
            [ "$ARCH" = "amd64" ] || err "Debian 12 package is only available for amd64."
            ;;
        13:*|14:*|*:trixie|*:forky|*:sid)
            DISTRO="debian-13"
            ;;
        *)
            err "Unsupported Debian version '${OS_VERSION_ID}' (requires Debian 12 or newer)."
            ;;
    esac
elif is_like "fedora"; then
    PKG_EXT="rpm"
    FEDORA_MAJOR="${OS_VERSION_ID%%.*}"
    case "$FEDORA_MAJOR" in
        43)
            DISTRO="fedora-43"
            ;;
        44)
            DISTRO="fedora-44"
            ;;
        *)
            if [ -n "$FEDORA_MAJOR" ] && [ "$FEDORA_MAJOR" -gt 44 ] 2>/dev/null; then
                DISTRO="fedora-44"
            else
                err "Unsupported Fedora version '${OS_VERSION_ID}' (requires Fedora 43 or newer)."
            fi
            ;;
    esac
elif [ "$OS_ID" = "alpine" ]; then
    DISTRO="alpine"
    PKG_EXT="apk"
elif is_like "arch" || [ "$OS_ID" = "archarm" ]; then
    DISTRO="archlinux"
    PKG_EXT="pkg.tar.zst"
else
    err "Unsupported Linux distribution: ${OS_ID}"
fi

if [ "$ARCH_BUILD" -eq 1 ] && [ "$DISTRO" != "archlinux" ]; then
    err "The 'build' option is only supported on Arch Linux."
fi

# 6. Resolve target release version (latest / X / X.Y / X.Y.Z)
resolve_version() {
    if [ -z "$REQ_VERSION" ]; then
        RELEASE_JSON="$(fetch_text "${API_BASE}/latest")" || err "Failed to fetch latest release metadata."
        TAG_NAME="$(printf '%s\n' "$RELEASE_JSON" \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -n 1 \
            | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
        [ -n "$TAG_NAME" ] || err "Could not determine latest release tag."
        VERSION="${TAG_NAME#v}"
        return
    fi

    ALL_RELEASES_JSON="$(fetch_text "${API_BASE}?per_page=100")" || err "Failed to fetch release list from GitHub."
    ALL_TAGS="$(printf '%s\n' "$ALL_RELEASES_JSON" \
        | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"

    # Determine format: X, X.Y, or X.Y.Z
    case "$REQ_VERSION" in
        *.*.*)
            # Exact version (X.Y.Z)
            TAG_NAME="$(printf '%s\n' "$ALL_TAGS" | grep -E "^v?${REQ_VERSION}$" | head -n 1 || true)"
            [ -n "$TAG_NAME" ] || err "Release version '${REQ_VERSION}' not found."
            VERSION="${TAG_NAME#v}"
            ;;
        *.*)
            # Latest in minor branch (X.Y -> X.Y.*)
            ESCAPED_VER="$(printf '%s' "$REQ_VERSION" | sed 's/\./\\./g')"
            TAG_NAME="$(printf '%s\n' "$ALL_TAGS" \
                | grep -E "^v?${ESCAPED_VER}(\.|$)" \
                | sed 's/^v//' \
                | sort -t. -k1,1n -k2,2n -k3,3n \
                | tail -n 1)"
            [ -n "$TAG_NAME" ] || err "No release found matching '${REQ_VERSION}.*'."
            # Restore original tag format (with or without 'v' prefix)
            if printf '%s\n' "$ALL_TAGS" | grep -qx "v${TAG_NAME}"; then
                TAG_NAME="v${TAG_NAME}"
            fi
            VERSION="${TAG_NAME#v}"
            ;;
        *)
            # Latest in major branch (X -> X.*.*)
            TAG_NAME="$(printf '%s\n' "$ALL_TAGS" \
                | grep -E "^v?${REQ_VERSION}\." \
                | sed 's/^v//' \
                | sort -t. -k1,1n -k2,2n -k3,3n \
                | tail -n 1)"
            [ -n "$TAG_NAME" ] || err "No release found matching '${REQ_VERSION}.*'."
            if printf '%s\n' "$ALL_TAGS" | grep -qx "v${TAG_NAME}"; then
                TAG_NAME="v${TAG_NAME}"
            fi
            VERSION="${TAG_NAME#v}"
            ;;
    esac
}

resolve_version
log "Detected OS: ${DISTRO} (${ARCH}) | Target version: ${VERSION}"

# 7. Create temporary working directory and clean up on exit
TMPDIR="$(mktemp -d /tmp/yacreader-install.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

verify_checksum() {
    TARGET_FILE="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        if fetch_text "${DL_BASE}/${TAG_NAME}/SHA256SUMS.txt" > "${TMPDIR}/SHA256SUMS.txt" 2>/dev/null; then
            EXPECTED="$(grep " ${TARGET_FILE}$" "${TMPDIR}/SHA256SUMS.txt" | awk '{print $1}' | head -n 1)"
            if [ -n "$EXPECTED" ]; then
                ACTUAL="$(sha256sum "${TMPDIR}/${TARGET_FILE}" | awk '{print $1}')"
                [ "$EXPECTED" = "$ACTUAL" ] || err "SHA-256 checksum mismatch for ${TARGET_FILE}!"
                log "SHA-256 checksum verified."
            fi
        fi
    fi
}

# 8. Download and install package
if [ "$DISTRO" = "archlinux" ] && [ "$ARCH_BUILD" -eq 1 ]; then
    PKGBUILD_FILE="yacreader_${VERSION}_archlinux.PKGBUILD"
    PKGBUILD_URL="${DL_BASE}/${TAG_NAME}/${PKGBUILD_FILE}"

    log "Downloading ${PKGBUILD_FILE}..."
    download_file "$PKGBUILD_URL" "${TMPDIR}/${PKGBUILD_FILE}" || err "Failed to download ${PKGBUILD_URL}"
    verify_checksum "$PKGBUILD_FILE"

    log "Installing build dependencies via pacman..."
    pacman -Sy --noconfirm
    pacman -S --needed --noconfirm \
        base-devel cmake git qt6-base qt6-declarative qt6-multimedia \
        qt6-svg qt6-5compat qt6-speech poppler-qt6 libarchive sqlite \
        qt6-tools qt6-shadertools

    # makepkg cannot run as root; build using a non-root user account
    BUILD_USER="${SUDO_USER:-nobody}"
    if [ "$BUILD_USER" = "root" ]; then
        BUILD_USER="nobody"
    fi
    chown -R "$BUILD_USER" "$TMPDIR"

    log "Building package as '${BUILD_USER}' using makepkg..."
    su -s /bin/sh "$BUILD_USER" -c "HOME='${TMPDIR}' && export HOME && cd '${TMPDIR}' && makepkg --noconfirm -p '${PKGBUILD_FILE}'"

    log "Installing built package..."
    pacman -U --noconfirm "${TMPDIR}"/yacreader-*.pkg.tar.*
else
    PKG_FILE="yacreader_${VERSION}_${DISTRO}_${ARCH}.${PKG_EXT}"
    PKG_URL="${DL_BASE}/${TAG_NAME}/${PKG_FILE}"

    log "Downloading ${PKG_FILE}..."
    download_file "$PKG_URL" "${TMPDIR}/${PKG_FILE}" || err "Failed to download ${PKG_URL}"
    verify_checksum "$PKG_FILE"

    log "Installing ${PKG_FILE}..."
    case "$PKG_EXT" in
        deb)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -q
            apt-get install -y "${TMPDIR}/${PKG_FILE}"
            ;;
        rpm)
            dnf install -y "${TMPDIR}/${PKG_FILE}"
            ;;
        apk)
            apk add --allow-untrusted "${TMPDIR}/${PKG_FILE}"
            ;;
        pkg.tar.zst)
            pacman -Sy --noconfirm
            pacman -U --noconfirm "${TMPDIR}/${PKG_FILE}"
            ;;
    esac
fi

log "YACReader ${VERSION} has been successfully installed!"