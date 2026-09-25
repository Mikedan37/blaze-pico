#!/bin/bash
# Debug script to watch serial output while sending commands

PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)

if [ -z "$PORT" ]; then
    echo "No Pico found"
    exit 1
fi

echo "Watching serial output on $PORT"
echo "Run commands in another terminal:"
echo "  cd PicoLEDControlSwift"
echo "  .build/release/PicoLEDControl --port $PORT GREEN ON"
echo ""
echo "Press Ctrl+C to exit"
echo ""

screen $PORT 115200
