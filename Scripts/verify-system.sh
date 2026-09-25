#!/bin/bash
# Final verification script

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SYSTEM VERIFICATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "✅ Daemon: $(ps aux | grep -v grep | grep AgentDaemon > /dev/null && echo "Running (PID: $(ps aux | grep -v grep | grep AgentDaemon | awk '{print $2}'))" || echo "Not running")"
echo "✅ Socket: $([ -S /tmp/blaze_agent.sock ] && echo "Exists" || echo "Missing")"
echo "✅ Pico: $(ls /dev/cu.usbmodem* 2>/dev/null | head -1 | sed 's|.*|Found: &|' || echo "Not found")"
echo ""
echo "Recent daemon logs:"
tail -20 /tmp/agentdaemon.log | tail -5
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Ready for testing!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
