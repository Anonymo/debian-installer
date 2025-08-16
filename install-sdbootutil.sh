#!/bin/bash
# Script to integrate openSUSE's sdbootutil into Debian
# sdbootutil source: https://github.com/openSUSE/sdbootutil
# Copyright notices preserved from original project

set -e

SDBOOTUTIL_REPO="https://github.com/openSUSE/sdbootutil.git"
TEMP_DIR="/tmp/sdbootutil-install"

install_sdbootutil() {
    local target_root="$1"
    
    echo "Installing sdbootutil from openSUSE (preserving original attribution)..."
    
    # Clone sdbootutil repository
    if [ ! -d "$TEMP_DIR" ]; then
        git clone "$SDBOOTUTIL_REPO" "$TEMP_DIR"
    fi
    
    # Copy main sdbootutil script
    cp "$TEMP_DIR/sdbootutil" "$target_root/usr/local/bin/"
    chmod +x "$target_root/usr/local/bin/sdbootutil"
    
    # Copy kernel hooks
    mkdir -p "$target_root/etc/kernel/install.d/"
    cp "$TEMP_DIR/50-sdbootutil.install" "$target_root/etc/kernel/install.d/"
    chmod +x "$target_root/etc/kernel/install.d/50-sdbootutil.install"
    
    # Copy configuration
    cp "$TEMP_DIR/kernel-install-sdbootutil.conf" "$target_root/etc/kernel/"
    
    # Copy snapper integration if using snapper
    if [ -f "$TEMP_DIR/10-sdbootutil.snapper" ]; then
        mkdir -p "$target_root/usr/share/snapper/hooks/"
        cp "$TEMP_DIR/10-sdbootutil.snapper" "$target_root/usr/share/snapper/hooks/"
        chmod +x "$target_root/usr/share/snapper/hooks/10-sdbootutil.snapper"
    fi
    
    # Create sdbootutil configuration
    cat > "$target_root/etc/sdbootutil.conf" << 'EOF'
# sdbootutil configuration for Debian with Btrfs
# Based on openSUSE's sdbootutil: https://github.com/openSUSE/sdbootutil
ENTRY_TOKEN=auto
BOOT_ROOT=/boot/efi
MACHINE_ID_FILE=/etc/machine-id
KERNEL_IMAGE_TYPE=vmlinuz
INITRD_GENERATOR=dracut
SNAPPER_CONFIG=root
EOF
    
    # Add attribution file
    cat > "$target_root/usr/share/doc/sdbootutil-attribution.txt" << 'EOF'
sdbootutil - systemd-boot integration tool
===========================================

This tool is from the openSUSE project and is licensed under MIT license.
Original source: https://github.com/openSUSE/sdbootutil
Copyright: SUSE LLC

This installation script preserves all original copyright notices and 
attributions from the sdbootutil project.

Integration into Debian Btrfs installer by: debian-installer-btrfs project
EOF
    
    echo "sdbootutil installation complete with attribution preserved"
}

# Call this function with the target root directory as argument
if [ "$#" -eq 1 ]; then
    install_sdbootutil "$1"
else
    echo "Usage: $0 <target_root_directory>"
    exit 1
fi