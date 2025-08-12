# Using Official Debian Live CD with Web Installer

This guide shows how to use the official Debian Trixie GNOME Live CD with the web-based installer interface - **no manual editing required!**

## Quick Start

### Option A: One-Line Installer (Easiest)
Boot the Live CD and run:
```bash
curl -L https://raw.githubusercontent.com/Anonymo/debian-installer/master/livecd-quick-install.sh | bash
```
This will automatically set up everything and start the web installer at http://localhost:5000/

### Option B: Manual Setup

#### 1. Get Official Debian Live CD
Download from: https://cdimage.debian.org/cdimage/weekly-live-builds/amd64/iso-hybrid/
- Look for: `debian-live-testing-amd64-gnome.iso`
- Write to USB: `sudo dd if=debian-live-testing-amd64-gnome.iso of=/dev/sdX bs=4M status=progress`

#### 2. Boot and Install Dependencies
Boot the Live CD and open a terminal:
```bash
# Enable non-free-firmware repository (skip cdrom and first line)
sudo sed -i '2,$ {/^deb cdrom/! s/ main$/ main non-free-firmware/}' /etc/apt/sources.list

# Install required packages
sudo apt update
sudo apt install -y git golang-go npm zfsutils-linux debootstrap

# Clone the installer
git clone https://github.com/Anonymo/debian-installer.git
cd debian-installer
```

#### 3. Build and Run Web Installer
```bash
# Build frontend
cd frontend
npm install
npm run build
cd ..

# Build backend
cd backend
go build -o opinionated-installer
cd ..

# Run the installer backend with correct paths
sudo INSTALLER_SCRIPT="$(pwd)/installer-zfs-native-encryption.sh" \
     ./backend/opinionated-installer backend -staticHtmlFolder "$(pwd)/frontend/dist"
```

#### 4. Open Web Interface
Open Firefox and navigate to:
```
http://localhost:5000/
```

#### 5. Fill Out the Form
The web interface provides a user-friendly form with:
- **Disk Selection**: Choose your target disk from dropdown
- **User Configuration**: Username, password, full name
- **Encryption Options**: 
  - Toggle "Enable Encryption" for ZFS native encryption
  - Set encryption password (if enabled)
- **System Settings**: Hostname, timezone, swap size
- **Optional**: SSH keys, NVIDIA drivers, etc.

Click the big **Install** button when ready!

## What You Get

Your system will have:
- **ZFS root filesystem** with datasets:
  - `rpool/ROOT/debian` - root filesystem
  - `rpool/home` - home directories  
  - `rpool/swap` - swap zvol (if configured)
- **Boot Environment Management** via `zectl`:
  - Automatic snapshots before system updates
  - Easy rollback if updates cause issues
  - `zectl list` - show boot environments
  - `zectl create <name>` - create new boot environment
  - `zectl activate <name>` - switch boot environments
- **ZFS Native Encryption** (optional):
  - Direct encryption at the ZFS layer
  - Encryption at the dataset level
  - Password prompt at boot
- **Automatic APT Snapshots**:
  - Creates boot environment before package upgrades
  - Located at `/etc/apt/apt.conf.d/80-zectl-snapshot`
- **Modern Boot Setup**:
  - systemd-boot instead of GRUB
  - Dracut instead of initramfs-tools

## Advanced Options

### Headless/Remote Installation
Edit the backend command to listen on all interfaces:
```bash
sudo ./backend/opinionated-installer backend -listenPort 5000
```
Then access from another machine: `http://<server-ip>:5000/`

**Warning**: No encryption/authentication - use only on trusted networks!

### Using Terminal UI Instead
```bash
# Run TUI interface
sudo ./backend/opinionated-installer tui
```

### Direct Installation (No UI)
Use the provided `installer-zfs-native-encryption.sh` script:
```bash
sudo ./installer-zfs-native-encryption.sh
```
But you'll need to edit variables at the top of the script first.

## Key Differences from Custom ISO

| Feature | Custom ISO | Official Live CD + Installer |
|---------|------------|------------------------------|
| Image-based install | ✓ Fast | ✗ Uses debootstrap (slower) |
| Internet required | ✗ Works offline | ✓ Downloads packages |
| Pre-configuration | ✓ Via installer.ini | ✗ Use web form |
| Build required | ✓ Must build ISO | ✗ Just run installer |

## Troubleshooting

### ZFS Module Issues
```bash
sudo modprobe zfs
sudo apt install --reinstall zfsutils-linux zfs-dkms
```

### Port Already in Use
```bash
# Check what's using port 5000
sudo lsof -i :5000
# Use different port
sudo ./backend/opinionated-installer backend -listenPort 8080
```

### Build Errors
```bash
# For frontend issues
cd frontend && rm -rf node_modules && npm install

# For backend issues  
cd backend && go mod download
```

## Post-Installation

After installation completes:
1. Remove USB drive
2. Reboot system
3. Login with your configured credentials

### Managing Boot Environments
```bash
# List boot environments
zectl list

# Create new boot environment before major change
sudo zectl create before-experiment

# Activate different boot environment
sudo zectl activate before-experiment

# Delete old boot environment
sudo zectl destroy old-be
```

### ZFS Encryption Management
If you enabled encryption:
```bash
# Check encryption status
zfs get encryption rpool

# Load keys at boot (if not using systemd integration)
zfs load-key rpool
```

## Benefits Over Manual Installation
- **No manual editing** - web form handles all configuration
- **Input validation** - prevents common mistakes
- **Live progress** - see installation output in real-time
- **Automatic setup** of zectl and APT hooks
- **Consistent results** - same installation every time