import Foundation
import ArgumentParser
import PicoLEDControlLib

/// Metrics rollup tool for analyzing telemetry JSONL logs
@main
struct BlazeMetrics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blaze-metrics",
        abstract: "Analyze telemetry JSONL logs and generate metrics reports"
    )
    
    @Option(name: .shortAndLong, help: "Time window in minutes (default: 60)")
    var minutes: Int = 60
    
    @Option(name: .shortAndLong, help: "Path to specific JSONL file (default: latest)")
    var file: String?
    
    @Flag(name: .shortAndLong, help: "Output machine-readable JSON summary")
    var json: Bool = false
    
    @Flag(name: .shortAndLong, help: "Show detailed trace breakdown")
    var verbose: Bool = false
    
    func run() async throws {
        let logPath: String
        
        if let file = file {
            logPath = file
        } else {
            guard let latest = Telemetry.shared.latestLogPath() else {
                print("Error: No telemetry log files found")
                print("Expected location: ~/Library/Logs/ProjectBlaze/telemetry-YYYY-MM-DD.jsonl")
                throw ExitCode.failure
            }
            logPath = latest
        }
        
        guard FileManager.default.fileExists(atPath: logPath) else {
            print("Error: Log file not found: \(logPath)")
            throw ExitCode.failure
        }
        
        // Read and parse JSONL file
        let events = try readJSONLEvents(from: logPath, withinMinutes: minutes)
        
        guard !events.isEmpty else {
            print("No events found in the specified time window")
            throw ExitCode.failure
        }
        
        // Compute metrics
        let metrics = computeMetrics(from: events)
        
        // Output results
        if json {
            outputJSON(metrics)
        } else {
            outputHumanReadable(metrics, verbose: verbose)
        }
        
        // Write summary.json next to the log file
        try writeSummaryJSON(metrics, logPath: logPath)
    }
    
    /// Read JSONL events from file, filtering by time window
    private func readJSONLEvents(from path: String, withinMinutes: Int) throws -> [TelemetryEvent] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        let cutoffTime = Date().addingTimeInterval(-Double(withinMinutes * 60))
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        var events: [TelemetryEvent] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(TelemetryEvent.self, from: data) else {
                continue
            }
            
            // Filter by time window
            if let eventTime = iso8601Formatter.date(from: event.tsWall),
               eventTime >= cutoffTime {
                events.append(event)
            }
        }
        
        return events
    }
    
    /// Compute metrics from events
    private func computeMetrics(from events: [TelemetryEvent]) -> MetricsRollup {
        // Group by trace ID
        let traces = Dictionary(grouping: events) { $0.traceID }
        
        // Stage latency histograms
        var stageLatencies: [String: [Double]] = [:]
        var stageDurations: [String: [Double]] = [:]
        
        // Success/error tracking
        var successCount = 0
        var errorCount = 0
        var timeoutCount = 0
        
        // Serial RTT tracking (serial_write to ack_received)
        var serialRTTs: [Double] = []
        
        // Process each trace
        for (_, traceEvents) in traces {
            let sortedEvents = traceEvents.sorted { $0.tsMonoNs < $1.tsMonoNs }
            
            // Calculate stage-to-stage latencies
            for i in 1..<sortedEvents.count {
                let prev = sortedEvents[i - 1]
                let curr = sortedEvents[i]
                
                let latencyNs = curr.tsMonoNs - prev.tsMonoNs
                let latencyMs = Double(latencyNs) / 1_000_000.0
                
                let stageKey = "\(prev.stage) → \(curr.stage)"
                if stageLatencies[stageKey] == nil {
                    stageLatencies[stageKey] = []
                }
                stageLatencies[stageKey]?.append(latencyMs)
            }
            
            // Track durations
            for event in sortedEvents {
                if let duration = event.durationMs {
                    if stageDurations[event.stage] == nil {
                        stageDurations[event.stage] = []
                    }
                    stageDurations[event.stage]?.append(duration)
                }
            }
            
            // Track outcomes
            for event in sortedEvents {
                switch event.outcome {
                case .ok:
                    successCount += 1
                case .error:
                    errorCount += 1
                case .timeout:
                    timeoutCount += 1
                }
            }
            
            // Extract serial RTT (serial_write_start to ack_received)
            if let serialStart = sortedEvents.first(where: { $0.stage == "serial_write_start" }),
               let ackReceived = sortedEvents.first(where: { $0.stage == "ack_received" }) {
                let rttNs = ackReceived.tsMonoNs - serialStart.tsMonoNs
                let rttMs = Double(rttNs) / 1_000_000.0
                serialRTTs.append(rttMs)
            }
        }
        
        // Compute percentiles for each stage
        var stageStats: [String: StageStatistics] = [:]
        for (stage, latencies) in stageLatencies {
            let sorted = latencies.sorted()
            stageStats[stage] = StageStatistics(
                count: sorted.count,
                p50: percentile(sorted, 0.50),
                p95: percentile(sorted, 0.95),
                p99: percentile(sorted, 0.99),
                min: sorted.first,
                max: sorted.last,
                mean: sorted.reduce(0, +) / Double(sorted.count)
            )
        }
        
        // Serial RTT histogram
        let serialRTTStats: StageStatistics?
        if !serialRTTs.isEmpty {
            let sorted = serialRTTs.sorted()
            serialRTTStats = StageStatistics(
                count: sorted.count,
                p50: percentile(sorted, 0.50),
                p95: percentile(sorted, 0.95),
                p99: percentile(sorted, 0.99),
                min: sorted.first,
                max: sorted.last,
                mean: sorted.reduce(0, +) / Double(sorted.count)
            )
        } else {
            serialRTTStats = nil
        }
        
        // Error frequency
        var errorFrequency: [String: Int] = [:]
        for event in events where event.outcome != .ok {
            let key = "\(event.stage):\(event.outcome.rawValue)"
            errorFrequency[key, default: 0] += 1
        }
        
        let totalEvents = events.count
        let successRate = totalEvents > 0 ? Double(successCount) / Double(totalEvents) : 0.0
        
        return MetricsRollup(
            timeWindowMinutes: minutes,
            totalEvents: totalEvents,
            totalTraces: traces.count,
            successRate: successRate,
            successCount: successCount,
            errorCount: errorCount,
            timeoutCount: timeoutCount,
            stageStatistics: stageStats,
            serialRTTStats: serialRTTStats,
            errorFrequency: errorFrequency
        )
    }
    
    /// Calculate percentile from sorted array
    private func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
    
    /// Output human-readable report
    private func outputHumanReadable(_ metrics: MetricsRollup, verbose: Bool) {
        print("\n" + String(repeating: "═", count: 80))
        print("TELEMETRY METRICS ROLLUP")
        print(String(repeating: "═", count: 80))
        print("Time window: \(metrics.timeWindowMinutes) minutes")
        print("Total events: \(metrics.totalEvents)")
        print("Total traces: \(metrics.totalTraces)")
        print()
        
        // Success rate
        print("📊 SUCCESS RATE")
        print(String(repeating: "─", count: 80))
        print(String(format: "  Overall: %.1f%% (%d/%d)", metrics.successRate * 100, metrics.successCount, metrics.totalEvents))
        if metrics.errorCount > 0 {
            print("  Errors: \(metrics.errorCount)")
        }
        if metrics.timeoutCount > 0 {
            print("  Timeouts: \(metrics.timeoutCount)")
        }
        print()
        
        // Stage statistics
        if !metrics.stageStatistics.isEmpty {
            print("⏱️  STAGE LATENCIES")
            print(String(repeating: "─", count: 80))
            for (stage, stats) in metrics.stageStatistics.sorted(by: { $0.key < $1.key }) {
                print("  \(stage):")
                print("    p50: \(formatMs(stats.p50))  p95: \(formatMs(stats.p95))  p99: \(formatMs(stats.p99))")
                if verbose {
                    print("    mean: \(formatMs(stats.mean))  min: \(formatMs(stats.min))  max: \(formatMs(stats.max))  count: \(stats.count)")
                }
            }
            print()
        }
        
        // Serial RTT
        if let rtt = metrics.serialRTTStats {
            print("📡 SERIAL ROUND-TRIP TIME")
            print(String(repeating: "─", count: 80))
            print("  p50: \(formatMs(rtt.p50))  p95: \(formatMs(rtt.p95))  p99: \(formatMs(rtt.p99))")
            if verbose {
                print("  mean: \(formatMs(rtt.mean))  min: \(formatMs(rtt.min))  max: \(formatMs(rtt.max))  count: \(rtt.count)")
            }
            print()
        }
        
        // Error frequency
        if !metrics.errorFrequency.isEmpty {
            print("❌ ERROR FREQUENCY")
            print(String(repeating: "─", count: 80))
            for (error, count) in metrics.errorFrequency.sorted(by: { $0.value > $1.value }) {
                print("  \(error): \(count)")
            }
            print()
        }
        
        print(String(repeating: "═", count: 80))
        print()
    }
    
    /// Output JSON report
    private func outputJSON(_ metrics: MetricsRollup) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(metrics),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }
    
    /// Write summary.json next to log file
    private func writeSummaryJSON(_ metrics: MetricsRollup, logPath: String) throws {
        let logURL = URL(fileURLWithPath: logPath)
        let summaryURL = logURL.deletingLastPathComponent().appendingPathComponent("summary.json")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metrics)
        try data.write(to: summaryURL)
    }
    
    private func formatMs(_ ms: Double?) -> String {
        guard let ms = ms else { return "N/A" }
        return String(format: "%.1f ms", ms)
    }
}

/// Metrics rollup structure
struct MetricsRollup: Codable {
    let timeWindowMinutes: Int
    let totalEvents: Int
    let totalTraces: Int
    let successRate: Double
    let successCount: Int
    let errorCount: Int
    let timeoutCount: Int
    let stageStatistics: [String: StageStatistics]
    let serialRTTStats: StageStatistics?
    let errorFrequency: [String: Int]
}

struct StageStatistics: Codable {
    let count: Int
    let p50: Double?
    let p95: Double?
    let p99: Double?
    let min: Double?
    let max: Double?
    let mean: Double?
}
