#!/bin/bash
#
# verify-install.sh - Verify all CLI tools are installed and working
#

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}PICO CLI VERIFICATION${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

COMMANDS=("pico-build" "pico-wait" "pico-flash" "pico-monitor" "pico-all" "pico-hot" "pico-watch" "pico-detect")
INSTALL_DIR="/usr/local/bin"

ALL_OK=true

for cmd in "${COMMANDS[@]}"; do
    if command -v "$cmd" &> /dev/null; then
        CMD_PATH=$(which "$cmd")
        if [ -x "$CMD_PATH" ]; then
            echo -e "${GREEN}✓${NC} $cmd (found at $CMD_PATH)"
        else
            echo -e "${RED}✗${NC} $cmd (not executable)"
            ALL_OK=false
        fi
    else
        echo -e "${RED}✗${NC} $cmd (not found)"
        ALL_OK=false
    fi
done

echo ""

# Check optional dependencies
echo -e "${YELLOW}Checking optional dependencies...${NC}"
echo ""

if command -v fswatch &> /dev/null; then
    echo -e "${GREEN}✓${NC} fswatch (required for pico-watch)"
else
    echo -e "${YELLOW}⚠${NC} fswatch not found (install: brew install fswatch)"
fi

if command -v screen &> /dev/null; then
    echo -e "${GREEN}✓${NC} screen (required for pico-monitor)"
else
    echo -e "${YELLOW}⚠${NC} screen not found (install: brew install screen)"
fi

if command -v ioreg &> /dev/null; then
    echo -e "${GREEN}✓${NC} ioreg (required for pico-detect)"
else
    echo -e "${RED}✗${NC} ioreg not found (should be on macOS)"
    ALL_OK=false
fi

echo ""

if [ "$ALL_OK" = true ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ ALL CHECKS PASSED${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}✗ SOME CHECKS FAILED${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
fi
