#!/bin/bash
set -e

# Quick installer script for Official Debian Live CD
# This automates the entire process of setting up and running the web installer

echo "=== Debian Installer Quick Setup for Live CD ==="
echo ""

# Enable non-free-firmware repository (skip cdrom and first line)
echo "→ Enabling non-free-firmware repository..."
# Skip first line and cdrom lines, add non-free-firmware to others ending with 'main'
sudo sed -i '2,$ {/^deb cdrom/! s/ main$/ main non-free-firmware/}' /etc/apt/sources.list 2>/dev/null || true

# Update package lists
echo "→ Updating package lists..."
sudo apt update

# Install minimal dependencies to download and run pre-built binary
echo "→ Installing minimal dependencies..."
sudo apt install -y curl git zfsutils-linux debootstrap

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