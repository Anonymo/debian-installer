#!/bin/bash
set -e

# Quick installer script for Official Debian Live CD
# This automates the entire process of setting up and running the web installer

echo "=== Debian Installer Quick Setup for Live CD ==="
echo ""

# Enable non-free and contrib repositories
echo "→ Enabling non-free and contrib repositories..."
sudo sed -i 's/main/main contrib non-free non-free-firmware/g' /etc/apt/sources.list 2>/dev/null || true
sudo sed -i 's/main/main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/*.sources 2>/dev/null || true

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

# Try to open Firefox automatically
if command -v firefox &> /dev/null; then
    echo "→ Opening Firefox browser..."
    firefox http://localhost:5000/ &>/dev/null &
    sleep 2
else
    echo "→ Please open your browser and navigate to: http://localhost:5000/"
fi

echo "→ Press Ctrl+C to stop the installer"
echo ""

# Run the backend
sudo ./backend/opinionated-installer backend