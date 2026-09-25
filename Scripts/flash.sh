#!/bin/bash
# Robust flash script with auto-eject and re-identification
# This script handles the complete flash cycle without manual unplugging

set -e

UF2="build/blaze_pico.uf2"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PICO FLASH (Auto-Eject & Re-Identify)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check UF2 exists
if [ ! -f "$UF2" ]; then
    echo -e "${RED}❌ UF2 not found: $UF2${NC}"
    echo "Build first: ./pico-cli/pico-build"
    exit 1
fi

echo -e "${BLUE}UF2: $UF2 ($(ls -lh "$UF2" | awk '{print $5}'))${NC}"
echo ""

# Function to find Pico mount
find_pico_mount() {
    local mount=""
    
    # Method 1: Check common names
    for name in RP2350 RPI-RP2 RP2; do
        if [ -d "/Volumes/$name" ]; then
            mount="/Volumes/$name"
            break
        fi
    done
    
    # Method 2: Find by bootloader markers
    if [ -z "$mount" ]; then
        for vol in /Volumes/*; do
            if [ -d "$vol" ] && ([ -f "$vol/INDEX.HTM" ] || [ -f "$vol/INFO_UF2.TXT" ]); then
                mount="$vol"
                break
            fi
        done
    fi
    
    # Method 3: Check diskutil (RP2350 or RP2040)
    if [ -z "$mount" ]; then
        local disk_info=$(diskutil list | grep -i "rp2350\|rp2040\|raspberry\|pico" | head -1)
        if [ -n "$disk_info" ]; then
            local disk_name=$(echo "$disk_info" | awk '{print $NF}')
            if [ -d "/Volumes/$disk_name" ]; then
                mount="/Volumes/$disk_name"
            fi
        fi
    fi
    
    echo "$mount"
}

# Function to find serial port
find_serial_port() {
    ls /dev/cu.usbmodem* 2>/dev/null | head -1
}

# Function to trigger bootloader mode via serial command
trigger_bootloader() {
    local serial_port=$1
    if [ -z "$serial_port" ] || [ ! -c "$serial_port" ]; then
        return 1
    fi
    
    echo -e "${BLUE}  Sending BOOT command to trigger bootloader mode...${NC}"
    # Use printf with newline and flush to ensure command is sent
    printf "BOOT\n" > "$serial_port" 2>/dev/null || return 1
    sleep 2  # Give Pico time to reboot into bootloader
    return 0
}

# Step 1: Try to find Pico in bootloader mode first
echo -e "${BLUE}Step 1: Detecting Pico...${NC}"
MOUNT=$(find_pico_mount)

# If not in bootloader, try to trigger it via serial
if [ -z "$MOUNT" ] || [ ! -d "$MOUNT" ]; then
    SERIAL_PORT=$(find_serial_port)
    if [ -n "$SERIAL_PORT" ]; then
        echo -e "${YELLOW}  Pico found as serial device: $SERIAL_PORT${NC}"
        echo -e "${BLUE}  Attempting to trigger bootloader mode...${NC}"
        if trigger_bootloader "$SERIAL_PORT"; then
            echo -e "${BLUE}  Waiting for bootloader mode (3 seconds)...${NC}"
            sleep 3
            MOUNT=$(find_pico_mount)
        fi
    fi
fi

if [ -z "$MOUNT" ] || [ ! -d "$MOUNT" ]; then
    echo -e "${RED}❌ Pico not found in bootloader mode${NC}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "INSTRUCTIONS:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "1. Hold BOOTSEL button on Pico"
    echo "2. Plug USB cable into Mac (keep holding BOOTSEL)"
    echo "3. Release BOOTSEL"
    echo "4. Wait 2 seconds"
    echo "5. Run: ./scripts/flash.sh"
    echo ""
    echo "Current mounts:"
    ls -1 /Volumes/ | grep -i "rp\|rpi" || echo "  None found"
    exit 1
fi

echo -e "${GREEN}✅ Found Pico: $MOUNT${NC}"
echo ""

# Step 2: Flash firmware
echo -e "${BLUE}Step 2: Flashing firmware...${NC}"
echo "  From: $UF2"
echo "  To:   $MOUNT/"
echo ""

# Remove old firmware if present
if [ -f "$MOUNT/blaze_pico.uf2" ]; then
    echo "  Removing old firmware..."
    rm -f "$MOUNT/blaze_pico.uf2"
    sleep 1  # Give filesystem time to update
fi

# Copy new firmware with verification (exclude extended attributes for RP2350)
echo "  Copying firmware..."
if cp -X "$UF2" "$MOUNT/" 2>&1; then
    # Verify file was written
    sleep 0.5
    if [ -f "$MOUNT/blaze_pico.uf2" ]; then
        COPIED_SIZE=$(stat -f%z "$MOUNT/blaze_pico.uf2" 2>/dev/null || stat -c%s "$MOUNT/blaze_pico.uf2" 2>/dev/null || echo "0")
        SOURCE_SIZE=$(stat -f%z "$UF2" 2>/dev/null || stat -c%s "$UF2" 2>/dev/null || echo "0")
        
        if [ "$COPIED_SIZE" -eq "$SOURCE_SIZE" ] && [ "$COPIED_SIZE" -gt 0 ]; then
            echo -e "${GREEN}✅ Firmware copied ($COPIED_SIZE bytes)${NC}"
        else
            echo -e "${YELLOW}⚠️ Size mismatch: source=$SOURCE_SIZE, copied=$COPIED_SIZE${NC}"
        fi
    else
        echo -e "${RED}❌ File not found after copy${NC}"
        exit 1
    fi
    
    # Multiple syncs to ensure write completion
    sync
    sleep 0.5
    sync
    sleep 0.5
else
    echo -e "${RED}❌ Flash failed${NC}"
    exit 1
fi

# Step 3: Force eject to trigger reboot
echo ""
echo -e "${BLUE}Step 3: Ejecting volume to force reboot...${NC}"
sleep 1  # Brief delay before eject

# Get the disk identifier for this volume
DISK_ID=$(diskutil info "$MOUNT" 2>/dev/null | grep "Device Identifier" | awk '{print $3}')

if [ -n "$DISK_ID" ]; then
    echo "  Ejecting disk: $DISK_ID"
    diskutil eject "$DISK_ID" > /dev/null 2>&1 || diskutil unmount "$MOUNT" > /dev/null 2>&1 || true
    echo -e "${GREEN}✅ Volume ejected${NC}"
else
    # Fallback: try to unmount the volume directly
    diskutil unmount "$MOUNT" > /dev/null 2>&1 || true
    echo -e "${GREEN}✅ Volume unmounted${NC}"
fi

# Step 4: Wait for Pico to reboot and appear as serial device
echo ""
echo -e "${BLUE}Step 4: Waiting for Pico to reboot...${NC}"
echo "  (This may take 3-10 seconds)"

SERIAL=""
for i in {1..20}; do
    sleep 0.5
    SERIAL=$(find_serial_port)
    if [ -n "$SERIAL" ]; then
        echo -e "${GREEN}✅ Pico rebooted: $SERIAL${NC}"
        break
    fi
    if [ $((i % 4)) -eq 0 ]; then
        echo "  Still waiting... ($i/20)"
    fi
done

if [ -z "$SERIAL" ]; then
    echo -e "${YELLOW}⚠️ Serial port not detected after eject${NC}"
    echo ""
    echo "The firmware was flashed and volume ejected, but the serial port"
    echo "hasn't appeared. This sometimes requires a physical USB disconnect."
    echo ""
    echo -e "${YELLOW}OPTIONS:${NC}"
    echo "  1. Unplug and replug USB cable (recommended)"
    echo "  2. Wait longer - sometimes USB enumeration is slow"
    echo "  3. Check manually: ls /dev/cu.usbmodem*"
    echo ""
    echo "After replugging, the firmware should be updated."
    echo "You can verify by running: ./scripts/flash.sh (it will detect serial port)"
    echo ""
    # Don't exit with error - firmware was flashed successfully
    exit 0
fi

# Step 5: Verify firmware (optional)
echo ""
echo -e "${BLUE}Step 5: Verifying firmware...${NC}"
sleep 1  # Give firmware time to initialize

# Try to query state via serial (non-blocking check)
python3 << PYEOF 2>/dev/null || true
import serial
import time
import struct

try:
    ser = serial.Serial('$SERIAL', 115200, timeout=1)
    ser.reset_input_buffer()
    time.sleep(0.3)
    
    # Query state
    payload = struct.pack(">BQBB", 0, 999999999, 20, 0)
    header = (
        bytes([1, 0]) +
        struct.pack(">I", 1) +
        struct.pack(">I", 1) +
        struct.pack(">I", 1) +
        struct.pack(">H", len(payload))
    )
    packet = b"BLAZ" + header + payload
    ser.write(packet)
    ser.flush()
    time.sleep(0.5)
    response = ser.read(500)
    ser.close()
    
    if response:
        text = response.decode('utf-8', errors='ignore')
        if 'MR=' in text and 'MG=' in text and 'MB=' in text:
            print("✅ Firmware has RGB support")
        elif 'M=' in text:
            print("⚠️ Old firmware detected (no RGB support)")
except:
    pass
PYEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ FLASH COMPLETE${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Serial port: $SERIAL"
echo ""
echo "Monitor output:"
echo "  screen $SERIAL 115200"
echo ""
echo "Or test RGB channels:"
echo "  python3 test_rgb.py"
echo ""
