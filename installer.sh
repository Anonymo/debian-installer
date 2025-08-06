#!/bin/bash

if [ -z "${NON_INTERACTIVE}" ]; then
# edit this:
DISK=/dev/vda
USERNAME=user
USER_FULL_NAME="Debian User"
USER_PASSWORD=hunter2
ROOT_PASSWORD=changeme
DISABLE_LUKS=false
LUKS_PASSWORD=luke
ENABLE_TPM=true
HOSTNAME=debian13
SWAP_SIZE=2
NVIDIA_PACKAGE=
ENABLE_POPCON=false
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

if [ "${DISABLE_LUKS}" != "true" ]; then
  if [ -z "${LUKS_PASSWORD}" ]; then
      echo "LUKS_PASSWORD variable is missing" >&2
      exit 3
  fi
fi

if [ -z "${NON_INTERACTIVE}" ]; then
    notify install required packages
    apt-get update -y  || exit 1
    apt-get install -y cryptsetup debootstrap uuid-runtime zfsutils-linux dosfstools || exit 1
fi

KEYFILE=luks.key
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
if [ "${DISABLE_LUKS}" != "true" ]; then
  kernel_params="rd.luks.options=tpm2-device=auto ${kernel_params}"
  luks_device_name=root
  root_device=/dev/mapper/${luks_device_name}
else
  root_device=${main_partition}
fi

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

if [ "${DISABLE_LUKS}" != "true" -a ! -f $KEYFILE ]; then
    # TODO do we want to store this file in the installed system?
    notify generate key file for luks
    dd if=/dev/random of=${KEYFILE} bs=512 count=1 || exit 1
    notify "remove any old luks on ${main_partition} (root)"
    cryptsetup erase --batch-mode ${main_partition}
    wait_for_file ${main_partition}
    wipefs -a ${main_partition} || exit 1
    wait_for_file ${main_partition}
fi

function setup_luks {
  cryptsetup isLuks "$1"
  retVal=$?
  if [ $retVal -ne 0 ]; then
      notify setup luks on "$1"
      cryptsetup luksFormat "$1" --type luks2 --batch-mode --key-file $KEYFILE || exit 1
      notify setup luks password on "$1"
      echo -n "${LUKS_PASSWORD}" > /tmp/passwd
      cryptsetup --key-file=luks.key luksAddKey "$1" /tmp/passwd || exit 1
      rm -f /tmp/passwd
  else
      echo luks already set up on "$1"
  fi
  cryptsetup luksUUID "$1" > luks.uuid || exit 1
}

if [ "${DISABLE_LUKS}" != "true" ]; then
  setup_luks ${main_partition}
  root_uuid=$(cat luks.uuid)

  if [ ! -e ${root_device} ]; then
      notify open luks on root
      cryptsetup luksOpen ${main_partition} ${luks_device_name} --key-file $KEYFILE || exit 1
  fi
fi

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
        zpool create -f -o ashift=12 -O compression=lz4 -O acltype=posixacl -O xattr=sa \
            -O normalization=formD -O mountpoint=none -O canmount=off -O dnodesize=auto \
            -O relatime=on ${zpool_name} ${root_device} || exit 1
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
    zpool import -f ${zpool_name} || exit 1
fi

if ! zfs list ${zpool_name}/ROOT > /dev/null 2>&1; then
    notify create ZFS datasets
    zfs create -o mountpoint=none ${zpool_name}/ROOT || exit 1
    zfs create -o mountpoint=/ ${zpool_name}/ROOT/debian || exit 1
    zfs create -o mountpoint=/home ${zpool_name}/home || exit 1
    if [ ${SWAP_SIZE} -gt 0 ]; then
        notify create swap zvol
        zfs create -V ${SWAP_SIZE}G -b $(getconf PAGESIZE) \
            -o compression=zle -o logbias=throughput -o sync=always \
            -o primarycache=metadata -o secondarycache=none \
            -o com.sun:auto-snapshot=false ${zpool_name}/swap || exit 1
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
    mount ${efi_partition} ${target}/boot/efi -o umask=077 || exit 1
fi

if [ ! -z "${HOSTNAME}" ]; then
    notify setup hostname
    echo "$HOSTNAME" > ${target}/etc/hostname || exit 1
fi

notify setup timezone
echo "${TIMEZONE}" > ${target}/etc/timezone || exit 1
rm -f ${target}/etc/localtime
(cd ${target} && ln -s /usr/share/zoneinfo/${TIMEZONE} etc/localtime)

notify setup fstab
cat <<EOF > ${target}/etc/fstab || exit 1
# ZFS datasets are managed by ZFS, not fstab
PARTUUID=${efi_part_uuid} /boot/efi vfat defaults,umask=077 0 2
EOF

if [ ${SWAP_SIZE} -gt 0 ]; then
cat <<EOF >> ${target}/etc/fstab || exit 1
/dev/zvol/${zpool_name}/swap none swap defaults 0 0
EOF
fi

notify setup sources list
rm -f ${target}/etc/apt/sources.list
mkdir -p ${target}/etc/apt/sources.list.d
cat <<EOF > ${target}/etc/apt/sources.list.d/debian.sources || exit 1
Types: deb
URIs: http://deb.debian.org/debian/
Suites: ${DEBIAN_VERSION}
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian/
Suites: ${DEBIAN_VERSION}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: ${DEBIAN_VERSION}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

cat <<EOF > ${target}/etc/apt/sources.list.d/debian-backports.sources || exit 1
Types: deb
URIs: http://deb.debian.org/debian/
Suites: ${DEBIAN_VERSION}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

if [ "$SHARE_APT_ARCHIVE" = true ] ; then
    mkdir -p ${target}/var/cache/apt/archives || exit 1
    if mountpoint -q "${target}/var/cache/apt/archives" ; then
        echo apt cache directory already bind mounted on target
    else
        notify bind mounting apt cache directory to target
        mount /var/cache/apt/archives ${target}/var/cache/apt/archives -o bind || exit 1
    fi
fi

notify enable 32bit
chroot ${target}/ dpkg --add-architecture i386

if grep -qs 'root:\$' ${target}/etc/shadow ; then
    echo root password already set up
elif [ ! -z "${ROOT_PASSWORD}" ]; then
    notify set up root password
    echo "root:${ROOT_PASSWORD}" > ${target}/tmp/passwd || exit 1
    chroot ${target}/ bash -c "chpasswd < /tmp/passwd" || exit 1
    rm -f ${target}/tmp/passwd
fi

if [ ! -z "${USERNAME}" ]; then
    if grep -qs "^${USERNAME}:" ${target}/etc/shadow ; then
        echo ${USERNAME} user already set up
    else
        notify set up ${USERNAME} user
        chroot ${target}/ bash -c "adduser ${USERNAME} --disabled-password --gecos "${USER_FULL_NAME}"" || exit 1
        chroot ${target}/ bash -c "adduser ${USERNAME} sudo" || exit 1
        if [ ! -z "${USER_PASSWORD}" ]; then
            echo "${USERNAME}:${USER_PASSWORD}" > ${target}/tmp/passwd || exit 1
            chroot ${target}/ bash -c "chpasswd < /tmp/passwd" || exit 1
            rm -f ${target}/tmp/passwd
        fi
    fi
fi

if [ ! -z "${NVIDIA_PACKAGE}" ]; then
  # TODO the debian page says to do this instead:
  # echo "options nvidia-drm modeset=1" >> /etc/modprobe.d/nvidia-options.conf
  kernel_params="${kernel_params} nvidia-drm.modeset=1"
fi

notify configuring dracut and kernel command line
mkdir -p ${target}/etc/dracut.conf.d
cat <<EOF > ${target}/etc/dracut.conf.d/90-luks.conf || exit 1
add_dracutmodules+=" systemd crypt zfs tpm2-tss "
kernel_cmdline="${kernel_params}"
EOF
cat <<EOF > ${target}/etc/kernel/cmdline || exit 1
${kernel_params}
EOF

notify install required packages on ${target}
if [ -z "${NON_INTERACTIVE}" ]; then
    chroot ${target}/ apt-get update -y || exit 1
fi
cat <<EOF > ${target}/tmp/run1.sh || exit 1
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get install -y locales  tasksel network-manager sudo git python3 python3-pip || exit 1
apt-get install -y -t ${BACKPORTS_VERSION} systemd systemd-boot dracut zfsutils-linux zfs-initramfs cryptsetup tpm2-tools tpm-udev || exit 1
bootctl install || exit 1

# Install zectl for boot environment management
git clone https://github.com/johnramsden/zectl /tmp/zectl || exit 1
cd /tmp/zectl || exit 1
pip3 install --break-system-packages . || exit 1
cd / || exit 1
rm -rf /tmp/zectl || exit 1

# Configure zectl
zectl set bootloader=systemdboot || exit 1
EOF
chroot ${target}/ sh /tmp/run1.sh || exit 1

if [ "${DISABLE_LUKS}" != "true" -a "${ENABLE_TPM}" == "true" ]; then
  notify checking for tpm
  cp ${KEYFILE} ${target}/ || exit 1
  chmod 600 ${target}/${KEYFILE} || exit 1
  cat <<EOF > ${target}/tmp/run4.sh || exit 1
systemd-cryptenroll --tpm2-device=list > /tmp/tpm-list.txt || exit 1
if grep -qs "/dev/tpm" /tmp/tpm-list.txt ; then
      echo tpm available, enrolling
      echo "... on root"
      systemd-cryptenroll --unlock-key-file=/${KEYFILE} --tpm2-device=auto ${main_partition} --tpm2-pcrs=${TPM_PCRS} || exit 1
else
    echo tpm not available
fi
EOF
  chroot ${target}/ bash /tmp/run4.sh || exit 1
  rm ${target}/${KEYFILE} || exit 1
fi

notify install kernel and firmware on ${target}
cat <<EOF > ${target}/tmp/packages.txt || exit 1
zfs-auto-snapshot
locales
adduser
passwd
sudo
tasksel
network-manager
binutils
console-setup
exim4-daemon-light
kpartx
pigz
pkg-config
EOF
cat <<EOF > ${target}/tmp/packages_backports.txt || exit 1
linux-image-amd64
systemd
systemd-cryptsetup
systemd-timesyncd
zfsutils-linux
zfs-initramfs
zfs-dkms
dosfstools
dracut
firmware-linux
atmel-firmware
bluez-firmware
dahdi-firmware-nonfree
firmware-amd-graphics
firmware-ath9k-htc
firmware-atheros
firmware-bnx2
firmware-bnx2x
firmware-brcm80211
firmware-carl9170
firmware-cavium
firmware-intel-misc
firmware-intel-sound
firmware-iwlwifi
firmware-libertas
firmware-misc-nonfree
firmware-myricom
firmware-netronome
firmware-netxen
firmware-qcom-soc
firmware-qlogic
firmware-realtek
firmware-ti-connectivity
firmware-zd1211
cryptsetup
lvm2
mdadm
plymouth-themes
polkitd
tpm2-tools
tpm-udev
EOF
cat <<EOF > ${target}/tmp/run2.sh || exit 1
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
xargs apt-get install -y < /tmp/packages.txt || exit 1
xargs apt-get install -t ${BACKPORTS_VERSION} -y < /tmp/packages_backports.txt || exit 1
systemctl disable systemd-networkd.service  # seems to fight with NetworkManager
systemctl disable systemd-networkd.socket
systemctl disable systemd-networkd-wait-online.service
EOF
chroot ${target}/ bash /tmp/run2.sh || exit 1

if [ "$ENABLE_POPCON" = true ] ; then
  notify enabling popularity-contest
  cat <<EOF > ${target}/tmp/run3.sh || exit 1
#!/bin/bash
echo "popularity-contest      popularity-contest/participate  boolean true" | debconf-set-selections
apt-get install -y popularity-contest
EOF
  chroot ${target}/ bash /tmp/run3.sh || exit 1
fi

if [ ! -z "${SSH_PUBLIC_KEY}" ]; then
    notify adding ssh public key to user and root authorized_keys file
    mkdir -p ${target}/root/.ssh || exit 1
    chmod 700 ${target}/root/.ssh || exit 1
    echo "${SSH_PUBLIC_KEY}" > ${target}/root/.ssh/authorized_keys || exit 1
    chmod 600 ${target}/root/.ssh/authorized_keys || exit 1

    if [ ! -z "${USERNAME}" ]; then
        mkdir -p ${target}/home/${USERNAME}/.ssh || exit 1
        chmod 700 ${target}/home/${USERNAME}/.ssh || exit 1
        echo "${SSH_PUBLIC_KEY}" > ${target}/home/${USERNAME}/.ssh/authorized_keys || exit 1
        chmod 600 ${target}/home/${USERNAME}/.ssh/authorized_keys || exit 1
        chroot ${target}/ chown -R ${USERNAME} /home/${USERNAME}/.ssh || exit 1
    fi

    notify installing openssh-server
    chroot ${target}/ apt-get install -y openssh-server || exit 1
fi

if [ -z "${NON_INTERACTIVE}" ]; then
    notify running tasksel
    chroot ${target}/ tasksel
fi

if [ ! -z "${NVIDIA_PACKAGE}" ]; then
  notify installing ${NVIDIA_PACKAGE}
  # XXX dracut-install: ERROR: installing nvidia-blacklists-nouveau.conf nvidia.conf
  cat <<EOF > ${target}/etc/dracut.conf.d/10-nvidia.conf || exit 1
install_items+=" /etc/modprobe.d/nvidia-blacklists-nouveau.conf /etc/modprobe.d/nvidia.conf /etc/modprobe.d/nvidia-options.conf "
EOF
  chroot ${target}/ apt-get install -t ${BACKPORTS_VERSION} -y "${NVIDIA_PACKAGE}" nvidia-driver-libs:i386 linux-headers-amd64 || exit 1
fi

notify cleaning up
chroot ${target}/ apt-get autoremove -y

notify umounting all filesystems
if [ ${SWAP_SIZE} -gt 0 ]; then
    swapoff /dev/zvol/${zpool_name}/swap
fi
zfs unmount -a
zpool export ${zpool_name}

if [ "${DISABLE_LUKS}" != "true" ]; then
  notify closing luks
  cryptsetup luksClose ${luks_device_name}
fi

notify INSTALLATION FINISHED

if [ ! -z "${AFTER_INSTALLED_CMD}" ]; then
  notify running ${AFTER_INSTALLED_CMD}
  sh -c "${AFTER_INSTALLED_CMD}" || exit 1
fi
