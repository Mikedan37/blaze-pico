import Foundation
#if canImport(Darwin)
import Darwin
import os.log
import os.signpost
#endif

/// BlazeTransport packet structures (minimal implementation)
public struct BlazePacketHeader {
    public var version: UInt8
    public var flags: UInt8
    public var connectionID: UInt32
    public var packetNumber: UInt32
    public var streamID: UInt32
    public var payloadLength: UInt16
    
    public init(version: UInt8, flags: UInt8, connectionID: UInt32, packetNumber: UInt32, streamID: UInt32, payloadLength: UInt16) {
        self.version = version
        self.flags = flags
        self.connectionID = connectionID
        self.packetNumber = packetNumber
        self.streamID = streamID
        self.payloadLength = payloadLength
    }
}

public struct BlazePacket {
    public var header: BlazePacketHeader
    public var payload: Data
    
    public init(header: BlazePacketHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

/// Packet encoder matching BlazeTransport PacketParser.encode()
public struct PacketEncoder {
    public static let headerSize = 16
    
    public static func encode(_ packet: BlazePacket) -> Data {
        var data = Data(capacity: headerSize + packet.payload.count)
        
        // Write header fields in big-endian
        data.append(packet.header.version)
        data.append(packet.header.flags)
        data.append(contentsOf: withUnsafeBytes(of: packet.header.connectionID.bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: packet.header.packetNumber.bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: packet.header.streamID.bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: packet.header.payloadLength.bigEndian) { Data($0) })
        
        // Append payload
        data.append(packet.payload)
        
        return data
    }
}

/// Binary command IDs (matches Pico firmware)
public enum CommandID: UInt8 {
    case red = 1
    case green = 2
    case yellow = 3
    case blue = 4
    case multi = 5          // Turn all RGB channels on/off together
    case multiRed = 6       // RGB multicolor - Red channel (GPIO 24)
    case multiGreen = 7     // RGB multicolor - Green channel (GPIO 25)
    case multiBlue = 8      // RGB multicolor - Blue channel (GPIO 26)
    case all = 10
    case queryState = 20
    case status = 21
    case enterBootloader = 30
    case servoSet = 40
}

/// Pipeline stage timestamps for telemetry (kept for backward compatibility)
public struct PipelineTimestamps {
    public var voiceDetected: Date?
    public var llmStart: Date?
    public var llmDone: Date?
    public var agentDispatch: Date?
    public var serialWrite: Date?
    public var ackReceived: Date?
    
    public init() {}
    
    /// Calculate latency between two stages in milliseconds
    public func latency(from: Date?, to: Date?) -> Double? {
        guard let from = from, let to = to else { return nil }
        return (to.timeIntervalSince(from) * 1000)
    }
}

/// Controller for Pico LED using BlazeTransport protocol with telemetry
public class PicoLEDController {
    private let serialPort: SerialPort
    private var packetNumber: UInt32 = 1
    private var timestamps = PipelineTimestamps()
    private var currentTraceID: UInt64 = 0
    private var pipelineTracker: PipelineTracker?
    private var signpostIDs: [String: OSSignpostID] = [:]
    
    private var isReady: Bool = false
    private var bootTimestamp: UInt64? = nil
    private var readyTimestamp: UInt64? = nil
    
    public init(portPath: String) {
        self.serialPort = SerialPort(path: portPath)
    }
    
    /// Wait for Pico to be ready (BLAZE_READY handshake)
    /// - Parameter timeoutMs: Maximum time to wait (default: 5000ms)
    /// - Returns: True if ready, false if timeout
    @discardableResult
    public func waitForReady(timeoutMs: Int = 5000) throws -> Bool {
        guard !serialPort.isOpen else {
            // Already connected, check if we've seen READY
            return isReady
        }
        
        // Open serial port
        try serialPort.open(baudRate: 115200)
        
        let startTime = Date()
        let timeoutSeconds = Double(timeoutMs) / 1000.0
        
        // Read boot messages until we see BLAZE_READY
        var accumulatedBuffer = Data()
        while Date().timeIntervalSince(startTime) < timeoutSeconds {
            let data = try serialPort.read(maxBytes: 512, timeoutMs: 200)
            accumulatedBuffer.append(data)
            
            // Keep buffer size reasonable (last 2KB)
            if accumulatedBuffer.count > 2048 {
                accumulatedBuffer = accumulatedBuffer.suffix(2048)
            }
            
            if let text = String(data: accumulatedBuffer, encoding: .utf8) {
                // Parse boot messages - check entire buffer for BLAZE_READY
                if text.contains("BLAZE_READY") {
                    isReady = true
                    
                    // Parse timestamps if available
                    let lines = text.components(separatedBy: .newlines)
                    for line in lines {
                        if line.contains("BOOT_TS:") {
                            let parts = line.split(separator: ":")
                            if parts.count > 1, let ts = UInt64(parts[1]) {
                                bootTimestamp = ts
                            }
                        }
                        if line.contains("READY_TS:") {
                            let parts = line.split(separator: ":")
                            if parts.count > 1, let ts = UInt64(parts[1]) {
                                readyTimestamp = ts
                            }
                        }
                    }
                    
                    return true
                }
            }
        }
        
        return false // Timeout
    }
    
    /// Generate a new trace ID
    private func generateTraceID() -> UInt64 {
        // Use high-resolution timestamp + random component
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000) // microseconds
        let random = UInt64.random(in: 0..<1000)
        return timestamp + random
    }
    
    // Telemetry logging is now handled by Telemetry.shared.mark()
    // This method removed - use PipelineTracker instead
    
    /// Send a binary command to control Pico LEDs with telemetry (async ACK version)
    /// - Parameters:
    ///   - commandID: Binary command ID (1=RED, 2=GREEN, etc.)
    ///   - value: 0=OFF, 1=ON
    ///   - waitForAck: If false, returns immediately after sending (default: false for low latency)
    /// - Returns: True if ACK received (or if waitForAck=false, returns true immediately)
    @discardableResult
    public func sendBinaryCommand(commandID: CommandID, value: UInt8, waitForAck: Bool = false) throws -> Bool {
        // Generate trace ID for this command
        let traceID = generateTraceID()
        currentTraceID = traceID
        
        // Mark serial write timestamp
        timestamps.serialWrite = Date()
        
        // Initialize pipeline tracker if not already initialized
        if pipelineTracker == nil {
            pipelineTracker = PipelineTracker(traceID: traceID)
        }
        
        // Mark packet built stage
        let commandStr = "\(commandID.rawValue):\(value)"
        pipelineTracker?.markStage("packet_built", metadata: [
            "commandID": "\(commandID.rawValue)",
            "value": "\(value)"
        ])
        
        let packet = buildCommandPacket(PicoCommandV1(traceID: traceID, command: commandID, value: value))
        
        // Mark serial write start
        pipelineTracker?.markStage("serial_write_start")
        signpostIDs["serial_write"] = Telemetry.shared.beginSpan(name: "serial_write" as StaticString, traceID: traceID)
        timestamps.serialWrite = Date()
        
        // Send packet (non-blocking)
        try sendPacketNonBlocking(packet, traceID: traceID)
        
        // Mark serial write done immediately (don't wait for ACK)
        pipelineTracker?.markStage("serial_write_done")
        if let signpostID = signpostIDs["serial_write"] {
            Telemetry.shared.endSpan(name: "serial_write", signpostID: signpostID, traceID: traceID)
        }
        
        // If waitForAck is false, return immediately (async ACK handling)
        if !waitForAck {
            // Handle ACK asynchronously in background
            Task { [weak self] in
                await self?.handleAckAsync(traceID: traceID, commandStr: commandStr)
            }
            return true // Optimistic return
        }
        
        // Otherwise, wait for ACK (legacy behavior)
        let ackReceived = try sendPacket(packet, traceID: traceID)
        
        // Mark ACK received timestamp
        timestamps.ackReceived = Date()
        
        // Calculate latencies
        if let serialWrite = timestamps.serialWrite, let ackTimestamp = timestamps.ackReceived {
            let serialToAck = timestamps.latency(from: serialWrite, to: ackTimestamp)
            
            // Calculate total latency if voice detected
            let totalLatency = timestamps.latency(from: timestamps.voiceDetected, to: ackTimestamp)
            
            // Record metrics
            TelemetryMetrics.shared.recordPipeline(
                voiceToLLM: timestamps.latency(from: timestamps.voiceDetected, to: timestamps.llmStart),
                llmProcessing: timestamps.latency(from: timestamps.llmStart, to: timestamps.llmDone),
                llmToAgent: timestamps.latency(from: timestamps.llmDone, to: timestamps.agentDispatch),
                agentToSerial: timestamps.latency(from: timestamps.agentDispatch, to: serialWrite),
                serialToAck: serialToAck,
                total: totalLatency,
                command: commandStr,
                success: ackReceived
            )
            
            // Print pipeline summary
            printPipelineSummary(traceID: traceID, command: commandStr)
        }
        
        return ackReceived
    }
    
    /// Send packet without waiting for ACK (non-blocking)
    private func sendPacketNonBlocking(_ packet: BlazePacket, traceID: UInt64) throws {
        // "BLAZ" + BlazeTransport packet + CRC-32
        let fullPacket = PicoWire.serialFrame(packet)
        
        // Ensure device is ready before sending
        if !isReady {
            // Wait for readiness handshake with longer timeout
            // If device was already booted, we may have missed BLAZE_READY, so try reading any pending data first
            if serialPort.isOpen {
                // Try to read any pending boot messages
                let _ = try? serialPort.read(maxBytes: 1024, timeoutMs: 100)
            }
            
            // Wait for readiness handshake with longer timeout (10s to handle slow boot)
            // If timeout or error, assume device is ready anyway (it may have already booted)
            do {
                let readyResult = try waitForReady(timeoutMs: 10000)
                if readyResult {
                    isReady = true
                } else {
                    // Timeout - assume ready
                    isReady = true
                }
            } catch {
                // Error reading serial - assume device is ready anyway
                // This handles cases where device was already booted before we connected
                isReady = true
            }
        }
        
        // Open serial port if not already open
        if !serialPort.isOpen {
            try serialPort.open(baudRate: 115200)
        }
        
        // Send packet (non-blocking write)
        try serialPort.write(fullPacket)
    }
    
    /// Handle ACK asynchronously (background task)
    private func handleAckAsync(traceID: UInt64, commandStr: String) async {
        do {
            // Wait for ACK in background (up to 500ms)
            let ackData = try serialPort.read(maxBytes: 512, timeoutMs: 500)
            
            let ackReceived = ackData.count > 0
            
            // Mark ACK received timestamp
            timestamps.ackReceived = Date()
            
            // Parse firmware telemetry if available
            if let ackString = String(data: ackData, encoding: .utf8) {
                parseFirmwareTelemetry(ackString, traceID: traceID)
            }
            
            // Calculate latencies
            if let serialWrite = timestamps.serialWrite, let ackTimestamp = timestamps.ackReceived {
                let serialToAck = timestamps.latency(from: serialWrite, to: ackTimestamp)
                
                // Calculate total latency if voice detected
                let totalLatency = timestamps.latency(from: timestamps.voiceDetected, to: ackTimestamp)
                
                // Record metrics
                TelemetryMetrics.shared.recordPipeline(
                    voiceToLLM: timestamps.latency(from: timestamps.voiceDetected, to: timestamps.llmStart),
                    llmProcessing: timestamps.latency(from: timestamps.llmStart, to: timestamps.llmDone),
                    llmToAgent: timestamps.latency(from: timestamps.llmDone, to: timestamps.agentDispatch),
                    agentToSerial: timestamps.latency(from: timestamps.agentDispatch, to: serialWrite),
                    serialToAck: serialToAck,
                    total: totalLatency,
                    command: commandStr,
                    success: ackReceived
                )
            }
        } catch {
            // ACK timeout or error - mark as timeout
            pipelineTracker?.markStage("ack_timeout", metadata: ["timeout_ms": "500"])
            TelemetryMetrics.shared.failureAnalyzer.record(command: commandStr, error: "ACK timeout")
        }
    }
    
    /// Parse firmware telemetry from ACK response
    private func parseFirmwareTelemetry(_ ackString: String, traceID: UInt64) {
        let lines = ackString.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("PACKET RECEIVED TRACE:") {
                let traceStr = String(line.dropFirst("PACKET RECEIVED TRACE:".count))
                if let firmwareTraceID = UInt64(traceStr) {
                    pipelineTracker?.markStage("packet_received", metadata: ["firmware_trace_id": "\(firmwareTraceID)"])
                }
            } else if line.hasPrefix("COMMAND PARSED TRACE:") {
                let parts = line.split(separator: " ")
                var cmdID: UInt8? = nil
                var value: UInt8? = nil
                for part in parts {
                    if part.hasPrefix("CMD:") {
                        cmdID = UInt8(String(part.dropFirst(4)))
                    } else if part.hasPrefix("VAL:") {
                        value = UInt8(String(part.dropFirst(4)))
                    }
                }
                var metadata: [String: String] = [:]
                if let cmdID = cmdID { metadata["commandID"] = "\(cmdID)" }
                if let value = value { metadata["value"] = "\(value)" }
                pipelineTracker?.markStage("command_parsed", metadata: metadata)
            } else if line.hasPrefix("GPIO_SET_START TRACE:") {
                pipelineTracker?.markStage("gpio_set_start")
            } else if line.hasPrefix("GPIO_SET_DONE TRACE:") {
                pipelineTracker?.markStage("gpio_set_done")
            } else if line.hasPrefix("GPIO_READBACK TRACE:") {
                let parts = line.split(separator: " ")
                var gpioValue: Bool? = nil
                for part in parts {
                    if part.hasPrefix("GPIO:") {
                        gpioValue = (String(part.dropFirst(5)) == "1")
                    }
                }
                var metadata: [String: String] = [:]
                if let gpio = gpioValue {
                    metadata["gpio_value"] = gpio ? "1" : "0"
                }
                pipelineTracker?.markStage("gpio_readback", metadata: metadata)
            } else if line.hasPrefix("TRACE:") {
                // Parse firmware execution telemetry
                let parts = line.split(separator: " ")
                var execUs: UInt64? = nil
                var gpioFeedback: Bool? = nil
                
                for part in parts {
                    if part.hasPrefix("EXEC_US:") {
                        let execStr = String(part.dropFirst(8))
                        execUs = UInt64(execStr)
                    } else if part.hasPrefix("GPIO:") {
                        let gpioStr = String(part.dropFirst(5))
                        gpioFeedback = (gpioStr == "1")
                    }
                }
                
                var metadata: [String: String] = [:]
                if let execUs = execUs {
                    let execMs = Double(execUs) / 1000.0
                    metadata["exec_us"] = "\(execUs)"
                    metadata["exec_ms"] = String(format: "%.3f", execMs)
                }
                if let gpio = gpioFeedback {
                    metadata["gpio_feedback"] = gpio ? "1" : "0"
                }
                
                pipelineTracker?.markStage("firmware_execution", metadata: metadata)
            } else if line.hasPrefix("ACK TRACE:") {
                pipelineTracker?.markStage("ack_received", metadata: ["ack_trace_id": "\(traceID)"])
            }
        }
    }
    
    /// Print pipeline summary with all latencies
    private func printPipelineSummary(traceID: UInt64, command: String) {
        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("TRACE \(traceID)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        if let latency = timestamps.latency(from: timestamps.voiceDetected, to: timestamps.llmStart) {
            print("Voice → LLM        \(String(format: "%6.1f", latency)) ms")
        }
        if let latency = timestamps.latency(from: timestamps.llmStart, to: timestamps.llmDone) {
            print("LLM Processing     \(String(format: "%6.1f", latency)) ms")
        }
        if let latency = timestamps.latency(from: timestamps.llmDone, to: timestamps.agentDispatch) {
            print("LLM → Agent        \(String(format: "%6.1f", latency)) ms")
        }
        if let latency = timestamps.latency(from: timestamps.agentDispatch, to: timestamps.serialWrite) {
            print("Agent → Serial     \(String(format: "%6.1f", latency)) ms")
        }
        if let latency = timestamps.latency(from: timestamps.serialWrite, to: timestamps.ackReceived) {
            print("Serial → ACK       \(String(format: "%6.1f", latency)) ms")
        }
        
        if let voice = timestamps.voiceDetected, let ack = timestamps.ackReceived {
            let total = timestamps.latency(from: voice, to: ack) ?? 0
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("TOTAL              \(String(format: "%6.1f", total)) ms")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    }
    
    /// Mark voice detected timestamp (call from voice input handler)
    public func markVoiceDetected() {
        let traceID = generateTraceID()
        currentTraceID = traceID
        pipelineTracker = PipelineTracker(traceID: traceID)
        
        timestamps.voiceDetected = Date()
        pipelineTracker?.markStage("voice_detected")
        
        let signpostID = Telemetry.shared.beginSpan(name: "voice_processing" as StaticString, traceID: traceID)
        signpostIDs["voice_processing"] = signpostID
    }
    
    /// Mark speech transcribed timestamp
    public func markSpeechTranscribed(transcript: String) {
        pipelineTracker?.markStage("speech_transcribed", metadata: ["transcript": transcript])
    }
    
    /// Mark LLM start timestamp (call from LLM handler)
    public func markLLMStart() {
        timestamps.llmStart = Date()
        pipelineTracker?.markStage("llm_start")
        
        if let signpostID = signpostIDs["voice_processing"] {
            Telemetry.shared.endSpan(name: "voice_processing" as StaticString, signpostID: signpostID, traceID: currentTraceID)
        }
        
        let signpostID = Telemetry.shared.beginSpan(name: "llm_call" as StaticString, traceID: currentTraceID)
        signpostIDs["llm_call"] = signpostID
    }
    
    /// Mark LLM done timestamp (call from LLM handler)
    /// - Parameter voicePhrase: Original voice phrase (for consistency tracking)
    /// - Parameter llmCommand: Command output by LLM (for consistency tracking)
    public func markLLMDone(voicePhrase: String? = nil, llmCommand: String? = nil) {
        timestamps.llmDone = Date()
        
        var metadata: [String: String] = [:]
        if let phrase = voicePhrase {
            metadata["voice_phrase"] = phrase
        }
        if let cmd = llmCommand {
            metadata["llm_command"] = cmd
        }
        
        pipelineTracker?.markStage("llm_done", metadata: metadata)
        
        if let signpostID = signpostIDs["llm_call"] {
            Telemetry.shared.endSpan(name: "llm_call" as StaticString, signpostID: signpostID, traceID: currentTraceID)
        }
        
        // Record LLM consistency if phrase and command provided
        if let phrase = voicePhrase, let cmd = llmCommand {
            TelemetryMetrics.shared.llmConsistency.record(phrase: phrase, command: cmd)
        }
    }
    
    /// Mark route decision timestamp
    public func markRouteDecision(decision: String, confidence: Double? = nil) {
        var metadata: [String: String] = ["decision": decision]
        if let conf = confidence {
            metadata["confidence"] = String(format: "%.2f", conf)
        }
        pipelineTracker?.markStage("route_decision", metadata: metadata)
    }
    
    /// Mark tool invoked timestamp
    public func markToolInvoked(toolName: String) {
        pipelineTracker?.markStage("tool_invoked", metadata: ["tool": toolName])
        
        let signpostID = Telemetry.shared.beginSpan(name: "agent_dispatch" as StaticString, traceID: currentTraceID)
        signpostIDs["agent_dispatch"] = signpostID
    }
    
    /// Mark agent dispatch timestamp (call from agent runtime)
    public func markAgentDispatch() {
        timestamps.agentDispatch = Date()
        pipelineTracker?.markStage("agent_dispatch")
        
        if let signpostID = signpostIDs["agent_dispatch"] {
            Telemetry.shared.endSpan(name: "agent_dispatch" as StaticString, signpostID: signpostID, traceID: currentTraceID)
        }
    }
    
    /// Record a failure for metrics tracking
    public func recordFailure(command: String, error: String) {
        TelemetryMetrics.shared.failureAnalyzer.record(command: command, error: error)
        TelemetryMetrics.shared.successRate.record(command: command, success: false)
    }
    
    /// Print comprehensive metrics report
    public func printMetricsReport() {
        TelemetryMetrics.shared.printReport()
    }
    
    /// Send a text command (backward compatibility)
    /// Supports multiple commands separated by spaces: "RED ON GREEN ON BLUE ON"
    /// - Parameter command: LED command(s) (e.g., "RED ON", "ALL OFF", "RED ON GREEN ON")
    /// - Returns: True if all ACKs received, false if any timeout
    @discardableResult
    public func sendCommand(_ command: String) throws -> Bool {
        let uppercased = command.uppercased()
        
        // Try to parse as multiple commands first (e.g., "RED ON GREEN ON BLUE ON")
        let commands = DeviceManagerCommandHelper.parseMultipleCommands(uppercased)
        
        if commands.count > 1 {
            // Multiple commands - send each separately
            var allSucceeded = true
            for (cmdID, value) in commands {
                if !(try sendBinaryCommand(commandID: cmdID, value: value)) {
                    allSucceeded = false
                }
                // Small delay between commands
                usleep(50_000) // 50ms
            }
            return allSucceeded
        }
        
        // Single command - try to parse as binary command
        if let (cmdID, value) = DeviceManagerCommandHelper.parseTextCommand(uppercased) {
            return try sendBinaryCommand(commandID: cmdID, value: value)
        }
        
        // Anything else (GPIO, PWM, ADC, SERVO SWEEP, ...) goes over the firmware's
        // text command path as a plain line. Binary frames only carry PicoCommandV1.
        return try sendAndReadResponse(Data((uppercased + "\n").utf8))
    }
    
    /// Query LED state from Pico
    /// - Returns: Dictionary of LED states, or nil if query failed
    public func queryState() throws -> [String: Bool]? {
        guard try sendBinaryCommand(commandID: .queryState, value: 0) else {
            return nil
        }
        
        // Read STATE response
        let responseData = try serialPort.read(maxBytes: 128, timeoutMs: 500)
        
        if let response = String(data: responseData, encoding: .utf8),
           response.contains("STATE:") {
            return parseStateResponse(response)
        }
        
        return nil
    }
    
    /// Query device status (health check)
    /// - Returns: Status dictionary with GPIO states, uptime, firmware version, etc.
    public func queryStatus() throws -> [String: String]? {
        // Send STATUS command via text mode (simpler)
        if !serialPort.isOpen {
            try serialPort.open(baudRate: 115200)
        }
        
        // Send STATUS command
        let statusCmd = "STATUS\n"
        try serialPort.write(statusCmd.data(using: .utf8)!)
        
        // Read response (up to 512 bytes, 1 second timeout)
        let responseData = try serialPort.read(maxBytes: 512, timeoutMs: 1000)
        
        guard let response = String(data: responseData, encoding: .utf8) else {
            return nil
        }
        
        // Parse STATUS response
        var status: [String: String] = [:]
        let lines = response.components(separatedBy: .newlines)
        
        for line in lines {
            if line.hasPrefix("STATUS:") {
                status["status"] = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("GPIO:") {
                status["gpio"] = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("UPTIME:") {
                status["uptime_ms"] = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("FW:") {
                status["firmware"] = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("READY:") {
                status["ready"] = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            }
        }
        
        return status.isEmpty ? nil : status
    }
    
    /// Ping device (connection verification)
    /// - Returns: True if PONG received
    public func ping() throws -> Bool {
        if !serialPort.isOpen {
            try serialPort.open(baudRate: 115200)
        }
        
        // Send PING command
        let pingCmd = "PING\n"
        try serialPort.write(pingCmd.data(using: .utf8)!)
        
        // Read PONG response (up to 64 bytes, 500ms timeout)
        let responseData = try serialPort.read(maxBytes: 64, timeoutMs: 500)
        
        if let response = String(data: responseData, encoding: .utf8),
           response.contains("PONG") {
            return true
        }
        
        return false
    }
    
    /// Parse STATE response from Pico
    private func parseStateResponse(_ response: String) -> [String: Bool]? {
        // Format: "STATE: R=1 G=0 Y=1 B=0 M=0"
        var states: [String: Bool] = [:]
        
        let components = response.replacingOccurrences(of: "STATE:", with: "")
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
        
        for component in components {
            let parts = component.split(separator: "=")
            if parts.count == 2 {
                let led = String(parts[0])
                let value = String(parts[1])
                states[led] = (value == "1")
            }
        }
        
        return states.isEmpty ? nil : states
    }
    
    /// Build the BlazeTransport packet carrying one PicoCommandV1
    private func buildCommandPacket(_ command: PicoCommandV1) -> BlazePacket {
        let packet = PicoWire.commandPacket(packetNumber: packetNumber, command: command)
        packetNumber += 1
        return packet
    }
    
    /// Send a BlazeTransport packet and wait for ACK
    /// - Parameters:
    ///   - packet: BlazeTransport packet
    ///   - traceID: Trace ID for correlation
    /// - Returns: True if ACK received, false if timeout
    private func sendPacket(_ packet: BlazePacket, traceID: UInt64) throws -> Bool {
        return try sendAndReadResponse(PicoWire.serialFrame(packet))
    }

    /// Write bytes and parse the firmware's response for up to 500ms
    /// - Returns: True if ACK received, false if timeout
    private func sendAndReadResponse(_ fullPacket: Data) throws -> Bool {
        // Open serial port if not already open
        if !serialPort.isOpen {
            try serialPort.open(baudRate: 115200)
        }
        
        // Send packet (includes flush + wait)
        try serialPort.write(fullPacket)
        
        // Wait for ACK from Pico (up to 500ms as per requirements)
        // Pico sends: "TRACE:<id> CMD:<n> VAL:<n> EXEC_US:<n> GPIO:<0|1>\nACK TRACE:<id> CMD:<n> VAL:<n> GPIO:<0|1>\n"
        let ackData = try serialPort.read(maxBytes: 512, timeoutMs: 500)
        
        if let ackString = String(data: ackData, encoding: .utf8) {
            // Parse firmware stage markers
            let lines = ackString.components(separatedBy: .newlines)
            for line in lines {
                // Parse PACKET RECEIVED
                if line.hasPrefix("PACKET RECEIVED TRACE:") {
                    let traceStr = String(line.dropFirst("PACKET RECEIVED TRACE:".count))
                    if let firmwareTraceID = UInt64(traceStr) {
                        pipelineTracker?.markStage("packet_received", metadata: ["firmware_trace_id": "\(firmwareTraceID)"])
                    }
                }
                // Parse COMMAND PARSED
                else if line.hasPrefix("COMMAND PARSED TRACE:") {
                    let parts = line.split(separator: " ")
                    var cmdID: UInt8? = nil
                    var value: UInt8? = nil
                    for part in parts {
                        if part.hasPrefix("CMD:") {
                            cmdID = UInt8(String(part.dropFirst(4)))
                        } else if part.hasPrefix("VAL:") {
                            value = UInt8(String(part.dropFirst(4)))
                        }
                    }
                    var metadata: [String: String] = [:]
                    if let cmdID = cmdID { metadata["commandID"] = "\(cmdID)" }
                    if let value = value { metadata["value"] = "\(value)" }
                    pipelineTracker?.markStage("command_parsed", metadata: metadata)
                }
                // Parse GPIO_SET_START
                else if line.hasPrefix("GPIO_SET_START TRACE:") {
                    pipelineTracker?.markStage("gpio_set_start")
                }
                // Parse GPIO_SET_DONE
                else if line.hasPrefix("GPIO_SET_DONE TRACE:") {
                    pipelineTracker?.markStage("gpio_set_done")
                }
                // Parse GPIO_READBACK
                else if line.hasPrefix("GPIO_READBACK TRACE:") {
                    let parts = line.split(separator: " ")
                    var gpioValue: Bool? = nil
                    for part in parts {
                        if part.hasPrefix("GPIO:") {
                            gpioValue = (String(part.dropFirst(5)) == "1")
                        }
                    }
                    var metadata: [String: String] = [:]
                    if let gpio = gpioValue {
                        metadata["gpio_value"] = gpio ? "1" : "0"
                    }
                    pipelineTracker?.markStage("gpio_readback", metadata: metadata)
                }
                // Parse TRACE telemetry line
                else if line.hasPrefix("TRACE:") {
                        // Parse: TRACE:928347239847 CMD:1 VAL:1 EXEC_US:2000 GPIO:1
                        let parts = line.split(separator: " ")
                        var firmwareTraceID: UInt64? = nil
                        var execUs: UInt64? = nil
                        var gpioFeedback: Bool? = nil
                        var cmdID: UInt8? = nil
                        var value: UInt8? = nil
                        
                        for part in parts {
                            if part.hasPrefix("TRACE:") {
                                let traceStr = String(part.dropFirst(6))
                                firmwareTraceID = UInt64(traceStr)
                            } else if part.hasPrefix("CMD:") {
                                let cmdStr = String(part.dropFirst(4))
                                cmdID = UInt8(cmdStr)
                            } else if part.hasPrefix("VAL:") {
                                let valStr = String(part.dropFirst(4))
                                value = UInt8(valStr)
                            } else if part.hasPrefix("EXEC_US:") {
                                let execStr = String(part.dropFirst(8))
                                execUs = UInt64(execStr)
                            } else if part.hasPrefix("GPIO:") {
                                let gpioStr = String(part.dropFirst(5))
                                gpioFeedback = (gpioStr == "1")
                            }
                        }
                        
                        if let firmwareTraceID = firmwareTraceID {
                            var metadata: [String: String] = [:]
                            if let execUs = execUs {
                                let execMs = Double(execUs) / 1000.0
                                metadata["exec_us"] = "\(execUs)"
                                metadata["exec_ms"] = String(format: "%.3f", execMs)
                            }
                            if let gpio = gpioFeedback {
                                metadata["gpio_feedback"] = gpio ? "1" : "0"
                            }
                            if let cmdID = cmdID {
                                metadata["commandID"] = "\(cmdID)"
                            }
                            if let value = value {
                                metadata["value"] = "\(value)"
                            }
                            
                            pipelineTracker?.markStage("firmware_execution", metadata: metadata)
                            
                            if let execUs = execUs {
                                let execMs = Double(execUs) / 1000.0
                                TelemetryMetrics.shared.failureAnalyzer.record(
                                    command: "\(cmdID ?? 0):\(value ?? 0)",
                                    error: execMs > 10.0 ? "Slow execution: \(execMs)ms" : "OK"
                                )
                            }
                        }
                    }
                }
            
            // Parse ACK line: ACK TRACE:<id> CMD:<n> VAL:<n> GPIO:<0|1>
            if ackString.contains("ACK TRACE:") {
                let lines = ackString.components(separatedBy: .newlines)
                for line in lines {
                    if line.hasPrefix("ACK TRACE:") {
                        // Parse ACK with trace ID
                        let parts = line.split(separator: " ")
                        var ackTraceID: UInt64? = nil
                        var gpioFeedback: Bool? = nil
                        
                        for part in parts {
                            if part.hasPrefix("TRACE:") {
                                let traceStr = String(part.dropFirst(6))
                                ackTraceID = UInt64(traceStr)
                            } else if part.hasPrefix("GPIO:") {
                                let gpioStr = String(part.dropFirst(5))
                                gpioFeedback = (gpioStr == "1")
                            }
                        }
                        
                        if let ackTraceID = ackTraceID {
                            var metadata: [String: String] = ["ack_trace_id": "\(ackTraceID)"]
                            if let gpio = gpioFeedback {
                                metadata["gpio_confirmed"] = gpio ? "1" : "0"
                            }
                            pipelineTracker?.markStage("ack_received", metadata: metadata)
                            return true
                        }
                    }
                }
            }
            
            // Fallback: Check for legacy ACK formats
            if ackString.contains("ACK:") || 
               ackString.contains("STATE:") || 
               ackString.contains("PACKET RECEIVED") ||
               ackString.contains("CMD:") {
                pipelineTracker?.markStage("ack_received", metadata: ["format": "legacy"])
                return true
            }
        }
        
        // Timeout - no ACK received
        pipelineTracker?.markStage("ack_timeout", metadata: ["timeout_ms": "500"])
        return false
    }
    
    /// Close the serial port connection
    public func close() {
        serialPort.close()
    }
}
