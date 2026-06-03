#!/bin/sh
set -eu

REPO="riii111/zask"
BINARY_NAME="zask"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

detect_target() {
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case "$os" in
        darwin) os="macos" ;;
        linux) os="linux-gnu" ;;
        *)
            echo "error: unsupported OS: $os" >&2
            exit 1
            ;;
    esac

    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *)
            echo "error: unsupported architecture: $arch" >&2
            exit 1
            ;;
    esac

    target="${arch}-${os}"
}

latest_version() {
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' |
        head -n 1
}

verify_checksum() {
    archive="$1"
    checksum="$2"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c "$checksum" >/dev/null
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c "$checksum" >/dev/null
    else
        echo "warning: sha256sum or shasum not found; skipping checksum verification" >&2
        return 0
    fi
}

detect_target
version=$(latest_version)

if [ -z "$version" ]; then
    echo "error: could not determine latest zask release" >&2
    exit 1
fi

archive_name="${BINARY_NAME}-${target}.tar.gz"
download_url="https://github.com/${REPO}/releases/download/${version}/${archive_name}"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

echo "Installing ${BINARY_NAME} ${version} for ${target}"
curl -fsSL "$download_url" -o "${tmp_dir}/${archive_name}"
curl -fsSL "${download_url}.sha256" -o "${tmp_dir}/${archive_name}.sha256"

cd "$tmp_dir"
verify_checksum "$archive_name" "${archive_name}.sha256"
tar -xzf "$archive_name"

mkdir -p "$INSTALL_DIR"
install -m 0755 "$BINARY_NAME" "${INSTALL_DIR}/${BINARY_NAME}"

echo "Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}"
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        echo "Add ${INSTALL_DIR} to PATH to run ${BINARY_NAME} from any shell."
        ;;
esac
