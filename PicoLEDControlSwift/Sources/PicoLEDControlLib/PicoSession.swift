import Foundation
import Combine

/// Device event types emitted by the Pico
public enum PicoEventType {
    case boot(BootEvent)
    case status(StatusEvent)
    case trace(TraceEvent)
    case ack(AckEvent)
    case gpio(GPIOEvent)
    case heartbeat(HeartbeatEvent)
    case error(ErrorEvent)
}

/// Boot sequence event
public struct BootEvent {
    public let stage: String  // GPIO_INIT, GPIO_TEST, GPIO_OK, USB_WAIT, USB_OK
    public let bootTimestamp: UInt64?
    public let readyTimestamp: UInt64?
}

/// Status query response event
public struct StatusEvent {
    public let status: String  // OK, ERROR
    public let gpio: [String: Bool]
    public let uptimeMs: UInt64?
    public let firmware: String?
    public let ready: Bool
}

/// Trace telemetry event from firmware
public struct TraceEvent {
    public let traceID: UInt64
    public let commandID: UInt8
    public let value: UInt8
    public let execUs: UInt64?
    public let gpioFeedback: Bool?
}

/// ACK event
public struct AckEvent {
    public let traceID: UInt64
    public let commandID: UInt8
    public let value: UInt8
    public let gpioFeedback: Bool?
}

/// GPIO state change event
public struct GPIOEvent {
    public let pin: Int
    public let state: Bool
    public let timestamp: Date
}

/// Heartbeat/watchdog event
public struct HeartbeatEvent {
    public let uptimeMs: UInt64
    public let memoryFree: UInt32?
    public let errorCount: UInt32?
    public let timestamp: Date
}

/// Error event
public struct ErrorEvent {
    public let message: String
    public let code: Int?
    public let timestamp: Date
}

/// Persistent session for a Pico device
/// Maintains open serial connection and streams events asynchronously
/// RULE 5: Serial write must be single writer - all writes serialized via writeLock
///
/// LOCK ORDER (never acquire a lower lock while holding a higher one):
///   1. sessionStateLock     (session lifecycle: isConnected, isReady, sequence, identity)
///   2. gpioStateLock        (GPIO state cache)
///   3. pendingCommandsLock  (in-flight command tracking)
///   4. completedTracesLock  (ACK idempotency set)
///   5. commandQueueLock     (batch command queue)
///   6. invalidationLock     (session invalidation flag)
///   7. writeLock            (serial port writes -- always innermost)
public final class PicoSession: ObservableObject, @unchecked Sendable {
    /// Lossy ASCII conversion that never fails — strips non-printable bytes instead of
    /// returning nil when a single binary byte corrupts the UTF-8 decode.
    private static func resilientString(from data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data.map { (0x0A...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "?" })
    }

    private let serialPort: SerialPort
    public let deviceID: String
    
    // Session lifecycle state -- all protected by sessionStateLock
    private var _isConnected: Bool = false
    private var _isReady: Bool = false
    private var _bootTimestamp: UInt64?
    private var _readyTimestamp: UInt64?
    private var _lastHeartbeat: Date?
    private var _currentSessionID: UInt32? = nil
    private var _lastAppliedSequence: UInt64 = 0
    private var _lastKnownBootTimestamp: UInt64?
    private var _packetNumber: UInt32 = 1
    private var _reconnectAttempts: Int = 0
    private let sessionStateLock = NSLock()
    
    public private(set) var isConnected: Bool {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _isConnected }
        set { sessionStateLock.lock(); _isConnected = newValue; sessionStateLock.unlock() }
    }
    public private(set) var isReady: Bool {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _isReady }
        set { sessionStateLock.lock(); _isReady = newValue; sessionStateLock.unlock() }
    }
    private var bootTimestamp: UInt64? {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _bootTimestamp }
        set { sessionStateLock.lock(); _bootTimestamp = newValue; sessionStateLock.unlock() }
    }
    private var readyTimestamp: UInt64? {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _readyTimestamp }
        set { sessionStateLock.lock(); _readyTimestamp = newValue; sessionStateLock.unlock() }
    }
    private var lastHeartbeat: Date? {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _lastHeartbeat }
        set { sessionStateLock.lock(); _lastHeartbeat = newValue; sessionStateLock.unlock() }
    }
    private var currentSessionID: UInt32? {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _currentSessionID }
        set { sessionStateLock.lock(); _currentSessionID = newValue; sessionStateLock.unlock() }
    }
    private var lastAppliedSequence: UInt64 {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _lastAppliedSequence }
        set { sessionStateLock.lock(); _lastAppliedSequence = newValue; sessionStateLock.unlock() }
    }
    private var lastKnownBootTimestamp: UInt64? {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _lastKnownBootTimestamp }
        set { sessionStateLock.lock(); _lastKnownBootTimestamp = newValue; sessionStateLock.unlock() }
    }
    private var packetNumber: UInt32 {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _packetNumber }
        set { sessionStateLock.lock(); _packetNumber = newValue; sessionStateLock.unlock() }
    }
    private var reconnectAttempts: Int {
        get { sessionStateLock.lock(); defer { sessionStateLock.unlock() }; return _reconnectAttempts }
        set { sessionStateLock.lock(); _reconnectAttempts = newValue; sessionStateLock.unlock() }
    }
    
    // RULE 5: Single writer lock for serial writes (prevents concurrent USB writes)
    private let writeLock = NSLock()
    
    // CRITICAL GAP #2: Session invalidation (prevents zombie FD writes during recovery)
    private var isInvalidated = false
    private let invalidationLock = NSLock()
    
    // Event stream
    public let events = PassthroughSubject<PicoEventType, Never>()
    
    // Background reader task
    private var readerTask: Task<Void, Never>?
    private var heartbeatMonitorTask: Task<Void, Never>?
    private let readerQueue = DispatchQueue(label: "com.blaze.pico.reader")
    
    // ACK idempotency protection (prevents double ACK arrival bugs)
    // CRITICAL: Track completed trace IDs to ignore duplicate ACKs
    // BOUNDED SET: Capped at 1000 traces with random eviction (prevents unbounded memory growth)
    private var completedTraces: Set<UInt64> = []
    private let completedTracesLock = NSLock()
    private let maxCompletedTraces = 1000
    
    // Pending command tracking (for session change failure)
    // CRITICAL: Track pending commands to fail them on session change
    // BOUNDED SET: Cap at 100 pending commands, fail fast if exceeded
    private var pendingCommands: [UInt64: (commandID: CommandID, value: UInt8, startTime: Date)] = [:]
    private let pendingCommandsLock = NSLock()
    private let maxPendingCommands = 100
    
    private let maxReconnectAttempts: Int = 5
    
    // Command queue for automatic batching
    private var commandQueue: [(CommandID, UInt8, UInt64?)] = [] // (commandID, value, traceID?)
    private let commandQueueLock = NSLock()
    private var batchFlushTask: Task<Void, Never>?
    private let batchWindowMs: Int = 3 // Short batch window for multiple commands (reduced from 20ms)
    private let maxBatchSize: Int = 16 // Maximum commands per batch (firmware limit)
    
    // Last known GPIO state from any source (boot STATE, QUERY_STATE, STATE_CHANGE)
    private var _lastKnownGPIOState: [String: Bool]?
    private var _lastKnownServoAngle: Int?
    private var _deviceCapabilities: DeviceCapabilities?
    private let gpioStateLock = NSLock()
    
    // Generic text command response handler
    // Used by sendTextCommand() to wait for a firmware response matching a prefix.
    // Only one text command can be in-flight at a time (serialized by textCommandQueue).
    private var pendingTextResponse: (prefix: String, continuation: CheckedContinuation<String?, Never>)?
    private let pendingTextResponseLock = NSLock()
    private let textCommandQueue = DispatchQueue(label: "com.blaze.pico.textcmd")
    
    // Multi-line response handler for BEGIN/END delimited blocks (PINMAP, DEVICE_INFO)
    private var pendingMultiLineResponse: (endMarker: String, lines: [String], continuation: CheckedContinuation<[String], Never>)?
    private let pendingMultiLineLock = NSLock()
    
    /// Thread-safe last known GPIO state from any firmware response
    public var lastKnownGPIOState: [String: Bool]? {
        gpioStateLock.lock()
        defer { gpioStateLock.unlock() }
        return _lastKnownGPIOState
    }
    
    /// Thread-safe last known servo angle from any firmware response
    public var lastKnownServoAngle: Int? {
        gpioStateLock.lock()
        defer { gpioStateLock.unlock() }
        return _lastKnownServoAngle
    }
    
    /// Thread-safe device capabilities (populated on connect)
    public var deviceCapabilities: DeviceCapabilities? {
        gpioStateLock.lock()
        defer { gpioStateLock.unlock() }
        return _deviceCapabilities
    }
    
    public init(portPath: String, deviceID: String? = nil) {
        self.serialPort = SerialPort(path: portPath)
        self.deviceID = deviceID ?? "blaze-pico-\(UUID().uuidString.prefix(8))"
    }
    
    /// Connect to device and start event stream
    public func connect(timeoutMs: Int = 2000) async throws {
        guard !isConnected else { return }
        
        // Reset session tracking atomically on new connection
        sessionStateLock.lock()
        _currentSessionID = nil
        _lastAppliedSequence = 0
        _reconnectAttempts = 0
        sessionStateLock.unlock()
        
        // Open serial port
        try serialPort.open(baudRate: 115200)
        
        let readyReceived: Bool
        do {
            readyReceived = try await waitForReady(timeoutMs: timeoutMs)
        } catch {
            serialPort.close()
            throw error
        }
        
        isConnected = true
        
        if readyReceived {
            // BLAZE_READY received (push lifecycle event).
            // This GUARANTEES: GPIO init, timers, heartbeat, USB CDC stable.
            // STATUS probe is supplementary — BLAZE_READY is authoritative.
            isReady = true
            let transportVerified = try await verifyTransport()
            if transportVerified {
                print("[PicoSession] ✅ BLAZE_READY + STATUS probe confirmed — commands enabled")
            } else {
                print("[PicoSession] ✅ BLAZE_READY received — commands enabled (STATUS probe unavailable, firmware may be older)")
            }
            fflush(stdout)
        } else {
            // BLAZE_READY missed (firmware booted before we connected).
            // CMD_STATUS is the pull-based fallback to determine readiness.
            print("[PicoSession] ⚠️ BLAZE_READY not received — sending STATUS probe...")
            fflush(stdout)
            let transportVerified = try await verifyTransport()
            if transportVerified {
                isReady = true
                print("[PicoSession] ✅ STATUS probe confirmed ready (late-join recovery)")
                fflush(stdout)
            } else {
                isReady = false
                print("[PicoSession] ⚠️ STATUS probe failed — commands blocked until event reader detects readiness")
                fflush(stdout)
            }
        }
        
        // Query device capabilities before starting event reader
        // (uses raw serial reads since event reader isn't running yet)
        if isReady {
            do {
                let caps = try queryDeviceCapabilities()
                gpioStateLock.lock()
                _deviceCapabilities = caps
                gpioStateLock.unlock()
                print("[PicoSession] Device: \(caps.summary)")
                fflush(stdout)
            } catch {
                print("[PicoSession] Capability query failed (non-fatal): \(error)")
                fflush(stdout)
            }
        }
        
        // Start event reader
        startEventReader()
        
        // Start heartbeat monitoring
        startHeartbeatMonitor()
    }
    
    /// Disconnect from device
    public func disconnect() {
        // Cancel batch flush task
        batchFlushTask?.cancel()
        batchFlushTask = nil
        
        // Cancel heartbeat monitor task
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
        
        // Clear command queue (commands will be lost, but that's expected on disconnect)
        commandQueueLock.lock()
        let pendingCount = commandQueue.count
        commandQueue.removeAll()
        commandQueueLock.unlock()
        
        if pendingCount > 0 {
            print("[PicoSession] ⚠️ Disconnecting with \(pendingCount) commands in queue (discarded)")
            fflush(stdout)
        }
        
        readerTask?.cancel()
        readerTask = nil
        serialPort.close()
        sessionStateLock.lock()
        _isConnected = false
        _isReady = false
        sessionStateLock.unlock()
        
        // Resume any pending text/multi-line continuations to prevent callers from hanging
        pendingTextResponseLock.lock()
        let pendingText = pendingTextResponse
        pendingTextResponse = nil
        pendingTextResponseLock.unlock()
        pendingText?.continuation.resume(returning: nil)
        
        pendingMultiLineLock.lock()
        let pendingMultiLine = pendingMultiLineResponse
        pendingMultiLineResponse = nil
        pendingMultiLineLock.unlock()
        pendingMultiLine?.continuation.resume(returning: [])
    }
    
    /// CRITICAL GAP #2: Invalidate session (prevents all future operations)
    /// Called during recovery to cancel active writes/reads
    /// HARDENING #1: Idempotent - safe to call multiple times
    /// HARDENING #2: Closes FD to break kernel-blocked IO immediately
    /// HARDENING #3: Emits SESSION_INVALIDATED event for telemetry
    public func invalidate() {
        // Acquire invalidationLock only to CAS the flag, then release before taking other locks.
        // This preserves lock order: sessionStateLock(1) > commandQueueLock(5) > invalidationLock(6).
        invalidationLock.lock()
        let wasAlreadyInvalidated = isInvalidated
        if !wasAlreadyInvalidated { isInvalidated = true }
        invalidationLock.unlock()
        
        guard !wasAlreadyInvalidated else {
            print("[PicoSession] ⚠️ Invalidate() called on already-invalidated session (deviceID: \(deviceID))")
            return
        }
        
        // Cancel batch flush task
        batchFlushTask?.cancel()
        batchFlushTask = nil
        
        // Cancel heartbeat monitor task
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
        
        // Clear command queue (commands will be lost during invalidation)
        commandQueueLock.lock()
        let pendingCount = commandQueue.count
        commandQueue.removeAll()
        commandQueueLock.unlock()
        
        if pendingCount > 0 {
            print("[PicoSession] ⚠️ Invalidating session with \(pendingCount) commands in queue (discarded)")
            fflush(stdout)
        }
        
        // HARDENING #2: Close FD immediately to break kernel-blocked IO
        // This unblocks any pending read()/write() calls in the kernel
        sessionStateLock.lock()
        let wasConnected = _isConnected
        _isConnected = false
        _isReady = false
        sessionStateLock.unlock()
        
        if wasConnected {
            print("[PicoSession] 🔴 Closing FD to break kernel-blocked IO (deviceID: \(deviceID))")
            serialPort.close()
            readerTask?.cancel()
        }
        
        // Resume any pending text/multi-line continuations to prevent callers from hanging
        pendingTextResponseLock.lock()
        let pendingText = pendingTextResponse
        pendingTextResponse = nil
        pendingTextResponseLock.unlock()
        pendingText?.continuation.resume(returning: nil)
        
        pendingMultiLineLock.lock()
        let pendingMultiLine = pendingMultiLineResponse
        pendingMultiLineResponse = nil
        pendingMultiLineLock.unlock()
        pendingMultiLine?.continuation.resume(returning: [])
        
        // HARDENING #3: Emit lifecycle event for telemetry/diagnosis
        events.send(.error(ErrorEvent(
            message: "SESSION_INVALIDATED: Session invalidated during recovery (deviceID: \(deviceID))",
            code: -99,
            timestamp: Date()
        )))
        
        print("[PicoSession] Session invalidated (deviceID: \(deviceID), FD closed)")
    }
    
    /// CRITICAL GAP #2: Check if session is still valid
    public var isValid: Bool {
        invalidationLock.lock()
        defer { invalidationLock.unlock() }
        return !isInvalidated
    }
    
    /// Wait for device readiness (BLAZE_READY)
    /// Wait for device ready signal
    /// RULE 6: Serial response timeout must be short (150ms for hardware response)
    /// Default timeout reduced to 2s for faster failure if device not connected
    private func waitForReady(timeoutMs: Int = 2000) async throws -> Bool {
        print("[PicoSession] Waiting for BLAZE_READY signal (timeout: \(timeoutMs)ms)...")
        fflush(stdout)
        
        let startTime = Date()
        let timeoutSeconds = Double(timeoutMs) / 1000.0
        
        var buffer = Data()
        
        while Date().timeIntervalSince(startTime) < timeoutSeconds {
            let data = try serialPort.read(maxBytes: 256, timeoutMs: 100)
            buffer.append(data)
            
            let text = Self.resilientString(from: buffer)

            if text.contains("BLAZE_READY") {
                print("[PicoSession] ✅ BLAZE_READY received!")
                fflush(stdout)
                parseBootTimestamps(text)
                return true
            }
            
            if text.contains("HEARTBEAT:") && text.contains("READY:1") {
                print("[PicoSession] ✅ HEARTBEAT with READY:1 detected - device already running (late-join)")
                fflush(stdout)
                return true
            }

            if text.contains("HEARTBEAT:") {
                print("[PicoSession] ✅ HEARTBEAT detected during waitForReady - device is alive")
                fflush(stdout)
                return true
            }
            
            if buffer.count > 512 {
                buffer = buffer.suffix(512)
            }
        }
        
        return false
    }
    
    /// Layer 3 transport verification: send a real binary QUERY_STATE packet and read a response.
    /// Confirms the USB CDC bidirectional channel is alive after BLAZE_READY.
    /// Pull-based health probe: sends CMD_STATUS and checks for `ready=1`.
    /// Complements the push-based BLAZE_READY lifecycle event.
    ///   - BLAZE_READY = boot finished (push, once per session)
    ///   - CMD_STATUS  = health check  (pull, on demand)
    ///   - ACK         = command confirmation (neither readiness nor health)
    private func verifyTransport(maxRetries: Int = 3) async throws -> Bool {
        for attempt in 1...maxRetries {
            print("[PicoSession] 🔍 STATUS probe attempt \(attempt)/\(maxRetries)...")
            fflush(stdout)
            
            do {
                let probeTraceID = generateTraceID()
                var payload = Data()
                payload.append(0x00) // frameType
                payload.append(contentsOf: withUnsafeBytes(of: probeTraceID.bigEndian) { Data($0) })
                payload.append(CommandID.status.rawValue) // 21
                payload.append(0) // value (unused for STATUS)
                
                let packet = buildBlazePacket(payload: payload)
                let packetData = PacketEncoder.encode(packet)
                var fullPacket = Data("BLAZ".utf8)
                fullPacket.append(packetData)
                
                try serialPort.write(fullPacket)
                
                let response = try serialPort.read(maxBytes: 512, timeoutMs: 1000)
                let text = Self.resilientString(from: response)

                if text.contains("STATUS:") && text.contains("ready=1") {
                    print("[PicoSession] ✅ STATUS probe: device ready (\(text.prefix(90).trimmingCharacters(in: .whitespacesAndNewlines)))")
                    fflush(stdout)
                    return true
                }

                if text.contains("STATUS:") && text.contains("ready=0") {
                    print("[PicoSession] ⚠️ STATUS probe: device alive but not ready yet")
                    fflush(stdout)
                }

                // Accept HEARTBEAT with READY:1 as equivalent (firmware may not have CMD_STATUS yet)
                if text.contains("HEARTBEAT") && text.contains("READY:1") {
                    print("[PicoSession] ✅ Fallback: HEARTBEAT READY:1 received — device ready")
                    fflush(stdout)
                    return true
                }
                
                if text.contains("HEARTBEAT") {
                    print("[PicoSession] ✅ Fallback: HEARTBEAT received — device alive")
                    fflush(stdout)
                    return true
                }

                print("[PicoSession] ⚠️ STATUS probe attempt \(attempt): no match in \(response.count) bytes: '\(text.prefix(80))'")
                fflush(stdout)
                
                if attempt < maxRetries {
                    usleep(200_000)
                }
            } catch {
                print("[PicoSession] ⚠️ STATUS probe attempt \(attempt) failed: \(error)")
                fflush(stdout)
                if attempt < maxRetries {
                    usleep(300_000)
                }
            }
        }
        
        print("[PicoSession] 🔴 STATUS probe failed after \(maxRetries) attempts")
        fflush(stdout)
        return false
    }
    
    /// Query DEVICE_INFO + PINMAP during the connect handshake (before event reader starts).
    /// Uses raw serial reads. Tolerates interleaved heartbeat lines.
    private func queryDeviceCapabilities() throws -> DeviceCapabilities {
        // --- DEVICE_INFO ---
        let infoCmd = Data("DEVICE_INFO\n".utf8)
        try serialPort.write(infoCmd)
        let infoLines = try readMultiLineResponse(begin: "DEVICE_INFO_BEGIN", end: "DEVICE_INFO_END", timeoutMs: 2000)
        var caps = DeviceCapabilities.parseDeviceInfo(lines: infoLines)
        
        // --- PINMAP ---
        let pinmapCmd = Data("PINMAP\n".utf8)
        try serialPort.write(pinmapCmd)
        let pinLines = try readMultiLineResponse(begin: "PINMAP_BEGIN", end: "PINMAP_END", timeoutMs: 2000)
        caps.pins = DeviceCapabilities.parsePinMap(lines: pinLines)
        
        return caps
    }
    
    /// Read a multi-line BEGIN/END delimited response from serial.
    /// Discards lines outside the BEGIN/END block (heartbeats, etc.).
    private func readMultiLineResponse(begin: String, end: String, timeoutMs: Int) throws -> [String] {
        let startTime = Date()
        let timeoutSeconds = Double(timeoutMs) / 1000.0
        var buffer = Data()
        var insideBlock = false
        var lines: [String] = []
        
        while Date().timeIntervalSince(startTime) < timeoutSeconds {
            let data = try serialPort.read(maxBytes: 512, timeoutMs: 100)
            buffer.append(data)
            
            let text = Self.resilientString(from: buffer)
            let allLines = text.components(separatedBy: "\n")
            
            // Keep the last (possibly incomplete) line in the buffer
            let complete = allLines.dropLast()
            if let lastPart = allLines.last {
                buffer = Data(lastPart.utf8)
            }
            
            for line in complete {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                
                if trimmed == begin {
                    insideBlock = true
                    continue
                }
                if trimmed == end {
                    return lines
                }
                if insideBlock {
                    // Filter out interleaved noise (heartbeats, debug output, etc.)
                    let isNoise = trimmed.hasPrefix("HEARTBEAT:") ||
                                  trimmed.hasPrefix("[") ||
                                  trimmed.hasPrefix("BOOT:") ||
                                  trimmed.hasPrefix("DEBUG:")
                    if !isNoise {
                        lines.append(trimmed)
                    }
                }
            }
        }
        
        throw NSError(domain: "PicoSession", code: -10,
                      userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for \(begin)...\(end) response"])
    }
    
    /// Handle session change (device reboot detected)
    /// CRITICAL: Resets sequence tracking when session changes to prevent permanent state blackout
    /// CRITICAL: Fails all pending commands when session changes (command timeout + reconnect race protection)
    private func handleSessionChange(newSessionID: UInt32) {
        if let oldSessionID = currentSessionID {
            if oldSessionID != newSessionID {
                // Session changed - device rebooted
                print("[PicoSession] 🔄 Session changed: \(String(format: "%08X", oldSessionID)) -> \(String(format: "%08X", newSessionID)) - resetting sequence tracking")
                fflush(stdout)
                lastAppliedSequence = 0  // Reset sequence to allow new session's events
                
                // CRITICAL: Fail all pending commands (command timeout + reconnect race protection)
                // Device rebooted mid-command - original command never completed
                pendingCommandsLock.lock()
                let pending = pendingCommands
                pendingCommands.removeAll()
                pendingCommandsLock.unlock()
                
                if !pending.isEmpty {
                    print("[PicoSession] ⚠️ Session changed - failing \(pending.count) pending command(s)")
                    fflush(stdout)
                    // Commands will timeout naturally, but this ensures they don't auto-complete
                    // with state from the new session
                }
            }
        } else {
            // First session - initialize
            print("[PicoSession] 📍 First session detected: \(String(format: "%08X", newSessionID))")
            fflush(stdout)
        }
        currentSessionID = newSessionID
    }
    
    /// Parse boot timestamps from boot messages
    /// FIRMWARE REBOOT DETECTION: If boot timestamp changes unexpectedly, device silently reset
    private func parseBootTimestamps(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("BOOT_TS:") {
                let parts = line.split(separator: ":")
                if parts.count > 1, let ts = UInt64(parts[1]) {
                    // SILENT REBOOT DETECTION: Check if boot timestamp changed unexpectedly
                    if let lastBoot = lastKnownBootTimestamp, lastBoot != ts {
                        // Boot timestamp changed - device silently rebooted
                        // Invalidate state mirror (state is now unknown)
                        let errorEvent = ErrorEvent(
                            message: "Device silently rebooted (boot timestamp changed) - invalidating state mirror",
                            code: -3,
                            timestamp: Date()
                        )
                        events.send(.error(errorEvent))
                        print("⚠️ SILENT REBOOT DETECTED: Boot timestamp changed from \(lastBoot) to \(ts)")
                    }
                    lastKnownBootTimestamp = ts
                    bootTimestamp = ts
                }
            } else if line.hasPrefix("READY_TS:") {
                let parts = line.split(separator: ":")
                if parts.count > 1, let ts = UInt64(parts[1]) {
                    readyTimestamp = ts
                }
            }
        }
    }
    
    /// Start background event reader
    /// PARTIAL FRAME PROTECTION: Handles truncated frames and resyncs on newline/frame header
    private func startEventReader() {
        readerTask?.cancel()
        
        readerTask = Task { [weak self] in
            guard let self = self else {
                print("[PicoSession] ⚠️ Event reader: self was nil at start — exiting")
                fflush(stdout)
                return
            }
            
            print("[PicoSession] 🟢 Event reader started (isConnected=\(self.isConnected), isReady=\(self.isReady))")
            fflush(stdout)
            
            var buffer = Data()
            var consecutiveInvalidReads = 0
            let maxInvalidReads = 10
            var readCount = 0
            var emptyReadCount = 0
            
            while !Task.isCancelled && self.isConnected {
                invalidationLock.lock()
                let invalid = self.isInvalidated
                invalidationLock.unlock()
                
                guard !invalid else {
                    print("[PicoSession] Reader task exiting - session invalidated")
                    break
                }
                
                do {
                    let data = try self.serialPort.read(maxBytes: 512, timeoutMs: 150)
                    readCount += 1
                    
                    if readCount <= 10 {
                        let preview = data.isEmpty ? "(empty)" : Self.resilientString(from: data).prefix(60)
                        print("[PicoSession] 📖 Event reader read #\(readCount): \(data.count) bytes: '\(preview)'")
                        fflush(stdout)
                    }
                    
                    if !data.isEmpty {
                        buffer.append(data)
                        consecutiveInvalidReads = 0
                        emptyReadCount = 0
                        
                        let text = Self.resilientString(from: buffer)
                        let lines = text.components(separatedBy: .newlines)
                        
                        let completeLines: ArraySlice<String>
                        if text.last != "\n" && !lines.isEmpty {
                            buffer = lines.last!.data(using: .utf8) ?? Data()
                            completeLines = lines.dropLast()
                        } else {
                            buffer = Data()
                            completeLines = lines[...]
                        }
                        
                        for line in completeLines where !line.isEmpty {
                            self.processEventLine(line)
                        }

                        if buffer.count > 1024 {
                            buffer = Data()
                        }
                    } else {
                        emptyReadCount += 1
                        if emptyReadCount == 50 {
                            print("[PicoSession] 📭 Event reader: 50 consecutive empty reads (readCount=\(readCount), isConnected=\(self.isConnected))")
                            fflush(stdout)
                        }
                        // Dead connection detection: Pico heartbeat is ~25s.
                        // 200 empty reads × 150ms = ~30s with no data = missed at least 1 heartbeat.
                        // Declare connection dead to trigger reconnect.
                        let maxEmptyBeforeDead = 200
                        if emptyReadCount >= maxEmptyBeforeDead {
                            print("[PicoSession] 🔴 Event reader: \(emptyReadCount) consecutive empty reads — declaring connection dead")
                            fflush(stdout)
                            self.isConnected = false
                            self.isReady = false
                            self.events.send(.error(ErrorEvent(
                                message: "Connection lost: no data received for \(emptyReadCount) read cycles (~\(emptyReadCount * 150 / 1000)s)",
                                code: -5,
                                timestamp: Date()
                            )))
                            break
                        }
                        if emptyReadCount % 500 == 0 {
                            print("[PicoSession] 📭 Event reader: \(emptyReadCount) empty reads (total=\(readCount))")
                            fflush(stdout)
                        }
                    }
                } catch {
                    print("[PicoSession] 🔴 Event reader error (triggering disconnect): \(error)")
                    fflush(stdout)
                    self.isConnected = false
                    self.isReady = false
                    self.events.send(.error(ErrorEvent(
                        message: "Serial read failed: \(error.localizedDescription)",
                        code: -5,
                        timestamp: Date()
                    )))
                    break
                }
                
                try? await ContinuousClock().sleep(until: .now + .milliseconds(1))
            }
            
            print("[PicoSession] 🔴 Event reader exited (isCancelled=\(Task.isCancelled), isConnected=\(self.isConnected), readCount=\(readCount))")
            fflush(stdout)
        }
    }
    
    /// Process a single event line from firmware
    /// PARTIAL FRAME PROTECTION: Validates line completeness before processing
    private func processEventLine(_ line: String) {
        // PARTIAL FRAME PROTECTION: Validate line completeness
        // If line looks truncated (missing expected fields), discard and resync
        // This prevents concatenating garbage into next read
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Check if a pending text command response handler is waiting for this line.
        // Match rules:
        //   - Exact "OK" match (not prefix, to avoid matching "OKAY" etc.)
        //   - Prefix match for structured responses (e.g. "GPIO_READ:", "ADC_READ:")
        //   - "ERROR:" but NOT "ERROR_EVENT:" (that's telemetry, not a command response)
        pendingTextResponseLock.lock()
        if let pending = pendingTextResponse {
            let isOKMatch = pending.prefix == "OK" && trimmed == "OK"
            let isPrefixMatch = pending.prefix != "OK" && trimmed.hasPrefix(pending.prefix)
            let isErrorResponse = trimmed.hasPrefix("ERROR:") && !trimmed.hasPrefix("ERROR_EVENT:")
            if isOKMatch || isPrefixMatch || isErrorResponse {
                pendingTextResponse = nil
                pendingTextResponseLock.unlock()
                pending.continuation.resume(returning: trimmed)
                // Also emit error event for subscribers if it was an error
                if isErrorResponse {
                    let message = String(trimmed.dropFirst(6))
                    events.send(.error(ErrorEvent(message: message, code: nil, timestamp: Date())))
                }
                return
            }
        }
        pendingTextResponseLock.unlock()
        
        // Check if a multi-line response handler is accumulating lines
        pendingMultiLineLock.lock()
        if var pending = pendingMultiLineResponse {
            if trimmed == pending.endMarker {
                let lines = pending.lines
                pendingMultiLineResponse = nil
                pendingMultiLineLock.unlock()
                pending.continuation.resume(returning: lines)
                return
            } else {
                pending.lines.append(trimmed)
                pendingMultiLineResponse = pending
                pendingMultiLineLock.unlock()
                return
            }
        }
        pendingMultiLineLock.unlock()
        
        // Check if this is a BEGIN marker that should start multi-line capture
        pendingMultiLineLock.lock()
        let isBeginMarker = trimmed == "PINMAP_BEGIN" || trimmed == "DEVICE_INFO_BEGIN"
        pendingMultiLineLock.unlock()
        if isBeginMarker {
            return
        }
        
        // --- Push-based lifecycle readiness (BLAZE_READY) ---
        // Catches BLAZE_READY if it arrives after connect() finished (e.g. reconnect).
        if trimmed.contains("BLAZE_READY") && !self.isReady {
            print("[PicoSession] ✅ BLAZE_READY detected by event reader — marking ready")
            fflush(stdout)
            self.isReady = true
            parseBootTimestamps(trimmed)
            let bootEvt = BootEvent(stage: "BLAZE_READY", bootTimestamp: bootTimestamp, readyTimestamp: readyTimestamp)
            events.send(.boot(bootEvt))
        }
        
        // HEARTBEAT with READY:1 is the next-best lifecycle signal (late-join recovery).
        if trimmed.contains("HEARTBEAT:") && trimmed.contains("READY:1") && !self.isReady {
            print("[PicoSession] ✅ HEARTBEAT READY:1 detected — marking ready (late-join)")
            fflush(stdout)
            self.isReady = true
        }

        // --- Pull-based health probe (STATUS) ---
        // If the event reader sees a STATUS response with ready=1, mark ready.
        if trimmed.hasPrefix("STATUS:") && trimmed.contains("ready=1") && !self.isReady {
            print("[PicoSession] ✅ STATUS ready=1 detected by event reader — marking ready")
            fflush(stdout)
            self.isReady = true
        }
        
        // Session identity (CRITICAL: Detects device reboots for sequence reset)
        if trimmed.hasPrefix("SESSION:") {
            let sessionStr = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let sessionID = UInt32(sessionStr, radix: 16) {
                handleSessionChange(newSessionID: sessionID)
            }
        }
        
        // Boot events
        if trimmed.hasPrefix("BOOT:") {
            let stage = String(trimmed.dropFirst(5))
            let bootEvt = BootEvent(stage: stage, bootTimestamp: bootTimestamp, readyTimestamp: readyTimestamp)
            events.send(.boot(bootEvt))
            
            // FIRMWARE REBOOT DETECTION: Check for boot timestamp in boot messages
            if trimmed.contains("BOOT_TS:") {
                parseBootTimestamps(trimmed)
            }
            
            if stage == "GPIO_OK" {
                // Emit GPIO test completion
            }
        }
        
        // Status events
        else if trimmed.hasPrefix("STATUS:") {
            // Status parsing handled separately
        }
        else if trimmed.hasPrefix("GPIO:") {
            // GPIO state parsing
        }
        
        // Trace events
        else if trimmed.hasPrefix("TRACE:") {
            if let traceEvent = parseTraceEvent(trimmed) {
                events.send(.trace(traceEvent))
            }
        }
        
        // ACK events
        else if trimmed.hasPrefix("ACK TRACE:") || trimmed.hasPrefix("ACK:") {
            if let ackEvent = parseAckEvent(trimmed) {
                events.send(.ack(ackEvent))
            }
        }
        
        // Error events (exclude ERROR_EVENT: telemetry)
        else if trimmed.hasPrefix("ERROR:") && !trimmed.hasPrefix("ERROR_EVENT:") {
            let message = String(trimmed.dropFirst(6))
            let errorEvt = ErrorEvent(message: message, code: nil, timestamp: Date())
            events.send(.error(errorEvt))
        }
        
        // Heartbeat
        else if trimmed.hasPrefix("HEARTBEAT:") {
            if let heartbeat = parseHeartbeatEvent(trimmed) {
                events.send(.heartbeat(heartbeat))
                lastHeartbeat = Date()
            }
        }
        
        // STATE_CHANGE: automatic state notification after every command
        else if trimmed.hasPrefix("STATE_CHANGE:") {
            print("[PicoSession] Received STATE_CHANGE event: \(trimmed)")
            fflush(stdout)
            
            let (sequence, traceID, stateStr) = parseStateChangeHeader(trimmed)
            
            // CRITICAL: Sequence reset handling
            // If seq < lastAppliedSequence AND session changed, reset sequence tracking
            // This handles device reboots where seq resets to 0 but we still have old lastAppliedSequence
            if sequence < lastAppliedSequence {
                // Check if this is a new session (device reboot detected)
                if currentSessionID != nil {
                    // Session exists but seq went backwards - device rebooted
                    print("[PicoSession] 🔄 Sequence reset detected (seq=\(sequence) < lastSeq=\(lastAppliedSequence)) - device rebooted, resetting sequence tracking")
                    fflush(stdout)
                    lastAppliedSequence = 0  // Reset to allow new sequence
                } else {
                    // No session yet - this is first connection, allow it
                    print("[PicoSession] ℹ️ First connection, accepting seq=\(sequence)")
                    fflush(stdout)
                }
            }
            
            // Seq-based deduplication: only apply if sequence > lastAppliedSequence
            if sequence <= lastAppliedSequence {
                print("[PicoSession] ⏭️ STATE_CHANGE ignored (duplicate/out-of-order): seq=\(sequence) <= lastSeq=\(lastAppliedSequence)")
                fflush(stdout)
                return  // Ignore duplicate/out-of-order events
            }
            
            lastAppliedSequence = sequence
            
            // Parse GPIO state
            let gpioState = parseStateResponse(stateStr)
            gpioStateLock.lock()
            _lastKnownGPIOState = gpioState
            gpioStateLock.unlock()
            print("[PicoSession] 📡 Parsed GPIO state from STATE_CHANGE: seq=\(sequence), trace=\(traceID.map(formatTraceID) ?? "nil"), state=\(gpioState)")
            fflush(stdout)
            
            let statusEvt = StatusEvent(status: "OK", gpio: gpioState, uptimeMs: nil, firmware: nil, ready: true)
            events.send(.status(statusEvt))
            print("[PicoSession] 📡 Sent STATUS event with GPIO state from STATE_CHANGE (seq=\(sequence))")
            fflush(stdout)
        }
        
        // STATE: response (from QUERY_STATE command)
        else if trimmed.contains("STATE:") {
            print("[PicoSession] Received STATE response: \(trimmed)")
            fflush(stdout)
            let stateStr = trimmed.contains("STATE:") ? trimmed : "STATE: \(trimmed)"
            let gpioState = parseStateResponse(stateStr)
            gpioStateLock.lock()
            _lastKnownGPIOState = gpioState
            gpioStateLock.unlock()
            let statusEvt = StatusEvent(status: "OK", gpio: gpioState, uptimeMs: nil, firmware: nil, ready: true)
            events.send(.status(statusEvt))
        }
    }
    
    /// Parse STATE: response into GPIO state dictionary
    /// Parse STATE_CHANGE header to extract sequence number and trace ID
    /// Format: STATE_CHANGE: trace=<traceID> seq=<sequence> R=... or STATE_CHANGE: seq=<sequence> R=...
    /// Returns: (sequence: UInt64, traceID: UInt64?, stateLine: String)
    private func parseStateChangeHeader(_ line: String) -> (sequence: UInt64, traceID: UInt64?, stateLine: String) {
        var sequence: UInt64 = 0
        var traceID: UInt64? = nil
        
        // Extract trace= if present (handles both mid-line and end-of-line positions)
        if let traceRange = line.range(of: "trace=") {
            let afterTrace = String(line[traceRange.upperBound...])
            if let spaceRange = afterTrace.range(of: " ") {
                let traceStr = String(afterTrace[..<spaceRange.lowerBound])
                traceID = UInt64(traceStr)
            } else {
                // trace= is at end of line (no trailing space)
                traceID = UInt64(afterTrace.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        
        // Extract seq= (handles both mid-line and end-of-line positions)
        if let seqRange = line.range(of: "seq=") {
            let afterSeq = String(line[seqRange.upperBound...])
            if let spaceRange = afterSeq.range(of: " ") {
                let seqStr = String(afterSeq[..<spaceRange.lowerBound])
                sequence = UInt64(seqStr) ?? 0
            } else {
                // seq= is at end of line (no trailing space)
                sequence = UInt64(afterSeq.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }
        
        // Create state line for parsing (remove trace= and seq=, keep R= G= etc.)
        var stateLine = line.replacingOccurrences(of: "STATE_CHANGE:", with: "STATE:")
        if let traceRange = stateLine.range(of: "trace=") {
            // Remove trace=... part
            if let spaceAfterTrace = stateLine[traceRange.upperBound...].firstIndex(of: " ") {
                stateLine.removeSubrange(traceRange.lowerBound..<stateLine.index(after: spaceAfterTrace))
            }
        }
        if let seqRange = stateLine.range(of: "seq=") {
            // Remove seq=... part
            if let spaceAfterSeq = stateLine[seqRange.upperBound...].firstIndex(of: " ") {
                stateLine.removeSubrange(seqRange.lowerBound..<stateLine.index(after: spaceAfterSeq))
            }
        }
        
        return (sequence, traceID, stateLine)
    }
    
    /// UPDATED: Now handles new firmware format with MR, MG, MB (Multi Red, Multi Green, Multi Blue)
    /// Also handles seq= in STATE: responses (extracts and updates lastAppliedSequence)
    /// CRITICAL: Includes sequence reset handling for device reboots
    /// Returns keys: "R", "G", "Y", "B", "MR", "MG", "MB"
    private func parseStateResponse(_ line: String) -> [String: Bool] {
        var states: [String: Bool] = [:]
        
        // Extract seq= if present and update lastAppliedSequence
        if let seqRange = line.range(of: "seq=") {
            let afterSeq = String(line[seqRange.upperBound...])
            if let spaceRange = afterSeq.range(of: " ") {
                let seqStr = String(afterSeq[..<spaceRange.lowerBound])
                if let seq = UInt64(seqStr) {
                    // CRITICAL: Sequence reset handling
                    if seq < lastAppliedSequence && currentSessionID != nil {
                        // Device rebooted - reset sequence tracking
                        print("[PicoSession] 🔄 Sequence reset in STATE response (seq=\(seq) < lastSeq=\(lastAppliedSequence)) - resetting")
                        fflush(stdout)
                        lastAppliedSequence = 0
                    }
                    if seq > lastAppliedSequence {
                        lastAppliedSequence = seq
                    }
                }
            }
        }
        
        // Remove seq= and trace= for parsing GPIO state
        var cleanLine = line.replacingOccurrences(of: "STATE:", with: "")
        if let seqRange = cleanLine.range(of: "seq=") {
            if let spaceAfterSeq = cleanLine[seqRange.upperBound...].firstIndex(of: " ") {
                cleanLine.removeSubrange(seqRange.lowerBound..<cleanLine.index(after: spaceAfterSeq))
            }
        }
        if let traceRange = cleanLine.range(of: "trace=") {
            if let spaceAfterTrace = cleanLine[traceRange.upperBound...].firstIndex(of: " ") {
                cleanLine.removeSubrange(traceRange.lowerBound..<cleanLine.index(after: spaceAfterTrace))
            }
        }
        
        // New firmware format: "STATE: R=1 G=0 Y=1 B=0 MR=0 MG=0 MB=0"
        // Old format (for compatibility): "STATE: R=1 G=0 Y=1 B=0 M=0"
        let components = cleanLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ")
        
        for component in components {
            let parts = component.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            
            // MR/MG/MB report brightness 0-100; any non-zero = on
            let boolValue = value != "0"
            
            switch key {
            case "R":
                states["R"] = boolValue
            case "G":
                states["G"] = boolValue
            case "Y":
                states["Y"] = boolValue
            case "B":
                states["B"] = boolValue
            case "MR":
                states["MR"] = boolValue
            case "MG":
                states["MG"] = boolValue
            case "MB":
                states["MB"] = boolValue
            case "M":
                states["MR"] = boolValue
                states["MG"] = boolValue
                states["MB"] = boolValue
            case "S":
                if let angle = Int(value) {
                    gpioStateLock.lock()
                    _lastKnownServoAngle = angle
                    gpioStateLock.unlock()
                }
            default:
                break
            }
        }
        
        return states
    }
    
    /// Parse TRACE event line
    private func parseTraceEvent(_ line: String) -> TraceEvent? {
        let parts = line.split(separator: " ")
        var traceID: UInt64?
        var commandID: UInt8?
        var value: UInt8?
        var execUs: UInt64?
        var gpioFeedback: Bool?
        
        for part in parts {
            if part.hasPrefix("TRACE:") {
                traceID = UInt64(String(part.dropFirst(6)))
            } else if part.hasPrefix("CMD:") {
                commandID = UInt8(String(part.dropFirst(4)))
            } else if part.hasPrefix("VAL:") {
                value = UInt8(String(part.dropFirst(4)))
            } else if part.hasPrefix("EXEC_US:") {
                execUs = UInt64(String(part.dropFirst(8)))
            } else if part.hasPrefix("GPIO:") {
                gpioFeedback = (String(part.dropFirst(5)) == "1")
            }
        }
        
        guard let traceID = traceID,
              let cmdID = commandID,
              let val = value else {
            return nil
        }
        
        return TraceEvent(
            traceID: traceID,
            commandID: cmdID,
            value: val,
            execUs: execUs,
            gpioFeedback: gpioFeedback
        )
    }
    
    /// Parse ACK event line
    private func parseAckEvent(_ line: String) -> AckEvent? {
        let parts = line.split(separator: " ")
        var traceID: UInt64?
        var commandID: UInt8?
        var value: UInt8?
        var gpioFeedback: Bool?
        
        for part in parts {
            let p = String(part)
            if p.hasPrefix("TRACE:") {
                traceID = UInt64(String(p.dropFirst(6)))
            } else if p.hasPrefix("CMD:") {
                commandID = UInt8(String(p.dropFirst(4)))
            } else if p.hasPrefix("cmdID=") {
                commandID = UInt8(String(p.dropFirst(6)))
            } else if p.hasPrefix("VAL:") {
                value = UInt8(String(p.dropFirst(4)))
            } else if p.hasPrefix("value=") {
                value = UInt8(String(p.dropFirst(6)))
            } else if p.hasPrefix("GPIO:") {
                gpioFeedback = (String(p.dropFirst(5)) == "1")
            }
        }
        
        guard let traceID = traceID,
              let cmdID = commandID,
              let val = value else {
            return nil
        }
        
        return AckEvent(
            traceID: traceID,
            commandID: cmdID,
            value: val,
            gpioFeedback: gpioFeedback
        )
    }
    
    /// Parse heartbeat event
    private func parseHeartbeatEvent(_ line: String) -> HeartbeatEvent? {
        // Format: HEARTBEAT: UPTIME:12345 MEM:12345 ERR:0
        let parts = line.split(separator: " ")
        var uptimeMs: UInt64?
        var memoryFree: UInt32?
        var errorCount: UInt32?
        
        for part in parts {
            if part.hasPrefix("UPTIME:") {
                uptimeMs = UInt64(String(part.dropFirst(7)))
            } else if part.hasPrefix("MEM:") {
                memoryFree = UInt32(String(part.dropFirst(4)))
            } else if part.hasPrefix("ERR:") {
                errorCount = UInt32(String(part.dropFirst(4)))
            }
        }
        
        guard let uptime = uptimeMs else { return nil }
        
        return HeartbeatEvent(
            uptimeMs: uptime,
            memoryFree: memoryFree,
            errorCount: errorCount,
            timestamp: Date()
        )
    }
    
    /// Start heartbeat monitoring (detects device freeze/crash)
    /// Also sends periodic keep-alive pings to warm serial session
    private func startHeartbeatMonitor() {
        heartbeatMonitorTask?.cancel()
        // Monitor heartbeat events from device
        // CLOCK MONOTONICITY: Use ContinuousClock for timing
        heartbeatMonitorTask = Task { [weak self] in
            while let self = self, self.isConnected {
                try? await ContinuousClock().sleep(until: .now + .seconds(3))
                
                if let lastHeartbeat = self.lastHeartbeat {
                    // Use Date for elapsed calculation (heartbeat uses Date)
                    let dateElapsed = Date().timeIntervalSince(lastHeartbeat)
                    if dateElapsed > 5.0 { // No heartbeat for 5 seconds
                        self.events.send(.error(ErrorEvent(
                            message: "Device heartbeat timeout - possible freeze or disconnect",
                            code: -1,
                            timestamp: Date()
                        )))
                        
                        // Attempt reconnect
                        await self.handleReconnect()
                    }
                }
            }
        }
        
        // Keepalive is handled by DeviceManager.startKeepalivePing() only.
        // Removed duplicate PicoSession keepalive to prevent COMMAND ALREADY IN FLIGHT collisions.
    }
    
    /// Handle reconnection logic
    private func handleReconnect() async {
        guard reconnectAttempts < maxReconnectAttempts else {
            events.send(.error(ErrorEvent(
                message: "Max reconnection attempts reached",
                code: -2,
                timestamp: Date()
            )))
            return
        }
        
        reconnectAttempts += 1
        disconnect()
        
        try? await ContinuousClock().sleep(until: .now + .seconds(1))
        
        do {
            try await connect()
            reconnectAttempts = 0
        } catch {
            events.send(.error(ErrorEvent(
                message: "Reconnection attempt \(reconnectAttempts) failed: \(error.localizedDescription)",
                code: reconnectAttempts,
                timestamp: Date()
            )))
        }
    }
    
    /// Send a single command (non-blocking, uses persistent connection)
    /// AUTOMATIC BATCHING: Commands are queued and automatically batched within a time window
    /// RULE 5: Single writer lock ensures no concurrent USB writes
    /// RULE 7: Telemetry markers tracked for latency measurement
    /// CRITICAL GAP #2: Check invalidation before write
    /// CRITICAL FIX #2: Single command serialization - only one command at a time
    private let commandSerializationQueue = DispatchQueue(label: "com.blaze.pico.command.serial", qos: .userInitiated)
    private var isCommandInFlight = false
    
    /// Read-only view for callers that want to skip (e.g. keepalive) instead of throwing
    public var commandInFlight: Bool {
        commandSerializationQueue.sync { isCommandInFlight }
    }
    
    public func sendCommand(commandID: CommandID, value: UInt8, traceID: UInt64? = nil) async throws {
        // CRITICAL FIX #2: Enforce single command at a time - prevent protocol desync
        return try await withCheckedThrowingContinuation { continuation in
            commandSerializationQueue.async {
                // Check if another command is in flight
                if self.isCommandInFlight {
                    print("[PicoSession] 🔴❌ COMMAND ALREADY IN FLIGHT - protocol violation!")
                    print("[PicoSession] 🔴❌ This will cause protocol desync - rejecting command")
                    fflush(stdout)
                    continuation.resume(throwing: NSError(
                        domain: "PicoSession",
                        code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "Command already in flight - only one command at a time allowed to prevent protocol desync"]
                    ))
                    return
                }
                
                self.isCommandInFlight = true
                
                Task {
                    defer {
                        self.commandSerializationQueue.async {
                            self.isCommandInFlight = false
                        }
                    }
                    
                    do {
                        try await self._sendCommand(commandID: commandID, value: value, traceID: traceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    private func _sendCommand(commandID: CommandID, value: UInt8, traceID: UInt64?) async throws {
        // CRITICAL GAP #2: Check invalidation BEFORE any operation
        invalidationLock.lock()
        let invalid = isInvalidated
        invalidationLock.unlock()
        
        guard !invalid else {
            throw NSError(domain: "PicoSession", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Session was invalidated during recovery"])
        }
        
        // HARD READINESS GATE: No commands until BLAZE_READY received
        // USB CDC port open ≠ firmware ready. Only firmware knows when it's ready.
        guard isConnected else {
            throw NSError(domain: "PicoSession", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Device not connected"])
        }
        
        guard isReady else {
            throw NSError(domain: "PicoSession", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Device not ready - BLAZE_READY not received. Wait for device to finish booting before sending commands."])
        }
        
        let actualTraceID = traceID ?? generateTraceID()
        
        // ADAPTIVE BATCHING: Single commands flush immediately, multiple commands use short batch window
        commandQueueLock.lock()
        let queueWasEmpty = commandQueue.isEmpty
        let shouldFlushImmediately = commandQueue.count >= maxBatchSize - 1
        commandQueue.append((commandID, value, actualTraceID))
        let queueSize = commandQueue.count
        commandQueueLock.unlock()
        
        if shouldFlushImmediately {
            // Queue is full - flush immediately
            try await flushCommandQueue()
        } else if queueWasEmpty {
            // First command in queue - flush immediately (zero delay for single commands)
            try await flushCommandQueue()
        } else {
            // Additional commands arriving - use short batch window to collect more
            scheduleBatchFlush()
        }
        
        print("[PicoSession] 📥 Queued command: commandID=\(commandID.rawValue), value=\(value), traceID=\(formatTraceID(actualTraceID)), queueSize=\(queueSize)")
        fflush(stdout)
    }
    
    /// Schedule automatic batch flush after batch window
    private func scheduleBatchFlush() {
        // Cancel previous flush task
        batchFlushTask?.cancel()
        
        // Capture batch window before creating task
        let windowMs = batchWindowMs
        
        // Schedule new flush task
        batchFlushTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(windowMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            
            // Check if session is still valid before flushing
            self.invalidationLock.lock()
            let invalid = self.isInvalidated
            self.invalidationLock.unlock()
            
            guard !invalid else {
                print("[PicoSession] ⚠️ Skipping batch flush - session invalidated")
                fflush(stdout)
                return
            }
            
            try? await self.flushCommandQueue()
        }
    }
    
    /// Flush queued commands as a batch (or single command if only one)
    private func flushCommandQueue() async throws {
        // Extract all queued commands atomically
        commandQueueLock.lock()
        let commandsToSend = commandQueue
        commandQueue.removeAll()
        commandQueueLock.unlock()
        
        guard !commandsToSend.isEmpty else { return }
        
        if commandsToSend.count == 1 {
            // Single command - send directly (no batching overhead)
            let (commandID, value, traceID) = commandsToSend[0]
            let actualTraceID = traceID ?? generateTraceID()
            
            // Build binary payload
            var payload = Data()
            payload.append(0x00) // frameType
            payload.append(contentsOf: withUnsafeBytes(of: actualTraceID.bigEndian) { Data($0) })
            payload.append(commandID.rawValue)
            payload.append(value)
            
            // Build packet
            let packet = buildBlazePacket(payload: payload)
            
            // Send (non-blocking, connection stays open)
            // RULE 5: writeLock ensures single writer
            try sendPacketNonBlocking(packet)
            
            print("[PicoSession] 📤 Sent single command: commandID=\(commandID.rawValue), value=\(value), traceID=\(formatTraceID(actualTraceID))")
            fflush(stdout)
        } else {
            // Multiple commands - send as batch
            // Use first command's traceID for the batch (or generate new one)
            let batchTraceID = commandsToSend.first?.2 ?? generateTraceID()
            
            // Build batched payload: [frameType][traceID][count][cmd1][val1][cmd2][val2]...
            var payload = Data()
            payload.append(0x00) // frameType
            payload.append(contentsOf: withUnsafeBytes(of: batchTraceID.bigEndian) { Data($0) })
            payload.append(UInt8(commandsToSend.count)) // Command count
            
            for (cmdID, value, _) in commandsToSend {
                payload.append(cmdID.rawValue)
                payload.append(value)
            }
            
            // Build packet
            let packet = buildBlazePacket(payload: payload)
            
            // Send batch
            try sendPacketNonBlocking(packet)
            
            print("[PicoSession] 📤 Sent batch: \(commandsToSend.count) commands, traceID=\(formatTraceID(batchTraceID))")
            for (idx, (cmdID, value, _)) in commandsToSend.enumerated() {
                print("[PicoSession]   Batch[\(idx)]: commandID=\(cmdID.rawValue), value=\(value)")
            }
            fflush(stdout)
        }
    }
    
    /// Wait for STATE event from event stream (event reader processes STATE responses)
    private func waitForStateEvent(timeoutMs: Int) async throws -> [String: Bool]? {
        let timeoutSeconds = Double(timeoutMs) / 1000.0
        let startTime = Date()
        
        return try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            var timeoutTask: Task<Void, Never>?
            var hasResumed = false
            let resumeLock = NSLock()
            
            func safeResume(returning value: [String: Bool]?) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                cancellable?.cancel()
                cancellable = nil
                timeoutTask?.cancel()
                timeoutTask = nil
                continuation.resume(returning: value)
            }
            
            cancellable = events
                .sink { event in
                    if case .status(let statusEvent) = event,
                       !statusEvent.gpio.isEmpty {
                        let gpio = statusEvent.gpio
                        if gpio["R"] != nil || gpio["G"] != nil || gpio["Y"] != nil || gpio["B"] != nil || 
                           gpio["MR"] != nil || gpio["MG"] != nil || gpio["MB"] != nil || gpio["M"] != nil {
                            safeResume(returning: gpio)
                            return
                        }
                    }
                    
                    if Date().timeIntervalSince(startTime) >= timeoutSeconds {
                        safeResume(returning: nil)
                    }
                }
            
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs * 1_000_000))
                safeResume(returning: nil)
            }
        }
    }
    
    /// Query device state (returns current LED states)
    /// Uses CMD_QUERY_STATE to get authoritative state from hardware.
    /// SINGLE STREAM OWNER: All reads go through the event reader -- never direct serialPort.read().
    public func queryState(timeoutMs: Int = 1000) async throws -> [String: Bool]? {
        invalidationLock.lock()
        let invalid = isInvalidated
        invalidationLock.unlock()
        
        guard !invalid else {
            throw NSError(domain: "PicoSession", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Session was invalidated during recovery"])
        }
        
        guard isConnected else {
            throw NSError(domain: "PicoSession", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Device not connected"])
        }
        
        guard isReady else {
            throw NSError(domain: "PicoSession", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Device not ready - BLAZE_READY not received. Wait for device to finish booting before querying state."])
        }
        
        if commandInFlight {
            print("[PicoSession] queryState skipped - command already in flight")
            fflush(stdout)
            return nil
        }
        
        print("[PicoSession] Sending QUERY_STATE command (timeout: \(timeoutMs)ms)...")
        fflush(stdout)
        try await sendCommand(commandID: .queryState, value: 0)
        
        print("[PicoSession] Waiting for STATE event via event reader (timeout: \(timeoutMs)ms)...")
        fflush(stdout)
        let result = try await waitForStateEvent(timeoutMs: timeoutMs)
        if let result = result {
            print("[PicoSession] ✅ STATE event received: \(result)")
            fflush(stdout)
            return result
        } else {
            print("[PicoSession] ⚠️ STATE event timeout - no response received (returning nil gracefully)")
            fflush(stdout)
            return nil
        }
    }
    
    /// Send command and wait for ACK + STATE_CHANGE event (recommended for agent daemon)
    /// This is the best way for agents to send commands - it waits for ACK to confirm success,
    /// then gets state from STATE_CHANGE event (automatic, no query needed).
    /// 
    /// CRITICAL: Use this instead of sendCommand() + queryState() to prevent stalling
    /// 
    /// Uses trace ID correlation: waits for STATE_CHANGE with matching trace ID or seq > lastSeq
    /// This prevents unrelated state spam from interfering with command confirmation.
    /// 
    /// - Parameters:
    ///   - commandID: Command to execute
    ///   - value: Command value (0=OFF, 1=ON)
    ///   - traceID: Optional trace ID (auto-generated if nil)
    ///   - ackTimeoutMs: Timeout for ACK (default 500ms)
    ///   - stateTimeoutMs: Timeout for STATE_CHANGE event (default 1500ms - increased for USB hiccups)
    /// - Returns: Tuple of (success: Bool, state: [String: Bool]?)
    ///   - success: true if ACK received, false if timeout
    ///   - state: GPIO state from STATE_CHANGE event, or nil if timeout
    /// - Throws: Connection errors only (timeouts return success=false, state=nil)
    public func sendCommandWithCompletion(
        commandID: CommandID,
        value: UInt8,
        traceID: UInt64? = nil,
        ackTimeoutMs: Int = 500,
        stateTimeoutMs: Int = 50  // STATE_CHANGE arrives within ms of ACK; long waits waste time
    ) async throws -> (success: Bool, state: [String: Bool]?) {
        let actualTraceID = traceID ?? generateTraceID()
        let seqBeforeCommand = lastAppliedSequence
        
        // Track pending command (for session change failure)
        // BOUNDED SET: Fail fast if too many pending commands (prevents unbounded growth)
        pendingCommandsLock.lock()
        if pendingCommands.count >= maxPendingCommands {
            pendingCommandsLock.unlock()
            throw NSError(domain: "PicoSession", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Too many pending commands (\(pendingCommands.count)) - possible command timeout leak"])
        }
        pendingCommands[actualTraceID] = (commandID: commandID, value: value, startTime: Date())
        pendingCommandsLock.unlock()
        
        // Send command
        try await sendCommand(commandID: commandID, value: value, traceID: actualTraceID)
        
        // Wait for ACK first (confirms command executed)
        // Pass expectedTraceID for idempotency protection
        let ackReceived = try await waitForAck(timeoutMs: ackTimeoutMs, expectedTraceID: actualTraceID)
        
        // Remove from pending on success or timeout
        pendingCommandsLock.lock()
        pendingCommands.removeValue(forKey: actualTraceID)
        pendingCommandsLock.unlock()
        
        if !ackReceived {
            print("[PicoSession] ⚠️ ACK timeout - command may not have executed")
            fflush(stdout)
            PipelineLog.shared.log(.warn, component: "PicoSession", event: "ack_timeout",
                                   message: "cmdID=\(commandID.rawValue) val=\(value)", traceID: actualTraceID)
            return (success: false, state: nil)
        }
        
        print("[PicoSession] ✅ ACK received - command executed successfully")
        fflush(stdout)
        PipelineLog.shared.log(.info, component: "PicoSession", event: "ack_received",
                               message: "cmdID=\(commandID.rawValue) val=\(value)", traceID: actualTraceID)
        
        // Wait for STATE_CHANGE event (sent automatically after command)
        // Uses trace ID correlation: wait for STATE_CHANGE with matching trace ID or seq > lastSeq
        // This prevents unrelated state spam from interfering with command confirmation
        print("[PicoSession] Waiting for STATE_CHANGE event (trace=\(formatTraceID(actualTraceID)), seqBefore=\(seqBeforeCommand), timeout: \(stateTimeoutMs)ms)...")
        fflush(stdout)
        
        let timeoutSeconds = Double(stateTimeoutMs) / 1000.0
        let startTime = Date()
        
        let state = try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<[String: Bool]?, Error>) in
            guard let self = self else {
                continuation.resume(returning: nil)
                return
            }
            
            var cancellable: AnyCancellable?
            var timeoutTask: Task<Void, Never>?
            var hasResumed = false
            let resumeLock = NSLock()
            
            func safeResume(returning value: [String: Bool]?) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                cancellable?.cancel()
                cancellable = nil
                timeoutTask?.cancel()
                timeoutTask = nil
                continuation.resume(returning: value)
            }
            
            cancellable = self.events
                .sink { event in
                    if case .status(let statusEvent) = event,
                       !statusEvent.gpio.isEmpty {
                        let gpio = statusEvent.gpio
                        
                        if self.lastAppliedSequence > seqBeforeCommand {
                            print("[PicoSession] ✅ STATE_CHANGE event received (seq=\(self.lastAppliedSequence), trace=\(self.formatTraceID(actualTraceID))): \(gpio)")
                            fflush(stdout)
                            safeResume(returning: gpio)
                            return
                        }
                    }
                    
                    if Date().timeIntervalSince(startTime) >= timeoutSeconds {
                        print("[PicoSession] ⚠️ STATE_CHANGE timeout (returning nil gracefully)")
                        fflush(stdout)
                        safeResume(returning: nil)
                    }
                }
            
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(stateTimeoutMs * 1_000_000))
                print("[PicoSession] ⚠️ STATE_CHANGE timeout (returning nil gracefully)")
                fflush(stdout)
                safeResume(returning: nil)
            }
        }
        
        // Return success=true (ACK received) and state (may be nil if timeout)
        return (success: true, state: state)
    }
    
    /// Wait for ACK event for a sent command
    /// CRITICAL: Includes ACK idempotency protection (ignores duplicate ACKs)
    /// - Parameter timeoutMs: Timeout in milliseconds (default 500ms)
    /// - Parameter expectedTraceID: Trace ID to wait for (for idempotency check)
    /// - Returns: true if ACK received, false if timeout
    private func waitForAck(timeoutMs: Int = 500, expectedTraceID: UInt64? = nil) async throws -> Bool {
        let timeoutSeconds = Double(timeoutMs) / 1000.0
        let startTime = Date()
        
        return try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Bool, Error>) in
            guard let self = self else {
                continuation.resume(returning: false)
                return
            }
            
            var cancellable: AnyCancellable?
            var timeoutTask: Task<Void, Never>?
            var hasResumed = false
            let resumeLock = NSLock()
            
            func safeResume(returning value: Bool) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                cancellable?.cancel()
                cancellable = nil
                timeoutTask?.cancel()
                timeoutTask = nil
                continuation.resume(returning: value)
            }
            
            cancellable = self.events
                .sink { event in
                    if case .ack(let ackEvent) = event {
                        if let expectedTrace = expectedTraceID, ackEvent.traceID != expectedTrace {
                            return
                        }
                        
                        self.completedTracesLock.lock()
                        let alreadySeen = self.completedTraces.contains(ackEvent.traceID)
                        if !alreadySeen {
                            self.completedTraces.insert(ackEvent.traceID)
                            if self.completedTraces.count > self.maxCompletedTraces {
                                let toRemove = self.completedTraces.prefix(self.maxCompletedTraces / 10)
                                self.completedTraces.subtract(toRemove)
                            }
                        }
                        self.completedTracesLock.unlock()
                        
                        if alreadySeen {
                            print("[PicoSession] ⏭️ Duplicate ACK ignored (trace=\(self.formatTraceID(ackEvent.traceID)))")
                            fflush(stdout)
                            return
                        }
                        
                        safeResume(returning: true)
                        return
                    }
                    
                    if Date().timeIntervalSince(startTime) >= timeoutSeconds {
                        safeResume(returning: false)
                    }
                }
            
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs * 1_000_000))
                safeResume(returning: false)
            }
        }
    }
    
    /// Send servo angle command (0-180) and wait for ACK + STATE_CHANGE
    public func sendServoCommand(angle: Int, traceID: UInt64? = nil) async throws -> (success: Bool, state: [String: Bool]?) {
        let clamped = UInt8(min(max(angle, 0), 180))
        return try await sendCommandWithCompletion(
            commandID: .servoSet,
            value: clamped,
            traceID: traceID,
            ackTimeoutMs: 500,
            stateTimeoutMs: 50
        )
    }
    
    /// Send a raw text command and optionally wait for a response line matching `responsePrefix`.
    ///
    /// Serialized: only one text command can be in-flight at a time. Concurrent callers
    /// queue on `textCommandQueue` to prevent single-slot continuation overwrites.
    /// The continuation is registered BEFORE writing to prevent TOCTOU races.
    ///
    /// - Parameters:
    ///   - text: The text command to send (e.g., "GPIO SET 5 1"). Newline is appended automatically.
    ///   - responsePrefix: Expected response prefix (e.g., "GPIO_READ:", "ADC_READ:", "OK"). 
    ///                     If nil, the command is fire-and-forget.
    ///   - timeoutMs: Maximum time to wait for the response (default 2000ms).
    /// - Returns: The matched response line, or nil on timeout / fire-and-forget.
    /// - Throws: If the device is not connected/ready or the write fails.
    public func sendTextCommand(_ text: String, responsePrefix: String? = nil, timeoutMs: Int = 2000) async throws -> String? {
        invalidationLock.lock()
        let invalid = isInvalidated
        invalidationLock.unlock()
        guard !invalid else {
            throw NSError(domain: "PicoSession", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Session was invalidated"])
        }
        guard isConnected else {
            throw NSError(domain: "PicoSession", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Device not connected"])
        }
        guard isReady else {
            throw NSError(domain: "PicoSession", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Device not ready"])
        }
        
        let commandData = Data((text + "\n").utf8)
        
        guard let prefix = responsePrefix else {
            writeLock.lock()
            defer { writeLock.unlock() }
            try serialPort.write(commandData)
            return nil
        }
        
        // Serialize text commands: only one pending response at a time
        return try await withCheckedThrowingContinuation { (outer: CheckedContinuation<String?, Error>) in
            self.textCommandQueue.async {
                let semaphore = DispatchSemaphore(value: 0)
                var responseValue: String? = nil
                
                // Step 1: Register continuation BEFORE writing (prevents TOCTOU race)
                let registrationTask = Task<Void, Never> {
                    let resp: String? = await withCheckedContinuation { (inner: CheckedContinuation<String?, Never>) in
                        self.pendingTextResponseLock.lock()
                        self.pendingTextResponse = (prefix: prefix, continuation: inner)
                        self.pendingTextResponseLock.unlock()
                        
                        // Step 2: Write command AFTER continuation is registered
                        self.writeLock.lock()
                        do {
                            try self.serialPort.write(commandData)
                            self.writeLock.unlock()
                        } catch {
                            self.writeLock.unlock()
                            // Write failed — clean up pending handler and signal
                            self.pendingTextResponseLock.lock()
                            if let pending = self.pendingTextResponse {
                                self.pendingTextResponse = nil
                                self.pendingTextResponseLock.unlock()
                                pending.continuation.resume(returning: nil)
                            } else {
                                self.pendingTextResponseLock.unlock()
                            }
                            return
                        }
                    }
                    responseValue = resp
                    semaphore.signal()
                }
                
                // Step 3: Wait for response or timeout
                let waitResult = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
                
                if waitResult == .timedOut {
                    // Timeout: atomically take-and-resume the pending handler
                    self.pendingTextResponseLock.lock()
                    if let pending = self.pendingTextResponse {
                        self.pendingTextResponse = nil
                        self.pendingTextResponseLock.unlock()
                        pending.continuation.resume(returning: nil)
                    } else {
                        self.pendingTextResponseLock.unlock()
                    }
                    // Wait for the task to finish (continuation was just resumed)
                    _ = registrationTask
                    semaphore.wait()
                    outer.resume(returning: nil)
                } else {
                    outer.resume(returning: responseValue)
                }
            }
        }
    }
    
    /// Refresh pin capabilities from firmware (on-demand, after event reader is running).
    /// Returns updated pin list and also updates the cached deviceCapabilities.
    public func queryPinMap(timeoutMs: Int = 2000) async throws -> [PinCapability] {
        guard isConnected && isReady else {
            throw NSError(domain: "PicoSession", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Device not connected/ready"])
        }
        let lines = try await sendMultiLineCommand("PINMAP", endMarker: "PINMAP_END", timeoutMs: timeoutMs)
        let pins = DeviceCapabilities.parsePinMap(lines: lines)
        
        gpioStateLock.lock()
        _deviceCapabilities?.pins = pins
        gpioStateLock.unlock()
        
        return pins
    }
    
    /// Send a text command and collect a multi-line BEGIN/END delimited response.
    /// Serialized on textCommandQueue to avoid conflicts with single-line sendTextCommand.
    private func sendMultiLineCommand(_ command: String, endMarker: String, timeoutMs: Int) async throws -> [String] {
        let commandData = Data((command + "\n").utf8)
        
        return try await withCheckedThrowingContinuation { (outer: CheckedContinuation<[String], Error>) in
            self.textCommandQueue.async {
                let semaphore = DispatchSemaphore(value: 0)
                var resultLines: [String] = []
                
                // Register handler AND write inside the same Task body
                // so the handler is guaranteed registered before the write.
                let registrationTask = Task<Void, Never> {
                    let lines: [String] = await withCheckedContinuation { (inner: CheckedContinuation<[String], Never>) in
                        self.pendingMultiLineLock.lock()
                        self.pendingMultiLineResponse = (endMarker: endMarker, lines: [], continuation: inner)
                        self.pendingMultiLineLock.unlock()
                        
                        // Write command AFTER handler is registered (prevents TOCTOU race)
                        self.writeLock.lock()
                        do {
                            try self.serialPort.write(commandData)
                            self.writeLock.unlock()
                        } catch {
                            self.writeLock.unlock()
                            self.pendingMultiLineLock.lock()
                            if let pending = self.pendingMultiLineResponse {
                                self.pendingMultiLineResponse = nil
                                self.pendingMultiLineLock.unlock()
                                pending.continuation.resume(returning: [])
                            } else {
                                self.pendingMultiLineLock.unlock()
                            }
                            return
                        }
                    }
                    resultLines = lines
                    semaphore.signal()
                }
                
                let waitResult = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
                if waitResult == .timedOut {
                    self.pendingMultiLineLock.lock()
                    if let pending = self.pendingMultiLineResponse {
                        self.pendingMultiLineResponse = nil
                        self.pendingMultiLineLock.unlock()
                        pending.continuation.resume(returning: [])
                    } else {
                        self.pendingMultiLineLock.unlock()
                    }
                    _ = registrationTask
                    semaphore.wait()
                    outer.resume(throwing: NSError(domain: "PicoSession", code: -10,
                                                   userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for \(endMarker)"]))
                } else {
                    outer.resume(returning: resultLines)
                }
            }
        }
    }
    
    /// Send batched commands (single packet, multiple commands)
    /// CRITICAL GAP #2: Check invalidation before operation
    public func sendBatch(commands: [(CommandID, UInt8)], traceID: UInt64? = nil) async throws {
        // CRITICAL GAP #2: Check invalidation BEFORE any operation
        invalidationLock.lock()
        let invalid = isInvalidated
        invalidationLock.unlock()
        
        guard !invalid else {
            throw NSError(domain: "PicoSession", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Session was invalidated during recovery"])
        }
        
        // CRITICAL FIX: Allow batch commands even if not ready
        guard isConnected else {
            throw NSError(domain: "PicoSession", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Device not connected"])
        }
        
        // HARD READINESS GATE: No batches until BLAZE_READY received
        guard isReady else {
            throw NSError(domain: "PicoSession", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Device not ready - BLAZE_READY not received. Wait for device to finish booting before sending batches."])
        }
        
        let actualTraceID = traceID ?? generateTraceID()
        
        // Build batched payload: [frameType][traceID][count][cmd1][val1][cmd2][val2]...
        var payload = Data()
        payload.append(0x00) // frameType
        payload.append(contentsOf: withUnsafeBytes(of: actualTraceID.bigEndian) { Data($0) })
        payload.append(UInt8(commands.count)) // Command count
        
        for (cmdID, value) in commands {
            payload.append(cmdID.rawValue)
            payload.append(value)
        }
        
        // Build packet
        let packet = buildBlazePacket(payload: payload)
        
        // Send
        try sendPacketNonBlocking(packet)
    }
    
    /// Generate trace ID
    /// Generate unique trace ID (trace reuse prevention)
    /// CRITICAL: Uses UUID-based generation to prevent trace ID collisions after daemon restarts
    /// Format: High 32 bits from UUID, low 32 bits from counter/timestamp
    /// This ensures uniqueness even if daemon restarts quickly
    private func generateTraceID() -> UInt64 {
        // Use UUID for uniqueness (prevents collisions after daemon restart)
        // Convert UUID to UInt64 by taking first 8 bytes
        let uuid = UUID()
        let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        let highBits = uuidBytes.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let lowBits = uuidBytes.dropFirst(4).prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        
        // Combine into UInt64 (big-endian for consistency)
        let traceID = (UInt64(highBits.bigEndian) << 32) | UInt64(lowBits.bigEndian)
        return traceID
    }
    
    /// Format trace ID for logging (log hygiene)
    /// Returns short hex representation (first 8 hex chars) for readability
    /// Full trace ID only logged when debugging enabled
    private func formatTraceID(_ traceID: UInt64) -> String {
        // Short format: first 8 hex chars (most significant bits)
        // This is readable while still being unique enough for correlation
        return String(format: "%016llX", traceID).prefix(8).uppercased()
    }
    
    /// Build BlazeTransport packet
    private func buildBlazePacket(payload: Data) -> BlazePacket {
        let header = BlazePacketHeader(
            version: 1,
            flags: 0,
            connectionID: 1,
            packetNumber: packetNumber,
            streamID: 1,
            payloadLength: UInt16(payload.count)
        )
        
        packetNumber += 1
        
        return BlazePacket(header: header, payload: payload)
    }
    
    /// Send packet non-blocking (connection stays open)
    /// RULE 5: Single writer lock ensures no concurrent USB writes
    /// RULE 1: Emit error event on hard failure so DeviceManager can handleHardFailure()
    /// CRITICAL GAP #2: Check invalidation before write
    private func sendPacketNonBlocking(_ packet: BlazePacket) throws {
        // Check invalidation BEFORE acquiring writeLock (lock order: invalidationLock(6) < writeLock(7))
        invalidationLock.lock()
        let invalid = isInvalidated
        invalidationLock.unlock()
        
        guard !invalid else {
            throw NSError(domain: "PicoSession", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Session was invalidated during recovery"])
        }
        
        let packetData = PacketEncoder.encode(packet)
        var fullPacket = Data("BLAZ".utf8)
        fullPacket.append(packetData)
        
        // writeLock is innermost -- no other locks acquired while held
        writeLock.lock()
        let writeResult: Result<Void, Error>
        do {
            print("[PicoSession] 📤 Writing packet to serial port: \(fullPacket.count) bytes")
            fflush(stdout)
            try serialPort.write(fullPacket)
            print("[PicoSession] ✅ Packet written successfully")
            fflush(stdout)
            writeResult = .success(())
        } catch {
            writeResult = .failure(error)
        }
        writeLock.unlock()
        
        // Handle write result AFTER releasing writeLock (lock order safe for sessionStateLock)
        switch writeResult {
        case .success:
            return
        case .failure(let error):
            if let writeError = error as? SerialPortError {
                if writeError.isFatal {
                    print("[PicoSession] 🔴 FATAL write error (session dead): \(writeError)")
                    fflush(stdout)
                    sessionStateLock.lock()
                    _isConnected = false
                    _isReady = false
                    sessionStateLock.unlock()
                    events.send(.error(ErrorEvent(
                        message: "Serial write failed (fatal): \(writeError.localizedDescription)",
                        code: -1,
                        timestamp: Date()
                    )))
                } else {
                    print("[PicoSession] ⚠️ Transient write error (session alive): \(writeError)")
                    fflush(stdout)
                }
                throw writeError
            } else {
                print("[PicoSession] 🔴 Unknown write error: \(error)")
                fflush(stdout)
                throw error
            }
        }
    }
    
    deinit {
        disconnect()
    }
}
