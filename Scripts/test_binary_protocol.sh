#!/bin/bash
# Test binary protocol upgrade

set -e

echo "🔥 Testing Binary Protocol Upgrade"
echo "=================================="
echo ""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check firmware exists
if [ ! -f "build/blaze_pico.uf2" ]; then
    echo -e "${YELLOW}⚠ Firmware not built. Building...${NC}"
    cd build
    cmake .. > /dev/null 2>&1
    make -j4 > /dev/null 2>&1
    cd ..
fi

# Check Swift tool exists
if [ ! -f "PicoLEDControlSwift/.build/release/PicoLEDControl" ]; then
    echo -e "${YELLOW}⚠ Swift tool not built. Building...${NC}"
    cd PicoLEDControlSwift
    swift build -c release > /dev/null 2>&1
    cd ..
fi

# Find Pico port
PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
if [ -z "$PORT" ]; then
    echo -e "${RED}✗ No Pico found. Connect Pico via USB.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found Pico at: $PORT${NC}"
echo ""

# Test 1: Binary command (via text interface)
echo -e "${YELLOW}Test 1: Binary command (RED ON)${NC}"
cd PicoLEDControlSwift
if .build/release/PicoLEDControl --port "$PORT" RED ON 2>&1 | grep -q "ACK received\|acknowledged"; then
    echo -e "${GREEN}✓ Binary command sent successfully${NC}"
else
    echo -e "${RED}✗ Binary command failed${NC}"
fi
echo ""

# Test 2: State query
echo -e "${YELLOW}Test 2: State query${NC}"
if .build/release/PicoLEDControl --port "$PORT" --query-state 2>&1 | grep -q "LED States"; then
    echo -e "${GREEN}✓ State query works${NC}"
else
    echo -e "${YELLOW}⚠ State query may have failed (check output)${NC}"
fi
echo ""

# Test 3: Multiple commands (send separately)
echo -e "${YELLOW}Test 3: Multiple binary commands${NC}"
.build/release/PicoLEDControl --port "$PORT" GREEN ON
.build/release/PicoLEDControl --port "$PORT" BLUE ON
.build/release/PicoLEDControl --port "$PORT" YELLOW ON
echo ""

echo "=================================="
echo -e "${GREEN}✅ Binary protocol tests complete!${NC}"
echo ""
echo "Check serial output for:"
echo "  - ACK:commandID:value format"
echo "  - STATE: R=... responses"
echo ""
echo "Run: screen $PORT 115200"
