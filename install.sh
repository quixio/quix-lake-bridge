#!/usr/bin/env sh
# Downloads and installs the bridge on Linux and on macOS.
#
# The script reads the machine, picks one of the four asset names, downloads it
# from the release page and installs it. It asks nothing.
#
#   linux-x64     linux-arm64     osx-x64     osx-arm64
#
# On Linux with dpkg or rpm it takes the deb or the rpm, so the package manager
# owns the file. Everywhere else it takes the tar.gz and copies the binary.
#
# usage:
#   curl -fsSL https://github.com/quixio/quix-lake-bridge/raw/main/install.sh | sh
#   QUIX_BRIDGE_VERSION=0.1.0 sh install.sh
set -eu

REPO="${QUIX_BRIDGE_REPO:-quixio/quix-lake-bridge}"
VERSION="${QUIX_BRIDGE_VERSION:-latest}"
PREFIX="${QUIX_BRIDGE_PREFIX:-/usr/local/bin}"

fail() { echo "$1" >&2; exit 1; }

# ---- read the machine, and name the runtime -------------------------------

os="$(uname -s)"
machine="$(uname -m)"

case "$os" in
    Linux)  os_part="linux" ;;
    Darwin) os_part="osx" ;;
    *) fail "This script installs the bridge on Linux and on macOS. It read '$os'. On Windows, run install.ps1." ;;
esac

case "$machine" in
    x86_64|amd64)  arch_part="x64" ;;
    aarch64|arm64) arch_part="arm64" ;;
    *) fail "The bridge has no build for the architecture '$machine'." ;;
esac

RUNTIME="${os_part}-${arch_part}"
echo "This machine is $RUNTIME."

# ---- resolve the version and the asset ------------------------------------

# The release tag carries a v, and the asset name does not. So a pinned install
# reads "download/v1.2.0/quix-bridge-1.2.0-linux-x64.deb". A tag with no v answers
# 404. install.ps1 builds the same URL.
if [ "$VERSION" = "latest" ]; then
    base="https://github.com/${REPO}/releases/latest/download"
else
    # A caller may type the tag or the number. The asset name needs the number.
    VERSION="${VERSION#v}"
    base="https://github.com/${REPO}/releases/download/v${VERSION}"
fi

# The version goes into every asset name, so a "latest" install must learn the
# real number first.
if [ "$VERSION" = "latest" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -n 's/.*"tag_name" *: *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$VERSION" ] || fail "The script could not read the newest release of $REPO."
fi

echo "The newest version is $VERSION."

# Prefer the native package on Linux. The package manager then owns the upgrade
# and the removal.
kind="tar"
if [ "$os_part" = "linux" ]; then
    if command -v dpkg > /dev/null 2>&1; then
        kind="deb"
    elif command -v rpm > /dev/null 2>&1; then
        kind="rpm"
    fi
fi

case "$kind" in
    deb) asset="quix-bridge-${VERSION}-${RUNTIME}.deb" ;;
    rpm) asset="quix-bridge-${VERSION}-${RUNTIME}.rpm" ;;
    *)   asset="quix-bridge-${VERSION}-${RUNTIME}.tar.gz" ;;
esac

url="${base}/${asset}"
echo "Download $url"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fSL -o "${work}/${asset}" "$url" || fail "The download of $url failed."

# ---- check the download before anything runs ------------------------------

# SHA256SUMS comes from the same release. It must name this asset, and the hash must
# match. Any other answer stops the script before the file installs.
curl -fsSL -o "${work}/SHA256SUMS" "${base}/SHA256SUMS" \
    || fail "The download of ${base}/SHA256SUMS failed. The script installed nothing."

expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "${work}/SHA256SUMS")"
[ -n "$expected" ] || fail "SHA256SUMS names no line for $asset. The script installed nothing."

if command -v sha256sum > /dev/null 2>&1; then
    actual="$(sha256sum "${work}/${asset}" | cut -d ' ' -f 1)"
elif command -v shasum > /dev/null 2>&1; then
    actual="$(shasum -a 256 "${work}/${asset}" | cut -d ' ' -f 1)"
else
    fail "This machine has no sha256sum and no shasum, so the script cannot check the download."
fi

expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
[ "$actual" = "$expected" ] \
    || fail "The SHA256 of $asset does not match SHA256SUMS. The script installed nothing. Download it again."
echo "The SHA256 of $asset matches SHA256SUMS."
echo "This build is unsigned. The script checked its SHA256 only."

# ---- install --------------------------------------------------------------

sudo_if_needed() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo > /dev/null 2>&1; then
        sudo "$@"
    else
        fail "The install needs root rights, and this machine has no sudo. Run the script as root."
    fi
}

# THE INSTALL MUST RESOLVE DEPENDENCIES. The bridge needs ICU, OpenSSL and a CA
# trust store, and the package names all three. `dpkg -i` and `rpm -Uvh` install one
# file and resolve NOTHING, so on a plain machine they leave the package unconfigured
# or, worse, installed and unable to start. apt-get and dnf read the same file and
# pull what it needs, so the script prefers them and falls back only where neither
# exists.
case "$kind" in
    deb)
        if command -v apt-get > /dev/null 2>&1; then
            sudo_if_needed apt-get install -y "${work}/${asset}"
        else
            sudo_if_needed dpkg -i "${work}/${asset}"
        fi
        ;;
    rpm)
        if command -v dnf > /dev/null 2>&1; then
            sudo_if_needed dnf install -y "${work}/${asset}"
        elif command -v yum > /dev/null 2>&1; then
            sudo_if_needed yum install -y "${work}/${asset}"
        else
            sudo_if_needed rpm -Uvh "${work}/${asset}"
        fi
        ;;
    *)
        tar -xzf "${work}/${asset}" -C "$work"
        [ -f "${work}/quix-bridge" ] || fail "The archive holds no quix-bridge binary."
        sudo_if_needed install -m 0755 "${work}/quix-bridge" "${PREFIX}/quix-bridge"
        echo "The script wrote ${PREFIX}/quix-bridge."
        # A tar.gz install has no package manager, so nothing pulls the three
        # libraries the bridge opens at start. Name them here, because the .NET
        # failure message names no package.
        if [ "$os_part" = "linux" ]; then
            echo "This machine needs ICU, OpenSSL and a CA trust store."
            echo "  RHEL family:      sudo dnf install libicu openssl-libs ca-certificates"
            echo "  Debian family:    sudo apt install libicu<N> libssl<N> ca-certificates"
            echo "Run 'quix-bridge version' now. It prints the version when all three are there."
        fi
        echo "Run 'sudo ${PREFIX}/quix-bridge service install' to register the service."
        ;;
esac

echo "Done. Run 'quix-bridge status' to read the state."
