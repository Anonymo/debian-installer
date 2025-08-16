#!/bin/bash

set -euo pipefail

# This script prepares a Debian Live session to run the browser-based installer.
# It installs missing tools (wget/curl/git/node/go/xdg-utils), builds frontend/backend
# if sources are present, starts the backend on localhost:5000, and opens the browser.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PORT=5000
STATIC_DIR="${ROOT_DIR}/frontend/dist"
BACKEND_BIN="${ROOT_DIR}/frontend-tui/opinionated-installer"

need_root_pkgs=(apt-get dpkg)
for p in "${need_root_pkgs[@]}"; do
  if ! command -v "$p" >/dev/null 2>&1; then
    echo "This script expects a Debian-based Live environment with apt available." >&2
    exit 1
  fi
done

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Root privileges are required. Please run with sudo or as root." >&2
    exit 1
  fi
fi

ensure_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "> Installing package: $pkg"
    $SUDO apt-get update -y
    # Ensure DEBIAN_FRONTEND is propagated correctly through sudo
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  fi
}

echo "> Ensuring basic tools (wget/curl/git/xdg-open/tar) are available"
ensure_pkg ca-certificates || true
ensure_pkg wget || true
ensure_pkg curl || true
ensure_pkg git || true
ensure_pkg xdg-utils || true
ensure_pkg tar || true

# Try prebuilt bundle first (most automated, no build required)
BUNDLE_URL=${BUNDLE_URL:-"https://github.com/Anonymo/debian-installer/releases/latest/download/opinionated-debian-installer.tar.gz"}
TMP_DIR=$(mktemp -d)
echo "> Attempting to download prebuilt installer bundle..."
if (wget -q --show-progress -O "${TMP_DIR}/installer.tar.gz" "${BUNDLE_URL}" || curl -fL --progress-bar -o "${TMP_DIR}/installer.tar.gz" "${BUNDLE_URL}") && [ -s "${TMP_DIR}/installer.tar.gz" ]; then
  echo "> Downloaded bundle. Extracting and starting..."
  mkdir -p /opt
  BUNDLE_DIR=/opt/opinionated-debian-installer
  $SUDO rm -rf "${BUNDLE_DIR}"
  $SUDO mkdir -p "${BUNDLE_DIR}"
  $SUDO tar -xzf "${TMP_DIR}/installer.tar.gz" -C "${BUNDLE_DIR}" --strip-components=1
  $SUDO chmod +x "${BUNDLE_DIR}/run_from_bundle.sh" || true
  echo "> Launching from bundle"
  exec $SUDO "${BUNDLE_DIR}/run_from_bundle.sh"
else
  echo "> No prebuilt bundle found or download failed; falling back to building from sources..."
fi

# Build frontend if sources are present and dist is missing
if [ -d "${ROOT_DIR}/frontend" ]; then
  if [ ! -d "${STATIC_DIR}" ] || [ ! -f "${STATIC_DIR}/index.html" ]; then
    echo "> Frontend sources detected. Building web UI..."
    ensure_pkg nodejs || true
    ensure_pkg npm || true
    (
      set -e
      cd "${ROOT_DIR}/frontend"
      if [ -f package-lock.json ]; then
        npm ci
      else
        npm i
      fi
      npm run build
    )
  else
    echo "> Using existing frontend build at ${STATIC_DIR}"
  fi
fi

# Build backend if sources are present and binary missing
if [ -d "${ROOT_DIR}/frontend-tui" ]; then
  if [ ! -x "${BACKEND_BIN}" ]; then
    echo "> Backend sources detected. Building backend..."
    ensure_pkg golang-go || true
    (
      set -e
      cd "${ROOT_DIR}/frontend-tui"
      export CGO_ENABLED=0
      go build -v -ldflags="-s -w" -o opinionated-installer
    )
  else
    echo "> Using existing backend binary at ${BACKEND_BIN}"
  fi
fi

# Verify we have backend binary and static assets
if [ ! -x "${BACKEND_BIN}" ]; then
  echo "Backend binary not found at ${BACKEND_BIN}." >&2
  echo "Ensure the repository contains frontend-tui sources or place the built binary there." >&2
  exit 1
fi
if [ ! -d "${STATIC_DIR}" ]; then
  echo "Frontend static directory not found at ${STATIC_DIR}." >&2
  echo "Ensure the repository contains frontend sources and a successful build." >&2
  exit 1
fi

# Warn if not booted in EFI (installer requires EFI)
if [ ! -d /sys/firmware/efi ]; then
  echo "! Warning: System does not appear to be booted in EFI mode. The installer requires EFI." >&2
fi

# Export variables the backend expects
export BACK_END_IP_ADDRESS=127.0.0.1
export INSTALLER_SCRIPT="${ROOT_DIR}/installer.sh"

# Ensure installer script is executable
if [ ! -x "${INSTALLER_SCRIPT}" ]; then
  $SUDO chmod +x "${INSTALLER_SCRIPT}"
fi

echo "> Starting backend on http://localhost:${PORT}"
(
  set -m
  "${BACKEND_BIN}" backend --listenPort "${PORT}" --staticHtmlFolder "${STATIC_DIR}" &
  BACK_PID=$!
  sleep 2
  URL="http://localhost:${PORT}"
  # Try to open browser as the invoking desktop user, not root
  if [ -n "${SUDO_USER:-}" ] && command -v xdg-open >/dev/null 2>&1; then
    sudo -u "${SUDO_USER}" xdg-open "${URL}" >/dev/null 2>&1 || echo "Open your browser to: ${URL}"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${URL}" >/dev/null 2>&1 || echo "Open your browser to: ${URL}"
  elif command -v sensible-browser >/dev/null 2>&1; then
    sensible-browser "${URL}" >/dev/null 2>&1 || echo "Open your browser to: ${URL}"
  else
    echo "Open your browser to: ${URL}"
  fi
  echo "> Backend PID: ${BACK_PID}. Press Ctrl+C to stop."
  wait ${BACK_PID}
) 
