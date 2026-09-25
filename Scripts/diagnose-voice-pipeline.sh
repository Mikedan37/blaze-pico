#!/bin/bash
# Diagnose the full voice pipeline from VoiceAgentController to firmware

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VOICE PIPELINE DIAGNOSTIC"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Check daemon is running
echo "1. Checking AgentDaemon..."
if ps aux | grep -v grep | grep AgentDaemon > /dev/null; then
    DAEMON_PID=$(ps aux | grep -v grep | grep AgentDaemon | awk '{print $2}')
    echo "   ✅ Daemon running (PID: $DAEMON_PID)"
else
    echo "   ❌ Daemon NOT running"
    echo "   → Fix: Run ./scripts/start-agentdaemon.sh"
    exit 1
fi

# 2. Check socket exists
echo ""
echo "2. Checking daemon socket..."
if [ -S /tmp/blaze_agent.sock ]; then
    echo "   ✅ Socket exists: /tmp/blaze_agent.sock"
else
    echo "   ❌ Socket missing"
    echo "   → Fix: Restart daemon"
    exit 1
fi

# 3. Check Pico device
echo ""
echo "3. Checking Pico device..."
PICO_PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
if [ -n "$PICO_PORT" ]; then
    echo "   ✅ Pico found: $PICO_PORT"
else
    echo "   ❌ No Pico device found"
    echo "   → Fix: Plug in Pico"
    exit 1
fi

# 4. Check daemon has connected to Pico
echo ""
echo "4. Checking daemon Pico connection..."
if tail -200 /tmp/agentdaemon.log 2>/dev/null | grep -q "BLAZE_READY received"; then
    echo "   ✅ Daemon connected to Pico (BLAZE_READY received)"
else
    echo "   ⚠️  Daemon may not have connected to Pico"
    echo "   → Check: tail -f /tmp/agentdaemon.log | grep BLAZE_READY"
fi

# 5. Check for recent errors in daemon logs
echo ""
echo "5. Checking for errors in daemon logs..."
ERRORS=$(tail -500 /tmp/agentdaemon.log 2>/dev/null | grep -iE "error|failed|timeout|not ready" | tail -10)
if [ -n "$ERRORS" ]; then
    echo "   ⚠️  Recent errors found:"
    echo "$ERRORS" | sed 's/^/      /'
else
    echo "   ✅ No recent errors"
fi

# 6. Check IntentRouter routing
echo ""
echo "6. Checking IntentRouter patterns..."
echo "   Testing command: 'turn red light on'"
echo "   → Should match: deterministic(.light(color: .red, state: .on))"
echo "   → Check daemon logs for: '[IntentRouter] ✅ FAST-PATH ROUTED'"

# 7. Check DeviceManager readiness
echo ""
echo "7. Checking DeviceManager state..."
if tail -200 /tmp/agentdaemon.log 2>/dev/null | grep -q "DeviceManager.*ready\|warmStart.*complete"; then
    echo "   ✅ DeviceManager initialized"
else
    echo "   ⚠️  DeviceManager may not be ready"
fi

# 8. Test direct command execution
echo ""
echo "8. Testing direct command execution..."
cd /Users/mdanylchuk/pico/blaze-pico/PicoLEDControlSwift
if swift run PicoLEDControl RED OFF --port "$PICO_PORT" 2>&1 | grep -q "ACK received"; then
    echo "   ✅ Direct command execution works"
else
    echo "   ❌ Direct command execution failed"
    echo "   → This indicates firmware/transport issue"
fi

# 9. Monitor daemon logs for incoming commands
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DIAGNOSTIC COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "1. Send a voice command from VoiceAgentController"
echo "2. Watch daemon logs: tail -f /tmp/agentdaemon.log"
echo "3. Look for these messages:"
echo "   - '[ROUTER] IntentRouter.route() called'"
echo "   - '[IntentRouter] ✅ FAST-PATH ROUTED'"
echo "   - '[PicoLEDTool] Executing: ...'"
echo "   - '[PicoLEDTool] Success: ...'"
echo ""
echo "If you see errors, check:"
echo "  - DeviceManager ready: grep 'warmStart\|DeviceManager' /tmp/agentdaemon.log"
echo "  - PicoSession ready: grep 'BLAZE_READY\|isReady' /tmp/agentdaemon.log"
echo "  - IntentRouter match: grep 'IntentRouter\|FAST-PATH' /tmp/agentdaemon.log"
