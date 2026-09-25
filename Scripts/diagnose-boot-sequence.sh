#!/bin/bash
# Reality check: What actually happens when Pico boots?

echo "=== Boot Sequence Diagnostic ==="
echo ""
echo "This script will:"
echo "1. Monitor daemon logs for SESSION/STATE/READY"
echo "2. Monitor serial port directly (if device appears)"
echo "3. Report which message is MISSING"
echo ""
echo "Plug in Pico device now..."
echo "Press Ctrl+C to stop"
echo ""

# Track what we've seen
SESSION_SEEN=0
STATE_SEEN=0
READY_SEEN=0

# Function to check sequence
check_sequence() {
    if [ $SESSION_SEEN -eq 1 ] && [ $STATE_SEEN -eq 1 ] && [ $READY_SEEN -eq 1 ]; then
        echo ""
        echo ">>> ALL MESSAGES RECEIVED"
        echo ">>> SEQUENCE COMPLETE"
        exit 0
    elif [ $SESSION_SEEN -eq 0 ]; then
        echo ""
        echo ">>> MISSING: SESSION"
        echo ">>> DIAGNOSIS: Serial port opened too early OR firmware not emitting SESSION"
        exit 1
    elif [ $STATE_SEEN -eq 0 ]; then
        echo ""
        echo ">>> MISSING: STATE"
        echo ">>> DIAGNOSIS: Parser broken OR firmware STATE not emitted OR buffering issue"
        exit 1
    elif [ $READY_SEEN -eq 0 ]; then
        echo ""
        echo ">>> MISSING: BLAZE_READY"
        echo ">>> DIAGNOSIS: Firmware readiness gate wrong OR BLAZE_READY not emitted"
        exit 1
    fi
}

# Monitor daemon logs
tail -f /tmp/agentdaemon.log 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -q "SESSION:"; then
        echo "[DAEMON] SESSION detected: $line"
        SESSION_SEEN=1
        check_sequence
    fi
    if echo "$line" | grep -q "STATE:"; then
        echo "[DAEMON] STATE detected: $line"
        STATE_SEEN=1
        check_sequence
    fi
    if echo "$line" | grep -q "BLAZE_READY"; then
        echo "[DAEMON] BLAZE_READY detected: $line"
        READY_SEEN=1
        check_sequence
    fi
done &
LOG_PID=$!

# Wait for device
echo "Waiting for device..."
while [ ! -c /dev/cu.usbmodem* ] 2>/dev/null; do
    sleep 0.5
done

PORT=$(ls -1 /dev/cu.usbmodem* 2>/dev/null | head -1)
echo "Device detected: $PORT"
echo "Monitoring serial output directly..."
echo ""

# Monitor serial directly
stty -f "$PORT" 115200 raw -echo
cat "$PORT" 2>/dev/null | while IFS= read -r line || [ -n "$line" ]; do
    echo "[SERIAL] $line"
    
    if echo "$line" | grep -q "SESSION:"; then
        echo ">>> SESSION DETECTED IN SERIAL"
        SESSION_SEEN=1
    fi
    if echo "$line" | grep -q "STATE:"; then
        echo ">>> STATE DETECTED IN SERIAL"
        STATE_SEEN=1
    fi
    if echo "$line" | grep -q "BLAZE_READY"; then
        echo ">>> BLAZE_READY DETECTED IN SERIAL"
        READY_SEEN=1
    fi
    
    check_sequence
done &
SERIAL_PID=$!

# Timeout after 10 seconds
sleep 10
kill $LOG_PID $SERIAL_PID 2>/dev/null

echo ""
echo "=== TIMEOUT - Final Status ==="
check_sequence
