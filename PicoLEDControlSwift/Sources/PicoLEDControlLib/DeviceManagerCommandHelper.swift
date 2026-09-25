import Foundation

/// Helper for AgentDaemon to send commands via DeviceManager's persistent session
/// This eliminates port conflicts by using the shared persistent session instead of spawning CLI processes
public struct DeviceManagerCommandHelper {
    
    /// Parse text command (e.g., "RED ON", "GREEN OFF", "MULTIRED 50") into CommandID and value
    public static func parseTextCommand(_ command: String) -> (CommandID, UInt8)? {
        let uppercased = command.uppercased().trimmingCharacters(in: .whitespaces)
        let parts = uppercased.split(separator: " ")
        
        guard parts.count >= 2 else { return nil }
        
        let color = String(parts[0])
        let state = String(parts[1])
        
        if color == "SERVO", let angle = Int(state), angle >= 0 && angle <= 180 {
            return (.servoSet, UInt8(angle))
        }
        
        guard let commandID = parseColorToCommandID(color) else { return nil }
        
        if let brightness = Int(state), brightness >= 0 && brightness <= 100,
           isMultiLEDCommand(commandID) {
            return (commandID, UInt8(brightness))
        }
        
        guard let value = parseStateToValue(state) else { return nil }
        return (commandID, value)
    }
    
    private static func isMultiLEDCommand(_ cmd: CommandID) -> Bool {
        [.multi, .multiRed, .multiGreen, .multiBlue].contains(cmd)
    }
    
    /// Parse multiple commands from a string like "RED ON GREEN ON BLUE ON"
    public static func parseMultipleCommands(_ command: String) -> [(CommandID, UInt8)] {
        let uppercased = command.uppercased().trimmingCharacters(in: .whitespaces)
        let parts = uppercased.split(separator: " ")
        
        var commands: [(CommandID, UInt8)] = []
        var i = 0
        
        while i < parts.count - 1 {
            let color = String(parts[i])
            let state = String(parts[i + 1])
            
            if color == "SERVO", let angle = Int(state), angle >= 0 && angle <= 180 {
                commands.append((.servoSet, UInt8(angle)))
            } else if let cmdID = parseColorToCommandID(color) {
                if let brightness = Int(state), brightness >= 0 && brightness <= 100,
                   isMultiLEDCommand(cmdID) {
                    commands.append((cmdID, UInt8(brightness)))
                } else if let value = parseStateToValue(state) {
                    commands.append((cmdID, value))
                }
            }
            
            i += 2
        }
        
        return commands
    }
    
    /// Parse color string to CommandID
    private static func parseColorToCommandID(_ color: String) -> CommandID? {
        switch color.uppercased() {
        case "RED", "R":
            return .red
        case "GREEN", "G":
            return .green
        case "YELLOW", "Y":
            return .yellow
        case "BLUE", "B":
            return .blue
        case "ALL":
            return .all
        case "MULTI", "M":
            return .multi
        case "MULTIRED", "MR":
            return .multiRed
        case "MULTIGREEN", "MG":
            return .multiGreen
        case "MULTIBLUE", "MB":
            return .multiBlue
        default:
            return nil
        }
    }
    
    /// Parse state string to value (0 = OFF, 1 = ON)
    private static func parseStateToValue(_ state: String) -> UInt8? {
        switch state.uppercased() {
        case "ON", "1", "TRUE":
            return 1
        case "OFF", "0", "FALSE":
            return 0
        default:
            return nil
        }
    }
    
    /// Send a text command via DeviceManager's persistent session
    /// This is the recommended way for AgentDaemon to send commands - no port conflicts!
    /// 
    /// Example:
    ///   try await DeviceManagerCommandHelper.sendCommand("GREEN ON")
    ///   try await DeviceManagerCommandHelper.sendCommand("ALL OFF")
    ///   try await DeviceManagerCommandHelper.sendCommand("RED ON GREEN ON BLUE ON")
    ///
    /// - Parameter command: Text command (e.g., "RED ON", "ALL OFF")
    /// - Returns: Success status and optional state from STATE_CHANGE event
    /// - Throws: Connection errors, parse errors
    public static func sendCommand(_ command: String) async throws -> (success: Bool, state: [String: Bool]?) {
        let uppercased = command.uppercased().trimmingCharacters(in: .whitespaces)
        let startTime = Date()
        let log = PipelineLog.shared
        
        // Try to parse as multiple commands first
        let multipleCommands = parseMultipleCommands(uppercased)
        
        if multipleCommands.count > 1 {
            log.command("batch_start", command: uppercased)
            let session = try await DeviceManager.shared.getSession()
            var lastState: [String: Bool]? = nil
            
            for (cmdID, value) in multipleCommands {
                let result = try await session.sendCommandWithCompletion(
                    commandID: cmdID,
                    value: value,
                    ackTimeoutMs: 500,
                    stateTimeoutMs: 50
                )
                lastState = result.state
            }
            
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            log.command("batch_done", command: uppercased, durationMs: ms, state: lastState)
            return (success: true, state: lastState)
        }
        
        guard let (cmdID, value) = parseTextCommand(uppercased) else {
            log.command("parse_error", command: uppercased)
            throw NSError(
                domain: "DeviceManagerCommandHelper",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse command: \(command)"]
            )
        }
        
        log.command("cmd_start", command: uppercased)
        let session = try await DeviceManager.shared.getSession()
        
        let result = try await session.sendCommandWithCompletion(
            commandID: cmdID,
            value: value,
            ackTimeoutMs: 500,
            stateTimeoutMs: 50
        )
        
        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        if result.success {
            log.command("cmd_done", command: uppercased, durationMs: ms, state: result.state)
        } else {
            log.command("ack_timeout", command: uppercased, durationMs: ms)
        }
        
        return (success: result.success, state: result.state)
    }
    
    /// Send a servo angle command (0-180) via DeviceManager's persistent session
    public static func sendServoCommand(angle: Int) async throws -> (success: Bool, state: [String: Bool]?) {
        let log = PipelineLog.shared
        let clampedAngle = min(max(angle, 0), 180)
        log.command("servo_start", command: "SERVO \(clampedAngle)")
        
        let startTime = Date()
        let session = try await DeviceManager.shared.getSession()
        let result = try await session.sendServoCommand(angle: clampedAngle)
        
        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        if result.success {
            log.command("servo_done", command: "SERVO \(clampedAngle)", durationMs: ms, state: result.state)
        } else {
            log.command("servo_ack_timeout", command: "SERVO \(clampedAngle)", durationMs: ms)
        }
        
        return result
    }
    
    /// Get last known servo angle from session event reader cache
    public static func getServoAngle() async throws -> Int? {
        let session = try await DeviceManager.shared.getSession()
        return session.lastKnownServoAngle
    }
    
    // MARK: - Generic GPIO Control
    
    /// GPIO pin mode for generic pin configuration
    public enum GPIOPinMode: String {
        case output = "OUT"
        case input = "IN"
        case inputPullUp = "IN_PU"
        case inputPullDown = "IN_PD"
    }
    
    /// Set a GPIO pin high or low
    /// - Parameters:
    ///   - pin: GPIO pin number (0-29, excluding reserved pins)
    ///   - value: true = high, false = low
    /// - Throws: If pin is out of range, reserved, or write fails
    public static func gpioSet(pin: Int, value: Bool) async throws {
        let session = try await DeviceManager.shared.getSession()
        let cmd = "GPIO SET \(pin) \(value ? 1 : 0)"
        let response = try await session.sendTextCommand(cmd, responsePrefix: "OK", timeoutMs: 2000)
        if let resp = response, resp.hasPrefix("ERROR:") {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -10,
                         userInfo: [NSLocalizedDescriptionKey: resp])
        }
        guard response != nil else {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -11,
                         userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for GPIO SET response"])
        }
    }
    
    /// Read the digital value of a GPIO pin
    /// - Parameter pin: GPIO pin number (0-29, excluding reserved pins)
    /// - Returns: 0 or 1
    /// - Throws: If pin is out of range, reserved, or read fails
    public static func gpioGet(pin: Int) async throws -> Int {
        let session = try await DeviceManager.shared.getSession()
        let cmd = "GPIO GET \(pin)"
        let response = try await session.sendTextCommand(cmd, responsePrefix: "GPIO_READ:", timeoutMs: 2000)
        guard let resp = response else {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -11,
                         userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for GPIO GET response"])
        }
        if resp.hasPrefix("ERROR:") {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -10,
                         userInfo: [NSLocalizedDescriptionKey: resp])
        }
        // Parse "GPIO_READ: pin=5 value=1"
        guard let valueRange = resp.range(of: "value="),
              let val = Int(String(resp[valueRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -12,
                         userInfo: [NSLocalizedDescriptionKey: "Malformed GPIO_READ response: \(resp)"])
        }
        return val
    }
    
    /// Set GPIO pin direction and pull configuration
    /// - Parameters:
    ///   - pin: GPIO pin number (0-29, excluding reserved pins)
    ///   - mode: Pin mode (output, input, input with pull-up, input with pull-down)
    /// - Throws: If pin is out of range, reserved, or configuration fails
    public static func gpioMode(pin: Int, mode: GPIOPinMode) async throws {
        let session = try await DeviceManager.shared.getSession()
        let cmd = "GPIO MODE \(pin) \(mode.rawValue)"
        let response = try await session.sendTextCommand(cmd, responsePrefix: "OK", timeoutMs: 2000)
        if let resp = response, resp.hasPrefix("ERROR:") {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -10,
                         userInfo: [NSLocalizedDescriptionKey: resp])
        }
        guard response != nil else {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -11,
                         userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for GPIO MODE response"])
        }
    }
    
    // MARK: - Generic PWM Control
    
    /// Enable PWM on a pin with specified frequency and duty cycle
    /// - Parameters:
    ///   - pin: GPIO pin number (0-29, excluding reserved pins)
    ///   - frequency: PWM frequency in Hz (1-62500000)
    ///   - duty: Duty cycle percentage (0-100)
    /// - Throws: If parameters are out of range, pin is reserved, or configuration fails
    public static func pwmSet(pin: Int, frequency: Int, duty: Int) async throws {
        let session = try await DeviceManager.shared.getSession()
        let cmd = "PWM SET \(pin) \(frequency) \(duty)"
        let response = try await session.sendTextCommand(cmd, responsePrefix: "OK", timeoutMs: 2000)
        if let resp = response, resp.hasPrefix("ERROR:") {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -10,
                         userInfo: [NSLocalizedDescriptionKey: resp])
        }
        guard response != nil else {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -11,
                         userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for PWM SET response"])
        }
    }
    
    /// Disable PWM on a pin and return it to GPIO mode
    /// - Parameter pin: GPIO pin number with active PWM
    /// - Throws: If pin has no active PWM, is reserved, or operation fails
    public static func pwmStop(pin: Int) async throws {
        let session = try await DeviceManager.shared.getSession()
        let cmd = "PWM STOP \(pin)"
        let response = try await session.sendTextCommand(cmd, responsePrefix: "OK", timeoutMs: 2000)
        if let resp = response, resp.hasPrefix("ERROR:") {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -10,
                         userInfo: [NSLocalizedDescriptionKey: resp])
        }
        guard response != nil else {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -11,
                         userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for PWM STOP response"])
        }
    }
    
    // MARK: - ADC Control
    
    /// Read the analog value from an ADC-capable pin
    /// - Parameter pin: ADC pin number (26-29 on RP2350)
    /// - Returns: 12-bit raw ADC value (0-4095)
    /// - Throws: If pin is not ADC-capable, reserved, or read fails
    public static func adcRead(pin: Int) async throws -> Int {
        let session = try await DeviceManager.shared.getSession()
        let cmd = "ADC READ \(pin)"
        let response = try await session.sendTextCommand(cmd, responsePrefix: "ADC_READ:", timeoutMs: 2000)
        guard let resp = response else {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -11,
                         userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for ADC READ response"])
        }
        if resp.hasPrefix("ERROR:") {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -10,
                         userInfo: [NSLocalizedDescriptionKey: resp])
        }
        // Parse "ADC_READ: pin=26 value=3789"
        guard let valueRange = resp.range(of: "value="),
              let val = Int(String(resp[valueRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -12,
                         userInfo: [NSLocalizedDescriptionKey: "Malformed ADC_READ response: \(resp)"])
        }
        return val
    }
    
    /// Query device state via DeviceManager's persistent session.
    /// Returns cached GPIO state from session's event reader (populated by
    /// boot STATE, QUERY_STATE responses, and STATE_CHANGE events).
    /// Only sends a QUERY_STATE command if no cached state is available.
    public static func queryState() async throws -> [String: Bool]? {
        let session = try await DeviceManager.shared.getSession()
        
        // Fast path: return cached state from event reader (no I/O needed)
        if let cached = session.lastKnownGPIOState, !cached.isEmpty {
            return cached
        }
        
        // No cached state yet - send QUERY_STATE to populate it
        return try await session.queryState(timeoutMs: 1000)
    }
    
    /// Send ENTER_BOOTLOADER command via binary protocol.
    /// Device will ACK then reboot into USB bootloader. Serial disconnect is expected.
    /// Returns true if ACK was received before disconnect.
    public static func enterBootloader() async throws -> Bool {
        let log = PipelineLog.shared
        log.command("bootloader_enter", command: "ENTER_BOOTLOADER")
        
        let session = try await DeviceManager.shared.getSession()
        
        // Mark DeviceManager so it treats the upcoming disconnect as intentional
        await DeviceManager.shared.setBootloaderTransition(true)
        
        do {
            let result = try await session.sendCommandWithCompletion(
                commandID: .enterBootloader,
                value: 1,
                ackTimeoutMs: 2000,
                stateTimeoutMs: 0
            )
            log.command("bootloader_ack", command: "ENTER_BOOTLOADER")
            return result.success
        } catch {
            // Disconnect during/after ACK is expected — device rebooted into bootloader
            let msg = "\(error)"
            if msg.contains("disconnected") || msg.contains("closed") || msg.contains("broken pipe") || msg.contains("EAGAIN") {
                log.command("bootloader_transition", command: "ENTER_BOOTLOADER (disconnect = success)")
                return true
            }
            // Unexpected error: clear bootloader transition so reconnect is not suppressed
            await DeviceManager.shared.setBootloaderTransition(false)
            throw error
        }
    }
    
    /// Get cached device capabilities (populated on connect, no I/O)
    public static func getDeviceCapabilities() async throws -> DeviceCapabilities {
        guard let caps = await DeviceManager.shared.deviceCapabilities else {
            throw NSError(domain: "DeviceManagerCommandHelper", code: -20,
                         userInfo: [NSLocalizedDescriptionKey: "Device capabilities not available (device not connected?)"])
        }
        return caps
    }
    
    /// Refresh pin map from firmware (sends PINMAP command, returns updated capabilities)
    public static func refreshPinMap() async throws -> [PinCapability] {
        return try await DeviceManager.shared.refreshPinMap()
    }
    
    /// Initialize DeviceManager (call this once at AgentDaemon startup)
    /// This opens the persistent session and keeps it open
    public static func initialize() async throws {
        try await DeviceManager.shared.warmStart()
    }
}
