# Using Official Debian Live CD with ZFS Installer

This guide explains how to use the official Debian Trixie GNOME Live CD with this installer's ZFS setup script.

## Prerequisites

1. **Download Official Debian Trixie GNOME Live CD**
   - Get it from: https://cdimage.debian.org/cdimage/weekly-live-builds/amd64/iso-hybrid/
   - Look for: `debian-live-testing-amd64-gnome.iso`

2. **Create Bootable USB**
   ```bash
   sudo dd if=debian-live-testing-amd64-gnome.iso of=/dev/sdX bs=4M status=progress
   ```
   Replace `/dev/sdX` with your USB device.
   
   **If using Ventoy**: You may need to select "Boot with GRUB2 style" option when booting the ISO.

## Steps to Run Installer from Live CD

### 1. Boot from Official Live CD
- Boot your system from the Debian Live USB
- Select "Live" option (not the installer)
- Wait for GNOME desktop to load

### 2. Prepare the Environment
Open a terminal and run:
```bash
# Enable contrib and non-free repositories (skip first line with /run/live/medium)
sudo awk 'NR==1 {print; next} (/^deb / || /^deb-src /) && /main$/ {gsub(/main$/, "main contrib non-free non-free-firmware")} {print}' /etc/apt/sources.list > /tmp/sources.list.tmp && sudo mv /tmp/sources.list.tmp /etc/apt/sources.list

# Update package lists
sudo apt update

# Stop conflicting services if running  
sudo systemctl stop bind9 2>/dev/null || true
sudo systemctl stop named 2>/dev/null || true

# Install required dependencies including ZFS support
sudo apt install -y cryptsetup debootstrap uuid-runtime zfsutils-linux zfs-dkms dosfstools curl git linux-headers-$(uname -r)

# Load ZFS kernel module
sudo modprobe zfs || echo "ZFS module will be built by DKMS"

# If you want the web interface, also install:
sudo apt install -y npm golang-go
```

### 3. Get the Installer Files
```bash
# Clone this repository
git clone https://github.com/Anonymo/debian-installer.git
cd debian-installer

# Or download just the installer script:
wget https://raw.githubusercontent.com/Anonymo/debian-installer/master/installer.sh
chmod +x installer.sh
```

### 4. Configure Installation Parameters
Edit the installer.sh file to set your preferences:
```bash
sudo nano installer.sh
```

Key variables to modify (lines 5-18):
- `DISK=/dev/vda` - Change to your target disk (e.g., `/dev/sda`, `/dev/nvme0n1`)
- `USERNAME=user` - Your desired username
- `USER_PASSWORD=hunter2` - Your user password
- `ROOT_PASSWORD=changeme` - Root password
- `ENABLE_ENCRYPTION=false` - Set to `true` if you want ZFS native encryption
- `ENCRYPTION_PASSWORD=` - Encryption password (if using encryption)
- `HOSTNAME=debian13` - Your system hostname
- `SWAP_SIZE=2` - Swap size in GB

### 5. Run the Installation
```bash
# Run the installer script
sudo ./installer.sh
```

The script will:
1. Partition your disk (GPT with EFI and root partitions)
2. Set up ZFS native encryption (if enabled)
3. Create ZFS pool and datasets
4. Install base Debian system via debootstrap
5. Configure the system with your settings
6. Install bootloader and ZFS support

### 6. Optional: Use Web Interface
If you want the browser-based installer interface:

```bash
# Build the frontend (from debian-installer directory)
cd frontend
npm install
npm run build
cd ..

# Build the backend
cd backend
go build -o opinionated-installer
cd ..

# Run the installer backend
sudo ./backend/opinionated-installer

# Open browser to http://localhost:8080
```

## Important Notes

1. **Data Loss Warning**: The installer will ERASE the entire target disk
2. **No Image Acceleration**: Unlike the custom ISO, this method uses debootstrap which downloads packages during installation (requires internet)
3. **Manual Process**: You need to manually edit configuration - no pre-seeding like with custom ISO
4. **ZFS Module**: The Live CD may not have ZFS modules loaded, the installer will handle this

## Advantages of This Method
- No need to build custom ISO
- Uses official Debian images
- Can be done from any Debian/Ubuntu live system
- Still get ZFS with boot environments and encryption

## Troubleshooting

If ZFS modules fail to load:
```bash
sudo modprobe zfs
sudo apt install --reinstall zfsutils-linux zfs-dkms
```

If debootstrap fails:
```bash
# Check internet connection
ping -c 3 deb.debian.org

# Try different mirror
sudo nano installer.sh
# Add after line 28:
# MIRROR=http://ftp.us.debian.org/debian
```

## Post-Installation

After successful installation:
1. Remove USB drive
2. Reboot system
3. If using encryption, enter password at boot
4. Login with the credentials you configured

Your system will have:
- ZFS root with datasets at `rpool/ROOT/debian` and `rpool/home`
- Boot environment management via zectl
- Full disk encryption (if enabled)
- Systemd-boot instead of GRUB