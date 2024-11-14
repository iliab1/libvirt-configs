# Libvirt VM Configurations

This repository contains my libvirt VM configurations and scripts designed to streamline virtual machine deployment and management on Arch Linux.

My setup is:
- **CPU**: AMD 7950x3d
- **GPU1**: NVIDIA 4080 Super Founders Edition
- **GPU2**: NVIDIA A2000

## Contents

### Scripts

#### `hook_creator.sh`
As the name implies, this script automatically populates `/etc/libvirt/hooks` allows to add hooks on a per-VM basis to:
- Automatically bind and unbind VFIO drivers for GPU.
- Reserve and release hugepages.
- Set CPU governor.
- Isolate CPU cores.
- Disable GNOME screensaver.
- Switch display input using `ddcutil`.

#### `create_desktop_app.sh`
This script sets up an application for starting the VM directly from your desktop environment.

### Configuration Files

#### `win11.xml`
This is the configuration file for my Windows 11 virtual machine. It includes all the necessary settings for running Windows 11 smoothly on libvirt, including CPU, memory, disk, and device configurations. Make sure to modify it based on your system and devices.

## How to Use

1. **Create Hooks**:
   Run `hook_creator.sh` to generate libvirt hooks automatically:
   ```bash
   ./hook_creator.sh
   ```

2. **Set Up Desktop App**:
   Use `create_desktop_app.sh` to create a desktop shortcut for launching the VM:
   ```bash
   ./create_desktop_app.sh
   ```

3. **Configure VM**:
   Import the `win11.xml` configuration into libvirt:
   ```bash
   virsh define win11.xml
   ```

## Notes
- These scripts and configurations are tailored to my setup but can be modified to suit other environments.
- Ensure you have the necessary permissions to execute the scripts and manage libvirt configurations.

## Acknowledgments:
- [Bryan Steiner's GPU Passthrough Tutorial](https://github.com/bryansteiner/gpu-passthrough-tutorial)
- [PassthroughPOST's VFIO Tools](https://github.com/PassthroughPOST/VFIO-Tools)
- [ASUS Linux VFIO Guide](https://asus-linux.org/guides/vfio-guide/)
- [SharkWipf](https://github.com/SharkWipf/)

## License
This repository is provided as-is without any warranty. Use at your own risk.

