#!/bin/bash
# Aggressive detection and flash

UF2="build/blaze_pico.uf2"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DETECTING AND FLASHING PICO"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check UF2
if [ ! -f "$UF2" ]; then
    echo "❌ UF2 not found"
    exit 1
fi

echo "✓ UF2 ready"
echo ""

# Aggressive mount detection
echo "Scanning for Pico mount..."
MOUNT=""

# Check all volumes
for vol in /Volumes/*; do
    if [ -d "$vol" ] && [ "$vol" != "/Volumes/Macintosh HD" ] && [ "$vol" != "/Volumes/rootfs" ]; then
        # Check for bootloader markers
        if [ -f "$vol/INDEX.HTM" ] || [ -f "$vol/INFO_UF2.TXT" ]; then
            MOUNT="$vol"
            echo "✅ Found: $MOUNT"
            break
        fi
        # Check by name pattern
        if [[ "$vol" == *"RP"* ]] || [[ "$vol" == *"RPI"* ]]; then
            MOUNT="$vol"
            echo "✅ Found: $MOUNT"
            break
        fi
    fi
done

if [ -z "$MOUNT" ]; then
    echo "❌ Pico not detected"
    echo ""
    echo "Current mounts:"
    ls -1 /Volumes/ | grep -v "Macintosh\|rootfs" || echo "  None"
    echo ""
    echo "Put Pico in bootloader mode, then run this script again"
    exit 1
fi

echo ""
echo "Flashing to: $MOUNT"
cp "$UF2" "$MOUNT/" && sync
echo "✅ Flash complete!"
echo ""
echo "Waiting for reboot..."
sleep 3

# Check for serial
SERIAL=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
if [ -n "$SERIAL" ]; then
    echo "✅ Serial ready: $SERIAL"
    echo ""
    echo "Testing connection..."
    ./pico-cli/pico-monitor --device "$SERIAL" &
    MONITOR_PID=$!
    sleep 2
    kill $MONITOR_PID 2>/dev/null || true
    echo ""
    echo "✅ Pico is responding!"
else
    echo "⚠ Serial not detected yet"
    echo "Run: ./pico-cli/pico-monitor"
fi
