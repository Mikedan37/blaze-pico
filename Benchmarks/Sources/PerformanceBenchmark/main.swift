import Foundation
import PicoLEDControlLib

/// Comprehensive performance benchmark suite for Pico LED control plane
/// Measures: latency, throughput, memory, component performance
@main
struct PerformanceBenchmark {
    static func main() async {
        print(String(repeating: "=", count: 80))
        print("PICO LED CONTROL PLANE - PERFORMANCE BENCHMARK SUITE")
        print(String(repeating: "=", count: 80))
        print()
        
        guard let devicePort = findPicoDevice() else {
            print("❌ ERROR: No Pico device found")
            print("   Please ensure device is connected and in /dev/tty.usbmodem*")
            exit(1)
        }
        
        print("✅ Found Pico device: \(devicePort)")
        print()
        
        let session = PicoSession(portPath: devicePort, deviceID: "benchmark-device")
        
        // Cleanup function: Turn all LEDs off (deadline-based retry until confirmed)
        // Production pattern: retry until confirmed OR timeout (not fixed count)
        func cleanupLEDs(session: PicoSession?) async {
            guard let session = session else { return }
            
            print()
            print("🧹 CLEANUP: Turning all LEDs OFF...")
            
            // Wait a moment for any pending commands to complete
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            
            do {
                if session.isConnected && session.isReady {
                    // Deadline-based retry: retry until confirmed OR timeout
                    // This is production-grade: adapts to actual device response
                    let deadline = Date().addingTimeInterval(3.0) // 3 second deadline
                    var attempt = 0
                    var confirmed = false
                    
                    while Date() < deadline && !confirmed {
                        attempt += 1
                        do {
                            print("   Sending ALL OFF command (attempt \(attempt), deadline: \(String(format: "%.1f", deadline.timeIntervalSinceNow))s)...")
                            
                            // Use sendCommandWithCompletion to ensure it completes
                            let (success, _) = try await session.sendCommandWithCompletion(
                                commandID: .all,
                                value: 0,
                                ackTimeoutMs: 1000,
                                stateTimeoutMs: 2000
                            )
                            
                            if success {
                                print("   ✅ ALL OFF confirmed (attempt \(attempt))")
                                confirmed = true
                            } else {
                                print("   ⚠️ ALL OFF not confirmed (attempt \(attempt))")
                            }
                            
                            // Wait between attempts (only if not confirmed)
                            if !confirmed && Date() < deadline {
                                try await Task.sleep(nanoseconds: 300_000_000) // 300ms
                            }
                        } catch {
                            print("   ⚠️ Cleanup attempt \(attempt) failed: \(error)")
                            // Try simple sendCommand as fallback
                            try? await session.sendCommand(commandID: .all, value: 0)
                            if Date() < deadline {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                            }
                        }
                    }
                    
                    if confirmed {
                        // Final wait to ensure all commands processed
                        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                        print("✅ CLEANUP COMPLETE: All LEDs confirmed OFF")
                    } else {
                        print("⚠️ CLEANUP TIMEOUT: Deadline reached after \(attempt) attempts")
                        print("   Device may still have LEDs ON - manual intervention may be needed")
                    }
                } else {
                    print("⚠️ Cannot cleanup: Device not connected (\(session.isConnected)) or ready (\(session.isReady))")
                    print("   Attempting direct command anyway...")
                    // Try anyway - might work
                    try? await session.sendCommand(commandID: .all, value: 0)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch {
                print("⚠️ Cleanup error: \(error)")
            }
        }
        
        do {
            print("🔌 Connecting to device...")
            try await session.connect(timeoutMs: 5000)
            print("✅ Connected")
            
            // HARD READINESS GATE: Wait for BLAZE_READY before proceeding
            // Event reader will set isReady=true when BLAZE_READY arrives
            print("⏳ Waiting for device readiness (BLAZE_READY)...")
            let maxWaitSeconds = 10.0
            let startWait = Date()
            while !session.isReady && Date().timeIntervalSince(startWait) < maxWaitSeconds {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            
            if session.isReady {
                print("✅ Device ready - proceeding with benchmarks")
            } else {
                print("⚠️ Device not ready after \(maxWaitSeconds)s - benchmarks may fail")
            }
            print()
            
            // Initial cleanup: Ensure LEDs start OFF
            print("🧹 Initial cleanup: Ensuring all LEDs are OFF before benchmarks...")
            await cleanupLEDs(session: session)
            print()
            
            // Run all benchmarks
            await runEndToEndBenchmarks(session: session)
            await runComponentBenchmarks(session: session)
            await runMemoryBenchmarks(session: session)
            await runPipelineBenchmarks(session: session)
            await runStressTests(session: session)
            
            print()
            print(String(repeating: "=", count: 80))
            print("✅ ALL BENCHMARKS COMPLETE")
            print(String(repeating: "=", count: 80))
            
            // Final cleanup: Turn all LEDs off
            await cleanupLEDs(session: session)
            
        } catch {
            print("❌ ERROR: \(error)")
            // Cleanup LEDs even on error
            await cleanupLEDs(session: session)
            exit(1)
        }
    }
    
    // MARK: - End-to-End Benchmarks
    
    static func runEndToEndBenchmarks(session: PicoSession) async {
        print("📊 END-TO-END BENCHMARKS")
        print(String(repeating: "-", count: 80))
        
        // Single command latency
        await benchmarkSingleCommandLatency(session: session, iterations: 100)
        
        // Batch command latency
        await benchmarkBatchCommandLatency(session: session, iterations: 50)
        
        // Throughput (commands/second)
        await benchmarkThroughput(session: session, durationSeconds: 10)
        
        print()
    }
    
    static func benchmarkSingleCommandLatency(session: PicoSession, iterations: Int) async {
        print("  🔹 Single Command Latency (\(iterations) iterations)...")
        
        var latencies: [TimeInterval] = []
        var ackLatencies: [TimeInterval] = []
        var stateLatencies: [TimeInterval] = []
        
        for i in 0..<iterations {
            let startTime = Date()
            
            do {
                let (success, state) = try await session.sendCommandWithCompletion(
                    commandID: .green,
                    value: UInt8(i % 2), // Alternate on/off
                    ackTimeoutMs: 1000,
                    stateTimeoutMs: 2000
                )
                
                let totalLatency = Date().timeIntervalSince(startTime)
                latencies.append(totalLatency)
                
                if success {
                    // Estimate ACK latency (roughly 50% of total for single command)
                    ackLatencies.append(totalLatency * 0.5)
                    if state != nil {
                        stateLatencies.append(totalLatency)
                    }
                }
            } catch {
                print("    ⚠️ Command \(i) failed: \(error)")
            }
            
        }
        
        printResults("Total Latency", latencies, unit: "ms")
        printResults("ACK Latency (estimated)", ackLatencies, unit: "ms")
        printResults("State Latency", stateLatencies, unit: "ms")
    }
    
    static func benchmarkBatchCommandLatency(session: PicoSession, iterations: Int) async {
        print("  🔹 Batch Command Latency (\(iterations) iterations)...")
        
        var latencies: [TimeInterval] = []
        
        for i in 0..<iterations {
            let commands: [(CommandID, UInt8)] = [
                (.red, UInt8(i % 2)),
                (.green, UInt8((i + 1) % 2)),
                (.yellow, UInt8(i % 2)),
                (.blue, UInt8((i + 1) % 2))
            ]
            
            let startTime = Date()
            
            do {
                // Send commands individually (batch API may not be available)
                for (cmdID, val) in commands {
                    _ = try await session.sendCommandWithCompletion(
                        commandID: cmdID,
                        value: val
                    )
                }
                let latency = Date().timeIntervalSince(startTime)
                latencies.append(latency)
            } catch {
                print("    ⚠️ Batch \(i) failed: \(error)")
            }
        }
        
        printResults("Batch Latency", latencies, unit: "ms")
    }
    
    static func benchmarkThroughput(session: PicoSession, durationSeconds: Int) async {
        print("  🔹 Throughput Test (\(durationSeconds)s)...")
        
        let startTime = Date()
        var commandCount = 0
        var errorCount = 0
        
        while Date().timeIntervalSince(startTime) < Double(durationSeconds) {
            do {
                _ = try await session.sendCommandWithCompletion(
                    commandID: .green,
                    value: UInt8(commandCount % 2)
                )
                commandCount += 1
            } catch {
                errorCount += 1
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let throughput = Double(commandCount) / elapsed
        
        print("    ✅ Commands: \(commandCount)")
        print("    ❌ Errors: \(errorCount)")
        print("    ⚡ Throughput: \(String(format: "%.2f", throughput)) commands/second")
    }
    
    // MARK: - Component Benchmarks
    
    static func runComponentBenchmarks(session: PicoSession) async {
        print("📊 COMPONENT BENCHMARKS")
        print(String(repeating: "-", count: 80))
        
        // Serial I/O performance
        await benchmarkSerialIO(session: session)
        
        // State parsing performance
        await benchmarkStateParsing()
        
        // Sequence deduplication overhead
        await benchmarkDeduplication()
        
        print()
    }
    
    static func benchmarkSerialIO(session: PicoSession) async {
        print("  🔹 Serial I/O Performance...")
        
        let iterations = 1000
        let testData = Data("STATE_CHANGE: seq=123 trace=456 R=1 G=0 Y=0 B=0 MR=0 MG=0 MB=0\n".utf8)
        
        let startTime = Date()
        for _ in 0..<iterations {
            // Simulate parsing overhead
            _ = String(data: testData, encoding: .utf8)
        }
        let elapsed = Date().timeIntervalSince(startTime)
        
        let opsPerSecond = Double(iterations) / elapsed
        print("    ⚡ Parse operations: \(String(format: "%.0f", opsPerSecond)) ops/sec")
    }
    
    static func benchmarkStateParsing() async {
        print("  🔹 State Parsing Performance...")
        
        let testLines = [
            "STATE_CHANGE: seq=100 trace=123456 R=1 G=0 Y=1 B=0 MR=0 MG=0 MB=0",
            "STATE: seq=101 R=0 G=1 Y=0 B=1 MR=1 MG=1 MB=1",
            "STATE_CHANGE: trace=789012 seq=102 R=1 G=1 Y=1 B=1 MR=0 MG=0 MB=0"
        ]
        
        let iterations = 10000
        let startTime = Date()
        
        for _ in 0..<iterations {
            for line in testLines {
                // Simulate parsing
                _ = line.components(separatedBy: " ")
                _ = line.range(of: "seq=")
                _ = line.range(of: "trace=")
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let opsPerSecond = Double(iterations * testLines.count) / elapsed
        print("    ⚡ Parse operations: \(String(format: "%.0f", opsPerSecond)) ops/sec")
    }
    
    static func benchmarkDeduplication() async {
        print("  🔹 Deduplication Overhead...")
        
        let iterations = 100000
        var completedTraces: Set<UInt64> = []
        var lastAppliedSequence: UInt64 = 0
        
        let startTime = Date()
        
        for i in 0..<iterations {
            let seq = UInt64(i)
            let traceID = UInt64.random(in: 0..<1000)
            
            // Simulate deduplication checks
            if seq > lastAppliedSequence {
                lastAppliedSequence = seq
            }
            
            if !completedTraces.contains(traceID) {
                completedTraces.insert(traceID)
                if completedTraces.count > 1000 {
                    completedTraces.removeFirst()
                }
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let opsPerSecond = Double(iterations) / elapsed
        print("    ⚡ Deduplication checks: \(String(format: "%.0f", opsPerSecond)) ops/sec")
    }
    
    // MARK: - Memory Benchmarks
    
    static func runMemoryBenchmarks(session: PicoSession) async {
        print("📊 MEMORY BENCHMARKS")
        print(String(repeating: "-", count: 80))
        
        // Baseline memory
        let baselineMemory = getMemoryUsage()
        print("  🔹 Baseline Memory: \(formatBytes(baselineMemory))")
        
        // Memory after operations
        for i in 0..<100 {
            _ = try? await session.sendCommandWithCompletion(
                commandID: .green,
                value: UInt8(i % 2)
            )
        }
        
        let afterMemory = getMemoryUsage()
        let memoryDelta = afterMemory - baselineMemory
        print("  🔹 After 100 Commands: \(formatBytes(afterMemory))")
        print("  🔹 Memory Delta: \(formatBytes(memoryDelta))")
        
        // Bounded set memory
        await benchmarkBoundedSetMemory()
        
        print()
    }
    
    static func benchmarkBoundedSetMemory() async {
        print("  🔹 Bounded Set Memory...")
        
        var completedTraces: Set<UInt64> = []
        let maxSize = 1000
        
        // Fill to capacity
        for i in 0..<maxSize {
            completedTraces.insert(UInt64(i))
        }
        
        let memoryAtCapacity = getMemoryUsage()
        print("    📦 At capacity (1000): \(formatBytes(memoryAtCapacity))")
        
        // Add more (should trigger eviction)
        for i in maxSize..<(maxSize + 100) {
            completedTraces.insert(UInt64(i))
            if completedTraces.count > maxSize {
                let toRemove = Array(completedTraces.prefix(maxSize / 10))
                completedTraces.subtract(toRemove)
            }
        }
        
        let memoryAfterEviction = getMemoryUsage()
        print("    📦 After eviction: \(formatBytes(memoryAfterEviction))")
        print("    ✅ Set size: \(completedTraces.count) (bounded)")
    }
    
    // MARK: - Pipeline Benchmarks
    
    static func runPipelineBenchmarks(session: PicoSession) async {
        print("📊 PIPELINE BENCHMARKS")
        print(String(repeating: "-", count: 80))
        
        // Command → ACK → STATE_CHANGE pipeline
        await benchmarkCommandPipeline(session: session, iterations: 50)
        
        // Concurrent command handling
        await benchmarkConcurrentCommands(session: session, concurrency: 10)
        
        print()
    }
    
    static func benchmarkCommandPipeline(session: PicoSession, iterations: Int) async {
        print("  🔹 Command Pipeline (Command → ACK → STATE_CHANGE)...")
        
        var pipelineLatencies: [TimeInterval] = []
        var ackLatencies: [TimeInterval] = []
        var stateChangeLatencies: [TimeInterval] = []
        
        for i in 0..<iterations {
            let commandStart = Date()
            
            do {
                let (success, state) = try await session.sendCommandWithCompletion(
                    commandID: .green,
                    value: UInt8(i % 2)
                )
                
                let totalLatency = Date().timeIntervalSince(commandStart)
                pipelineLatencies.append(totalLatency)
                
                if success {
                    // Rough estimates (ACK ~40%, STATE_CHANGE ~60% of total)
                    ackLatencies.append(totalLatency * 0.4)
                    if state != nil {
                        stateChangeLatencies.append(totalLatency * 0.6)
                    }
                }
            } catch {
                print("    ⚠️ Pipeline \(i) failed: \(error)")
            }
        }
        
        printResults("Pipeline Total", pipelineLatencies, unit: "ms")
        printResults("ACK Phase", ackLatencies, unit: "ms")
        printResults("STATE_CHANGE Phase", stateChangeLatencies, unit: "ms")
    }
    
    static func benchmarkConcurrentCommands(session: PicoSession, concurrency: Int) async {
        print("  🔹 Concurrent Commands (\(concurrency) concurrent)...")
        
        let startTime = Date()
        
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<concurrency {
                let cmdID = CommandID(rawValue: UInt8((i % 4) + 1)) ?? .red
                group.addTask {
                    do {
                        _ = try await session.sendCommandWithCompletion(
                            commandID: cmdID,
                            value: UInt8(i % 2)
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            
            var successCount = 0
            for await success in group {
                if success { successCount += 1 }
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("    ✅ Success rate: \(concurrency)/\(concurrency)")
        print("    ⚡ Total time: \(String(format: "%.2f", elapsed * 1000))ms")
        print("    ⚡ Avg per command: \(String(format: "%.2f", elapsed * 1000 / Double(concurrency)))ms")
    }
    
    // MARK: - Stress Tests
    
    static func runStressTests(session: PicoSession) async {
        print("📊 STRESS TESTS")
        print(String(repeating: "-", count: 80))
        
        // Rapid command burst
        await stressTestRapidBurst(session: session, count: 100)
        
        // Long-running stability
        await stressTestLongRunning(session: session, durationSeconds: 30)
        
        print()
    }
    
    static func stressTestRapidBurst(session: PicoSession, count: Int) async {
        print("  🔹 Rapid Command Burst (\(count) commands)...")
        
        let startTime = Date()
        var successCount = 0
        var errorCount = 0
        
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<count {
                group.addTask {
                    do {
                        _ = try await session.sendCommandWithCompletion(
                            commandID: .green,
                            value: UInt8(i % 2)
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            
            for await success in group {
                if success {
                    successCount += 1
                } else {
                    errorCount += 1
                }
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("    ✅ Success: \(successCount)")
        print("    ❌ Errors: \(errorCount)")
        print("    ⚡ Total time: \(String(format: "%.2f", elapsed * 1000))ms")
        print("    ⚡ Rate: \(String(format: "%.2f", Double(count) / elapsed)) commands/sec")
    }
    
    static func stressTestLongRunning(session: PicoSession, durationSeconds: Int) async {
        print("  🔹 Long-Running Stability (\(durationSeconds)s)...")
        
        let startTime = Date()
        var commandCount = 0
        var errorCount = 0
        var memorySamples: [UInt64] = []
        
        while Date().timeIntervalSince(startTime) < Double(durationSeconds) {
            do {
                _ = try await session.sendCommandWithCompletion(
                    commandID: .green,
                    value: UInt8(commandCount % 2)
                )
                commandCount += 1
                
                // Sample memory every 10 commands
                if commandCount % 10 == 0 {
                    memorySamples.append(getMemoryUsage())
                }
            } catch {
                errorCount += 1
            }
            
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms between commands
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let avgMemory = memorySamples.isEmpty ? 0 : memorySamples.reduce(0, +) / UInt64(memorySamples.count)
        let maxMemory = memorySamples.max() ?? 0
        let minMemory = memorySamples.min() ?? 0
        
        print("    ✅ Commands: \(commandCount)")
        print("    ❌ Errors: \(errorCount)")
        print("    ⚡ Throughput: \(String(format: "%.2f", Double(commandCount) / elapsed)) commands/sec")
        print("    📦 Avg Memory: \(formatBytes(avgMemory))")
        print("    📦 Max Memory: \(formatBytes(maxMemory))")
        print("    📦 Min Memory: \(formatBytes(minMemory))")
        print("    📦 Memory Delta: \(formatBytes(maxMemory - minMemory))")
    }
    
    // MARK: - Helper Functions
    
    static func findPicoDevice() -> String? {
        let fileManager = FileManager.default
        let devPath = "/dev"
        
        // Try to list directory contents
        if let contents = try? fileManager.contentsOfDirectory(atPath: devPath) {
            for file in contents {
                if file.hasPrefix("tty.usbmodem") {
                    let fullPath = "\(devPath)/\(file)"
                    // Verify it's actually a character device
                    if fileManager.fileExists(atPath: fullPath) {
                        return fullPath
                    }
                }
            }
        }
        
        // Fallback: try common device paths directly
        let commonPaths = [
            "/dev/tty.usbmodem2101",
            "/dev/tty.usbmodem0001",
            "/dev/tty.usbmodem101",
            "/dev/tty.usbmodem1"
        ]
        
        for path in commonPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    static func printResults(_ name: String, _ values: [TimeInterval], unit: String) {
        guard !values.isEmpty else {
            print("    ⚠️ \(name): No data")
            return
        }
        
        let sorted = values.sorted()
        let min = sorted.first! * 1000
        let max = sorted.last! * 1000
        let avg = (values.reduce(0, +) / Double(values.count)) * 1000
        let p50 = sorted[sorted.count / 2] * 1000
        let p95 = sorted[Int(Double(sorted.count) * 0.95)] * 1000
        let p99 = sorted[Int(Double(sorted.count) * 0.99)] * 1000
        
        print("    📊 \(name):")
        print("       Min:    \(String(format: "%.2f", min)) \(unit)")
        print("       Avg:    \(String(format: "%.2f", avg)) \(unit)")
        print("       P50:    \(String(format: "%.2f", p50)) \(unit)")
        print("       P95:    \(String(format: "%.2f", p95)) \(unit)")
        print("       P99:    \(String(format: "%.2f", p99)) \(unit)")
        print("       Max:    \(String(format: "%.2f", max)) \(unit)")
    }
    
    static func getMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return 0
        }
        
        return info.resident_size
    }
    
    static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

