#!/bin/bash
# Simple LED test script - sends commands to Pico

SERIAL=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)

if [ -z "$SERIAL" ]; then
    echo "❌ No serial port found. Is Pico plugged in?"
    echo ""
    echo "Try:"
    echo "  1. Unplug Pico"
    echo "  2. Wait 2 seconds"
    echo "  3. Plug back in"
    echo "  4. Run this script again"
    exit 1
fi

echo "✅ Found serial port: $SERIAL"
echo ""
echo "Testing LEDs..."
echo ""

echo "→ Sending: ALL ON"
echo "ALL ON" > "$SERIAL"
sleep 2

echo "→ Sending: ALL OFF"
echo "ALL OFF" > "$SERIAL"
sleep 1

echo ""
echo "✅ Test complete. Did the LEDs turn on/off?"
