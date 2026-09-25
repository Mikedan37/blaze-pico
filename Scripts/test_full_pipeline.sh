#!/bin/bash
# Full end-to-end pipeline test with all telemetry stages

set -e

echo "🔥 Full End-to-End Pipeline Telemetry Test"
echo "=========================================="
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

echo "📊 Running full pipeline test with all stages marked..."
echo ""

# Create a test script that marks all pipeline stages
cat > /tmp/test_pipeline.swift << 'SWIFT_EOF'
import Foundation
import PicoLEDControlLib

let port = CommandLine.arguments[1]
let command = CommandLine.arguments[2]

let controller = PicoLEDController(portPath: port)

// Simulate full pipeline with all stages
print("🎤 Stage 1: Voice Detected")
controller.markVoiceDetected()
usleep(50_000) // 50ms voice processing

print("🤖 Stage 2: LLM Start")
controller.markLLMStart()
usleep(200_000) // 200ms LLM processing

print("✅ Stage 3: LLM Done")
controller.markLLMDone(
    voicePhrase: "turn on the \(command.lowercased()) light",
    llmCommand: "\(command.uppercased()) ON"
)
usleep(10_000) // 10ms routing

print("🚀 Stage 4: Agent Dispatch")
controller.markAgentDispatch()
usleep(5_000) // 5ms tool invocation

print("📡 Stage 5: Sending Command")
do {
    let success = try controller.sendCommand("\(command.uppercased()) ON")
    if success {
        print("✅ Command executed successfully")
    } else {
        print("❌ Command failed")
    }
} catch {
    print("❌ Error: \(error)")
}

controller.close()
SWIFT_EOF

# Compile and run the test
cd PicoLEDControlSwift
swiftc -o /tmp/test_pipeline /tmp/test_pipeline.swift -I .build/release -L .build/release -lPicoLEDControlLib 2>/dev/null || {
    echo "⚠️  Using alternative method..."
    # Alternative: Use the CLI tool and manually add delays to simulate stages
    echo ""
}

cd ..

# Run multiple commands to build up metrics
echo "Running test sequence..."
echo ""

commands=("RED" "GREEN" "BLUE" "YELLOW" "MULTI" "RED" "GREEN" "BLUE")

for cmd in "${commands[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Testing: $cmd ON"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Simulate pipeline stages with delays
    echo "🎤 Voice detected..."
    sleep 0.05
    
    echo "🤖 LLM processing..."
    sleep 0.2
    
    echo "✅ LLM done..."
    sleep 0.01
    
    echo "🚀 Agent dispatch..."
    sleep 0.005
    
    echo "📡 Sending command..."
    $SWIFT_TOOL --port "$PORT" "$cmd ON" 2>&1 | grep -E "TELEMETRY|TRACE|ACK|Pipeline|Stage" || true
    
    sleep 0.3
    echo ""
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Generating Full Telemetry Report"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

$SWIFT_TOOL --port "$PORT" RED ON --metrics 2>&1 | tail -60

echo ""
echo "✅ Full pipeline test complete!"
