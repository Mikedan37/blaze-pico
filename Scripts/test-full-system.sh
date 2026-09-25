#!/bin/bash
# Comprehensive test of daemon and microcontroller

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FULL SYSTEM TEST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Check daemon
echo "1. Daemon Status:"
if ps aux | grep -v grep | grep AgentDaemon > /dev/null; then
    echo "   ✅ Running"
    DAEMON_PID=$(ps aux | grep -v grep | grep AgentDaemon | awk '{print $2}')
    echo "   PID: $DAEMON_PID"
else
    echo "   ❌ Not running"
    exit 1
fi

# 2. Check socket
echo ""
echo "2. Socket:"
if [ -S /tmp/blaze_agent.sock ]; then
    echo "   ✅ Exists"
else
    echo "   ❌ Missing"
    exit 1
fi

# 3. Check Pico
echo ""
echo "3. Pico Device:"
PICO_PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
if [ -n "$PICO_PORT" ]; then
    echo "   ✅ Found: $PICO_PORT"
else
    echo "   ⚠️  Not found"
fi

# 4. Test direct Pico control
echo ""
echo "4. Testing Direct Pico Control:"
if [ -n "$PICO_PORT" ]; then
    cd /Users/mdanylchuk/pico/blaze-pico/PicoLEDControlSwift
    echo "   Testing RED ON..."
    if swift run PicoLEDControl RED ON --port "$PICO_PORT" 2>&1 | grep -q "ACK received"; then
        echo "   ✅ RED ON works"
    else
        echo "   ❌ RED ON failed"
    fi
    
    sleep 1
    
    echo "   Testing query state..."
    if swift run PicoLEDControl --query-state --port "$PICO_PORT" 2>&1 | grep -q "STATE:"; then
        echo "   ✅ Query state works"
    else
        echo "   ⚠️  Query state failed (may need firmware update)"
    fi
else
    echo "   ⏭️  Skipped (no device)"
fi

# 5. Check daemon logs for state query routing
echo ""
echo "5. Daemon State Query Routing:"
echo "   Recent 'what lights' queries:"
tail -200 /tmp/agentdaemon.log | grep -E "what lights|DEBUG|State query|deterministic.*queryState" | tail -5 || echo "   (None yet - send a query from the app)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "1. Send 'what lights are on' from the app"
echo "2. Check logs: tail -f /tmp/agentdaemon.log | grep DEBUG"
echo "3. Verify state appears in UI"
