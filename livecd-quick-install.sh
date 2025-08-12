#!/bin/bash
set -e

# Quick installer script for Official Debian Live CD
# This automates the entire process of setting up and running the web installer

echo "=== Debian Installer Quick Setup for Live CD ==="
echo ""

# Enable contrib and non-free repositories (skip first line with /run/live/medium)
echo "→ Enabling contrib and non-free repositories..."
# Modify existing sources.list to add contrib and non-free 
sudo sed -i '/^deb http.*debian.*trixie.*main$/s/main$/main contrib non-free/' /etc/apt/sources.list
sudo sed -i '/^deb-src http.*debian.*trixie.*main$/s/main$/main contrib non-free/' /etc/apt/sources.list

# Update package lists
echo "→ Updating package lists..."
sudo apt update

# Stop bind/named if running (can conflict with installation)
echo "→ Stopping conflicting services..."
sudo systemctl stop bind9 2>/dev/null || true
sudo systemctl stop named 2>/dev/null || true

# Install dependencies including ZFS support
echo "→ Installing dependencies including ZFS support..."
export DEBIAN_FRONTEND=noninteractive
echo 'zfs-dkms zfs-dkms/note-incompatible-licenses note true' | sudo debconf-set-selections
sudo -E apt install -y curl git zfsutils-linux zfs-dkms debootstrap linux-headers-$(uname -r) nvidia-detect

# Load ZFS kernel module
echo "→ Loading ZFS kernel module..."
sudo modprobe zfs 2>/dev/null || echo "ZFS module loading failed - it will be built during DKMS install"

# Clone the repository
echo "→ Cloning installer repository..."
if [ ! -d "debian-installer" ]; then
    git clone https://github.com/Anonymo/debian-installer.git
fi
cd debian-installer

# Check if pre-built binary exists, otherwise build it
if [ ! -f "backend/opinionated-installer" ]; then
    echo "→ Binary not found, building installer (this will take a few minutes)..."
    
    # Install build dependencies
    echo "  → Installing build dependencies..."
    sudo apt install -y golang-go npm
    
    # Build frontend
    echo "  → Building frontend..."
    cd frontend
    npm install
    npm run build
    cd ..
    
    # Build backend
    echo "  → Building backend..."
    cd backend
    CGO_ENABLED=0 go build -ldflags="-s -w" -o opinionated-installer
    cd ..
else
    echo "→ Using existing pre-built installer binary"
fi

# Run the installer
echo ""
echo "=== Starting Web Installer ==="
echo "→ The installer will be available at: http://localhost:5000/"
echo ""

# Stop any conflicting services before starting backend
echo "→ Stopping conflicting services..."
sudo systemctl stop bind9 2>/dev/null || true
sudo systemctl stop named 2>/dev/null || true

# Run the backend in background first with correct static path
echo "→ Starting backend server..."
sudo INSTALLER_SCRIPT="$(pwd)/installer-zfs-native-encryption.sh" ./backend/opinionated-installer backend -staticHtmlFolder "$(pwd)/frontend/dist" &
BACKEND_PID=$!

# Wait for backend to start
echo "→ Waiting for server to start..."
for i in {1..10}; do
    if curl -s http://localhost:5000/ >/dev/null 2>&1; then
        echo "→ Server is ready!"
        break
    fi
    sleep 1
done

# Try to open Firefox automatically
if command -v firefox &> /dev/null; then
    echo "→ Opening Firefox browser..."
    firefox http://localhost:5000/ &>/dev/null &
else
    echo "→ Please open your browser and navigate to: http://localhost:5000/"
fi

echo ""
echo "→ Press Ctrl+C to stop the installer"
echo ""

# Wait for backend process
wait $BACKEND_PID