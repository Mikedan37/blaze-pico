#!/bin/bash

# Wait for bootloader mode and flash automatically

set -e

echo "=========================================="
echo "WAITING FOR BOOTLOADER MODE"
echo "=========================================="
echo ""
echo "Please:"
echo "  1. Hold BOOTSEL button"
echo "  2. Press RESET button (while holding BOOTSEL)"
echo "  3. Release BOOTSEL"
echo ""
echo "Waiting for RPI-RP2 volume to appear..."
echo ""

# Wait for bootloader volume (max 30 seconds)
TIMEOUT=30
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    if [ -d "/Volumes/RPI-RP2" ]; then
        echo "✅ Bootloader volume detected!"
        echo ""
        
        cd "$(dirname "$0")/build"
        
        if [ ! -f "blaze_pico.uf2" ]; then
            echo "❌ ERROR: Firmware not found"
            exit 1
        fi
        
        echo "📤 Flashing firmware..."
        cp blaze_pico.uf2 /Volumes/RPI-RP2/
        sync
        sleep 2
        
        echo "✅ Firmware flashed"
        echo ""
        echo "⏳ Ejecting volume (device will reboot)..."
        diskutil eject /Volumes/RPI-RP2 > /dev/null 2>&1
        
        echo "✅ Done! Device should reboot in 5-10 seconds"
        echo ""
        echo "Waiting for device to appear..."
        
        # Wait for device to reboot
        sleep 5
        
        # Check for device
        for i in {1..10}; do
            DEVICE=$(find /dev -name "tty.usbmodem*" 2>/dev/null | head -1)
            if [ -n "$DEVICE" ]; then
                echo "✅ Device detected: $DEVICE"
                echo ""
                echo "📡 Checking boot output..."
                timeout 5 cat $DEVICE 2>/dev/null | head -20 || true
                echo ""
                echo "✅ Ready to test!"
                exit 0
            fi
            sleep 1
        done
        
        echo "⚠️  Device not detected yet - may need more time"
        exit 0
    fi
    
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    echo -n "."
done

echo ""
echo "❌ Timeout: Bootloader volume did not appear"
echo ""
echo "Troubleshooting:"
echo "  - Check USB cable connection"
echo "  - Try different USB port"
echo "  - Ensure BOOTSEL button works"
echo "  - Check: diskutil list | grep -i rpi"
exit 1
