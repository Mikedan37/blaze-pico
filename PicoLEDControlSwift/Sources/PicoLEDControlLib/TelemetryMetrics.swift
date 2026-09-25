import Foundation

/// Latency histogram for percentile tracking (p50, p95, p99)
public struct LatencyHistogram {
    private var samples: [Double] = []
    private let maxSamples: Int
    
    public init(maxSamples: Int = 1000) {
        self.maxSamples = maxSamples
    }
    
    /// Add a latency sample (in milliseconds)
    public mutating func record(_ latencyMs: Double) {
        samples.append(latencyMs)
        
        // Keep only recent samples
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
    
    /// Calculate percentile (0.0 to 1.0)
    public func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        
        let sorted = samples.sorted()
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
    
    /// Get p50, p95, p99 latencies
    public func percentiles() -> (p50: Double?, p95: Double?, p99: Double?) {
        return (
            percentile(0.50),
            percentile(0.95),
            percentile(0.99)
        )
    }
    
    /// Get statistics summary
    public func summary() -> LatencySummary {
        guard !samples.isEmpty else {
            return LatencySummary(count: 0, min: nil, max: nil, mean: nil, p50: nil, p95: nil, p99: nil)
        }
        
        let sorted = samples.sorted()
        let min = sorted.first!
        let max = sorted.last!
        let mean = samples.reduce(0, +) / Double(samples.count)
        
        let (p50, p95, p99) = percentiles()
        
        return LatencySummary(
            count: samples.count,
            min: min,
            max: max,
            mean: mean,
            p50: p50,
            p95: p95,
            p99: p99
        )
    }
}

public struct LatencySummary: Codable {
    public let count: Int
    public let min: Double?
    public let max: Double?
    public let mean: Double?
    public let p50: Double?
    public let p95: Double?
    public let p99: Double?
}

/// Command success rate tracker
public struct SuccessRateTracker {
    private var successes: [String: Int] = [:]
    private var failures: [String: Int] = [:]
    
    /// Record a command execution result
    public mutating func record(command: String, success: Bool) {
        if success {
            successes[command, default: 0] += 1
        } else {
            failures[command, default: 0] += 1
        }
    }
    
    /// Get success rate for a command (0.0 to 1.0)
    public func successRate(for command: String) -> Double? {
        let total = successes[command, default: 0] + failures[command, default: 0]
        guard total > 0 else { return nil }
        return Double(successes[command, default: 0]) / Double(total)
    }
    
    /// Get all command statistics
    public func allStats() -> [String: CommandStats] {
        var stats: [String: CommandStats] = [:]
        let allCommands = Set(successes.keys).union(Set(failures.keys))
        
        for command in allCommands {
            let successCount = successes[command, default: 0]
            let failureCount = failures[command, default: 0]
            let total = successCount + failureCount
            let rate = total > 0 ? Double(successCount) / Double(total) : nil
            
            stats[command] = CommandStats(
                total: total,
                successes: successCount,
                failures: failureCount,
                successRate: rate
            )
        }
        
        return stats
    }
}

public struct CommandStats: Codable {
    public let total: Int
    public let successes: Int
    public let failures: Int
    public let successRate: Double?
}

/// LLM decision consistency tracker
/// Tracks voice phrase → command mapping to detect hallucination drift
public struct LLMConsistencyTracker {
    private var mappings: [String: [String: Int]] = [:] // phrase -> command -> count
    
    /// Record a voice phrase → command mapping
    public mutating func record(phrase: String, command: String) {
        if mappings[phrase] == nil {
            mappings[phrase] = [:]
        }
        mappings[phrase]?[command, default: 0] += 1
    }
    
    /// Get consistency score for a phrase (1.0 = always same command, 0.0 = random)
    public func consistency(for phrase: String) -> Double? {
        guard let commands = mappings[phrase], !commands.isEmpty else { return nil }
        
        let total = commands.values.reduce(0, +)
        guard total > 0 else { return nil }
        
        // Find most common command
        let maxCount = commands.values.max() ?? 0
        return Double(maxCount) / Double(total)
    }
    
    /// Detect inconsistent mappings (potential hallucinations)
    public func detectInconsistencies(threshold: Double = 0.9) -> [String: InconsistencyReport] {
        var reports: [String: InconsistencyReport] = [:]
        
        for (phrase, commands) in mappings {
            let total = commands.values.reduce(0, +)
            guard total > 0 else { continue }
            
            let maxCount = commands.values.max() ?? 0
            let consistency = Double(maxCount) / Double(total)
            
            if consistency < threshold {
                // Inconsistent mapping detected
                let commandDistribution = commands.map { (cmd, count) in
                    (cmd, Double(count) / Double(total))
                }.sorted { $0.1 > $1.1 }
                
                reports[phrase] = InconsistencyReport(
                    phrase: phrase,
                    consistency: consistency,
                    totalMappings: total,
                    commandDistribution: commandDistribution
                )
            }
        }
        
        return reports
    }
    
    /// Get all phrase → command mappings
    public func allMappings() -> [String: [String: Int]] {
        return mappings
    }
}

public struct InconsistencyReport: Codable {
    public let phrase: String
    public let consistency: Double
    public let totalMappings: Int
    public let commandDistribution: [(String, Double)]
    
    enum CodingKeys: String, CodingKey {
        case phrase, consistency, totalMappings, commandDistribution
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phrase, forKey: .phrase)
        try container.encode(consistency, forKey: .consistency)
        try container.encode(totalMappings, forKey: .totalMappings)
        
        // Encode commandDistribution as array of objects with String keys
        struct CommandDist: Codable {
            let command: String
            let frequency: Double
        }
        let distArray = commandDistribution.map { CommandDist(command: $0.0, frequency: $0.1) }
        try container.encode(distArray, forKey: .commandDistribution)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phrase = try container.decode(String.self, forKey: .phrase)
        consistency = try container.decode(Double.self, forKey: .consistency)
        totalMappings = try container.decode(Int.self, forKey: .totalMappings)
        
        struct CommandDist: Codable {
            let command: String
            let frequency: Double
        }
        let distArray = try container.decode([CommandDist].self, forKey: .commandDistribution)
        commandDistribution = distArray.map { ($0.command, $0.frequency) }
    }
    
    public init(phrase: String, consistency: Double, totalMappings: Int, commandDistribution: [(String, Double)]) {
        self.phrase = phrase
        self.consistency = consistency
        self.totalMappings = totalMappings
        self.commandDistribution = commandDistribution
    }
}

/// Failure pattern analyzer
public struct FailurePatternAnalyzer {
    private var failures: [FailureRecord] = []
    private let maxRecords: Int
    
    public init(maxRecords: Int = 500) {
        self.maxRecords = maxRecords
    }
    
    /// Record a failure
    public mutating func record(command: String, error: String, timestamp: Date = Date()) {
        failures.append(FailureRecord(
            command: command,
            error: error,
            timestamp: timestamp
        ))
        
        // Keep only recent failures
        if failures.count > maxRecords {
            failures.removeFirst(failures.count - maxRecords)
        }
    }
    
    /// Analyze failure patterns
    public func analyze() -> FailureAnalysis {
        guard !failures.isEmpty else {
            return FailureAnalysis(
                totalFailures: 0,
                errorFrequency: [:],
                commandFailureRate: [:],
                recentTrend: .stable,
                commonErrors: []
            )
        }
        
        // Error frequency
        var errorFreq: [String: Int] = [:]
        for failure in failures {
            errorFreq[failure.error, default: 0] += 1
        }
        
        // Command failure rate
        var commandFailures: [String: Int] = [:]
        for failure in failures {
            commandFailures[failure.command, default: 0] += 1
        }
        
        // Recent trend (last 10 failures vs previous 10)
        let recentTrend: Trend
        if failures.count >= 20 {
            let recent = Array(failures.suffix(10))
            let previous = Array(failures.suffix(20).prefix(10))
            let recentRate = Double(recent.count) / 10.0
            let previousRate = Double(previous.count) / 10.0
            
            if recentRate > previousRate * 1.2 {
                recentTrend = .increasing
            } else if recentRate < previousRate * 0.8 {
                recentTrend = .decreasing
            } else {
                recentTrend = .stable
            }
        } else {
            recentTrend = .stable
        }
        
        // Common errors (top 5)
        let commonErrors = errorFreq.sorted { $0.value > $1.value }.prefix(5).map { $0.key }
        
        return FailureAnalysis(
            totalFailures: failures.count,
            errorFrequency: errorFreq,
            commandFailureRate: commandFailures,
            recentTrend: recentTrend,
            commonErrors: commonErrors
        )
    }
}

public struct FailureRecord: Codable {
    public let command: String
    public let error: String
    public let timestamp: Date
}

public enum Trend: String, Codable {
    case increasing
    case decreasing
    case stable
}

public struct FailureAnalysis: Codable {
    public let totalFailures: Int
    public let errorFrequency: [String: Int]
    public let commandFailureRate: [String: Int]
    public let recentTrend: Trend
    public let commonErrors: [String]
}

/// System drift detector
public struct SystemDriftDetector {
    private var latencyWindows: [[Double]] = [] // Sliding windows of latencies
    private let windowSize: Int
    private let maxWindows: Int
    
    public init(windowSize: Int = 50, maxWindows: Int = 20) {
        self.windowSize = windowSize
        self.maxWindows = maxWindows
    }
    
    /// Record a latency sample
    public mutating func record(_ latencyMs: Double) {
        if latencyWindows.isEmpty || latencyWindows.last!.count >= windowSize {
            // Start new window
            latencyWindows.append([latencyMs])
        } else {
            // Add to current window
            latencyWindows[latencyWindows.count - 1].append(latencyMs)
        }
        
        // Keep only recent windows
        if latencyWindows.count > maxWindows {
            latencyWindows.removeFirst()
        }
    }
    
    /// Detect drift (comparing recent windows to baseline)
    public func detectDrift(baselineWindows: Int = 5, threshold: Double = 1.2) -> DriftReport? {
        guard latencyWindows.count >= baselineWindows + 2 else { return nil }
        
        // Baseline: first N windows
        let baseline = Array(latencyWindows.prefix(baselineWindows))
        let baselineMean = baseline.flatMap { $0 }.reduce(0, +) / Double(baseline.flatMap { $0 }.count)
        
        // Recent: last 2 windows
        let recent = Array(latencyWindows.suffix(2))
        let recentMean = recent.flatMap { $0 }.reduce(0, +) / Double(recent.flatMap { $0 }.count)
        
        let ratio = recentMean / baselineMean
        
        if ratio > threshold {
            return DriftReport(
                detected: true,
                baselineMean: baselineMean,
                recentMean: recentMean,
                driftRatio: ratio,
                severity: ratio > 2.0 ? .severe : .moderate
            )
        }
        
        return DriftReport(
            detected: false,
            baselineMean: baselineMean,
            recentMean: recentMean,
            driftRatio: ratio,
            severity: .none
        )
    }
}

public enum DriftSeverity: String, Codable {
    case none
    case moderate
    case severe
}

public struct DriftReport: Codable {
    public let detected: Bool
    public let baselineMean: Double
    public let recentMean: Double
    public let driftRatio: Double
    public let severity: DriftSeverity
}

/// Central telemetry metrics collector
public class TelemetryMetrics {
    public static let shared = TelemetryMetrics()
    
    // Latency histograms by stage
    public var voiceToLLM: LatencyHistogram
    public var llmProcessing: LatencyHistogram
    public var llmToAgent: LatencyHistogram
    public var agentToSerial: LatencyHistogram
    public var serialToAck: LatencyHistogram
    public var totalLatency: LatencyHistogram
    
    // Success rate tracking
    public var successRate: SuccessRateTracker
    
    // LLM consistency tracking
    public var llmConsistency: LLMConsistencyTracker
    
    // Failure analysis
    public var failureAnalyzer: FailurePatternAnalyzer
    
    // System drift detection
    public var driftDetector: SystemDriftDetector
    
    private init() {
        self.voiceToLLM = LatencyHistogram()
        self.llmProcessing = LatencyHistogram()
        self.llmToAgent = LatencyHistogram()
        self.agentToSerial = LatencyHistogram()
        self.serialToAck = LatencyHistogram()
        self.totalLatency = LatencyHistogram()
        self.successRate = SuccessRateTracker()
        self.llmConsistency = LLMConsistencyTracker()
        self.failureAnalyzer = FailurePatternAnalyzer()
        self.driftDetector = SystemDriftDetector()
    }
    
    /// Record a complete pipeline execution
    public func recordPipeline(
        voiceToLLM: Double?,
        llmProcessing: Double?,
        llmToAgent: Double?,
        agentToSerial: Double?,
        serialToAck: Double?,
        total: Double?,
        command: String,
        success: Bool,
        voicePhrase: String? = nil,
        llmCommand: String? = nil
    ) {
        if let latency = voiceToLLM { self.voiceToLLM.record(latency) }
        if let latency = llmProcessing { self.llmProcessing.record(latency) }
        if let latency = llmToAgent { self.llmToAgent.record(latency) }
        if let latency = agentToSerial { self.agentToSerial.record(latency) }
        if let latency = serialToAck { self.serialToAck.record(latency) }
        if let latency = total { self.totalLatency.record(latency) }
        
        successRate.record(command: command, success: success)
        
        if let phrase = voicePhrase, let cmd = llmCommand {
            llmConsistency.record(phrase: phrase, command: cmd)
        }
        
        if let latency = total {
            driftDetector.record(latency)
        }
        
        if !success {
            failureAnalyzer.record(command: command, error: "Command failed")
        }
    }
    
    /// Generate comprehensive metrics report
    public func generateReport() -> MetricsReport {
        return MetricsReport(
            latencyStats: LatencyStats(
                voiceToLLM: voiceToLLM.summary(),
                llmProcessing: llmProcessing.summary(),
                llmToAgent: llmToAgent.summary(),
                agentToSerial: agentToSerial.summary(),
                serialToAck: serialToAck.summary(),
                total: totalLatency.summary()
            ),
            successRates: successRate.allStats(),
            llmInconsistencies: llmConsistency.detectInconsistencies(),
            failureAnalysis: failureAnalyzer.analyze(),
            driftReport: driftDetector.detectDrift()
        )
    }
    
    /// Print formatted metrics report
    public func printReport() {
        let report = generateReport()
        
        print("\n" + String(repeating: "═", count: 80))
        print("TELEMETRY METRICS REPORT")
        print(String(repeating: "═", count: 80))
        
        // Latency percentiles
        print("\n📊 LATENCY STATISTICS")
        print(String(repeating: "─", count: 80))
        if let total = report.latencyStats.total {
            print("Total Pipeline:")
            print("  p50: \(formatMs(total.p50))  p95: \(formatMs(total.p95))  p99: \(formatMs(total.p99))")
            print("  mean: \(formatMs(total.mean))  min: \(formatMs(total.min))  max: \(formatMs(total.max))")
        }
        
        print("\nStage Breakdown:")
        print("  Voice → LLM:        p50: \(formatMs(report.latencyStats.voiceToLLM.p50))  p95: \(formatMs(report.latencyStats.voiceToLLM.p95))")
        print("  LLM Processing:     p50: \(formatMs(report.latencyStats.llmProcessing.p50))  p95: \(formatMs(report.latencyStats.llmProcessing.p95))")
        print("  LLM → Agent:        p50: \(formatMs(report.latencyStats.llmToAgent.p50))  p95: \(formatMs(report.latencyStats.llmToAgent.p95))")
        print("  Agent → Serial:     p50: \(formatMs(report.latencyStats.agentToSerial.p50))  p95: \(formatMs(report.latencyStats.agentToSerial.p95))")
        print("  Serial → ACK:       p50: \(formatMs(report.latencyStats.serialToAck.p50))  p95: \(formatMs(report.latencyStats.serialToAck.p95))")
        
        // Success rates
        print("\n✅ SUCCESS RATES")
        print(String(repeating: "─", count: 80))
        for (command, stats) in report.successRates.sorted(by: { $0.key < $1.key }) {
            let rate = stats.successRate.map { String(format: "%.1f%%", $0 * 100) } ?? "N/A"
            print("  \(command): \(rate) (\(stats.successes)/\(stats.total))")
        }
        
        // LLM inconsistencies
        if !report.llmInconsistencies.isEmpty {
            print("\n⚠️  LLM CONSISTENCY ISSUES")
            print(String(repeating: "─", count: 80))
            for (phrase, report) in report.llmInconsistencies.sorted(by: { $0.value.consistency < $1.value.consistency }) {
                let consistency = String(format: "%.1f%%", report.consistency * 100)
                print("  \"\(phrase)\": \(consistency) consistency")
                print("    Top commands:")
                for (cmd, freq) in report.commandDistribution.prefix(3) {
                    print("      \(cmd): \(String(format: "%.1f%%", freq * 100))")
                }
            }
        }
        
        // Failure analysis
        if report.failureAnalysis.totalFailures > 0 {
            print("\n❌ FAILURE ANALYSIS")
            print(String(repeating: "─", count: 80))
            print("  Total failures: \(report.failureAnalysis.totalFailures)")
            print("  Trend: \(report.failureAnalysis.recentTrend.rawValue)")
            if !report.failureAnalysis.commonErrors.isEmpty {
                print("  Common errors:")
                for error in report.failureAnalysis.commonErrors {
                    let count = report.failureAnalysis.errorFrequency[error] ?? 0
                    print("    - \(error): \(count)")
                }
            }
        }
        
        // Drift detection
        if let drift = report.driftReport, drift.detected {
            print("\n📈 SYSTEM DRIFT DETECTED")
            print(String(repeating: "─", count: 80))
            print("  Severity: \(drift.severity.rawValue)")
            print("  Baseline mean: \(formatMs(drift.baselineMean))")
            print("  Recent mean: \(formatMs(drift.recentMean))")
            print("  Drift ratio: \(String(format: "%.2fx", drift.driftRatio))")
        }
        
        print("\n" + String(repeating: "═", count: 80) + "\n")
    }
    
    private func formatMs(_ ms: Double?) -> String {
        guard let ms = ms else { return "N/A" }
        return String(format: "%.1f ms", ms)
    }
}

public struct MetricsReport: Codable {
    public let latencyStats: LatencyStats
    public let successRates: [String: CommandStats]
    public let llmInconsistencies: [String: InconsistencyReport]
    public let failureAnalysis: FailureAnalysis
    public let driftReport: DriftReport?
}

public struct LatencyStats: Codable {
    public let voiceToLLM: LatencySummary
    public let llmProcessing: LatencySummary
    public let llmToAgent: LatencySummary
    public let agentToSerial: LatencySummary
    public let serialToAck: LatencySummary
    public let total: LatencySummary?
}
