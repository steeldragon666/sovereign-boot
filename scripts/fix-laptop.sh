#!/bin/bash
# Fix all USB blocking issues on the sovereign laptop
# Run with: sudo bash fix-laptop.sh

if [[ $EUID -ne 0 ]]; then
    echo "Run with: sudo bash $0"
    exit 1
fi

echo "Fixing USB blocking..."

# Remove ALL sovereign udev rules
rm -f /etc/udev/rules.d/*sovereign*
rm -f /etc/udev/rules.d/99-*usb*

# Remove UAS blacklist if it exists
rm -f /etc/modprobe.d/no-uas.conf

# Remove any USB storage blacklists
find /etc/modprobe.d -name "*usb*" -exec rm -f {} +

# Reload all udev rules
udevadm control --reload-rules
udevadm trigger

# Reload USB modules
modprobe -r uas 2>/dev/null || true
modprobe -r usb-storage 2>/dev/null || true
modprobe usb-storage
modprobe uas

# Fix any blocked /dev/sd* permissions
for dev in /dev/sd?; do
    [[ -b "$dev" ]] && chmod 660 "$dev"
done

# Remove sovereign security overrides
rm -f /etc/udev/rules.d/99-sovereign-usb.rules

echo ""
echo "DONE. All USB blocks removed."
echo "Unplug and replug your USB drives."
echo "Run: lsblk"
echo ""
echo "If still not working, reboot: sudo reboot"
