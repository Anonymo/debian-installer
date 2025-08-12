#!/bin/bash

if [ -z "${NON_INTERACTIVE}" ]; then
# edit this:
DISK=/dev/vda
USERNAME=user
USER_FULL_NAME="Debian User"
USER_PASSWORD=hunter2
ROOT_PASSWORD=changeme
ENABLE_ENCRYPTION=false
ENCRYPTION_PASSWORD=
ENABLE_TPM=true
HOSTNAME=debian13
SWAP_SIZE=2
NVIDIA_PACKAGE=
ENABLE_POPCON=false
ENABLE_UBUNTU_THEME=false
ENABLE_SUDO=false
SSH_PUBLIC_KEY=
AFTER_INSTALLED_CMD=
fi

function notify () {
    echo $@
    if [ -z "${NON_INTERACTIVE}" ]; then
      read -p "Enter to continue"
    fi
}

DEBIAN_VERSION=trixie
BACKPORTS_VERSION=${DEBIAN_VERSION}  # TODO append "-backports" when available
# see https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html#--tpm2-pcrs=PCR
TPM_PCRS="7+14"
# do not enable this on a live-cd
SHARE_APT_ARCHIVE=false
FSFLAGS="compress=zstd:1"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

if [ "$(id -u)" -ne 0 ]; then
    echo 'This script must be run by root' >&2
    exit 1
fi

if [ -z "${DISK}" ]; then
    echo "DISK variable is missing" >&2
    exit 2
fi

if [ "${ENABLE_ENCRYPTION}" == "true" ]; then
  if [ -z "${ENCRYPTION_PASSWORD}" ]; then
      echo "ENCRYPTION_PASSWORD variable is missing" >&2
      exit 3
  fi
fi

if [ -z "${NON_INTERACTIVE}" ]; then
    notify install required packages
    apt-get update -y  || exit 1
    apt-get install -y debootstrap uuid-runtime zfsutils-linux dosfstools git || exit 1
fi

if [ ! -f efi-part.uuid ]; then
    notify generate uuid for efi partition
    uuidgen > efi-part.uuid || exit 1
fi
if [ ! -f main-part.uuid ]; then
    notify generate uuid for main partition
    uuidgen > main-part.uuid || exit 1
fi

if [ ! -f zpool.name ]; then
    notify generate zpool name
    echo "rpool" > zpool.name || exit 1
fi

root_part_type="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"  # X86_64
system_part_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

efi_part_uuid=$(cat efi-part.uuid)
main_part_uuid=$(cat main-part.uuid)
efi_partition=/dev/disk/by-partuuid/${efi_part_uuid}
main_partition=/dev/disk/by-partuuid/${main_part_uuid}
zpool_name=$(cat zpool.name)
top_level_mount=/mnt/top_level_mount
target=/target
kernel_params="rw quiet root=ZFS=${zpool_name}/ROOT/debian rd.auto=1 splash"
root_device=${main_partition}

if [ ! -f partitions_created.txt ]; then
notify create partitions on ${DISK}
sfdisk $DISK <<EOF || exit 1
label: gpt
unit: sectors
sector-size: 512

start=2048, size=2097152, type=${system_part_type}, name="EFI system partition", uuid=${efi_part_uuid}
start=2099200, size=4096000, type=${root_part_type}, name="Root partition", uuid=${main_part_uuid}
EOF

notify resize the root partition on ${DISK} to fill available space
echo ", +" | sfdisk -N 2 $DISK || exit 1

sfdisk -d $DISK > partitions_created.txt || exit 1
fi

function wait_for_file {
    filename="$1"
    while [ ! -e $filename ]
    do
        echo waiting for $filename to be created
        sleep 3
    done
}

wait_for_file ${main_partition}

if [ -e /dev/disk/by-partlabel/BaseImage ]; then
    if [ ! -f base_image_copied.txt ]; then
        notify copy base image to ${root_device}
        wipefs -a ${root_device} || exit 1
        dd if=/dev/disk/by-partlabel/BaseImage of=${root_device} bs=256M oflag=dsync status=progress || exit 1
        notify import and configure zpool
        zpool import -f -d ${root_device} ${zpool_name} || exit 1
        zpool export ${zpool_name} || exit 1
        touch base_image_copied.txt
    fi
else
    if [ ! -f zfs_created.txt ]; then
        notify create ZFS pool on ${root_device}
        wipefs -a ${root_device} || exit 1
        
        # Create ZFS pool with optional native encryption
        if [ "${ENABLE_ENCRYPTION}" == "true" ]; then
            notify "Creating encrypted ZFS pool"
            echo -n "${ENCRYPTION_PASSWORD}" | \
            zpool create -f -o ashift=12 \
                -O compression=lz4 -O acltype=posixacl -O xattr=sa \
                -O normalization=formD -O mountpoint=none -O canmount=off \
                -O dnodesize=auto -O relatime=on \
                -O encryption=aes-256-gcm -O keylocation=prompt -O keyformat=passphrase \
                ${zpool_name} ${root_device} || exit 1
        else
            notify "Creating unencrypted ZFS pool"
            zpool create -f -o ashift=12 \
                -O compression=lz4 -O acltype=posixacl -O xattr=sa \
                -O normalization=formD -O mountpoint=none -O canmount=off \
                -O dnodesize=auto -O relatime=on \
                ${zpool_name} ${root_device} || exit 1
        fi
        touch zfs_created.txt
    fi
fi

if [ ! -f vfat_created.txt ]; then
    notify create esp filesystem on ${efi_partition}
    wipefs -a ${efi_partition} || exit 1
    mkfs.vfat ${efi_partition} || exit 1
    touch vfat_created.txt
fi

if zpool list ${zpool_name} > /dev/null 2>&1; then
    echo ZFS pool ${zpool_name} already imported
else
    notify import ZFS pool ${zpool_name}
    if [ "${ENABLE_ENCRYPTION}" == "true" ]; then
        echo -n "${ENCRYPTION_PASSWORD}" | zpool import -f -l ${zpool_name} || exit 1
    else
        zpool import -f ${zpool_name} || exit 1
    fi
fi

if ! zfs list ${zpool_name}/ROOT > /dev/null 2>&1; then
    notify create ZFS datasets
    # Create datasets with inherited encryption if pool is encrypted
    zfs create -o mountpoint=none ${zpool_name}/ROOT || exit 1
    zfs create -o mountpoint=/ ${zpool_name}/ROOT/debian || exit 1
    zfs create -o mountpoint=/home ${zpool_name}/home || exit 1
    if [ ${SWAP_SIZE} -gt 0 ]; then
        notify create swap zvol
        # Swap should not be encrypted for performance
        if [ "${ENABLE_ENCRYPTION}" == "true" ]; then
            zfs create -V ${SWAP_SIZE}G -b $(getconf PAGESIZE) \
                -o compression=zle -o logbias=throughput -o sync=always \
                -o primarycache=metadata -o secondarycache=none \
                -o com.sun:auto-snapshot=false \
                -o encryption=off ${zpool_name}/swap || exit 1
        else
            zfs create -V ${SWAP_SIZE}G -b $(getconf PAGESIZE) \
                -o compression=zle -o logbias=throughput -o sync=always \
                -o primarycache=metadata -o secondarycache=none \
                -o com.sun:auto-snapshot=false ${zpool_name}/swap || exit 1
        fi
    fi
fi

if mountpoint -q "${target}" ; then
    echo ZFS datasets already mounted on ${target}
else
    notify mount ZFS datasets on ${target}
    mkdir -p ${target} || exit 1
    zfs set mountpoint=${target} ${zpool_name}/ROOT/debian || exit 1
    zfs mount ${zpool_name}/ROOT/debian || exit 1
    mkdir -p ${target}/home || exit 1
    zfs set mountpoint=${target}/home ${zpool_name}/home || exit 1
    zfs mount ${zpool_name}/home || exit 1
fi

if [ ${SWAP_SIZE} -gt 0 ]; then
    if ! grep -qs "/dev/zvol/${zpool_name}/swap" /proc/swaps ; then
      notify configure and enable swap zvol
      mkswap -f /dev/zvol/${zpool_name}/swap || exit 1
      swapon /dev/zvol/${zpool_name}/swap || exit 1
    fi
    kernel_params="${kernel_params} resume=/dev/zvol/${zpool_name}/swap"
fi

if [ ! -f ${target}/etc/debian_version ]; then
    notify install debian on ${target}
    debootstrap ${DEBIAN_VERSION} ${target} http://deb.debian.org/debian || exit 1
fi

if mountpoint -q "${target}/proc" ; then
    echo bind mounts already set up on ${target}
else
    notify bind mount dev, proc, sys, run on ${target}
    mount -t proc none ${target}/proc || exit 1
    mount --make-rslave --rbind /sys ${target}/sys || exit 1
    mount --make-rslave --rbind /dev ${target}/dev || exit 1
    mount --make-rslave --rbind /run ${target}/run || exit 1
    mount --bind /etc/resolv.conf ${target}/etc/resolv.conf || exit 1
fi

if mountpoint -q "${target}/boot/efi" ; then
    echo efi esp partition ${efi_partition} already mounted on ${target}/boot/efi
else
    notify mount efi esp partition ${efi_partition} on ${target}/boot/efi
    mkdir -p ${target}/boot/efi || exit 1
    mount ${efi_partition} ${target}/boot/efi || exit 1
fi

# Continue with the rest of the installation...
notify configure hostname
echo ${HOSTNAME} > ${target}/etc/hostname || exit 1
cat > ${target}/etc/hosts <<EOF || exit 1
127.0.0.1       localhost
127.0.1.1       ${HOSTNAME}
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

notify configure apt sources
cat > ${target}/etc/apt/sources.list <<EOF || exit 1
deb http://deb.debian.org/debian ${DEBIAN_VERSION} main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian ${DEBIAN_VERSION} main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security ${DEBIAN_VERSION}-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security ${DEBIAN_VERSION}-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian ${BACKPORTS_VERSION}-backports main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian ${BACKPORTS_VERSION}-backports main contrib non-free non-free-firmware
EOF

notify install essential packages in chroot
chroot ${target} apt-get update || exit 1
chroot ${target} apt-get install -y \
    linux-image-amd64 linux-headers-amd64 firmware-linux \
    zfsutils-linux zfs-dkms zfs-initramfs \
    systemd-boot dracut network-manager sudo \
    locales console-setup keyboard-configuration || exit 1

# Configure ZFS for boot
notify configure ZFS for boot
echo ${zpool_name}/ROOT/debian > ${target}/etc/zfs/zfs-list.cache/${zpool_name} || exit 1
mkdir -p ${target}/etc/zfs/zfs-list.cache || exit 1
touch ${target}/etc/zfs/zfs-list.cache/${zpool_name} || exit 1

# Install and configure zectl
notify "Installing zectl for boot environment management"
chroot ${target} bash -c "
cd /tmp
git clone https://github.com/johnramsden/zectl || exit 1
cd zectl
make install PREFIX=/usr || exit 1
cd ..
rm -rf zectl
" || exit 1

# Configure zectl
chroot ${target} zectl set bootloader=systemdboot || exit 1

# Create APT hook for automatic boot environment snapshots
notify "Creating APT hook for automatic boot environment snapshots"
cat > ${target}/etc/apt/apt.conf.d/80-zectl-snapshot <<'EOF' || exit 1
# Automatically create boot environment before package upgrades
DPkg::Pre-Invoke {
    "if [ -x /usr/bin/zectl ] && [ \"$DPKG_RUNNING_VERSION\" ]; then
        BE_NAME=\"apt-$(date +%Y%m%d-%H%M%S)\"
        echo \"Creating boot environment: $BE_NAME\"
        /usr/bin/zectl create $BE_NAME || true
    fi";
};
EOF

# Configure systemd-boot
notify configure systemd-boot
chroot ${target} bootctl install || exit 1

# Create loader configuration
cat > ${target}/boot/efi/loader/loader.conf <<EOF || exit 1
default debian
timeout 3
console-mode max
editor no
EOF

# Create boot entry
cat > ${target}/boot/efi/loader/entries/debian.conf <<EOF || exit 1
title   Debian GNU/Linux
linux   /vmlinuz
initrd  /initrd.img
options ${kernel_params}
EOF

# Set up kernel hooks to copy kernel/initrd to ESP
cat > ${target}/etc/kernel/postinst.d/zz-update-systemd-boot <<'EOF' || exit 1
#!/bin/sh
set -e
cp /vmlinuz /boot/efi/vmlinuz
cp /initrd.img /boot/efi/initrd.img
EOF
chmod +x ${target}/etc/kernel/postinst.d/zz-update-systemd-boot || exit 1

# Configure users
notify configure users
if [ "${ENABLE_SUDO}" == "true" ]; then
    chroot ${target} useradd -m -s /bin/bash -G sudo ${USERNAME} || exit 1
else
    chroot ${target} useradd -m -s /bin/bash ${USERNAME} || exit 1
fi
echo "${USERNAME}:${USER_PASSWORD}" | chroot ${target} chpasswd || exit 1
echo "root:${ROOT_PASSWORD}" | chroot ${target} chpasswd || exit 1

# Configure sudo
echo "${USERNAME} ALL=(ALL:ALL) ALL" > ${target}/etc/sudoers.d/${USERNAME} || exit 1

# SSH key if provided
if [ -n "${SSH_PUBLIC_KEY}" ]; then
    notify configure SSH keys
    chroot ${target} apt-get install -y openssh-server || exit 1
    mkdir -p ${target}/home/${USERNAME}/.ssh || exit 1
    echo "${SSH_PUBLIC_KEY}" > ${target}/home/${USERNAME}/.ssh/authorized_keys || exit 1
    chroot ${target} chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh || exit 1
    chmod 700 ${target}/home/${USERNAME}/.ssh || exit 1
    chmod 600 ${target}/home/${USERNAME}/.ssh/authorized_keys || exit 1
fi

# Configure locales
notify configure locales
echo "en_US.UTF-8 UTF-8" > ${target}/etc/locale.gen || exit 1
chroot ${target} locale-gen || exit 1
echo "LANG=en_US.UTF-8" > ${target}/etc/default/locale || exit 1

# Configure network
notify configure network
cat > ${target}/etc/NetworkManager/NetworkManager.conf <<EOF || exit 1
[main]
plugins=ifupdown,keyfile
dhcp=internal

[ifupdown]
managed=true
EOF

# Update initramfs
notify update initramfs
chroot ${target} update-initramfs -u -k all || exit 1

# Export pool
notify export ZFS pool
zfs umount -a || exit 1
zpool export ${zpool_name} || exit 1

notify "Installation complete!"
echo "Remove installation media and reboot"

if [ "${ENABLE_UBUNTU_THEME}" == "true" ]; then
    notify applying Ubuntu-like theme
    
    # Install theme packages
    chroot ${target}/ apt install -y yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon \
        yaru-theme-sound fonts-ubuntu gnome-tweaks \
        gnome-shell-extension-dash-to-dock gnome-shell-extension-appindicator \
        gnome-shell-extension-desktop-icons-ng || true
    
    # Create script for user theme configuration (runs on first login)
    cat > ${target}/etc/profile.d/ubuntu-theme-setup.sh <<'EOTHEME'
#!/bin/bash
# Apply Ubuntu theme settings for the user on first login
if [ ! -f "$HOME/.ubuntu-theme-applied" ]; then
    # Set Yaru theme
    gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme 'Yaru' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface cursor-theme 'Yaru' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface font-name 'Ubuntu 11' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface document-font-name 'Ubuntu 11' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface monospace-font-name 'Ubuntu Mono 13' 2>/dev/null || true
    gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Ubuntu Bold 11' 2>/dev/null || true
    
    # Enable extensions
    gsettings set org.gnome.shell enabled-extensions "['dash-to-dock@micxgx.gmail.com', 'appindicatorsupport@rgcjonas.gmail.com', 'ding@rastersoft.com']" 2>/dev/null || true
    
    # Configure dash-to-dock
    gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'LEFT' 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed true 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock extend-height true 2>/dev/null || true
    
    # Mark as applied
    touch "$HOME/.ubuntu-theme-applied"
fi
EOTHEME
    chmod +x ${target}/etc/profile.d/ubuntu-theme-setup.sh
fi

if [ -n "${AFTER_INSTALLED_CMD}" ]; then
    ${AFTER_INSTALLED_CMD}
fi