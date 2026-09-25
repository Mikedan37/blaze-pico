#!/bin/bash
# Quick check: Did we see the boot sequence?

echo "=== Checking Boot Sequence ==="
echo ""

# Check daemon logs for sequence
if [ -f /tmp/agentdaemon.log ]; then
    echo "Daemon logs:"
    if grep -q "SESSION:" /tmp/agentdaemon.log; then
        echo "  [OK] SESSION seen"
        SESSION_SEEN=1
    else
        echo "  [MISSING] SESSION"
        SESSION_SEEN=0
    fi
    
    if grep -q "STATE:" /tmp/agentdaemon.log; then
        echo "  [OK] STATE seen"
        STATE_SEEN=1
    else
        echo "  [MISSING] STATE"
        STATE_SEEN=0
    fi
    
    if grep -q "BLAZE_READY" /tmp/agentdaemon.log; then
        echo "  [OK] BLAZE_READY seen"
        READY_SEEN=1
    else
        echo "  [MISSING] BLAZE_READY"
        READY_SEEN=0
    fi
    
    echo ""
    
    # Check order
    if [ $SESSION_SEEN -eq 1 ] && [ $STATE_SEEN -eq 1 ] && [ $READY_SEEN -eq 1 ]; then
        SESSION_LINE=$(grep -n "SESSION:" /tmp/agentdaemon.log | head -1 | cut -d: -f1)
        STATE_LINE=$(grep -n "STATE:" /tmp/agentdaemon.log | head -1 | cut -d: -f1)
        READY_LINE=$(grep -n "BLAZE_READY" /tmp/agentdaemon.log | head -1 | cut -d: -f1)
        
        if [ "$SESSION_LINE" -lt "$STATE_LINE" ] && [ "$STATE_LINE" -lt "$READY_LINE" ]; then
            echo ">>> SEQUENCE CORRECT: SESSION → STATE → READY"
        else
            echo ">>> SEQUENCE BROKEN: Wrong order detected"
        fi
    else
        echo ">>> INCOMPLETE SEQUENCE: Missing messages"
    fi
else
    echo "No daemon log found"
fi

echo ""
echo "Device status:"
if ls /dev/cu.usbmodem* 1>/dev/null 2>&1; then
    echo "  Device connected: $(ls -1 /dev/cu.usbmodem* | head -1)"
else
    echo "  No device connected"
fi
