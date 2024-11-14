#!/usr/bin/env bash
#
# Script to set up the libvirt qemu hook and directory structure for a specified VM

####################################################
# 1. Create libvirt qemu hook                      #
####################################################

HOOK_DIR="/etc/libvirt/hooks"
QEMU_FILE="$HOOK_DIR/qemu"
QEMU_D="$HOOK_DIR/qemu.d"

# Ensure the hooks directory exists
if [ ! -d "$HOOK_DIR" ]; then
    echo "Creating hooks directory at $HOOK_DIR..."
    sudo mkdir -p "$HOOK_DIR"
    echo "Directory created."
else
    echo "$HOOK_DIR already exists."
fi

# Create the qemu hook file if it doesn't exist
if [ ! -f "$QEMU_FILE" ]; then
    echo "Creating qemu hook file at $QEMU_FILE..."
    sudo wget 'https://raw.githubusercontent.com/PassthroughPOST/VFIO-Tools/master/libvirt_hooks/qemu' -O "$QEMU_FILE"
    sudo chmod +x "$QEMU_FILE"
    echo "Hook file created and made executable."
    sudo service libvirtd restart
    echo "Restarted libvirtd service."
else
    if command -v systemctl &> /dev/null; then
        # Restart libvirtd using systemctl
        echo "Using systemctl to restart libvirtd..."
        sudo systemctl restart libvirtd
    elif command -v service &> /dev/null; then
        # Restart libvirtd using service command
        echo "Using service to restart libvirtd..."
        sudo service libvirtd restart
    fi
fi

####################################################
# 2. Create directory structure for a specified VM #
####################################################

read -p "Enter the name of the VM (e.g., win11): " VM_NAME
read -p "Enter the GPU PCI addresses to pass to the VM (separated by spaces, e.g., pci_0000_01_00_0 pci_0000_01_00_1): " VFIO_DEVICES

VM_DIR="$QEMU_D/$VM_NAME"
VM_VARS_FILE="$VM_DIR/vm-vars.conf"
PREPARE_BEGIN_DIR="$VM_DIR/prepare/begin"
START_BEGIN_DIR="$VM_DIR/start/begin"
STARTED_BEGIN_DIR="$VM_DIR/started/begin"
STOPPED_END_DIR="$VM_DIR/stopped/end"
RELEASE_END_DIR="$VM_DIR/release/end"

# Create the VM directory structure
echo "Creating directory structure for VM $VM_NAME..."
sudo mkdir -p "$PREPARE_BEGIN_DIR" "$START_BEGIN_DIR" "$STARTED_BEGIN_DIR" "$STOPPED_END_DIR" "$RELEASE_END_DIR"

####################################################
# 3. VM vars file                                  #
####################################################
if [ ! -f "$VM_VARS_FILE" ]; then
    sudo tee "$VM_VARS_FILE" > /dev/null << EOF
    ## $VM_NAME VM Script Parameters

    # Define the PCI addresses to pass to the VM
    VFIO_DEVICES=\"$VFIO_DEVICES\"

    # User Information
    LOGGED_IN_USERNAME=$(whoami)
    LOGGED_IN_USERID=$(id -u)

    # Screen Settings
    GNOME_IDLE_DELAY=900

    # VM Memory Configuration
    VM_MEMORY=62499840

    # CPU Governor Settings
    VM_ON_GOVERNOR=performance
    VM_OFF_GOVERNOR=schedutil

    # Power Profile Settings
    VM_ON_PWRPROFILE=performance
    VM_OFF_PWRPROFILE=power-saver

    # CPU Isolation Configuration
    VM_ISOLATED_CPUS=0-7,16-23
    SYS_TOTAL_CPUS=0-31

    # SWITCH DISPLAY INPUT
    VM_DISPLAY="1"
    VM_INPUT="0f"
    HOST_INPUT="13"
EOF
    # Make VM vars file readable
    sudo chmod 644 "$VM_VARS_FILE"
    echo "Created VM configuration file at $VM_VARS_FILE."
else
    echo "$VM_VARS_FILE already exists."
fi

####################################################
# 4. BIND and UNBIND VFIO                          #
####################################################

# Bind VFIO script
echo "#!/bin/bash" | sudo tee "$PREPARE_BEGIN_DIR/bind_vfio.sh" > /dev/null
echo "source \"$VM_VARS_FILE\"" | sudo tee -a "$PREPARE_BEGIN_DIR/bind_vfio.sh" > /dev/null
sudo tee -a "$PREPARE_BEGIN_DIR/bind_vfio.sh" > /dev/null << 'EOF'
modprobe vfio
modprobe vfio_iommu_type1
modprobe vfio_pci

for DEVICE in $VFIO_DEVICES; do
    echo "Detaching device $DEVICE"
    virsh nodedev-detach $DEVICE
done
EOF
sudo chmod +x "$PREPARE_BEGIN_DIR/bind_vfio.sh"
echo "Created bind_vfio.sh hook at $PREPARE_BEGIN_DIR/bind_vfio.sh."

# Unbind VFIO script
echo "#!/bin/bash" | sudo tee "$RELEASE_END_DIR/unbind_vfio.sh" > /dev/null
echo "source \"$VM_VARS_FILE\"" | sudo tee -a "$RELEASE_END_DIR/unbind_vfio.sh" > /dev/null
sudo tee -a "$RELEASE_END_DIR/unbind_vfio.sh" > /dev/null << 'EOF'
for DEVICE in $VFIO_DEVICES; do
    echo "Reattaching device $DEVICE"
    virsh nodedev-reattach $DEVICE
done

modprobe -r vfio_pci
modprobe -r vfio_iommu_type1
modprobe -r vfio
EOF
sudo chmod +x "$RELEASE_END_DIR/unbind_vfio.sh"
echo "Created unbind_vfio.sh hook at $RELEASE_END_DIR/unbind_vfio.sh."

####################################################
# 5. RESERVE and RELEASE HUGEPAGES                 #
####################################################

# Remember to add <hugepages> to the domain XML file to reserve hugepages for the VM:
# <memoryBacking>
#    <hugepages/>
#  </memoryBacking>

# Reserve hugepages script
sudo tee "$PREPARE_BEGIN_DIR/reserve_hugepages.sh" > /dev/null << 'EOF'
#!/usr/bin/env bash
#
# Author: SharkWipf (https://github.com/SharkWipf)
#
# This file depends on the PassthroughPOST hook helper script found here:
# https://github.com/PassthroughPOST/VFIO-Tools/tree/master/libvirt_hooks
# This hook only needs to run on `prepare/begin`, not on stop.
# Place this script in this directory:
# $SYSCONFDIR/libvirt/hooks/qemu.d/your_vm/prepare/begin/
# $SYSCONFDIR usually is /etc/libvirt.
#
# This hook will help free and compact memory to ease THP allocation.
# QEMU VMs will use THP (Transparent HugePages) by default if enough
# unfragmented memory can be found on startup. If your memory is very
# fragmented, this may cause a slow VM startup (like a slowly responding 
# VM start button/command), and may cause QEMU to fall back to regular
# memory pages, slowing down VM performance.
# If you (suspect you) suffer from this, this hook will help ease THP
# allocation so you don't need to resort to misexplained placebo scripts.
#
# Don't use the old hugepages.sh script in this repo. It's useless.
# It's only kept in for archival reasons and offers no benefits.
#

# Finish writing any outstanding writes to disk.
sync
# Drop all filesystem caches to free up more memory.
echo 3 > /proc/sys/vm/drop_caches
# Do another run of writing any possible new outstanding writes.
sync
# Tell the kernel to "defragment" memory where possible.
echo 1 > /proc/sys/vm/compact_memory
EOF
sudo chmod +x "$PREPARE_BEGIN_DIR/reserve_hugepages.sh"

####################################################
# 6. SET and RESTORE CPU GOVERNOR                  #
####################################################

# set CPU governor
echo "#!/bin/bash" | sudo tee "$PREPARE_BEGIN_DIR/set-governor.sh" > /dev/null
echo "source \"$VM_VARS_FILE\"" | sudo tee -a "$PREPARE_BEGIN_DIR/set-governor.sh" > /dev/null
sudo tee -a "$PREPARE_BEGIN_DIR/set-governor.sh" > /dev/null << 'EOF'
## Set CPU governor to mode indicated by variable
CPU_COUNT=0
for file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
do
    echo $VM_ON_GOVERNOR > $file;
    echo "CPU $CPU_COUNT governor: $VM_ON_GOVERNOR";
    let CPU_COUNT+=1
done

## Set system power profile to performance
powerprofilesctl set $VM_ON_PWRPROFILE

sleep 1
EOF
sudo chmod +x "$PREPARE_BEGIN_DIR/set-governor.sh"

# restore-governor.sh to restore CPU governor
echo "#!/bin/bash" | sudo tee "$RELEASE_END_DIR/restore-governor.sh" > /dev/null
echo "source \"$VM_VARS_FILE\"" | sudo tee -a "$RELEASE_END_DIR/restore-governor.sh" > /dev/null
sudo tee -a "$RELEASE_END_DIR/restore-governor.sh" > /dev/null << 'EOF'
## Reset CPU governor to mode indicated by variable
CPU_COUNT=0
for file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
do
    echo $VM_OFF_GOVERNOR > $file;
    echo "CPU $CPU_COUNT governor: $VM_OFF_GOVERNOR";
    let CPU_COUNT+=1
done

## Set system power profile back to powersave
powerprofilesctl set $VM_OFF_PWRPROFILE

sleep 1
EOF
sudo chmod +x "$RELEASE_END_DIR/restore-governor.sh"
echo "Created CPU governor hooks"

####################################################
# 7. ISOLATE AND RELEASE CPU CORES                 #
####################################################

# isolate CPUs
echo "#!/bin/bash" | sudo tee "$PREPARE_BEGIN_DIR/isolate-cpus.sh" > /dev/null
echo "source \"$VM_VARS_FILE\"" | sudo tee -a "$PREPARE_BEGIN_DIR/isolate-cpus.sh" > /dev/null
sudo tee -a "$PREPARE_BEGIN_DIR/isolate-cpus.sh" > /dev/null << 'EOF'
## Reset CPU governor to mode indicated by variable
CPU_COUNT=0
for file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
do
    echo $VM_OFF_GOVERNOR > $file;
    echo "CPU $CPU_COUNT governor: $VM_OFF_GOVERNOR";
    let CPU_COUNT+=1
done

## Set system power profile back to powersave
powerprofilesctl set $VM_OFF_PWRPROFILE

sleep 1
EOF
sudo chmod +x "$PREPARE_BEGIN_DIR/isolate-cpus.sh"

# return CPUs
echo "#!/bin/bash" | sudo tee "$RELEASE_END_DIR/return-cpus.sh" > /dev/null
echo "source \"$VM_VARS_FILE\"" | sudo tee -a "$RELEASE_END_DIR/return-cpus.sh" > /dev/null
sudo tee -a "$RELEASE_END_DIR/return-cpus.sh" > /dev/null << 'EOF'
# return CPUs
## Return CPU cores as per set variable
systemctl set-property --runtime -- user.slice AllowedCPUs=$SYS_TOTAL_CPUS
systemctl set-property --runtime -- system.slice AllowedCPUs=$SYS_TOTAL_CPUS
systemctl set-property --runtime -- init.scope AllowedCPUs=$SYS_TOTAL_CPUS

sleep 1
EOF
sudo chmod +x "$RELEASE_END_DIR/return-cpus.sh"
echo "Created CPU isolation hooks"

####################################################
# 8. DISABLE and RE-ENABLE GNOME SCREENSAVER       #
####################################################

# disable screensaver
echo "#!/bin/bash" | sudo tee "$PREPARE_BEGIN_DIR/disable_screensaver.sh" > /dev/null
echo "source \"$VM_VARS_FILE\"" | sudo tee -a "$PREPARE_BEGIN_DIR/disable_screensaver.sh" > /dev/null
sudo tee -a "$PREPARE_BEGIN_DIR/disable_screensaver.sh" > /dev/null << 'EOF'
## Set dconf keys to disable screensaver and screen blanking. This is
## needed as looking-glass disable screensaver doesn't work with Gnome
export LOGGED_IN_USERID
su $LOGGED_IN_USERNAME -c 'export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$LOGGED_IN_USERID/bus \
&& dconf write /org/gnome/settings-daemon/plugins/power/idle-dim false \
&& dconf write /org/gnome/desktop/session/idle-delay "uint32 0"'

sleep 1
EOF
sudo chmod +x "$PREPARE_BEGIN_DIR/disable_screensaver.sh"

# enable screensaver
echo "#!/bin/bash" | sudo tee "$RELEASE_END_DIR/enable_screensaver.sh" > /dev/null
echo "source \"$VM_VARS_FILE\"" | sudo tee -a "$RELEASE_END_DIR/enable_screensaver.sh" > /dev/null
sudo tee -a "$RELEASE_END_DIR/enable_screensaver.sh" > /dev/null << 'EOF'
## Set dconf keys to re-enable screensaver and screen blanking. This is
## needed as looking-glass disable screensaver doesn't work with Gnome
export LOGGED_IN_USERID
export GNOME_IDLE_DELAY
su $LOGGED_IN_USERNAME -c 'export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$LOGGED_IN_USERID/bus \
&& dconf write /org/gnome/settings-daemon/plugins/power/idle-dim true \
&& dconf write /org/gnome/desktop/session/idle-delay "uint32 $GNOME_IDLE_DELAY"'

sleep 1
EOF
sudo chmod +x "$RELEASE_END_DIR/enable_screensaver.sh"
echo "Created screen_saver hooks"

####################################################
# 9. SWITCH DISPLAY INPUT                          #
####################################################

# Change display input when VM starts and stops
echo "#!/usr/bin/env bash" | sudo tee "$STARTED_BEGIN_DIR/switch_displays.sh" > /dev/null
echo "source \"$VM_VARS_FILE\"" | sudo tee -a "$STARTED_BEGIN_DIR/switch_displays.sh" > /dev/null
sudo tee -a "$STARTED_BEGIN_DIR/switch_displays.sh" > /dev/null << 'EOF'
#
# Author: SharkWipf
#
# This hook allows automatically switch monitor inputs when starting/stopping a VM.
# This file depends on the Passthrough POST hook helper script found in this repo.
# Place this script in BOTH these directories (or symlink it): 
# $SYSCONFDIR/libvirt/hooks/qemu.d/your_vm/started/begin/
# $SYSCONFDIR/libvirt/hooks/qemu.d/your_vm/stopped/end/
# $SYSCONFDIR usuallu is /etc/libvirt.
# Set the files as executable through `chmod +x` and configure your inputs.
# You also need `ddcutil` and a ddcutil-compatible monitor.

if [[ "$2/$3" == "started/begin" ]]; then
    INPUT="$VM_INPUT"
elif [[ "$2/$3" == "stopped/end" ]]; then
    INPUT="$HOST_INPUT"
fi

if [[ "$(ddcutil -d "$VM_DISPLAY" getvcp 60 --terse | awk '{print $4}')" != "x$INPUT" ]]; then
    ddcutil -d "$VM_DISPLAY" setvcp 60 "0x$INPUT"
fi
EOF
# Copy switch_displays.sh to stopped/end directory
sudo cp "$STARTED_BEGIN_DIR/switch_displays.sh" "$STOPPED_END_DIR/switch_displays.sh"

sudo chmod +x "$STARTED_BEGIN_DIR/switch_displays.sh"
sudo chmod +x "$STOPPED_END_DIR/switch_displays.sh"
echo "Created switch_displays.sh hooks"

echo "All setup completed for VM $VM_NAME."
