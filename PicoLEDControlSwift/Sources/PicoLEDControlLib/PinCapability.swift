import Foundation

/// Runtime state of a single GPIO pin (snapshot, may be stale)
public enum PinRuntimeState: Sendable, Equatable {
    case idle
    case gpioOutput(high: Bool)
    case gpioInput
    case activePWM
}

/// Static + runtime capability descriptor for a single pin
public struct PinCapability: Sendable {
    public let pin: Int
    public let supportsGPIO: Bool
    public let supportsPWM: Bool
    public let supportsADC: Bool
    public let reserved: Bool
    public var runtimeState: PinRuntimeState?
    
    public init(pin: Int, supportsGPIO: Bool, supportsPWM: Bool, supportsADC: Bool, reserved: Bool, runtimeState: PinRuntimeState? = nil) {
        self.pin = pin
        self.supportsGPIO = supportsGPIO
        self.supportsPWM = supportsPWM
        self.supportsADC = supportsADC
        self.reserved = reserved
        self.runtimeState = runtimeState
    }
    
    /// Parse a firmware PINMAP line like "PIN 5 GPIO PWM ACTIVE_PWM"
    public static func parse(line: String) -> PinCapability? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "PIN", let pin = Int(parts[1]),
              pin >= 0 && pin <= 29 else {
            return nil
        }
        let tokens = Set(parts.dropFirst(2).map { String($0) })
        
        let reserved = tokens.contains("RESERVED")
        let supportsGPIO = tokens.contains("GPIO")
        let supportsPWM = tokens.contains("PWM")
        let supportsADC = tokens.contains("ADC")
        
        var runtimeState: PinRuntimeState? = nil
        if tokens.contains("ACTIVE_PWM") {
            runtimeState = .activePWM
        } else if tokens.contains("OUTPUT") {
            runtimeState = .gpioOutput(high: tokens.contains("HIGH"))
        } else if tokens.contains("INPUT") {
            runtimeState = .gpioInput
        }
        
        return PinCapability(
            pin: pin,
            supportsGPIO: supportsGPIO,
            supportsPWM: supportsPWM,
            supportsADC: supportsADC,
            reserved: reserved,
            runtimeState: runtimeState
        )
    }
}

/// Full device capability descriptor, populated from DEVICE_INFO + PINMAP
public struct DeviceCapabilities: Sendable {
    public let model: String
    public let firmwareVersion: String
    public let protocolVersion: Int
    public let deviceID: String
    public let maxCommandLength: Int
    public let gpioCount: Int
    public let adcPins: Int
    public let pwmSlices: Int
    public let reservedCount: Int
    public var pins: [PinCapability]
    
    public init(model: String, firmwareVersion: String, protocolVersion: Int, deviceID: String, maxCommandLength: Int, gpioCount: Int, adcPins: Int, pwmSlices: Int, reservedCount: Int, pins: [PinCapability]) {
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.maxCommandLength = maxCommandLength
        self.gpioCount = gpioCount
        self.adcPins = adcPins
        self.pwmSlices = pwmSlices
        self.reservedCount = reservedCount
        self.pins = pins
    }
    
    /// Parse DEVICE_INFO key-value lines (between BEGIN/END) into partial capabilities.
    /// Pins are populated separately from PINMAP.
    public static func parseDeviceInfo(lines: [String]) -> DeviceCapabilities {
        var dict: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eqIdx])
                let value = String(trimmed[trimmed.index(after: eqIdx)...])
                dict[key] = value
            }
        }
        return DeviceCapabilities(
            model: dict["MODEL"] ?? "UNKNOWN",
            firmwareVersion: dict["FW_VERSION"] ?? "0.0.0",
            protocolVersion: Int(dict["PROTOCOL"] ?? "0") ?? 0,
            deviceID: dict["DEVICE_ID"] ?? "",
            maxCommandLength: Int(dict["MAX_CMD"] ?? "128") ?? 128,
            gpioCount: Int(dict["GPIO_COUNT"] ?? "30") ?? 30,
            adcPins: Int(dict["ADC_PINS"] ?? "4") ?? 4,
            pwmSlices: Int(dict["PWM_SLICES"] ?? "8") ?? 8,
            reservedCount: Int(dict["RESERVED_COUNT"] ?? "0") ?? 0,
            pins: []
        )
    }
    
    /// Parse PINMAP lines (between BEGIN/END) into pin capabilities
    public static func parsePinMap(lines: [String]) -> [PinCapability] {
        return lines.compactMap { PinCapability.parse(line: $0) }
    }
    
    /// Human-readable summary
    public var summary: String {
        var s = "\(model) FW=\(firmwareVersion) PROTO=\(protocolVersion) ID=\(deviceID) MAX_CMD=\(maxCommandLength)"
        s += " GPIO=\(gpioCount) ADC=\(adcPins) PWM=\(pwmSlices) RESERVED=\(reservedCount)"
        s += " pins=\(pins.count)"
        return s
    }
}
