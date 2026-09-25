# Performance Benchmark Suite

Comprehensive performance analysis for the Pico LED control plane.

## What It Measures

### End-to-End Performance
- **Single command latency**: Command → ACK → STATE_CHANGE pipeline
- **Batch command latency**: Multiple commands in single transaction
- **Throughput**: Commands per second under sustained load

### Component Performance
- **Serial I/O**: USB CDC read/write performance
- **State parsing**: STATE_CHANGE and STATE response parsing
- **Deduplication**: Sequence and ACK idempotency overhead

### Memory Usage
- **Baseline memory**: Initial memory footprint
- **Memory growth**: Memory usage after operations
- **Bounded set memory**: Memory usage of completedTraces and pendingCommands

### Pipeline Performance
- **Command pipeline**: Breakdown of Command → ACK → STATE_CHANGE phases
- **Concurrent commands**: Performance under concurrent load

### Stress Tests
- **Rapid burst**: 100 commands fired simultaneously
- **Long-running**: 30-second sustained load test with memory monitoring

## Running Benchmarks

### Prerequisites
- Pico device connected via USB
- Device running latest firmware
- Swift 5.9+

### Quick Start

```bash
cd Benchmarks
./run_benchmarks.sh
```

### Manual Run

```bash
cd Benchmarks
swift build -c release
swift run -c release PerformanceBenchmark
```

## Output Format

Benchmarks output:
- **Latency metrics**: Min, Avg, P50, P95, P99, Max
- **Throughput**: Commands/second
- **Memory**: Current usage, growth, bounded set sizes
- **Error rates**: Success/failure counts

## Expected Performance

Based on architecture:
- **Single command latency**: ~25-50ms (ACK) + ~50-100ms (STATE_CHANGE)
- **Throughput**: 10-20 commands/second (USB CDC limited)
- **Memory**: <10MB baseline, <50MB after 1000 commands
- **Concurrent commands**: Serialized via writeLock (no true parallelism)

## Interpreting Results

### Good Performance
- ✅ P95 latency < 200ms
- ✅ Throughput > 10 commands/sec
- ✅ Memory growth < 1MB per 100 commands
- ✅ Error rate < 1%

### Performance Issues
- ⚠️ P95 latency > 500ms → USB/device bottleneck
- ⚠️ Throughput < 5 commands/sec → Serial I/O bottleneck
- ⚠️ Memory growth > 5MB per 100 commands → Memory leak
- ⚠️ Error rate > 5% → Stability issues

## Benchmark Details

### End-to-End Benchmarks
- **Single Command**: 100 iterations, alternating on/off
- **Batch Command**: 50 iterations, 4 commands per batch
- **Throughput**: 10-second sustained load

### Component Benchmarks
- **Serial I/O**: 1000 parse operations
- **State Parsing**: 10,000 parse operations
- **Deduplication**: 100,000 deduplication checks

### Memory Benchmarks
- **Baseline**: Initial memory footprint
- **After Operations**: Memory after 100 commands
- **Bounded Sets**: Memory at capacity and after eviction

### Pipeline Benchmarks
- **Command Pipeline**: 50 iterations with phase breakdown
- **Concurrent**: 10 concurrent commands

### Stress Tests
- **Rapid Burst**: 100 simultaneous commands
- **Long-Running**: 30-second test with memory sampling

## Notes

- Benchmarks require actual hardware (not simulated)
- Results vary based on USB connection quality
- macOS USB CDC implementation affects performance
- Firmware state affects command execution time
