#!/bin/bash
# Reality check test script for Swift Pico LED control

set -e

echo "🔥 Reality Check: Swift → Pico LED Control"
echo "=========================================="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if Pico is connected
echo "1️⃣ Checking for Pico..."
PORTS=$(ls /dev/cu.usbmodem* 2>/dev/null || echo "")
if [ -z "$PORTS" ]; then
    echo -e "${RED}✗ No Pico found. Connect Pico via USB.${NC}"
    exit 1
fi

PORT=$(echo "$PORTS" | head -1)
echo -e "${GREEN}✓ Found Pico at: $PORT${NC}"
echo ""

# Build Swift tool
echo "2️⃣ Building Swift tool..."
cd PicoLEDControlSwift
if swift build -c release > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Swift tool built successfully${NC}"
else
    echo -e "${RED}✗ Swift tool build failed${NC}"
    exit 1
fi
echo ""

# Test single command
echo "3️⃣ Testing single command (RED ON)..."
if .build/release/PicoLEDControl --port "$PORT" RED ON 2>&1 | grep -q "ACK received"; then
    echo -e "${GREEN}✓ Command sent and ACK received${NC}"
else
    echo -e "${YELLOW}⚠ Command sent but no ACK (check Pico firmware)${NC}"
fi
echo ""

# Test multiple commands
echo "4️⃣ Testing multiple commands..."
if .build/release/PicoLEDControl --port "$PORT" RED ON GREEN ON BLUE ON 2>&1 | grep -q "acknowledged"; then
    echo -e "${GREEN}✓ Multiple commands sent successfully${NC}"
else
    echo -e "${YELLOW}⚠ Multiple commands may have failed${NC}"
fi
echo ""

# Test ALL OFF
echo "5️⃣ Testing ALL OFF..."
.build/release/PicoLEDControl --port "$PORT" ALL OFF > /dev/null 2>&1
echo -e "${GREEN}✓ All LEDs should be off now${NC}"
echo ""

echo "=========================================="
echo -e "${GREEN}✅ Reality check complete!${NC}"
echo ""
echo "If LEDs responded, you have a working hardware control runtime."
echo "If not, check:"
echo "  - Pico firmware is flashed and running"
echo "  - LEDs are wired correctly"
echo "  - Serial port is correct"
echo ""
echo "Watch serial output: screen $PORT 115200"
