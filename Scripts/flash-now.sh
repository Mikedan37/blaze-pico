#!/bin/bash
#
# flash-now.sh - Wait for Pico bootloader and flash automatically
#

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UF2_FILE="$PROJECT_ROOT/build/blaze_pico.uf2"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}PICO FLASH HELPER${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ ! -f "$UF2_FILE" ]; then
    echo -e "${YELLOW}✗ UF2 not found. Building first...${NC}"
    "$PROJECT_ROOT/pico-cli/pico-build"
    echo ""
fi

echo -e "${YELLOW}Waiting for Pico in bootloader mode...${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "INSTRUCTIONS:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Hold BOOTSEL button on Pico"
echo "2. Plug in USB cable (keep holding BOOTSEL)"
echo "3. Release BOOTSEL"
echo ""
echo "Waiting for /Volumes/RP2350 or /Volumes/RPI-RP2..."
echo ""

# Wait for mount (up to 60 seconds)
MAX_WAIT=60
START_TIME=$(date +%s)
MOUNT=""

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo -e "${YELLOW}✗ Timeout after ${MAX_WAIT} seconds${NC}"
        echo "Make sure to hold BOOTSEL while plugging in USB"
        exit 1
    fi
    
    MOUNT=$(ls -d /Volumes/RP2350 /Volumes/RPI-RP2 2>/dev/null | head -1)
    if [ -n "$MOUNT" ]; then
        break
    fi
    
    printf "\r${YELLOW}Waiting... (${ELAPSED}s)${NC}"
    sleep 0.5
done

echo ""
echo ""
echo -e "${GREEN}✓ Pico detected: $MOUNT${NC}"
echo ""
echo "Flashing firmware..."
echo "  Source: $UF2_FILE"
echo "  Target: $MOUNT/"
echo ""

if cp "$UF2_FILE" "$MOUNT/" 2>&1; then
    sync
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ FLASH COMPLETE${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Pico will reboot automatically in ~2 seconds."
    echo ""
    echo "Waiting for serial device..."
    sleep 3
    
    SERIAL=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
    if [ -n "$SERIAL" ]; then
        echo -e "${GREEN}✓ Serial device ready: $SERIAL${NC}"
        echo ""
        echo "Monitor with: ./pico-cli/pico-monitor"
    else
        echo -e "${YELLOW}⚠ Serial device not detected yet${NC}"
        echo "Try: ./pico-cli/pico-monitor"
    fi
else
    echo -e "${YELLOW}✗ Flash failed${NC}"
    echo "Try unplugging and replugging the Pico"
    exit 1
fi
