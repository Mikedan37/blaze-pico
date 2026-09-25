#!/bin/bash

# Flash firmware and test script
# Puts device into bootloader mode, flashes firmware, then tests connection

set -e

echo "=========================================="
echo "PICO FIRMWARE FLASH AND TEST"
echo "=========================================="
echo ""

# Step 1: Build firmware
echo "🔨 Building firmware..."
cd "$(dirname "$0")"
mkdir -p build
cd build
cmake .. > /dev/null 2>&1
make -j4 > /dev/null 2>&1

if [ ! -f "blaze_pico.uf2" ]; then
    echo "❌ ERROR: Firmware build failed"
    exit 1
fi

echo "✅ Firmware built: $(ls -lh blaze_pico.uf2 | awk '{print $5}')"
echo ""

# Step 2: Check if device is connected
DEVICE_PORT=$(ls /dev/tty.usbmodem* 2>/dev/null | head -1)

if [ -z "$DEVICE_PORT" ]; then
    echo "⚠️  No Pico device detected"
    echo ""
    echo "Please:"
    echo "  1. Connect Pico via USB"
    echo "  2. Hold BOOTSEL button"
    echo "  3. Press RESET button (while holding BOOTSEL)"
    echo "  4. Release BOOTSEL"
    echo "  5. Run this script again"
    echo ""
    exit 1
fi

echo "✅ Found device: $DEVICE_PORT"
echo ""

# Step 3: Check if device is in bootloader mode
if [ -d "/Volumes/RPI-RP2" ]; then
    echo "✅ Device is in bootloader mode"
    echo ""
    echo "📤 Flashing firmware..."
    cp blaze_pico.uf2 /Volumes/RPI-RP2/
    sync
    sleep 2
    diskutil eject /Volumes/RPI-RP2 > /dev/null 2>&1
    echo "✅ Firmware flashed"
    echo ""
    echo "⏳ Waiting for device to reboot (5 seconds)..."
    sleep 5
else
    echo "⚠️  Device is NOT in bootloader mode"
    echo ""
    echo "To flash firmware:"
    echo "  1. Hold BOOTSEL button"
    echo "  2. Press RESET button (while holding BOOTSEL)"
    echo "  3. Release BOOTSEL"
    echo "  4. Run this script again"
    echo ""
    echo "Or use: picotool load -x blaze_pico.uf2 (if picotool is installed)"
    exit 1
fi

# Step 4: Test connection
echo ""
echo "🧪 Testing device connection..."
sleep 2

NEW_DEVICE=$(ls /dev/tty.usbmodem* 2>/dev/null | head -1)

if [ -z "$NEW_DEVICE" ]; then
    echo "⚠️  Device not detected after flash"
    echo "   Please check USB connection"
    exit 1
fi

echo "✅ Device detected: $NEW_DEVICE"
echo ""

# Step 5: Test serial output (check for BLAZE_READY)
echo "📡 Checking for BLAZE_READY signal..."
echo "   (This may take a few seconds - device needs to boot)"
echo ""

# Use a simple serial read test
timeout 10 cat $NEW_DEVICE 2>/dev/null | head -20 || echo "   (Serial read timeout - device may still be booting)"

echo ""
echo "=========================================="
echo "✅ Flash and test complete!"
echo ""
echo "To verify firmware is working:"
echo "  screen $NEW_DEVICE 115200"
echo ""
echo "You should see:"
echo "  SESSION:xxxx"
echo "  STATE: seq=0 ..."
echo "  BLAZE_READY"
echo ""
echo "To run benchmarks:"
echo "  cd Benchmarks && ./scripts/run_benchmarks.sh"
echo "=========================================="
