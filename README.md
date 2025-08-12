# Opinionated Debian Installer - ZFS Fork

**This is a fork of the [original Opinionated Debian Installer](https://github.com/r0b0/debian-installer) created by [r0b0](https://github.com/r0b0) that replaces BTRFS with ZFS and adds boot environment management via [zectl](https://github.com/johnramsden/zectl).**

## Credits

This project is based on the excellent work by multiple contributors:

- **Original Project**: [Opinionated Debian Installer](https://github.com/r0b0/debian-installer) by [r0b0](https://github.com/r0b0)
  - Core installer framework, web interface, and system installation logic

- **Ubuntu Theme Implementation**: [make-debian-look-like-ubuntu](https://github.com/DeltaLima/make-debian-look-like-ubuntu) by [DeltaLima](https://github.com/DeltaLima)
  - Ubuntu theme configuration scripts and GNOME customization approach

- **ZFS Fork Enhancements**: Additional features and ZFS integration by this fork
  - Desktop environment selection, hardware optimization, development tools integration

We extend our gratitude to all the original developers for creating the foundation that made this ZFS-enhanced version possible.

This tool can be used to create a modern installation of Debian. 
Our opinions of what a modern installation of Debian should look like in 2025 are:

 - Debian 13 (Trixie)
 - Backports and non-free enabled
 - Firmware installed
 - Installed on ZFS datasets with boot environment management via zectl
 - Optional ZFS native encryption (AES-256-GCM)
 - Multiple desktop environment options (GNOME, KDE, XFCE, or minimal)
 - Hardware-optimized ZFS performance settings
 - Automatic driver detection and installation
 - Optional development tools and Flatpak support
 - Browser-based installer with comprehensive validation
  
## Limitations

 - **The installer will take over your whole disk**
 - Amd64 with EFI only
 - The installer is in english only

## Installation Methods

### Method 1: Use Official Debian Live CD (Recommended)
**No custom ISO build required!** Boot an official Debian Live CD and run the web installer:

1. Download [Debian Trixie GNOME Live CD](https://cdimage.debian.org/cdimage/weekly-live-builds/amd64/iso-hybrid/)
   - **If using Ventoy**: Select "Boot with GRUB2 style" option when booting the ISO
2. Boot the Live CD and run:
   ```bash
   curl -L https://raw.githubusercontent.com/Anonymo/debian-installer/master/livecd-quick-install.sh | bash
   ```
3. Browser will automatically open to `http://localhost:5000/`
4. Fill out all required fields in the form:
   - Select target disk and desktop environment
   - Configure user account and passwords  
   - Choose optional features (encryption, development tools, Flatpak, etc.)
   - All required fields must be filled for Install button to activate
5. Or follow the manual steps in [LIVE_CD_WEB_INSTALLER.md](LIVE_CD_WEB_INSTALLER.md)

### Method 2: Manual Installation with Script

For advanced users who prefer command-line installation:

1. Boot any Debian Live CD and run:
   ```bash
   # Download and run the ZFS installer script directly
   curl -L https://raw.githubusercontent.com/Anonymo/debian-installer/master/installer-zfs-native-encryption.sh -o installer.sh
   chmod +x installer.sh
   
   # Edit the variables at the top of the script
   nano installer.sh
   
   # Run the installer
   sudo ./installer.sh
   ```

## What's Different in This Fork

### ZFS Instead of BTRFS
- Uses ZFS datasets instead of BTRFS subvolumes
- ZFS pool named `rpool` with datasets:
  - `rpool/ROOT/debian` for the root filesystem
  - `rpool/home` for `/home`
  - `rpool/swap` for swap (zvol)

### Desktop Environment Options
- **GNOME** (default) - Full GNOME desktop with GDM
- **KDE Plasma** - Modern KDE desktop with SDDM
- **XFCE** - Lightweight desktop with LightDM
- **Minimal** - Command-line only installation

### Hardware Detection & Optimization
- **Automatic driver detection** for NVIDIA/AMD graphics and WiFi chipsets
- **Storage-optimized ZFS settings** based on detected hardware (NVMe/SSD/HDD)
- **Dynamic ZFS ARC sizing** based on available RAM
- **TPM detection** with compatibility warnings for older hardware
- **Intelligent compression** selection (LZ4 for SSDs, ZSTD for HDDs)

### Ubuntu-Like Theme Option
- Optional Ubuntu-like appearance with Yaru theme (GNOME only)
- Installs Yaru theme packages, Ubuntu fonts, and GNOME extensions
- Configures dash-to-dock, app indicators, and desktop icons
- Applies automatically on first login after installation

### Development Tools & Software
- **Optional development environment** with Git, VS Code, Docker, build tools
- **Flatpak support** with desktop environment integration
- **Comprehensive package selection** including Python, Node.js, Java tools

### Boot Environment Management with zectl
- Integrated [zectl](https://github.com/johnramsden/zectl) for managing boot environments
- Create snapshots before system updates
- Easily rollback to previous boot environments
- Compatible with systemd-boot

### Encryption Support
- **ZFS Native Encryption** (NEW) - AES-256-GCM encryption at the dataset level
- Encryption is completely optional
- No additional encryption layers needed
- Password prompt at boot for ZFS native encryption

### Installation Features
- **Comprehensive validation** - disk space, connectivity, configuration checks
- **Progress indicators** - real-time installation progress with 12 distinct phases
- **Error handling** - detailed error messages with exit codes for troubleshooting
- **Hardware-aware configuration** - automatic optimization based on detected hardware
- **Rollback capability** - ZFS boot environments for safe system recovery

## Installation Result

After installation, you'll have a fully optimized Debian system with:

- **Your chosen desktop environment** - GNOME, KDE, XFCE, or minimal CLI
- **ZFS root filesystem** with hardware-optimized settings and compression
- **Boot environment management** - automatic snapshots before updates with rollback capability
- **Modern boot setup** - systemd-boot with dracut instead of legacy GRUB/initramfs
- **Optional encryption** - ZFS native encryption with boot-time password prompt
- **Development ready** - optional VS Code, Docker, Git, and modern development tools
- **Software flexibility** - Flatpak support for additional applications

## Details

- GPT disk partitions are created on the designated disk drive: 
  - UEFI ESP partition
  - Root partition - ZFS pool with optional native encryption
- ZFS pool is created directly on the partition
- GPT root partition is [auto-discoverable](https://www.freedesktop.org/software/systemd/man/systemd-gpt-auto-generator.html)
- ZFS datasets will be created as:
  - `rpool/ROOT/debian` for `/` (root filesystem)
  - `rpool/home` for `/home`
  - `rpool/swap` for swap (zvol)
- [zectl](https://github.com/johnramsden/zectl) is installed for boot environment management
- Boot environments allow easy rollback if system updates cause issues
- The system is installed using an image from the live iso. This will speed up the installation significantly and allow off-line installation.
- [Dracut](https://github.com/dracutdevs/dracut/wiki/) is used instead of initramfs-tools
- [Systemd-boot](https://www.freedesktop.org/wiki/Software/systemd/systemd-boot/) is used instead of grub
- [Network-manager](https://wiki.debian.org/NetworkManager) is used for networking
- ZFS native encryption with AES-256-GCM (no LUKS layer needed)
- [Sudo](https://wiki.debian.org/sudo) is installed and configured for the created user 

## (Optional) Configuration, Automatic Installation

Edit [installer.ini](installer-files/boot/efi/installer.ini) on the first (vfat) partition of the installer image.
It will allow you to pre-seed and automate the installation.

If you edit it directly in the booted installer image, it is /boot/efi/installer.ini
Reboot after editing the file for the new values to take effect.

## Headless Installation

You can use the installer for server installation.

As a start, edit the configuration file installer.ini (see above), set option BACK_END_IP_ADDRESS to 0.0.0.0 and reboot the installer.
**There is no encryption or authentication in the communication so only do this on a trusted network.**

You have several options to access the installer. 
Assuming the IP address of the installed machine is 192.168.1.29 and you can reach it from your PC:

* Use the web interface in a browser on a PC - open `http://192.168.1.29/opinionated-debian-installer/`
* Use the text mode interface - start `opinionated-installer tui -baseUrl http://192.168.1.29:5000`
* Use curl - again, see the [installer.ini](installer-files/boot/efi/installer.ini) file for list of all options for the form data in -F parameters:

      curl -v -F "DISK=/dev/vda" -F "USER_PASSWORD=hunter2" \
      -F "ROOT_PASSWORD=changeme" -F "ENCRYPTION_PASSWORD=secret" \ 
      http://192.168.1.29:5000/install

* Use curl to prompt for logs:

      curl  http://192.168.1.29:5000/download_log

## Testing

**⚠️ Note: Testing for this ZFS fork is pending. The instructions below are from the original BTRFS version and may need adjustments for ZFS.**

If you are testing in a virtual machine, attaching the downloaded image file as a virtual disk, you need to extend it first.
The image file that you downloaded is shrunk, there is no free space left in the filesystems.
Use `truncate -s +500M opinionated*.img` to add 500MB to the virtual disk before you attach it to a virtual machine.
The installer will expand the partitions and filesystem to fill the device.

### Libvirt

To test with [libvirt](https://libvirt.org/), make sure to create the VM with UEFI:

1. Select the _Customize configuration before install_ option at the end of the new VM dialog
2. In the VM configuration window, _Overview_ tab, _Hypervisor Details_ section, select _Firmware_: _UEFI_


To add a TPM module, you need to install the [swtpm-tools](https://packages.debian.org/trixie/swtpm-tools) package.

Attach the downloaded installer image file as _Device type: Disk device_, not ~~CDROM device~~.

### Hyper-V

To test with the MS hyper-v virtualization, make sure to create your VM with [Generation 2](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/Should-I-create-a-generation-1-or-2-virtual-machine-in-Hyper-V). 
This will enable UEFI.
TPM can be enabled and Secure Boot disabled in the Security tab of the Hyper-V settings.

You will also need to convert the installer image to VHDx format and make the file not sparse.
You can use [qemu-img](https://www.qemu.org/docs/master/tools/qemu-img.html) ([windows download](https://qemu.weilnetz.de/w64/)) and fsutil like this:

    qemu-img convert -f raw -O vhdx opinionated-debian-installer-*.img odin.vhdx
    fsutil sparse setflag odin.vhdx 0

Attach the generated VHDx file as a disk, not as a ~~CD~~.

## Hacking

## Development

### Building the Frontend

The frontend is a [Vue.js](https://vuejs.org/) application. Build it with:

```bash
cd frontend
npm install
npm run build
```

### Building the Backend

The backend is a [Go](https://go.dev/) application. Build it with:

```bash
cd backend
go build -o opinionated-installer
```

## Comparison

The following table contains comparison of features between our opinionated debian installer and official debian installers.

| Feature                                             | ODIN  | [Netinstall](https://www.debian.org/CD/netinst/) | [Calamares](https://get.debian.org/debian-cd/current-live/amd64/iso-hybrid/) |
|-----------------------------------------------------|-------|--------------------------------------------------|------------------------------------------------------------------------------|
| Installer internationalization                      | N     | Y                                                | Y                                                                            |
| Mirror selection, HTTP proxy support                | N     | Y                                                | N                                                                            |
| Manual disk partitioning, LVM, filesystem selection | N[4]  | Y                                                | Y                                                                            |
| ZFS datasets with boot environments                 | **Y**[2] | N                                                | N                                                                            |
| Full drive encryption                               | **Y** | Y[1]                                             | Y                                                                            |
| Passwordless unlock (TPM)                           | **Y** | N                                                | N                                                                            |
| Live CD + web installer                            | **Y** | N                                                | N                                                                            |
| Non-free and backports                              | **Y** | N                                                | N                                                                            |
| Browser-based installer                             | **Y** | N                                                | N                                                                            |

[1] `/boot` needs a separate unencrypted partition

[2] `rpool/ROOT/debian` and `rpool/home` with zectl boot environment management

[3] `@rootfs`

[4] Fixed partitioning (see Details above), ZFS native encryption is optional
