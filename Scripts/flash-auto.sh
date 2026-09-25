#!/bin/bash
# Auto-flash: Run this FIRST, then put Pico in bootloader mode

UF2="build/blaze_pico.uf2"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}PICO AUTO-FLASH${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ ! -f "$UF2" ]; then
    echo -e "${RED}✗ UF2 not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ UF2 ready: $UF2${NC}"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}PUT PICO IN BOOTLOADER MODE NOW:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  1. UNPLUG Pico (if connected)"
echo "  2. HOLD BOOTSEL button"
echo "  3. Plug USB into Mac (keep holding BOOTSEL)"
echo "  4. Release BOOTSEL"
echo ""
echo "Monitoring for Pico mount..."
echo ""

# Monitor for 30 seconds
for i in {1..60}; do
    # Check all possible mount locations
    for vol in /Volumes/RP2350 /Volumes/RPI-RP2 /Volumes/RP2*; do
        if [ -d "$vol" ] 2>/dev/null && ([ -f "$vol/INDEX.HTM" ] || [ -f "$vol/INFO_UF2.TXT" ] || [[ "$vol" == *"RP"* ]]); then
            echo ""
            echo -e "${GREEN}✓ Found Pico: $vol${NC}"
            echo ""
            echo "Flashing firmware..."
            
            if cp "$UF2" "$vol/" 2>&1; then
                sync
                echo ""
                echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${GREEN}✅ FLASH COMPLETE${NC}"
                echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                echo "Pico rebooting... Wait 3 seconds, then:"
                echo "  ./pico-cli/pico-monitor"
                exit 0
            else
                echo -e "${RED}✗ Flash failed${NC}"
                exit 1
            fi
        fi
    done
    
    # Also check by scanning all volumes for bootloader markers
    for vol in /Volumes/*; do
        if [ -d "$vol" ] && [ "$vol" != "/Volumes/Macintosh HD" ] && [ "$vol" != "/Volumes/rootfs" ]; then
            if [ -f "$vol/INDEX.HTM" ] || [ -f "$vol/INFO_UF2.TXT" ]; then
                echo ""
                echo -e "${GREEN}✓ Found Pico: $vol${NC}"
                echo ""
                echo "Flashing firmware..."
                
                if cp "$UF2" "$vol/" 2>&1; then
                    sync
                    echo ""
                    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                    echo -e "${GREEN}✅ FLASH COMPLETE${NC}"
                    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                    echo ""
                    echo "Pico rebooting... Wait 3 seconds, then:"
                    echo "  ./pico-cli/pico-monitor"
                    exit 0
                fi
            fi
        fi
    done
    
    printf "\r${YELLOW}Waiting... (${i}/60) ${NC}"
    sleep 0.5
done

echo ""
echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}TIMEOUT${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Pico not detected. Make sure:"
echo "  - BOOTSEL is held while plugging USB"
echo "  - USB cable supports data (not charge-only)"
echo "  - Pico LED lights up when plugged in"
echo ""
echo "Try:"
echo "  1. Unplug Pico completely"
echo "  2. Hold BOOTSEL"
echo "  3. Plug USB"
echo "  4. Release BOOTSEL"
echo "  5. Run: ./scripts/flash-auto.sh"
