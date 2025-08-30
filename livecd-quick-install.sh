#!/bin/bash
set -e

# --- Configuration ---
LOG_FILE="/tmp/debian-installer-quick-start.log"
REPO_URL="https://github.com/Anonymo/debian-installer.git"
REPO_DIR="debian-installer"

# --- Default settings ---
LISTEN_IP="127.0.0.1"
OPEN_BROWSER=true
GIT_BRANCH="master"
BACKEND_PID=""

# --- Functions ---

# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --remote          Listen on all network interfaces (0.0.0.0) for remote access."
    echo "  --no-browser      Do not automatically open the web browser."
    echo "  --branch <name>   Specify a git branch to clone (default: master)."
    echo "  --help            Display this help message."
    exit 0
}

# Function to handle cleanup on exit
cleanup() {
    echo ""
    echo "→ Cleaning up..."
    if [ -n "$BACKEND_PID" ]; then
        sudo kill $BACKEND_PID 2>/dev/null || true
        echo "→ Installer process stopped."
    fi
    echo "→ Log file available at: ${LOG_FILE}"
}

# Function for pre-flight checks
pre_flight_checks() {
    echo "→ Performing pre-flight checks..."
    
    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: This script should not be run as root. Run it as a normal user with sudo privileges." >&2
        exit 1
    fi

    if ! command -v sudo &> /dev/null; then
        echo "ERROR: sudo command not found. Please install it first." >&2
        exit 1
    fi

    if ! curl -s --head http://deb.debian.org/debian/ > /dev/null; then
        echo "WARNING: Internet connection not detected. The script might fail." >&2
        sleep 3
    fi
    echo "→ Pre-flight checks passed."
}

# --- Main Script ---

# Set up logging
exec > >(tee -i "${LOG_FILE}")
exec 2>&1

# Set trap for cleanup
trap cleanup EXIT

# Parse command-line arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        --remote)
            LISTEN_IP="0.0.0.0"
            shift
            ;;
        --no-browser)
            OPEN_BROWSER=false
            shift
            ;;
        --branch)
            GIT_BRANCH="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

echo "=== Debian Installer Quick Setup for Live CD ==="
echo "→ Started at: $(date)"
echo "→ Using branch: ${GIT_BRANCH}"
echo "→ Remote access: $([ "$LISTEN_IP" = "0.0.0.0" ] && echo "Enabled" || echo "Disabled")"
echo "→ Auto-open browser: ${OPEN_BROWSER}"
echo ""

# Run pre-flight checks
pre_flight_checks

# Enable contrib and non-free repositories (skip first line with /run/live/medium)
echo "→ Enabling contrib and non-free repositories..."
sudo sed -i '/^deb http/ s/ main$/ main contrib non-free non-free-firmware/' /etc/apt/sources.list
sudo sed -i '/^deb-src http/ s/ main$/ main contrib non-free non-free-firmware/' /etc/apt/sources.list

# Update package lists
echo "→ Updating package lists..."
sudo apt-get update -y

# Stop conflicting services
echo "→ Stopping conflicting services..."
sudo systemctl stop bind9 2>/dev/null || true
sudo systemctl stop named 2>/dev/null || true

# Install dependencies
echo "→ Installing dependencies including ZFS support..."
export DEBIAN_FRONTEND=noninteractive
echo 'zfs-dkms zfs-dkms/note-incompatible-licenses note true' | sudo debconf-set-selections
sudo -E apt-get install -y curl git zfsutils-linux zfs-dkms debootstrap linux-headers-$(uname -r) nvidia-detect

# Load ZFS kernel module
echo "→ Loading ZFS kernel module..."
sudo modprobe zfs 2>/dev/null || echo "ZFS module loading failed - it will be built during DKMS install"

# Clone the repository
echo "→ Cloning installer repository from branch '${GIT_BRANCH}'..."
if [ -d "${REPO_DIR}" ]; then
    echo "→ Existing repository found. Removing it to ensure a fresh clone."
    rm -rf "${REPO_DIR}"
fi
git clone --branch "${GIT_BRANCH}" "${REPO_URL}"

cd "${REPO_DIR}"

# Check if pre-built binary exists, otherwise build it
if [ ! -f "backend/opinionated-installer" ]; then
    echo "→ Binary not found, building installer (this will take a few minutes)..."
    
    echo "  → Installing build dependencies..."
    sudo apt-get install -y golang-go npm
    
    echo "  → Building frontend..."
    (cd frontend && npm install && npm run build)
    
    echo "  → Building backend..."
    (cd backend && CGO_ENABLED=0 go build -ldflags="-s -w" -o opinionated-installer)
else
    echo "→ Using existing pre-built installer binary."
fi

# Run the installer
echo ""
echo "=== Starting Web Installer ==="
INSTALLER_URL="http://${LISTEN_IP}:5000"
echo "→ The installer will be available at: ${INSTALLER_URL}"
if [ "$LISTEN_IP" = "0.0.0.0" ]; then
    echo "→ Accessible from other devices on your network."
fi
echo ""

# Stop conflicting services again before starting backend
echo "→ Stopping conflicting services..."
sudo systemctl stop bind9 2>/dev/null || true
sudo systemctl stop named 2>/dev/null || true

# Run the backend in the background
echo "→ Starting backend server..."
sudo INSTALLER_SCRIPT="$(pwd)/installer-zfs-native-encryption.sh" ./backend/opinionated-installer backend -listenAddr "${LISTEN_IP}" -staticHtmlFolder "$(pwd)/frontend/dist" &
BACKEND_PID=$!

# Wait for backend to start
echo "→ Waiting for server to start..."
for i in {1..15}; do
    if curl -s --head "${INSTALLER_URL}" >/dev/null 2>&1; then
        echo "→ Server is ready!"
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "ERROR: Server failed to start after 15 seconds." >&2
        exit 1
    fi
    sleep 1
done

# Try to open Firefox automatically
if [ "${OPEN_BROWSER}" = true ]; then
    if command -v firefox &> /dev/null; then
        echo "→ Opening Firefox browser..."
        firefox "${INSTALLER_URL}" &>/dev/null &
    else
        echo "→ Firefox not found. Please open your browser and navigate to: ${INSTALLER_URL}"
    fi
else
    echo "→ Skipping automatic browser launch."
fi

echo ""
echo "→ The installer is running. Press Ctrl+C in this terminal to stop it."
echo ""

# Wait for backend process
wait $BACKEND_PID
