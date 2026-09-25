# Benchmark Results Template

Run benchmarks and fill in results here.

## Test Environment
- **Date**: [Date]
- **Hardware**: Raspberry Pi Pico 2 (RP2350)
- **Firmware Version**: [Version]
- **macOS Version**: [Version]
- **Swift Version**: [Version]
- **USB Connection**: [Direct/Hub]

## End-to-End Benchmarks

### Single Command Latency (100 iterations)
- **Min**: [ms]
- **Avg**: [ms]
- **P50**: [ms]
- **P95**: [ms]
- **P99**: [ms]
- **Max**: [ms]

### Batch Command Latency (50 iterations, 4 commands/batch)
- **Min**: [ms]
- **Avg**: [ms]
- **P50**: [ms]
- **P95**: [ms]
- **P99**: [ms]
- **Max**: [ms]

### Throughput (10 seconds)
- **Commands**: [count]
- **Errors**: [count]
- **Throughput**: [commands/sec]

## Component Benchmarks

### Serial I/O Performance
- **Parse operations**: [ops/sec]

### State Parsing Performance
- **Parse operations**: [ops/sec]

### Deduplication Overhead
- **Deduplication checks**: [ops/sec]

## Memory Benchmarks

### Baseline Memory
- **Baseline**: [MB/KB]

### After Operations
- **After 100 Commands**: [MB/KB]
- **Memory Delta**: [MB/KB]

### Bounded Set Memory
- **At capacity (1000)**: [MB/KB]
- **After eviction**: [MB/KB]
- **Set size**: [count] (bounded)

## Pipeline Benchmarks

### Command Pipeline (50 iterations)
- **Pipeline Total**: [ms]
- **ACK Phase**: [ms]
- **STATE_CHANGE Phase**: [ms]

### Concurrent Commands (10 concurrent)
- **Success rate**: [count]/[count]
- **Total time**: [ms]
- **Avg per command**: [ms]

## Stress Tests

### Rapid Command Burst (100 commands)
- **Success**: [count]
- **Errors**: [count]
- **Total time**: [ms]
- **Rate**: [commands/sec]

### Long-Running Stability (30 seconds)
- **Commands**: [count]
- **Errors**: [count]
- **Throughput**: [commands/sec]
- **Avg Memory**: [MB/KB]
- **Max Memory**: [MB/KB]
- **Min Memory**: [MB/KB]
- **Memory Delta**: [MB/KB]

## Analysis

### Performance Characteristics
[Analysis of results]

### Bottlenecks Identified
[Any bottlenecks found]

### Memory Behavior
[Memory usage patterns]

### Stability Observations
[Any stability issues]

## Recommendations
[Any recommendations based on results]
