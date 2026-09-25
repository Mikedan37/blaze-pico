#!/bin/bash
# Monitor daemon logs in real-time when voice command is sent

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VOICE COMMAND MONITOR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Monitoring daemon logs for voice command activity..."
echo "Send a command from VoiceAgentController now!"
echo ""
echo "Looking for:"
echo "  ✓ [ROUTER] IntentRouter.route() called"
echo "  ✓ [IntentRouter] ✅ FAST-PATH ROUTED"
echo "  ✓ [PicoLEDTool] Executing: ..."
echo "  ✓ [PicoLEDTool] Success: ..."
echo "  ✗ Any ERROR or Failed messages"
echo ""
echo "Press Ctrl+C to stop"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

tail -f /tmp/agentdaemon.log 2>/dev/null | grep --line-buffered -E "IntentRouter|FAST-PATH|PicoLEDTool|PicoSession|DeviceManager|ERROR|Error|Failed|failed|timeout|Timeout|BLAZE_READY|isReady|planWork|handlePlanWork" | while IFS= read -r line; do
    # Color code messages
    if echo "$line" | grep -qE "FAST-PATH|Success|BLAZE_READY|isReady.*true"; then
        echo "✅ $line"
    elif echo "$line" | grep -qE "ERROR|Error|Failed|failed|timeout|Timeout|not ready"; then
        echo "❌ $line"
    elif echo "$line" | grep -qE "IntentRouter|PicoLEDTool|PicoSession|DeviceManager"; then
        echo "🔵 $line"
    else
        echo "   $line"
    fi
done
