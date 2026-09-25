#!/bin/bash

# Performance Benchmark Runner
# Runs comprehensive benchmarks and generates report

set -e

echo "=========================================="
echo "PICO LED CONTROL PLANE - BENCHMARK SUITE"
echo "=========================================="
echo ""

# Check if device is connected
if ! ls /dev/tty.usbmodem* 1> /dev/null 2>&1; then
    echo "❌ ERROR: No Pico device found"
    echo "   Please connect your Pico device and try again"
    exit 1
fi

echo "✅ Pico device detected"
echo ""

# Build benchmark tool
echo "🔨 Building benchmark tool..."
cd "$(dirname "$0")"
swift build -c release

echo ""
echo "🚀 Running benchmarks..."
echo ""

# Run benchmarks and capture output
OUTPUT_FILE="benchmark_results_$(date +%Y%m%d_%H%M%S).txt"
swift run -c release PerformanceBenchmark 2>&1 | tee "$OUTPUT_FILE"

echo ""
echo "=========================================="
echo "✅ Benchmarks complete!"
echo "📄 Results saved to: $OUTPUT_FILE"
echo "=========================================="
