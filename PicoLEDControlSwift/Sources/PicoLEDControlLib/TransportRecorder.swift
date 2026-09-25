import Foundation
import Combine

/// Records all serial read/write operations with timestamps for deterministic replay.
/// Sits as a transparent proxy between PicoSession and SerialPort.
/// Usage: wrap a SerialPort in TransportRecorder, pass to PicoSession.
///
/// Recording format (JSONL):
///   {"ts": 1234567890.123, "dir": "tx", "hex": "DEADBEEF", "len": 4}
///   {"ts": 1234567890.456, "dir": "rx", "hex": "CAFEBABE", "len": 4}
///   {"ts": 1234567890.789, "dir": "rx_empty", "len": 0}
///   {"ts": 1234567891.000, "dir": "error", "msg": "ENXIO"}
public final class TransportRecorder {
    
    public struct TransportEvent: Codable {
        public let ts: TimeInterval
        public let dir: String      // "tx", "rx", "rx_empty", "error"
        public let hex: String?
        public let len: Int
        public let msg: String?
        
        public init(dir: String, data: Data? = nil, msg: String? = nil) {
            self.ts = Date().timeIntervalSince1970
            self.dir = dir
            self.hex = data?.map { String(format: "%02x", $0) }.joined()
            self.len = data?.count ?? 0
            self.msg = msg
        }
    }
    
    private let outputURL: URL
    private let fileHandle: FileHandle
    private let encoder = JSONEncoder()
    private let lock = NSLock()
    private var eventCount: Int = 0
    
    /// Live event stream for real-time monitoring
    public let events = PassthroughSubject<TransportEvent, Never>()
    
    public var recordedEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventCount
    }
    
    public init(outputPath: String) throws {
        self.outputURL = URL(fileURLWithPath: outputPath)
        
        let dir = outputURL.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: outputURL)
        fileHandle.seekToEndOfFile()
    }
    
    public func recordTX(_ data: Data) {
        let event = TransportEvent(dir: "tx", data: data)
        write(event)
    }
    
    public func recordRX(_ data: Data) {
        if data.isEmpty {
            let event = TransportEvent(dir: "rx_empty")
            write(event)
        } else {
            let event = TransportEvent(dir: "rx", data: data)
            write(event)
        }
    }
    
    public func recordError(_ error: Error) {
        let event = TransportEvent(dir: "error", msg: "\(error)")
        write(event)
    }
    
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle.close()
    }
    
    private func write(_ event: TransportEvent) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let jsonData = try? encoder.encode(event),
              var line = String(data: jsonData, encoding: .utf8) else { return }
        line += "\n"
        if let lineData = line.data(using: .utf8) {
            fileHandle.write(lineData)
        }
        eventCount += 1
        events.send(event)
    }
}

/// Replays a recorded transport session for deterministic testing.
/// Provides rx data in sequence; tx calls are recorded for verification.
public final class TransportReplayer {
    
    public struct ReplayStats {
        public var rxEventsPlayed: Int = 0
        public var txEventsReceived: Int = 0
        public var errorsReplayed: Int = 0
        public var txMismatches: [(expected: Data?, actual: Data)] = []
    }
    
    private var rxEvents: [TransportRecorder.TransportEvent] = []
    private var txEvents: [TransportRecorder.TransportEvent] = []
    private var rxIndex: Int = 0
    private var txIndex: Int = 0
    public private(set) var stats = ReplayStats()
    
    public init(recordingPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: recordingPath))
        let decoder = JSONDecoder()
        let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
        
        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(TransportRecorder.TransportEvent.self, from: lineData) else { continue }
            
            switch event.dir {
            case "rx", "rx_empty":
                rxEvents.append(event)
            case "tx":
                txEvents.append(event)
            case "error":
                rxEvents.append(event)
            default:
                break
            }
        }
    }
    
    /// Returns the next rx data from the recording (empty Data for rx_empty, throws for errors)
    public func nextRX() throws -> Data {
        guard rxIndex < rxEvents.count else {
            return Data()
        }
        
        let event = rxEvents[rxIndex]
        rxIndex += 1
        stats.rxEventsPlayed += 1
        
        if event.dir == "error" {
            stats.errorsReplayed += 1
            throw SerialPortError.readFailed(errno: 6) // ENXIO
        }
        
        if event.dir == "rx_empty" {
            return Data()
        }
        
        guard let hex = event.hex else { return Data() }
        return Data(hexString: hex)
    }
    
    /// Record a tx event and verify against expected sequence
    public func recordTX(_ data: Data) {
        stats.txEventsReceived += 1
        
        if txIndex < txEvents.count {
            let expected = txEvents[txIndex]
            if let expectedHex = expected.hex {
                let expectedData = Data(hexString: expectedHex)
                if expectedData != data {
                    stats.txMismatches.append((expected: expectedData, actual: data))
                }
            }
            txIndex += 1
        }
    }
    
    public var isComplete: Bool {
        rxIndex >= rxEvents.count
    }
    
    public var summary: String {
        """
        Replay complete:
          RX events played: \(stats.rxEventsPlayed)/\(rxEvents.count)
          TX events received: \(stats.txEventsReceived)/\(txEvents.count)
          Errors replayed: \(stats.errorsReplayed)
          TX mismatches: \(stats.txMismatches.count)
        """
    }
}

extension Data {
    init(hexString: String) {
        self.init()
        var hex = hexString
        while hex.count >= 2 {
            let byte = String(hex.prefix(2))
            hex = String(hex.dropFirst(2))
            if let b = UInt8(byte, radix: 16) {
                append(b)
            }
        }
    }
}
