#!/bin/bash
# Wait for Pico bootloader mode, then flash automatically

UF2="build/blaze_pico.uf2"

if [ ! -f "$UF2" ]; then
    echo "UF2 not found: $UF2"
    echo "Build first: pico-build"
    exit 1
fi

echo "=== Waiting for Pico Bootloader ==="
echo "Put Pico in bootloader mode:"
echo "  1. Hold BOOTSEL button"
echo "  2. Plug USB cable"
echo "  3. Release BOOTSEL"
echo ""
echo "Waiting for bootloader volume..."

# Wait up to 30 seconds for bootloader
for i in {1..30}; do
    for vol in /Volumes/RP2350 /Volumes/RPI-RP2 /Volumes/RP2; do
        if [ -d "$vol" ]; then
            echo "Bootloader detected: $vol"
            echo "Copying firmware..."
            cp "$UF2" "$vol/"
            sync
            echo "Firmware copied. Pico will reboot automatically."
            sleep 2
            diskutil eject "$vol" 2>/dev/null || true
            echo "Done!"
            exit 0
        fi
    done
    sleep 1
done

echo "Timeout: Bootloader not detected"
exit 1
