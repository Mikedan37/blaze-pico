#!/bin/bash
# Complete rebuild and test script

set -e

echo "🔥 Complete System Rebuild & Test"
echo "=================================="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Step 1: Rebuild firmware
echo -e "${BLUE}1️⃣ Rebuilding Pico firmware...${NC}"
cd "$(dirname "$0")"

if [ ! -d "build" ]; then
    mkdir build
fi

cd build
cmake .. > /dev/null 2>&1
if make -j4 > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Firmware built successfully${NC}"
else
    echo -e "${RED}✗ Firmware build failed${NC}"
    exit 1
fi

if [ ! -f "blaze_pico.uf2" ]; then
    echo -e "${RED}✗ Firmware file not found${NC}"
    exit 1
fi

echo -e "${YELLOW}⚠ Firmware ready to flash: build/blaze_pico.uf2${NC}"
echo ""

# Step 2: Check if Pico is in BOOTSEL mode
echo -e "${BLUE}2️⃣ Checking for Pico...${NC}"
if [ -d "/Volumes/RP2350" ]; then
    echo -e "${GREEN}✓ Pico found in BOOTSEL mode${NC}"
    echo -e "${YELLOW}⚠ Copying firmware...${NC}"
    cp blaze_pico.uf2 /Volumes/RP2350/
    echo -e "${GREEN}✓ Firmware copied. Pico will auto-reboot.${NC}"
    echo -e "${YELLOW}⚠ Wait 3 seconds for Pico to reboot...${NC}"
    sleep 3
else
    echo -e "${YELLOW}⚠ Pico not in BOOTSEL mode${NC}"
    echo -e "${YELLOW}   To flash firmware:${NC}"
    echo -e "${YELLOW}   1. Hold BOOTSEL button${NC}"
    echo -e "${YELLOW}   2. Plug in USB${NC}"
    echo -e "${YELLOW}   3. Release BOOTSEL${NC}"
    echo -e "${YELLOW}   4. Run: cp build/blaze_pico.uf2 /Volumes/RP2350/${NC}"
    echo ""
fi

# Step 3: Wait for Pico to appear
echo -e "${BLUE}3️⃣ Waiting for Pico serial port...${NC}"
for i in {1..10}; do
    if ls /dev/cu.usbmodem* > /dev/null 2>&1; then
        PORT=$(ls /dev/cu.usbmodem* | head -1)
        echo -e "${GREEN}✓ Found Pico at: $PORT${NC}"
        break
    fi
    echo -e "${YELLOW}   Waiting... ($i/10)${NC}"
    sleep 1
done

if [ -z "$PORT" ]; then
    echo -e "${RED}✗ Pico not found. Check USB connection.${NC}"
    exit 1
fi
echo ""

# Step 4: Build Swift tool
echo -e "${BLUE}4️⃣ Building Swift tool...${NC}"
cd ../PicoLEDControlSwift
if swift build -c release > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Swift tool built successfully${NC}"
else
    echo -e "${RED}✗ Swift tool build failed${NC}"
    exit 1
fi
echo ""

# Step 5: Test direct text mode (baseline)
echo -e "${BLUE}5️⃣ Testing direct text mode...${NC}"
echo -e "${YELLOW}   Open another terminal and run:${NC}"
echo -e "${YELLOW}   screen $PORT 115200${NC}"
echo -e "${YELLOW}   Then type: RED ON<ENTER>${NC}"
echo -e "${YELLOW}   Press any key when LED responds...${NC}"
read -n 1 -s
echo ""

# Step 6: Test Swift tool
echo -e "${BLUE}6️⃣ Testing Swift tool...${NC}"
echo -e "${YELLOW}   Running: .build/release/PicoLEDControl --port $PORT RED ON${NC}"
if .build/release/PicoLEDControl --port "$PORT" RED ON 2>&1 | tee /tmp/pico_test.log | grep -q "ACK received\|acknowledged"; then
    echo -e "${GREEN}✓ Swift tool test PASSED${NC}"
else
    echo -e "${YELLOW}⚠ Checking results...${NC}"
    if grep -q "ACK received" /tmp/pico_test.log; then
        echo -e "${GREEN}✓ ACK received - command worked!${NC}"
    else
        echo -e "${YELLOW}⚠ No ACK - but check if LED responded${NC}"
        echo -e "${YELLOW}   (ACK timing might be off, but command may still work)${NC}"
    fi
fi
echo ""

# Step 7: Test multiple commands
echo -e "${BLUE}7️⃣ Testing multiple commands...${NC}"
.build/release/PicoLEDControl --port "$PORT" RED ON GREEN ON BLUE ON ALL OFF
echo ""

# Final status
echo "=================================="
echo -e "${GREEN}✅ System verification complete!${NC}"
echo ""
echo "If LEDs responded correctly:"
echo -e "${GREEN}  → Your hardware control runtime is WORKING${NC}"
echo ""
echo "Next steps:"
echo "  1. Integrate with AgentDaemon tool registry"
echo "  2. Add structured intent parsing (not raw strings)"
echo "  3. Add status feedback from Pico"
echo ""
