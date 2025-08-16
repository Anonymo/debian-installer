#!/bin/bash

set -euo pipefail

# This script prepares a Debian Live session to run the browser-based installer.
# It installs missing tools (wget/curl/git/node/go/xdg-utils), builds frontend/backend
# if sources are present, starts the backend on localhost:5000, and opens the browser.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PORT=${PORT:-5000}
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
SHA_URL=${BUNDLE_SHA_URL:-"https://github.com/Anonymo/debian-installer/releases/latest/download/SHA256SUMS"}
if (wget -q --show-progress -O "${TMP_DIR}/installer.tar.gz" "${BUNDLE_URL}" || curl -fL --progress-bar -o "${TMP_DIR}/installer.tar.gz" "${BUNDLE_URL}") && [ -s "${TMP_DIR}/installer.tar.gz" ]; then
  # Try checksum verification if available
  if (wget -q -O "${TMP_DIR}/SHA256SUMS" "${SHA_URL}" || curl -fsSL -o "${TMP_DIR}/SHA256SUMS" "${SHA_URL}") && [ -s "${TMP_DIR}/SHA256SUMS" ]; then
    echo "> Verifying checksum..."
    (cd "${TMP_DIR}" && sha256sum -c <(grep opinionated-debian-installer.tar.gz SHA256SUMS)) || {
      echo "! Checksum verification failed. Aborting bundle install." >&2
      exit 1
    }
  else
    echo "> No checksum found, continuing without verification"
  fi
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

# Helper: check and free/choose a port
is_port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -q ":${p}$"
  elif command -v fuser >/dev/null 2>&1; then
    fuser -s "${p}/tcp"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -i TCP:"${p}" -sTCP:LISTEN -t >/dev/null 2>&1
  else
    return 1
  fi
}

try_free_port() {
  local p="$1"
  # Try to kill our own previous backends
  pkill -f 'opinionated-installer.*backend' >/dev/null 2>&1 || true
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${p}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -i TCP:"${p}" -sTCP:LISTEN -t | xargs -r kill -9 >/dev/null 2>&1 || true
  fi
}

try_stop_services() {
  # Stop any systemd units that might hold the port
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop installer_backend.service 2>/dev/null || true
    systemctl disable installer_backend.service 2>/dev/null || true
    systemctl stop installer_tui.service 2>/dev/null || true
    systemctl disable installer_tui.service 2>/dev/null || true
  fi
}

pick_port() {
  local p="${1:-5000}"
  local max_tries=10
  local i=0
  while [ $i -le $max_tries ]; do
    if ! is_port_busy "$p"; then
      echo "$p"
      return 0
    fi
    try_stop_services
    try_free_port "$p"
    sleep 1
    if ! is_port_busy "$p"; then
      echo "$p"
      return 0
    fi
    p=$((p+1))
    i=$((i+1))
  done
  echo "$p"
}

if [ "${FORCE_PORT:-0}" = "1" ]; then
  echo "> FORCE_PORT set: attempting to free port ${PORT}"
  try_stop_services
  try_free_port "${PORT}"
fi

PORT="$(pick_port "${PORT}")"

URL="http://localhost:${PORT}"
echo "> Starting backend on ${URL}"

(
  set -m
  # Try to start; if it dies immediately (bind error), iterate next ports
  max_tries=10
  i=0
  while [ $i -le $max_tries ]; do
    "${BACKEND_BIN}" backend --listenPort "${PORT}" --staticHtmlFolder "${STATIC_DIR}" &
    BACK_PID=$!
    sleep 1
    if ps -p ${BACK_PID} >/dev/null 2>&1; then
      break
    fi
    # backend exited quickly; port may be in use; pick next
    PORT=$((PORT+1))
    URL="http://localhost:${PORT}"
    echo "> Port busy, retrying on ${URL}"
    i=$((i+1))
  done
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
