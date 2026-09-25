#!/bin/bash
# Comprehensive Pico flash script with diagnostics

set -e

UF2="build/blaze_pico.uf2"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}PICO FLASH (WITH DIAGNOSTICS)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check UF2
if [ ! -f "$UF2" ]; then
    echo -e "${RED}✗ UF2 not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ UF2 ready: $UF2 ($(ls -lh "$UF2" | awk '{print $5}'))${NC}"
echo ""

# Check for Pico mount (all possible names)
echo "Checking for Pico mount..."
MOUNT=""

# Method 1: Check by name
for name in RP2350 RPI-RP2 RP2; do
    if [ -d "/Volumes/$name" ]; then
        MOUNT="/Volumes/$name"
        echo -e "${GREEN}✓ Found by name: $MOUNT${NC}"
        break
    fi
done

# Method 2: Check by bootloader markers
if [ -z "$MOUNT" ]; then
    for vol in /Volumes/*; do
        if [ -d "$vol" ] && ([ -f "$vol/INDEX.HTM" ] || [ -f "$vol/INFO_UF2.TXT" ]); then
            MOUNT="$vol"
            echo -e "${GREEN}✓ Found by markers: $MOUNT${NC}"
            break
        fi
    done
fi

# Method 3: List all volumes and check
if [ -z "$MOUNT" ]; then
    echo "All mounted volumes:"
    ls -1 /Volumes/ | while read vol; do
        if [ "$vol" != "Macintosh HD" ] && [ "$vol" != "rootfs" ]; then
            echo "  - /Volumes/$vol"
        fi
    done
fi

if [ -z "$MOUNT" ] || [ ! -d "$MOUNT" ]; then
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}PICO NOT IN BOOTLOADER MODE${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Steps to put Pico in bootloader mode:"
    echo ""
    echo "  1. UNPLUG Pico from USB (if connected)"
    echo "  2. HOLD the BOOTSEL button on Pico"
    echo "  3. WHILE HOLDING BOOTSEL, plug USB into Mac"
    echo "  4. KEEP HOLDING for 1 second"
    echo "  5. RELEASE BOOTSEL"
    echo ""
    echo "You should see a new volume appear: /Volumes/RP2350"
    echo ""
    echo "Then run this script again:"
    echo "  ./scripts/flash-pico.sh"
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}FLASHING FIRMWARE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  From: $UF2"
echo "  To:   $MOUNT/"
echo ""

# Verify mount is writable
if [ ! -w "$MOUNT" ]; then
    echo -e "${RED}✗ Mount is not writable${NC}"
    echo "Try unplugging and replugging Pico"
    exit 1
fi

# Copy firmware
echo "Copying..."
if cp "$UF2" "$MOUNT/" 2>&1; then
    sync
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ FLASH COMPLETE${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Pico will reboot automatically (~2 seconds)"
    echo ""
    echo "Wait 3 seconds, then monitor:"
    echo "  ./pico-cli/pico-monitor"
else
    echo -e "${RED}✗ Flash failed${NC}"
    exit 1
fi
