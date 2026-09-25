#!/bin/bash
# Test script to verify daemon and microcontroller

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TESTING DAEMON AND MICROCONTROLLER"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check daemon is running
echo "1. Checking daemon status..."
if ps aux | grep -v grep | grep AgentDaemon > /dev/null; then
    echo "   ✅ Daemon is running"
    DAEMON_PID=$(ps aux | grep -v grep | grep AgentDaemon | awk '{print $2}')
    echo "   PID: $DAEMON_PID"
else
    echo "   ❌ Daemon is NOT running"
    exit 1
fi

# Check socket exists
echo ""
echo "2. Checking socket..."
if [ -S /tmp/blaze_agent.sock ]; then
    echo "   ✅ Socket exists: /tmp/blaze_agent.sock"
else
    echo "   ❌ Socket not found"
    exit 1
fi

# Check Pico device
echo ""
echo "3. Checking Pico device..."
PICO_PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
if [ -n "$PICO_PORT" ]; then
    echo "   ✅ Pico found: $PICO_PORT"
else
    echo "   ⚠️  No Pico device found (this is OK if testing without hardware)"
fi

# Test state query via daemon logs
echo ""
echo "4. Checking recent daemon logs..."
echo "   Recent state query attempts:"
tail -50 /tmp/agentdaemon.log | grep -E "what lights|State query|DEBUG|deterministic.*queryState" | tail -5 || echo "   (No state query logs found yet)"

echo ""
echo "5. Testing direct PicoLEDControl..."
if [ -n "$PICO_PORT" ]; then
    cd /Users/mdanylchuk/pico/blaze-pico/PicoLEDControlSwift
    if swift run PicoLEDControl --port "$PICO_PORT" --query-state 2>&1 | head -10; then
        echo "   ✅ Direct Pico control works"
    else
        echo "   ⚠️  Direct Pico control failed (may need firmware update)"
    fi
else
    echo "   ⏭️  Skipping (no Pico device)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
