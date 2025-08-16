#!/bin/bash

set -e

# --- Configuration ---
# IMPORTANT: You need to change this to your forked repository URL
INSTALLER_REPO="https://github.com/YOUR_USERNAME/debian-installer-btrfs"
INSTALLER_VERSION="latest"

# --- Helper Functions ---
function log() {
    echo ">>> $@"
}

function error_exit() {
    echo "!!! ERROR: $1" >&2
    exit 1
}

function check_dependencies() {
    log "Checking dependencies..."
    local dependencies=("wget" "tar")
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error_exit "Required command '$cmd' not found. Please install it."
        fi
    done
}

# --- Main Execution ---
function main() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run by root."
    fi

    check_dependencies

    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT

    log "Downloading the installer..."
    wget -O "${temp_dir}/installer.tar.gz" "${INSTALLER_REPO}/releases/download/${INSTALLER_VERSION}/opinionated-debian-installer.tar.gz"

    log "Extracting the installer..."
    mkdir -p "${temp_dir}/installer"
    tar -xzf "${temp_dir}/installer.tar.gz" -C "${temp_dir}/installer"

    log "Starting the installer backend..."
    export STATIC_HTML_FOLDER="${temp_dir}/installer/frontend"
    export INSTALLER_SCRIPT="${temp_dir}/installer/installer_debootstrap.sh"
    "${temp_dir}/installer/opinionated-installer" backend

    log "The installer is now running. Open your web browser to http://localhost:5000 to continue."
}

main
