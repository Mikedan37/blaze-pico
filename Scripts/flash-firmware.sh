#!/bin/bash
# Flash firmware helper - handles SDK setup and flashing

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PICO FIRMWARE FLASH HELPER"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check for Pico SDK
if [ -z "$PICO_SDK_PATH" ]; then
    if [ -d ~/pico-sdk ]; then
        export PICO_SDK_PATH=~/pico-sdk
        echo "✓ Using Pico SDK: $PICO_SDK_PATH"
    else
        echo "✗ Pico SDK not found"
        echo ""
        echo "Install with:"
        echo "  cd ~"
        echo "  git clone https://github.com/raspberrypi/pico-sdk.git"
        echo "  cd pico-sdk && git submodule update --init"
        exit 1
    fi
fi

# Check for ARM toolchain
if ! command -v arm-none-eabi-gcc &> /dev/null; then
    echo "✗ ARM toolchain not found"
    echo ""
    echo "Install with:"
    echo "  brew install arm-none-eabi-gcc"
    exit 1
fi

echo "✓ ARM toolchain found"
echo ""

# Note about newlib
echo "⚠ Note: If build fails with 'cannot find -lg' or '-lc',"
echo "  you need newlib. Options:"
echo "  1. Use VS Code Pico extension (recommended)"
echo "  2. Install newlib manually"
echo ""

# Build
echo "Building firmware..."
cd "$PROJECT_ROOT"
rm -rf build
mkdir build
cd build
cmake ..
make -j4 blaze_pico || {
    echo ""
    echo "✗ Build failed. This is likely due to missing newlib."
    echo ""
    echo "Recommended: Use VS Code with Pico extension"
    echo "  It handles toolchain setup automatically."
    exit 1
}

# Find UF2
UF2=$(find . -name "*.uf2" -type f | head -1)
if [ -z "$UF2" ]; then
    echo "✗ UF2 not found"
    exit 1
fi

echo "✓ UF2 built: $UF2"
echo ""

# Flash
MOUNT=$(ls -d /Volumes/RP2350 /Volumes/RPI-RP2 2>/dev/null | head -1)
if [ -n "$MOUNT" ]; then
    echo "Flashing to: $MOUNT"
    cp "$UF2" "$MOUNT/" && sync
    echo ""
    echo "✅ FLASH COMPLETE"
    echo "Pico will reboot automatically."
else
    echo "⚠ Pico not in bootloader mode"
    echo ""
    echo "To flash:"
    echo "1. Hold BOOTSEL button"
    echo "2. Plug USB"
    echo "3. Release BOOTSEL"
    echo "4. Run: cp $UF2 /Volumes/RP2350/"
fi
