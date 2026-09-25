#!/bin/bash
# Monitor Pico boot sequence - watch for SESSION → STATE → READY

echo "=== Monitoring Pico Boot Sequence ==="
echo "Plug in Pico device now..."
echo ""
echo "Watching for:"
echo "  1. SESSION:<uuid>"
echo "  2. STATE: seq=... R=... G=... Y=... B=..."
echo "  3. BLAZE_READY"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Monitor daemon logs
tail -f /tmp/agentdaemon.log 2>/dev/null | grep --line-buffered -E "SESSION|STATE|BLAZE_READY|DeviceManager|warmStart|PicoSession|connect" &
LOG_PID=$!

# Also monitor serial directly if device appears
while true; do
    if [ -c /dev/cu.usbmodem* ] 2>/dev/null; then
        PORT=$(ls -1 /dev/cu.usbmodem* 2>/dev/null | head -1)
        if [ -n "$PORT" ]; then
            echo "=== Device detected: $PORT ==="
            echo "Monitoring serial output..."
            cat "$PORT" 2>/dev/null | while IFS= read -r line; do
                echo "[SERIAL] $line"
                if echo "$line" | grep -q "SESSION:"; then
                    echo ">>> SESSION DETECTED"
                fi
                if echo "$line" | grep -q "STATE:"; then
                    echo ">>> STATE DETECTED"
                fi
                if echo "$line" | grep -q "BLAZE_READY"; then
                    echo ">>> BLAZE_READY DETECTED"
                fi
            done &
            break
        fi
    fi
    sleep 0.5
done

# Cleanup on exit
trap "kill $LOG_PID 2>/dev/null; exit" INT TERM
wait
