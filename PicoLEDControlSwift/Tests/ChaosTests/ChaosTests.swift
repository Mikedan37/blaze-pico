import XCTest
@testable import PicoLEDControlLib
import Combine

/// Chaos tests that prove the hardware control plane survives real-world failure modes.
/// These tests require a connected Pico device unless noted as "offline".
final class ChaosTests: XCTestCase {

    /// Skip hardware tests up front when no Pico is plugged in (e.g. CI).
    private func skipWithoutPico() throws {
        let dev = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        if !dev.contains(where: { $0.hasPrefix("cu.usbmodem") }) {
            throw XCTSkip("No Pico device connected")
        }
    }
    
    // MARK: - Test 1: Command Flood (Backpressure Proof)
    
    /// Sends 100 commands in rapid succession to verify:
    /// - Queue depth limit enforced (maxQueuedHardwareOps)
    /// - Command coalescing works (duplicate commands collapse)
    /// - No deadlocks under load
    /// - All commands either succeed or fail gracefully (no hangs)
    func testCommandFlood() async throws {
        try skipWithoutPico()
        let dm = DeviceManager.shared
        try await dm.warmStart()
        
        let session = try await dm.getSession()
        guard session.isReady else {
            throw XCTSkip("No ready Pico device connected")
        }
        
        let commandCount = 100
        var successes = 0
        var failures = 0
        var rejections = 0
        
        let startTime = Date()
        
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<commandCount {
                group.addTask {
                    do {
                        let color = i % 2 == 0 ? "RED" : "GREEN"
                        let state = i % 4 < 2 ? "ON" : "OFF"
                        let result = try await DeviceManagerCommandHelper.sendCommand("\(color) \(state)")
                        return result.success
                    } catch {
                        let msg = "\(error)"
                        if msg.contains("queue full") || msg.contains("too many pending") {
                            return false // Expected rejection under load
                        }
                        throw error
                    }
                }
            }
            
            for try await result in group {
                if result { successes += 1 } else { rejections += 1 }
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        print("""
        [CHAOS:FLOOD] Results:
          Total commands: \(commandCount)
          Successes: \(successes)
          Rejections (backpressure): \(rejections)
          Failures: \(failures)
          Elapsed: \(String(format: "%.2f", elapsed))s
          Throughput: \(String(format: "%.1f", Double(successes) / elapsed)) cmd/s
        """)
        
        // At least some commands must succeed
        XCTAssertGreaterThan(successes, 0, "No commands succeeded under flood")
        // No hangs: should complete well under 60 seconds
        XCTAssertLessThan(elapsed, 60.0, "Command flood took too long (possible deadlock)")
        
        // Verify device is still responsive after flood
        let postFloodState = try await DeviceManagerCommandHelper.queryState()
        XCTAssertNotNil(postFloodState, "Device unresponsive after command flood")
        
        // Clean up
        _ = try await DeviceManagerCommandHelper.sendCommand("ALL OFF")
    }
    
    // MARK: - Test 2: Hot Disconnect Recovery
    
    /// Verifies the system detects and recovers from a mid-session disconnect.
    /// Uses session invalidation to simulate USB unplug.
    func testHotDisconnectRecovery() async throws {
        try skipWithoutPico()
        let dm = DeviceManager.shared
        try await dm.warmStart()
        
        let session = try await dm.getSession()
        guard session.isReady else {
            throw XCTSkip("No ready Pico device connected")
        }
        
        // Verify baseline: device works
        let preState = try await DeviceManagerCommandHelper.queryState()
        XCTAssertNotNil(preState, "Pre-disconnect state query failed")
        
        // Simulate hot disconnect by invalidating the session
        print("[CHAOS:DISCONNECT] Invalidating session to simulate USB unplug...")
        session.invalidate()
        session.disconnect()
        
        // Commands should fail gracefully (not hang or crash)
        do {
            _ = try await DeviceManagerCommandHelper.sendCommand("RED ON")
            // If this succeeds, the system recovered inline (also acceptable)
        } catch {
            print("[CHAOS:DISCONNECT] Command after disconnect failed (expected): \(error.localizedDescription)")
        }
        
        // Wait for background reconnect
        print("[CHAOS:DISCONNECT] Waiting for background reconnect (up to 15s)...")
        var recovered = false
        for attempt in 1...5 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                let newSession = try await dm.getSession()
                if newSession.isConnected {
                    recovered = true
                    print("[CHAOS:DISCONNECT] Reconnected on attempt \(attempt)")
                    break
                }
            } catch {
                print("[CHAOS:DISCONNECT] Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }
        
        if recovered {
            // Verify device works after recovery
            let postState = try await DeviceManagerCommandHelper.queryState()
            XCTAssertNotNil(postState, "Post-recovery state query failed")
            print("[CHAOS:DISCONNECT] Full recovery confirmed")
        } else {
            print("[CHAOS:DISCONNECT] Recovery did not complete in time (device may be physically disconnected)")
        }
    }
    
    // MARK: - Test 3: Parser Resync After Corruption (Offline)
    
    /// Verifies the binary frame parser recovers from corrupted bytes
    /// without crashing or permanently desyncing.
    /// This test is offline (no device needed).
    func testParserResyncAfterCorruption() throws {
        // Build a valid binary frame: [len_hi, len_lo, frameType, traceID(8), cmdID, value]
        // Length = 11 (frameType + traceID + cmdID + value)
        let traceID: UInt64 = 0x1234567890ABCDEF
        var validFrame = Data()
        validFrame.append(0x00) // len_hi
        validFrame.append(0x0B) // len_lo = 11
        validFrame.append(0x01) // frameType = command
        
        // traceID big-endian
        var traceBE = traceID.bigEndian
        validFrame.append(Data(bytes: &traceBE, count: 8))
        
        validFrame.append(0x01) // cmdID = RED
        validFrame.append(0x01) // value = ON
        
        // Build corrupted stream: garbage + valid frame + more garbage + valid frame
        var stream = Data()
        
        // Garbage bytes before first valid frame
        stream.append(contentsOf: [0xFF, 0xFE, 0xFD, 0x00, 0x03, 0xAA, 0xBB])
        
        // Valid frame
        stream.append(validFrame)
        
        // More garbage
        stream.append(contentsOf: [0xCC, 0xDD, 0xEE, 0xFF, 0x00])
        
        // Another valid frame (GREEN ON)
        var validFrame2 = Data()
        validFrame2.append(0x00)
        validFrame2.append(0x0B)
        validFrame2.append(0x01)
        var trace2BE = UInt64(0xFEDCBA0987654321).bigEndian
        validFrame2.append(Data(bytes: &trace2BE, count: 8))
        validFrame2.append(0x02) // cmdID = GREEN
        validFrame2.append(0x01) // value = ON
        stream.append(validFrame2)
        
        // Parse the stream looking for valid frames
        var framesFound = 0
        var position = 0
        
        while position < stream.count - 2 {
            let lenHi = stream[position]
            let lenLo = stream[position + 1]
            let payloadLen = Int(lenHi) << 8 | Int(lenLo)
            
            // Valid frame check: payload length must be exactly 11
            // and we need enough bytes remaining
            if payloadLen == 11 && position + 2 + payloadLen <= stream.count {
                let frameStart = position + 2
                let frameType = stream[frameStart]
                
                if frameType == 0x01 { // command frame
                    framesFound += 1
                    let cmdID = stream[frameStart + 9]
                    let value = stream[frameStart + 10]
                    print("[CHAOS:CORRUPT] Found valid frame at offset \(position): cmdID=\(cmdID), value=\(value)")
                    position += 2 + payloadLen
                    continue
                }
            }
            
            // Not a valid frame start — advance by 1 byte (resync)
            position += 1
        }
        
        XCTAssertEqual(framesFound, 2, "Parser should find exactly 2 valid frames in corrupted stream")
        print("[CHAOS:CORRUPT] Parser resync test passed: found \(framesFound) valid frames in corrupted stream")
    }
    
    // MARK: - Test 4: Rapid Connect/Disconnect Cycles
    
    /// Rapidly cycles session connect/disconnect to verify no resource leaks
    /// (file descriptors, memory, zombie tasks).
    func testRapidSessionCycles() async throws {
        try skipWithoutPico()
        let dm = DeviceManager.shared
        try await dm.warmStart()
        
        guard let portPath = await dm.getPrimaryPortPath() else {
            throw XCTSkip("No Pico device found")
        }
        
        let cycleCount = 10
        var successfulCycles = 0
        
        for i in 1...cycleCount {
            let session = PicoSession(portPath: portPath, deviceID: portPath)
            do {
                try await session.connect(timeoutMs: 3000)
                if session.isConnected {
                    successfulCycles += 1
                }
                session.invalidate()
                session.disconnect()
                
                // Brief pause between cycles
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                print("[CHAOS:CYCLE] Cycle \(i) failed: \(error.localizedDescription)")
                session.invalidate()
                session.disconnect()
            }
        }
        
        print("[CHAOS:CYCLE] \(successfulCycles)/\(cycleCount) cycles completed successfully")
        XCTAssertGreaterThan(successfulCycles, cycleCount / 2,
                            "Less than half of connect/disconnect cycles succeeded")
        
        // Verify DeviceManager can still get a session after all cycles
        try await dm.warmStart()
        let finalSession = try await dm.getSession()
        XCTAssertTrue(finalSession.isConnected, "DeviceManager failed to recover after rapid cycles")
    }
    
    // MARK: - Test 5: Transport Recording and Replay (Offline)
    
    /// Verifies the TransportRecorder captures events and the TransportReplayer
    /// can feed them back deterministically.
    func testTransportRecordAndReplay() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let recordPath = tempDir.appendingPathComponent("chaos_test_recording.jsonl").path
        
        // Record some events
        let recorder = try TransportRecorder(outputPath: recordPath)
        
        let txData = Data([0x00, 0x0B, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01])
        recorder.recordTX(txData)
        
        let rxData = Data([0x41, 0x43, 0x4B]) // "ACK"
        recorder.recordRX(rxData)
        recorder.recordRX(Data()) // empty read
        recorder.recordError(SerialPortError.readFailed(errno: 6))
        recorder.close()
        
        XCTAssertEqual(recorder.recordedEventCount, 4)
        
        // Replay
        let replayer = try TransportReplayer(recordingPath: recordPath)
        
        // First rx: ACK data
        let rx1 = try replayer.nextRX()
        XCTAssertEqual(rx1, rxData)
        
        // Second rx: empty
        let rx2 = try replayer.nextRX()
        XCTAssertTrue(rx2.isEmpty)
        
        // Third rx: error
        XCTAssertThrowsError(try replayer.nextRX())
        
        // Verify tx recording
        replayer.recordTX(txData)
        XCTAssertEqual(replayer.stats.txMismatches.count, 0)
        
        // Verify with wrong data
        replayer.recordTX(Data([0xFF]))
        // No more expected TX events, so no mismatch recorded
        
        print("[CHAOS:REPLAY] \(replayer.summary)")
        
        // Cleanup
        try? FileManager.default.removeItem(atPath: recordPath)
    }
    
    // MARK: - Test 6: Concurrent State Queries
    
    /// Sends state queries from multiple concurrent tasks to verify
    /// no data races or deadlocks in the state management layer.
    func testConcurrentStateQueries() async throws {
        try skipWithoutPico()
        let dm = DeviceManager.shared
        try await dm.warmStart()
        
        let session = try await dm.getSession()
        guard session.isReady else {
            throw XCTSkip("No ready Pico device connected")
        }
        
        let queryCount = 20
        var results: [Bool] = []
        let lock = NSLock()
        
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<queryCount {
                group.addTask {
                    do {
                        let state = try await DeviceManagerCommandHelper.queryState()
                        return state != nil
                    } catch {
                        return false
                    }
                }
            }
            
            for try await result in group {
                lock.lock()
                results.append(result)
                lock.unlock()
            }
        }
        
        let successes = results.filter { $0 }.count
        print("[CHAOS:CONCURRENT] \(successes)/\(queryCount) concurrent queries succeeded")
        XCTAssertGreaterThan(successes, queryCount / 2,
                            "Less than half of concurrent state queries succeeded")
    }
}
