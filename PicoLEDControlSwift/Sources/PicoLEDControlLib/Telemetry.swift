import Foundation
import os.log
import os.signpost

/// Component identifier for telemetry events
public enum TelemetryComponent: String, Codable {
    case voiceApp = "voice_app"
    case agentDaemon = "agent_daemon"
    case toolSerial = "tool_serial"
    case picoFirmware = "pico_firmware"
}

/// Outcome status for telemetry events
public enum TelemetryOutcome: String, Codable {
    case ok = "ok"
    case error = "error"
    case timeout = "timeout"
}

/// Standardized telemetry event schema
public struct TelemetryEvent: Codable {
    public let traceID: UInt64
    public let tsWall: String  // ISO8601 wall clock time
    public let tsMonoNs: UInt64  // Monotonic timestamp in nanoseconds
    public let component: TelemetryComponent
    public let stage: String
    public let durationMs: Double?  // Optional duration for this stage
    public let outcome: TelemetryOutcome
    public let metadata: [String: String]
    
    enum CodingKeys: String, CodingKey {
        case traceID = "trace_id"
        case tsWall = "ts_wall"
        case tsMonoNs = "ts_mono_ns"
        case component
        case stage
        case durationMs = "duration_ms"
        case outcome
        case metadata
    }
}

/// End-to-end telemetry system with Unified Logging and JSONL file output
public class Telemetry {
    public static let shared = Telemetry()
    
    private let logger: Logger
    private let signpostLog: OSLog
    private var jsonlFileHandle: FileHandle?
    private let jsonlQueue = DispatchQueue(label: "com.projectblaze.telemetry.jsonl")
    private var currentLogFile: URL?
    
    private init() {
        // Unified Logging with ProjectBlaze subsystem
        self.logger = Logger(subsystem: "com.danylchukstudios.projectblaze", category: "telemetry")
        self.signpostLog = OSLog(subsystem: "com.danylchukstudios.projectblaze", category: .pointsOfInterest)
        
        // JSONL file in ~/Library/Logs/ProjectBlaze/
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
            .appendingPathComponent("ProjectBlaze")
        
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        
        // One file per day: telemetry-YYYY-MM-DD.jsonl
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let logFile = logDir.appendingPathComponent("telemetry-\(dateFormatter.string(from: Date())).jsonl")
        
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        
        self.currentLogFile = logFile
        self.jsonlFileHandle = try? FileHandle(forWritingTo: logFile)
        
        logger.info("Telemetry initialized, JSONL log: \(logFile.path)")
    }
    
    deinit {
        jsonlFileHandle?.closeFile()
    }
    
    /// Mark a pipeline stage with trace ID
    /// - Parameters:
    ///   - component: Component that generated this event
    ///   - stage: Stage name (e.g., "voice_detected", "llm_start", "ack_received")
    ///   - traceID: 64-bit trace ID
    ///   - metadata: Additional metadata
    ///   - durationMs: Duration for this stage (if applicable)
    ///   - outcome: Outcome status (default: .ok)
    public func mark(
        component: TelemetryComponent,
        stage: String,
        traceID: UInt64,
        metadata: [String: String] = [:],
        durationMs: Double? = nil,
        outcome: TelemetryOutcome = .ok
    ) {
        let monotonicNs = DispatchTime.now().uptimeNanoseconds
        let wallTime = Date()
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        // Unified Logging
        var logMessage = "[TRACE:\(traceID)] [\(component.rawValue)] Stage: \(stage)"
        if let duration = durationMs {
            logMessage += " Duration: \(String(format: "%.2f", duration))ms"
        }
        if outcome != .ok {
            logMessage += " Outcome: \(outcome.rawValue)"
        }
        if !metadata.isEmpty {
            logMessage += " Metadata: \(metadata)"
        }
        logger.info("\(logMessage)")
        
        // Create standardized event
        let event = TelemetryEvent(
            traceID: traceID,
            tsWall: iso8601Formatter.string(from: wallTime),
            tsMonoNs: monotonicNs,
            component: component,
            stage: stage,
            durationMs: durationMs,
            outcome: outcome,
            metadata: metadata
        )
        
        // Write to JSONL file
        jsonlQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if we need to rotate to a new day's file
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let todayFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs")
                .appendingPathComponent("ProjectBlaze")
                .appendingPathComponent("telemetry-\(dateFormatter.string(from: Date())).jsonl")
            
            if self.currentLogFile != todayFile {
                // Close previous day's file handle before rotating
                self.jsonlFileHandle?.closeFile()
                self.jsonlFileHandle = nil
                
                // Rotate to new day's file
                if !FileManager.default.fileExists(atPath: todayFile.path) {
                    FileManager.default.createFile(atPath: todayFile.path, contents: nil)
                }
                self.currentLogFile = todayFile
                self.jsonlFileHandle = try? FileHandle(forWritingTo: todayFile)
            }
            
            guard let jsonData = try? JSONEncoder().encode(event),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }
            
            if let fileHandle = self.jsonlFileHandle {
                fileHandle.seekToEndOfFile()
                if let data = "\(jsonString)\n".data(using: .utf8) {
                    fileHandle.write(data)
                }
            }
        }
    }
    
    /// Legacy mark() method for backward compatibility (uses tool_serial component)
    public func mark(
        stage: String,
        traceID: UInt64,
        metadata: [String: String] = [:],
        latencyFromPreviousMs: Double? = nil
    ) {
        mark(
            component: .toolSerial,
            stage: stage,
            traceID: traceID,
            metadata: metadata,
            durationMs: latencyFromPreviousMs,
            outcome: .ok
        )
    }
    
    /// Start a signpost span for timing analysis in Instruments
    /// - Parameters:
    ///   - name: Span name
    ///   - traceID: Trace ID
    /// - Returns: Signpost ID for ending the span
    @discardableResult
    public func beginSpan(name: StaticString, traceID: UInt64) -> OSSignpostID {
        let signpostID = OSSignpostID(log: signpostLog, object: NSNumber(value: traceID))
        os_signpost(.begin, log: signpostLog, name: name, signpostID: signpostID, "trace_id=%llu", traceID)
        return signpostID
    }
    
    /// End a signpost span
    /// - Parameters:
    ///   - name: Span name (must match beginSpan)
    ///   - signpostID: Signpost ID from beginSpan
    ///   - traceID: Trace ID
    public func endSpan(name: StaticString, signpostID: OSSignpostID, traceID: UInt64) {
        os_signpost(.end, log: signpostLog, name: name, signpostID: signpostID, "trace_id=%llu", traceID)
    }
    
    /// Get path to latest JSONL log file
    public func latestLogPath() -> String? {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
            .appendingPathComponent("ProjectBlaze")
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey]),
              !files.isEmpty else {
            return nil
        }
        
        let latest = files.max(by: { (url1, url2) -> Bool in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            return date1 < date2
        })
        
        return latest?.path
    }
    
    /// Get all JSONL log files
    public func allLogPaths() -> [String] {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
            .appendingPathComponent("ProjectBlaze")
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }
        
        return files.filter { $0.pathExtension == "jsonl" }
            .sorted { (url1, url2) -> Bool in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 > date2  // Most recent first
            }
            .map { $0.path }
    }
}

/// Pipeline stage tracker with automatic latency calculation
public class PipelineTracker {
    private var stageTimestamps: [String: (monotonicNs: UInt64, wallTime: Date)] = [:]
    public let traceID: UInt64
    
    public init(traceID: UInt64) {
        self.traceID = traceID
    }
    
    /// Mark a stage
    public func markStage(_ stage: String, metadata: [String: String] = [:]) {
        let now = DispatchTime.now()
        let monotonicNs = now.uptimeNanoseconds
        let wallTime = Date()
        
        // Calculate latency from previous stage
        var latencyMs: Double? = nil
        if let previousStage = stageTimestamps.keys.sorted().last,
           let previous = stageTimestamps[previousStage] {
            let deltaNs = monotonicNs - previous.monotonicNs
            latencyMs = Double(deltaNs) / 1_000_000.0
        }
        
        stageTimestamps[stage] = (monotonicNs, wallTime)
        
        Telemetry.shared.mark(
            component: .toolSerial,
            stage: stage,
            traceID: traceID,
            metadata: metadata,
            durationMs: latencyMs,
            outcome: .ok
        )
    }
    
}
