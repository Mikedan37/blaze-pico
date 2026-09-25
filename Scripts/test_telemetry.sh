#!/bin/bash
# Test telemetry system with 10 commands

set -e

echo "🔥 Telemetry Test - Running 10 Commands"
echo "========================================"
echo ""

PORT="/dev/cu.usbmodem1101"
SWIFT_TOOL="./PicoLEDControlSwift/.build/release/PicoLEDControl"

# Check if Swift tool exists
if [ ! -f "$SWIFT_TOOL" ]; then
    echo "❌ Swift tool not found. Building..."
    cd PicoLEDControlSwift
    swift build -c release
    cd ..
fi

echo "📊 Running 10 commands to build telemetry data..."
echo ""

commands=("RED" "GREEN" "BLUE" "YELLOW" "MULTI" "RED" "GREEN" "BLUE" "YELLOW" "MULTI")

for i in "${!commands[@]}"; do
    cmd="${commands[$i]}"
    num=$((i + 1))
    
    echo "[$num/10] Testing: $cmd ON"
    $SWIFT_TOOL --full-pipeline --port "$PORT" "$cmd ON" 2>&1 | grep -E "TRACE|TOTAL|Success|Failed" | head -3
    
    sleep 0.3
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Telemetry Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Find latest JSONL log
LOG_FILE=$(ls -t ~/Documents/BlazeTelemetry/*.jsonl 2>/dev/null | head -1)

if [ -n "$LOG_FILE" ]; then
    echo "✅ JSONL log: $LOG_FILE"
    echo ""
    echo "Sample events (last 5):"
    tail -5 "$LOG_FILE" | jq . 2>/dev/null || tail -5 "$LOG_FILE"
    echo ""
    echo "Stage breakdown:"
    grep -o '"stage":"[^"]*"' "$LOG_FILE" | sort | uniq -c | sort -rn
else
    echo "⚠️  No JSONL log found (telemetry may not be initialized)"
fi

echo ""
echo "✅ Test complete!"
echo ""
echo "To view full telemetry:"
echo "  log stream --predicate 'subsystem == \"com.blaze.pico\"' --level debug"
echo ""
echo "To analyze JSONL:"
echo "  jq . ~/Documents/BlazeTelemetry/telemetry_*.jsonl | less"
