# Benchmark Suite Summary

## Overview

Comprehensive performance benchmarking suite for the Pico LED control plane protocol.

## What It Measures

### 1. End-to-End Performance
- **Single Command Latency**: Full pipeline (Command → ACK → STATE_CHANGE)
- **Batch Command Latency**: Multiple commands in single transaction
- **Throughput**: Sustained commands per second

### 2. Component Performance
- **Serial I/O**: USB CDC read/write and parsing performance
- **State Parsing**: STATE_CHANGE and STATE response parsing speed
- **Deduplication**: Sequence and ACK idempotency overhead

### 3. Memory Usage
- **Baseline**: Initial memory footprint
- **Growth**: Memory usage after operations
- **Bounded Sets**: Memory usage of completedTraces and pendingCommands

### 4. Pipeline Performance
- **Command Pipeline**: Breakdown of Command → ACK → STATE_CHANGE phases
- **Concurrent Commands**: Performance under concurrent load

### 5. Stress Tests
- **Rapid Burst**: 100 commands fired simultaneously
- **Long-Running**: 30-second sustained load with memory monitoring

## Architecture Expectations

Based on the protocol design:

### Latency
- **ACK Phase**: ~25-50ms (USB CDC + firmware execution)
- **STATE_CHANGE Phase**: ~50-100ms (automatic state emission)
- **Total Pipeline**: ~75-150ms per command

### Throughput
- **USB CDC Limited**: ~10-20 commands/second
- **Serialization**: Commands serialized via writeLock (no true parallelism)
- **Batching**: Can improve throughput for multiple commands

### Memory
- **Baseline**: <10MB (session, buffers, state tracking)
- **After 100 Commands**: <50MB (bounded sets prevent unbounded growth)
- **Bounded Sets**: 
  - completedTraces: ~1000 entries max (~64KB)
  - pendingCommands: ~100 entries max (~8KB)

## Running Benchmarks

```bash
cd Benchmarks
./run_benchmarks.sh
```

Results saved to: `benchmark_results_YYYYMMDD_HHMMSS.txt`

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

## Key Metrics to Watch

1. **Latency Percentiles**: P50, P95, P99 show tail latency
2. **Throughput**: Sustained commands/second
3. **Memory Growth**: Should be bounded and stable
4. **Error Rate**: Should be < 1% under normal load
5. **Concurrent Performance**: Shows serialization overhead

## Notes

- Benchmarks require actual hardware (not simulated)
- Results vary based on USB connection quality
- macOS USB CDC implementation affects performance
- Firmware state affects command execution time
- System load affects results (run on idle system for consistency)
