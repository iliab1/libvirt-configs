#!/bin/bash
VM_NAME="win11"
APP_NAME="Windows Virtual Machine"

# Define the icon URL and target path
ICON_URL="https://example.com/path/to/Win10Logo.png"  # Replace with the actual URL of the icon
ICON_PATH="$HOME/.local/share/icons/hicolor/256x256/emblems/Win11Logo.png"

# Create the directory for the icon if it doesn't exist
mkdir -p "$(dirname "$ICON_PATH")"

# Download the icon
echo "Downloading the icon..."
curl -o "$ICON_PATH" "$ICON_URL"

# Check if the download was successful
if [[ $? -ne 0 ]]; then
    echo "Failed to download the icon. Exiting."
    exit 1
fi
echo "Icon downloaded successfully."

# Define the desktop entry properties
cat << EOF > ~/Desktop/$VM_NAME.desktop
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_NAME
GenericName=Starts $VM_NAME
Comment=Launches a $VM_NAME VM
Exec=sh -c "virsh --connect=qemu:///system start $VM_NAME"
Icon=$ICON_PATH
Terminal=false
Categories=Application;System;
EOF

# Install the desktop entry file to the system's applications directory
sudo desktop-file-install --dir=/usr/share/applications ~/Desktop/$VM_NAME.desktop

echo "$VM_NAME Desktop entry created and installed successfully!"
