#!/bin/bash
#
# flash-manual.sh - Simple manual flash (no waiting, just copy)
#

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UF2_FILE="$PROJECT_ROOT/build/blaze_pico.uf2"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}MANUAL PICO FLASH${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ ! -f "$UF2_FILE" ]; then
    echo -e "${RED}✗ UF2 not found: $UF2_FILE${NC}"
    echo "Build first: ./pico-cli/pico-build"
    exit 1
fi

echo -e "${GREEN}✓ UF2 ready: $UF2_FILE${NC}"
ls -lh "$UF2_FILE"
echo ""

# Check for mount
MOUNT=$(ls -d /Volumes/RP2350 /Volumes/RPI-RP2 2>/dev/null | head -1)

if [ -z "$MOUNT" ]; then
    echo -e "${YELLOW}⚠ Pico not in bootloader mode${NC}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TO FLASH:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "1. Hold BOOTSEL button on Pico"
    echo "2. Plug in USB cable (keep holding BOOTSEL)"
    echo "3. Release BOOTSEL"
    echo ""
    echo "Then run this script again, or run:"
    echo "  cp $UF2_FILE /Volumes/RP2350/"
    echo ""
    exit 0
fi

echo -e "${GREEN}✓ Pico detected: $MOUNT${NC}"
echo ""
echo "Flashing..."
echo "  From: $UF2_FILE"
echo "  To:   $MOUNT/"
echo ""

if cp "$UF2_FILE" "$MOUNT/" 2>&1; then
    sync
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ FLASH COMPLETE${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Pico will reboot automatically."
    echo ""
    echo "Wait 3 seconds, then monitor with:"
    echo "  ./pico-cli/pico-monitor"
else
    echo -e "${RED}✗ Flash failed${NC}"
    echo ""
    echo "Try:"
    echo "  1. Unplug Pico"
    echo "  2. Hold BOOTSEL"
    echo "  3. Plug in USB"
    echo "  4. Release BOOTSEL"
    echo "  5. Run this script again"
    exit 1
fi
