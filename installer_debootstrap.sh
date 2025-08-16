#!/bin/bash

set -e

# --- Configuration ---
DISK=${DISK:-/dev/vda}
USERNAME=${USERNAME:-user}
USER_FULL_NAME=${USER_FULL_NAME:-"Debian User"}
USER_PASSWORD=${USER_PASSWORD:-hunter2}
ROOT_PASSWORD=${ROOT_PASSWORD:-changeme}
DISABLE_LUKS=${DISABLE_LUKS:-false}
LUKS_PASSWORD=${LUKS_PASSWORD:-luke}
ENABLE_TPM=${ENABLE_TPM:-true}
HOTNAME=${HOSTNAME:-debian13}
SWAP_SIZE=${SWAP_SIZE:-2}
NVIDIA_PACKAGE=${NVIDIA_PACKAGE:-}
ENABLE_POPCON=${ENABLE_POPCON:-false}
LOCALE=${LOCALE:-C.UTF-8}
KEYMAP=${KEYMAP:-us}
TIMEZONE=${TIMEZONE:-UTC}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
AFTER_INSTALLED_CMD=${AFTER_INSTALLED_CMD:-}
MAKE_UBUNTU_LIKE=${MAKE_UBUNTU_LIKE:-false}
ENABLE_SUDO=${ENABLE_SUDO:-true}
DISABLE_ROOT_ACCOUNT=${DISABLE_ROOT_ACCOUNT:-false}

# --- Script Internals ---
DEBIAN_VERSION=trixie
BACKPORTS_VERSION=${DEBIAN_VERSION}
TPM_PCRS="7+14"
FSFLAGS="compress=zstd:1"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

# --- Helper Functions ---
function log() {
    echo ">>> $@"
}

function error_exit() {
    echo "!!! ERROR: $1" >&2
    exit 1
}

function notify() {
    log "$@"
    if [ -z "${NON_INTERACTIVE}" ]; then
        read -p "Press Enter to continue or Ctrl+C to abort..."
    fi
}

function check_dependencies() {
    log "Checking dependencies..."
    local dependencies=("cryptsetup" "debootstrap" "uuidgen" "btrfs" "dosfstools" "sfdisk" "wipefs" "mount" "umount" "chroot" "systemd-firstboot" "bootctl")
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error_exit "Required command '$cmd' not found. Please install it."
        fi
    done
}

# --- Main Functions ---

function partition_disk() {
    notify "Creating partitions on ${DISK}..."
    sfdisk "$DISK" <<EOF || error_exit "Failed to create partitions."
label: gpt
unit: sectors
sector-size: 512

start=2048, size=2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI system partition", uuid=$(uuidgen)
start=2099200, size=, type=4f68bce3-e8cd-4db1-96e7-fbcaf984b709, name="Root partition", uuid=$(uuidgen)
EOF
}

function setup_luks_and_btrfs() {
    efi_partition="$(lsblk -o PARTUUID,PATH | grep -v "-" | sed -n "2p" | awk '{print "/dev/disk/by-partuuid/"$1}')"
    root_partition="$(lsblk -o PARTUUID,PATH | grep -v "-" | sed -n "3p" | awk '{print "/dev/disk/by-partuuid/"$1}')"

    if [ "${DISABLE_LUKS}" != "true" ]; then
        log "Setting up LUKS on ${root_partition}..."
        echo -n "${LUKS_PASSWORD}" | cryptsetup luksFormat "${root_partition}" -
        echo -n "${LUKS_PASSWORD}" | cryptsetup luksOpen "${root_partition}" cryptroot -
        root_device="/dev/mapper/cryptroot"
    else
        root_device="${root_partition}"
    fi

    log "Creating Btrfs filesystem on ${root_device}..."
    mkfs.btrfs -f "${root_device}"
    btrfs_uuid=$(btrfs filesystem show "${root_device}" | grep -oP 'uuid: \K\S+')

    log "Creating Btrfs subvolumes..."
    mount "${root_device}" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    umount /mnt
}

function mount_and_debootstrap() {
    log "Mounting filesystems..."
    mount -o "${FSFLAGS},subvol=@" "${root_device}" /target
    mkdir -p /target/home
    mount -o "${FSFLAGS},subvol=@home" "${root_device}" /target/home
    mkdir -p /target/.snapshots
    mount -o "${FSFLAGS},subvol=@snapshots" "${root_device}" /target/.snapshots
    mkdir -p /target/boot/efi
    mount "${efi_partition}" /target/boot/efi

    log "Running debootstrap..."
    debootstrap "${DEBIAN_VERSION}" /target http://deb.debian.org/debian/
}

function configure_chroot() {
    log "Configuring the new system..."

    # Mount system directories
    mount -t proc none /target/proc
    mount --make-rslave --rbind /sys /target/sys
    mount --make-rslave --rbind /dev /target/dev

    # Setup fstab
    cat <<EOF > /target/etc/fstab
UUID=${btrfs_uuid} / btrfs defaults,subvol=@,${FSFLAGS} 0 0
UUID=${btrfs_uuid} /home btrfs defaults,subvol=@home,${FSFLAGS} 0 0
UUID=${btrfs_uuid} /.snapshots btrfs defaults,subvol=@snapshots,${FSFLAGS} 0 0
PARTUUID=$(lsblk -o PARTUUID,PATH | grep -v "-" | sed -n "2p" | awk '{print $1}') /boot/efi vfat defaults 0 0
EOF

    # Setup APT sources
    # ... (This part can be reused from the original script)

    # Chroot and install packages
    chroot /target /bin/bash <<EOF
set -e
apt-get update
apt-get install -y linux-image-amd64 systemd-boot btrfs-progs
bootctl install

# Create user
adduser --disabled-password --gecos "${USER_FULL_NAME}" "${USERNAME}"
if [ "${ENABLE_SUDO}" == "true" ]; then
    adduser "${USERNAME}" sudo
fi
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Set root password
echo "root:${ROOT_PASSWORD}" | chpasswd

# Disable root account if requested
if [ "${DISABLE_ROOT_ACCOUNT}" == "true" ]; then
    passwd -l root
fi

# Apply Ubuntu theme if requested
if [ "${MAKE_UBUNTU_LIKE}" == "true" ]; then
    apt-get install -y git
    git clone https://github.com/DeltaLima/make-debian-look-like-ubuntu.git /tmp/ubuntu-theme
    /tmp/ubuntu-theme/make-debian-look-like-ubuntu.sh
fi

EOF
}

function main() {
    check_dependencies
    partition_disk
    setup_luks_and_btrfs
    mount_and_debootstrap
    configure_chroot
    log "Installation finished successfully!"
}

main
