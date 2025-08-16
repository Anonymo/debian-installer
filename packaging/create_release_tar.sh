#!/bin/bash
set -euo pipefail

# Creates a self-contained tarball with:
#  - opinionated-installer (Go backend)
#  - static/ (built web UI)
#  - installer.sh (this repo’s installer script)
#  - run_from_bundle.sh (starter script for users)

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/dist"
BUNDLE_DIR="${OUT_DIR}/opinionated-debian-installer"
STATIC_SRC="${ROOT_DIR}/frontend/dist"
BACKEND_SRC_BIN="${ROOT_DIR}/frontend-tui/opinionated-installer"
INSTALLER_SH="${ROOT_DIR}/installer.sh"

rm -rf "${OUT_DIR}" && mkdir -p "${BUNDLE_DIR}"

if [ ! -x "${BACKEND_SRC_BIN}" ]; then
  echo "Backend binary not found at ${BACKEND_SRC_BIN}. Build it first." >&2
  exit 1
fi
if [ ! -d "${STATIC_SRC}" ]; then
  echo "Frontend dist not found at ${STATIC_SRC}. Build it first." >&2
  exit 1
fi
if [ ! -f "${INSTALLER_SH}" ]; then
  echo "installer.sh not found at ${INSTALLER_SH}." >&2
  exit 1
fi

cp -a "${BACKEND_SRC_BIN}" "${BUNDLE_DIR}/opinionated-installer"
mkdir -p "${BUNDLE_DIR}/static"
cp -a "${STATIC_SRC}/"* "${BUNDLE_DIR}/static/"
cp -a "${INSTALLER_SH}" "${BUNDLE_DIR}/installer.sh"
chmod +x "${BUNDLE_DIR}/opinionated-installer" "${BUNDLE_DIR}/installer.sh"

cat > "${BUNDLE_DIR}/run_from_bundle.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

PORT=${PORT:-5000}
BIND_ADDR=${BIND_ADDR:-127.0.0.1}
URL="http://${BIND_ADDR}:${PORT}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

export BACK_END_IP_ADDRESS="${BIND_ADDR}"
export INSTALLER_SCRIPT="${SCRIPT_DIR}/installer.sh"

if [ ! -d /sys/firmware/efi ]; then
  echo "! Warning: System does not appear to be booted in EFI mode. The installer requires EFI." >&2
fi

echo "> Starting installer backend on ${URL}"
# Helpers: port handling
is_port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -q ":${p}$"
  elif command -v fuser >/dev/null 2>&1; then
    fuser -s "${p}/tcp"
  else
    return 1
  fi
}

try_free_port() {
  local p="$1"
  pkill -f 'opinionated-installer.*backend' >/dev/null 2>&1 || true
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${p}/tcp" >/dev/null 2>&1 || true
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

PORT="$(pick_port "${PORT}")"
URL="http://${BIND_ADDR}:${PORT}"

"${SCRIPT_DIR}/opinionated-installer" backend --listenPort "${PORT}" --staticHtmlFolder "${SCRIPT_DIR}/static" &
PID=$!
sleep 1

if [ "${HEADLESS:-}" != "1" ]; then
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
else
  echo "Headless mode: not opening a browser. URL: ${URL}"
fi

echo "> Backend PID: ${PID}. Press Ctrl+C to stop."
wait ${PID}
EOF
chmod +x "${BUNDLE_DIR}/run_from_bundle.sh"

(cd "${OUT_DIR}" && tar -czf opinionated-debian-installer.tar.gz "$(basename "${BUNDLE_DIR}")")

# Create checksums
(cd "${OUT_DIR}" && sha256sum opinionated-debian-installer.tar.gz > SHA256SUMS)
echo "Created: ${OUT_DIR}/opinionated-debian-installer.tar.gz"
echo "SHA256: $(cut -d' ' -f1 "${OUT_DIR}/SHA256SUMS")"
