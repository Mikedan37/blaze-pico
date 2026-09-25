import XCTest
import Foundation
@testable import PicoLEDControlLib

/// Validation tests for telemetry system
final class TelemetryValidationTests: XCTestCase {
    
    func testTelemetryEventEncoding() throws {
        let event = TelemetryEvent(
            traceID: 928347239847,
            tsWall: "2026-02-18T14:23:45.123Z",
            tsMonoNs: 1234567890123456789,
            component: .toolSerial,
            stage: "serial_write_start",
            durationMs: nil,
            outcome: .ok,
            metadata: ["command": "RED ON"]
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(event)
        
        XCTAssertNotNil(data)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TelemetryEvent.self, from: data)
        
        XCTAssertEqual(decoded.traceID, event.traceID)
        XCTAssertEqual(decoded.component, event.component)
        XCTAssertEqual(decoded.stage, event.stage)
        XCTAssertEqual(decoded.outcome, event.outcome)
        XCTAssertEqual(decoded.metadata["command"], "RED ON")
    }
    
    func testTelemetryMark() {
        let telemetry = Telemetry.shared
        
        // Mark a stage
        telemetry.mark(
            component: .toolSerial,
            stage: "test_stage",
            traceID: 12345,
            metadata: ["test": "value"],
            durationMs: 42.5,
            outcome: .ok
        )
        
        // Verify log file exists
        let logPath = telemetry.latestLogPath()
        XCTAssertNotNil(logPath)
        
        // Read and verify JSONL entry
        if let path = logPath,
           let content = try? String(contentsOfFile: path),
           let lastLine = content.components(separatedBy: .newlines).last(where: { !$0.isEmpty }),
           let data = lastLine.data(using: .utf8),
           let event = try? JSONDecoder().decode(TelemetryEvent.self, from: data) {
            XCTAssertEqual(event.traceID, 12345)
            XCTAssertEqual(event.stage, "test_stage")
            XCTAssertEqual(event.component, .toolSerial)
            XCTAssertEqual(event.durationMs, 42.5)
            XCTAssertEqual(event.outcome, .ok)
        } else {
            XCTFail("Could not read or parse telemetry log")
        }
    }
    
    func testPipelineTracker() {
        let traceID: UInt64 = 99999
        let tracker = PipelineTracker(traceID: traceID)
        
        tracker.markStage("stage1")
        usleep(10_000)
        tracker.markStage("stage2")
        usleep(20_000)
        tracker.markStage("stage3")
        
        XCTAssertEqual(tracker.traceID, traceID)
    }
    
    func testMetricsRollup() {
        // Create sample events
        let events: [TelemetryEvent] = [
            TelemetryEvent(
                traceID: 1,
                tsWall: ISO8601DateFormatter().string(from: Date()),
                tsMonoNs: 1000_000_000,
                component: .toolSerial,
                stage: "serial_write_start",
                durationMs: nil,
                outcome: .ok,
                metadata: [:]
            ),
            TelemetryEvent(
                traceID: 1,
                tsWall: ISO8601DateFormatter().string(from: Date()),
                tsMonoNs: 2000_000_000, // 1ms later
                component: .toolSerial,
                stage: "ack_received",
                durationMs: 1.0,
                outcome: .ok,
                metadata: [:]
            ),
            TelemetryEvent(
                traceID: 2,
                tsWall: ISO8601DateFormatter().string(from: Date()),
                tsMonoNs: 3000_000_000,
                component: .toolSerial,
                stage: "serial_write_start",
                durationMs: nil,
                outcome: .ok,
                metadata: [:]
            ),
            TelemetryEvent(
                traceID: 2,
                tsWall: ISO8601DateFormatter().string(from: Date()),
                tsMonoNs: 5000_000_000, // 2ms later
                component: .toolSerial,
                stage: "ack_received",
                durationMs: 2.0,
                outcome: .ok,
                metadata: [:]
            )
        ]
        
        // Compute metrics (simplified version)
        let traces = Dictionary(grouping: events) { $0.traceID }
        XCTAssertEqual(traces.count, 2)
        
        // Verify serial RTT calculation
        for (traceID, traceEvents) in traces {
            let sorted = traceEvents.sorted { $0.tsMonoNs < $1.tsMonoNs }
            
            if let start = sorted.first(where: { $0.stage == "serial_write_start" }),
               let ack = sorted.first(where: { $0.stage == "ack_received" }) {
                let rttNs = ack.tsMonoNs - start.tsMonoNs
                let rttMs = Double(rttNs) / 1_000_000.0
                
                if traceID == 1 {
                    XCTAssertEqual(rttMs, 1.0, accuracy: 0.1)
                } else if traceID == 2 {
                    XCTAssertEqual(rttMs, 2.0, accuracy: 0.1)
                }
            }
        }
    }
    
    func testPercentileCalculation() {
        let sorted: [Double] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
        
        // p50 should be median
        let p50Index = Int(Double(sorted.count - 1) * 0.50)
        XCTAssertEqual(sorted[p50Index], 5.0)
        
        // p95 should be near the end
        let p95Index = Int(Double(sorted.count - 1) * 0.95)
        XCTAssertEqual(sorted[p95Index], 9.0)
        
        // p99 should be near the max
        let p99Index = Int(Double(sorted.count - 1) * 0.99)
        XCTAssertEqual(sorted[p99Index], 9.0)
    }
}
