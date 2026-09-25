#!/bin/bash
#
# install-pico-cli.sh - Install Pico CLI tools to /usr/local/bin
#
# Makes all pico-* commands available globally.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/bin"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}PICO CLI INSTALLER${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if running as root (for /usr/local/bin write access)
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Note: Installation to /usr/local/bin requires sudo${NC}"
    echo ""
    echo "This script will:"
    echo "  1. Copy pico-* commands to $INSTALL_DIR"
    echo "  2. Make them executable"
    echo "  3. Make them available globally"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled"
        exit 0
    fi
fi

# Commands to install
COMMANDS=("pico-build" "pico-wait" "pico-flash" "pico-monitor" "pico-all" "pico-hot" "pico-watch" "pico-detect")

# Check if commands exist
MISSING_COMMANDS=()
for cmd in "${COMMANDS[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$cmd" ]; then
        MISSING_COMMANDS+=("$cmd")
    fi
done

if [ ${#MISSING_COMMANDS[@]} -gt 0 ]; then
    echo -e "${RED}✗ Missing commands:${NC}"
    for cmd in "${MISSING_COMMANDS[@]}"; do
        echo "  - $cmd"
    done
    exit 1
fi

# Create install directory if it doesn't exist
if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}Creating $INSTALL_DIR...${NC}"
    sudo mkdir -p "$INSTALL_DIR"
fi

# Install each command
INSTALLED=0
for cmd in "${COMMANDS[@]}"; do
    SRC="$SCRIPT_DIR/$cmd"
    DEST="$INSTALL_DIR/$cmd"
    
    echo -e "${YELLOW}Installing $cmd...${NC}"
    
    # Copy file
    if sudo cp "$SRC" "$DEST"; then
        # Make executable
        sudo chmod +x "$DEST"
        INSTALLED=$((INSTALLED + 1))
        echo -e "  ${GREEN}✓${NC} Installed to $DEST"
    else
        echo -e "  ${RED}✗${NC} Failed to install $cmd"
    fi
done

echo ""
if [ $INSTALLED -eq ${#COMMANDS[@]} ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ PICO CLI INSTALLED${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Installed commands:"
    for cmd in "${COMMANDS[@]}"; do
        echo "  - $cmd"
    done
    echo ""
    echo "Usage:"
    echo "  pico-build    - Build firmware"
    echo "  pico-wait     - Wait for Pico in BOOTSEL mode"
    echo "  pico-flash    - Flash firmware to Pico"
    echo "  pico-monitor  - Open serial monitor"
    echo "  pico-all      - Complete workflow (build → flash → monitor)"
    echo "  pico-hot      - Hot flash mode (auto-detect disconnect/reconnect)"
    echo "  pico-watch    - Live rebuild + auto flash on file changes"
    echo "  pico-detect   - Detect Pico devices by VID/PID"
    echo ""
else
    echo -e "${RED}✗ Installation incomplete${NC}"
    echo "  Only $INSTALLED of ${#COMMANDS[@]} commands installed"
    exit 1
fi
