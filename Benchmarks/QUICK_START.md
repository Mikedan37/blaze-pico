# Quick Start - Running Benchmarks

## Prerequisites
1. Pico device connected via USB
2. Latest firmware flashed
3. Swift 5.9+ installed

## Run Benchmarks

```bash
cd Benchmarks
./run_benchmarks.sh
```

Or manually:

```bash
cd Benchmarks
swift build -c release
swift run -c release PerformanceBenchmark
```

## What Gets Measured

### End-to-End Performance
- Single command latency (Command → ACK → STATE_CHANGE)
- Batch command latency
- Throughput (commands/second)

### Component Performance  
- Serial I/O parsing speed
- State parsing performance
- Deduplication overhead

### Memory Usage
- Baseline memory footprint
- Memory growth after operations
- Bounded set memory usage

### Pipeline Performance
- Command pipeline breakdown
- Concurrent command handling

### Stress Tests
- Rapid command burst (100 simultaneous)
- Long-running stability (30 seconds)

## Expected Results

Based on architecture:
- **Latency**: ~25-50ms (ACK) + ~50-100ms (STATE_CHANGE)
- **Throughput**: 10-20 commands/second
- **Memory**: <10MB baseline, <50MB after 1000 commands

## Output

Results are printed to console and saved to `benchmark_results_YYYYMMDD_HHMMSS.txt`

## Troubleshooting

**No device found**: Ensure Pico is connected and shows up in `/dev/tty.usbmodem*`

**Build errors**: Ensure Swift 5.9+ and all dependencies are installed

**Connection errors**: Check firmware is flashed and device is ready
