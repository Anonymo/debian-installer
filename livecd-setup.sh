#!/bin/bash

set -e

# --- Configuration ---
INSTALLER_REPO="https://github.com/r0b0/debian-installer"
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

    log "Downloading the installer..."
    wget -O /tmp/installer.tar.gz "${INSTALLER_REPO}/releases/download/${INSTALLER_VERSION}/opinionated-debian-installer.tar.gz"

    log "Extracting the installer..."
    mkdir -p /opt/installer
    tar -xzf /tmp/installer.tar.gz -C /opt/installer

    log "Starting the installer backend..."
    /opt/installer/opinionated-installer backend

    log "The installer is now running. Open your web browser to http://localhost:5000 to continue."
}

main
