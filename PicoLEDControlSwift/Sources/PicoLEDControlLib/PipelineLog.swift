import Foundation

/// Structured pipeline logger for diagnosing command flow from daemon → PicoSession → firmware.
/// Writes to both stdout and a JSONL file at ~/Library/Logs/ProjectBlaze/pipeline.jsonl
/// Read with: `AgentDaemonClientCLI log` or `cat ~/Library/Logs/ProjectBlaze/pipeline.jsonl`
public final class PipelineLog: @unchecked Sendable {
    public static let shared = PipelineLog()
    
    public static let logDir: String = {
        let dir = NSHomeDirectory() + "/Library/Logs/ProjectBlaze"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    public static var logPath: String { logDir + "/pipeline.jsonl" }
    
    private let queue = DispatchQueue(label: "com.blaze.pipeline.log", qos: .utility)
    private var fileHandle: FileHandle?
    
    private init() {
        queue.sync {
            FileManager.default.createFile(atPath: PipelineLog.logPath, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: PipelineLog.logPath)
            fileHandle?.seekToEndOfFile()
        }
    }
    
    deinit {
        fileHandle?.closeFile()
    }
    
    public enum Level: String, Sendable {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }
    
    /// Log a pipeline event.
    /// - Parameters:
    ///   - level: Severity
    ///   - component: Source component (e.g. "IntentRouter", "PicoSession", "DeviceManager")
    ///   - event: Short event name (e.g. "cmd_sent", "ack_received", "ack_timeout")
    ///   - message: Human-readable detail
    ///   - traceID: Optional trace ID for correlation
    ///   - metadata: Optional key-value pairs
    public func log(
        _ level: Level = .info,
        component: String,
        event: String,
        message: String,
        traceID: UInt64? = nil,
        metadata: [String: String]? = nil
    ) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let traceStr = traceID.map { String(format: "%08X", UInt32(truncatingIfNeeded: $0)) } ?? ""
        
        // Structured JSONL line
        var fields: [String: Any] = [
            "ts": ts,
            "level": level.rawValue,
            "component": component,
            "event": event,
            "msg": message
        ]
        if !traceStr.isEmpty { fields["trace"] = traceStr }
        if let meta = metadata { fields["meta"] = meta }
        
        // Console line (human-readable)
        let consoleLine: String
        if !traceStr.isEmpty {
            consoleLine = "[\(ts)] [\(level.rawValue)] [\(component)] [\(traceStr)] \(event): \(message)"
        } else {
            consoleLine = "[\(ts)] [\(level.rawValue)] [\(component)] \(event): \(message)"
        }
        
        queue.async { [weak self] in
            // Write to stdout
            print(consoleLine)
            fflush(stdout)
            
            // Write JSONL to file
            if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                self?.fileHandle?.write((line + "\n").data(using: .utf8) ?? Data())
            }
        }
    }
    
    /// Convenience for command lifecycle events
    public func command(
        _ event: String,
        command: String,
        traceID: UInt64? = nil,
        durationMs: Int? = nil,
        state: [String: Bool]? = nil
    ) {
        var meta: [String: String] = ["command": command]
        if let d = durationMs { meta["duration_ms"] = String(d) }
        if let s = state { meta["state"] = s.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value ? "1" : "0")" }.joined(separator: " ") }
        
        let level: Level = event.contains("error") || event.contains("timeout") ? .warn : .info
        log(level, component: "Pipeline", event: event, message: command, traceID: traceID, metadata: meta)
    }
    
    /// Read the last N lines from the pipeline log
    public static func tail(_ count: Int = 50) -> [String] {
        guard let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Array(lines.suffix(count))
    }
}
