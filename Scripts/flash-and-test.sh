#!/bin/bash
# Complete flash and test automation

set -e

UF2="build/blaze_pico.uf2"
MAX_WAIT=120

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "AUTO FLASH & TEST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check UF2
if [ ! -f "$UF2" ]; then
    echo "❌ UF2 not found: $UF2"
    echo "Building firmware..."
    ./pico-cli/pico-build || exit 1
fi

echo "✓ UF2 ready: $UF2"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PUT PICO IN BOOTLOADER MODE NOW"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. UNPLUG Pico (if connected)"
echo "2. HOLD BOOTSEL button"
echo "3. Plug USB into Mac (keep holding BOOTSEL)"
echo "4. Release BOOTSEL"
echo ""
echo "Monitoring for Pico..."
echo ""

# Monitor for mount
FLASHED=false
for i in $(seq 1 $MAX_WAIT); do
    # Check known mount names
    for vol in /Volumes/RP2350 /Volumes/RPI-RP2; do
        if [ -d "$vol" ] 2>/dev/null; then
            echo ""
            echo "✅ Found: $vol"
            echo "Flashing..."
            cp "$UF2" "$vol/" && sync
            echo "✅ Flashed!"
            FLASHED=true
            break 2
        fi
    done
    
    # Check all volumes for bootloader markers
    for vol in /Volumes/*; do
        if [ -d "$vol" ] 2>/dev/null && [ "$vol" != "/Volumes/Macintosh HD" ] && [ "$vol" != "/Volumes/rootfs" ]; then
            if [ -f "$vol/INDEX.HTM" ] || [ -f "$vol/INFO_UF2.TXT" ] 2>/dev/null; then
                echo ""
                echo "✅ Found: $vol"
                echo "Flashing..."
                cp "$UF2" "$vol/" && sync
                echo "✅ Flashed!"
                FLASHED=true
                break 2
            fi
        fi
    done
    
    printf "\rWaiting... (%d/%d) " $i $MAX_WAIT
    sleep 0.5
done

echo ""

if [ "$FLASHED" != "true" ]; then
    echo "❌ Timeout - Pico not detected"
    exit 1
fi

echo ""
echo "Waiting for reboot..."
sleep 4

# Wait for serial device
echo ""
echo "Waiting for serial device..."
SERIAL=""
for i in $(seq 1 30); do
    SERIAL=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
    if [ -n "$SERIAL" ]; then
        break
    fi
    printf "\rWaiting for serial... (%d/30) " $i
    sleep 0.5
done

echo ""

if [ -z "$SERIAL" ]; then
    echo "⚠ Serial device not detected"
    echo "Pico may still be rebooting"
    exit 1
fi

echo "✅ Serial device: $SERIAL"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TESTING CONNECTION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test serial output
echo "Reading firmware output..."
timeout 3 cat "$SERIAL" 2>&1 | head -20 || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TESTING LED CONTROL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Build CLI if needed
if [ ! -f "PicoLEDControlSwift/.build/release/PicoLEDControl" ]; then
    echo "Building PicoLEDControl..."
    cd PicoLEDControlSwift
    swift build -c release
    cd ..
fi

CLI="PicoLEDControlSwift/.build/release/PicoLEDControl"

if [ ! -f "$CLI" ]; then
    echo "⚠ PicoLEDControl not found"
    exit 1
fi

echo "Testing RED ON..."
"$CLI" RED ON 2>&1
sleep 1

echo ""
echo "Testing GREEN ON..."
"$CLI" GREEN ON 2>&1
sleep 1

echo ""
echo "Testing ALL OFF..."
"$CLI" ALL OFF 2>&1

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅✅✅ FLASH & TEST COMPLETE ✅✅✅"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
