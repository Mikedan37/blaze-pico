#!/bin/bash
# Auto-detect, flash, and test Pico

UF2="build/blaze_pico.uf2"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "AUTO FLASH & TEST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ ! -f "$UF2" ]; then
    echo "❌ UF2 not found"
    exit 1
fi

echo "✓ UF2 ready"
echo ""
echo "Monitoring for Pico..."
echo "Put Pico in bootloader mode now..."
echo ""

# Monitor for mount
for i in {1..120}; do
    for vol in /Volumes/RP2350 /Volumes/RPI-RP2; do
        if [ -d "$vol" ] 2>/dev/null; then
            echo ""
            echo "✅ Found: $vol"
            echo "Flashing..."
            cp "$UF2" "$vol/" && sync
            echo "✅ Flashed!"
            echo ""
            echo "Waiting for reboot..."
            sleep 3
            
            # Check for serial
            SERIAL=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
            if [ -n "$SERIAL" ]; then
                echo "✅ Serial: $SERIAL"
                echo ""
                echo "Testing connection..."
                timeout 2 cat "$SERIAL" 2>&1 | head -10 || true
                echo ""
                echo "✅✅✅ SUCCESS ✅✅✅"
                exit 0
            fi
        fi
    done
    
    # Also check all volumes for bootloader markers
    for vol in /Volumes/*; do
        if [ -d "$vol" ] && [ -f "$vol/INDEX.HTM" ] 2>/dev/null; then
            echo ""
            echo "✅ Found: $vol"
            echo "Flashing..."
            cp "$UF2" "$vol/" && sync
            echo "✅ Flashed!"
            sleep 3
            SERIAL=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
            if [ -n "$SERIAL" ]; then
                echo "✅ Serial: $SERIAL"
                echo "Testing..."
                timeout 2 cat "$SERIAL" 2>&1 | head -10 || true
                echo "✅✅✅ SUCCESS ✅✅✅"
                exit 0
            fi
        fi
    done
    
    printf "\rWaiting... (%d/120) " $i
    sleep 0.5
done

echo ""
echo "❌ Timeout"
exit 1
