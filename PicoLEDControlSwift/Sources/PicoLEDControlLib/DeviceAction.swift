import Foundation

/// Unified hardware action model.
///
/// Replaces the fragmented action types (`ToolAction`, `FastPathAction`,
/// `HardwareCommandRequest`) with a single canonical representation of every
/// hardware operation the system can perform.
///
/// Usage:
///
///     let actions: [DeviceAction] = [
///         .led(target: .red, state: .on),
///         .gpioSet(pin: 5, value: true),
///         .pwmStart(pin: 9, frequency: 1000, duty: 50),
///     ]
///
public enum DeviceAction: Sendable, Equatable, CustomStringConvertible {

    // MARK: - LED control (binary protocol path)

    case led(target: LEDTarget, state: OnOffToggle)

    /// Set the RGB LED to a semantic or explicit color.
    /// The adapter layer resolves named colors to device-specific RGB values.
    case setLEDColor(LEDColor)

    // MARK: - Generic GPIO

    case gpioSet(pin: Int, value: Bool)
    case gpioRead(pin: Int)
    case gpioMode(pin: Int, mode: PinDirection)

    // MARK: - PWM

    case pwmStart(pin: Int, frequency: Int, duty: Int)
    case pwmStop(pin: Int)

    // MARK: - ADC

    case adcRead(pin: Int)

    // MARK: - Servo

    case servoSet(angle: Int)

    // MARK: - Queries

    case queryState
    case queryCapabilities
    case queryPinmap

    // MARK: - System

    case enterBootloader

    // MARK: - Monitoring

    case monitor(MonitoringRule)
    case stopMonitoring(id: UUID?)

    // MARK: - Description

    public var description: String {
        switch self {
        case .led(let target, let state):
            return "led(\(target.rawValue), \(state.rawValue))"
        case .setLEDColor(let color):
            return "setLEDColor(\(color))"
        case .gpioSet(let pin, let value):
            return "gpioSet(pin=\(pin), \(value ? "high" : "low"))"
        case .gpioRead(let pin):
            return "gpioRead(pin=\(pin))"
        case .gpioMode(let pin, let mode):
            return "gpioMode(pin=\(pin), \(mode.rawValue))"
        case .pwmStart(let pin, let freq, let duty):
            return "pwmStart(pin=\(pin), \(freq)Hz, \(duty)%)"
        case .pwmStop(let pin):
            return "pwmStop(pin=\(pin))"
        case .adcRead(let pin):
            return "adcRead(pin=\(pin))"
        case .servoSet(let angle):
            return "servoSet(\(angle)°)"
        case .queryState:
            return "queryState"
        case .queryCapabilities:
            return "queryCapabilities"
        case .queryPinmap:
            return "queryPinmap"
        case .enterBootloader:
            return "enterBootloader"
        case .monitor(let rule):
            return "monitor(\(rule.description))"
        case .stopMonitoring(let id):
            return "stopMonitoring(\(id?.uuidString.prefix(8) ?? "all"))"
        }
    }
}

// MARK: - Supporting types

public enum LEDTarget: String, Sendable, CaseIterable {
    case red
    case green
    case yellow
    case blue
    case multiRed
    case multiGreen
    case multiBlue
    case all

    /// The text command name used by DeviceManagerCommandHelper.
    public var commandName: String {
        switch self {
        case .red:        return "RED"
        case .green:      return "GREEN"
        case .yellow:     return "YELLOW"
        case .blue:       return "BLUE"
        case .multiRed:   return "MULTIRED"
        case .multiGreen: return "MULTIGREEN"
        case .multiBlue:  return "MULTIBLUE"
        case .all:        return "ALL"
        }
    }

    /// The state dictionary key from firmware responses.
    public var stateKey: String {
        switch self {
        case .red:        return "R"
        case .green:      return "G"
        case .yellow:     return "Y"
        case .blue:       return "B"
        case .multiRed:   return "MR"
        case .multiGreen: return "MG"
        case .multiBlue:  return "MB"
        case .all:        return "ALL"
        }
    }
}

public enum OnOffToggle: String, Sendable {
    case on
    case off
    case toggle
}

/// Semantic color representation. Named colors are resolved by the adapter layer
/// into device-specific values (e.g. RGB percentages for Pico, pixel data for
/// addressable strips). The parser never performs color math.
public enum LEDColor: Sendable, Equatable, CustomStringConvertible {
    /// A named color resolved by the adapter (e.g. "purple", "sunset orange").
    case named(String)
    /// Explicit RGB percentages (0-100 each).
    case rgb(r: Int, g: Int, b: Int)
    /// Turn the RGB LED off.
    case off

    public var description: String {
        switch self {
        case .named(let name): return name
        case .rgb(let r, let g, let b): return "rgb(\(r),\(g),\(b))"
        case .off: return "off"
        }
    }
}

public enum PinDirection: String, Sendable, CaseIterable {
    case output
    case input
    case inputPullUp
    case inputPullDown

    public var wireValue: String {
        switch self {
        case .output:       return "OUT"
        case .input:        return "IN"
        case .inputPullUp:  return "IN_PU"
        case .inputPullDown: return "IN_PD"
        }
    }
}

// MARK: - Monitoring types

public struct MonitoringRule: Sendable, Equatable, CustomStringConvertible {
    public let id: UUID
    public let label: String
    public let condition: MonitoringCondition
    public let pollInterval: TimeInterval?

    public init(id: UUID = UUID(), label: String, condition: MonitoringCondition, pollInterval: TimeInterval? = nil) {
        self.id = id
        self.label = label
        self.condition = condition
        self.pollInterval = pollInterval
    }

    public var description: String {
        "\(label): \(condition)"
    }
}

public enum MonitoringCondition: Sendable, Equatable, CustomStringConvertible {
    case pinChanged(pin: Int)
    case adcAbove(pin: Int, threshold: Double)
    case adcBelow(pin: Int, threshold: Double)
    case ledChanged(target: LEDTarget)
    case servoMoved

    public var description: String {
        switch self {
        case .pinChanged(let pin):            return "pin \(pin) changed"
        case .adcAbove(let pin, let thresh):  return "pin \(pin) ADC > \(String(format: "%.2f", thresh))V"
        case .adcBelow(let pin, let thresh):  return "pin \(pin) ADC < \(String(format: "%.2f", thresh))V"
        case .ledChanged(let target):         return "\(target.rawValue) LED changed"
        case .servoMoved:                     return "servo moved"
        }
    }
}

public enum MonitoringValue: Sendable {
    case digital(Bool)
    case analog(raw: Int, voltage: Double)
    case led(target: LEDTarget, on: Bool)
    case servo(angle: Int)
}

public struct MonitoringAlert: Sendable {
    public let ruleID: UUID
    public let ruleLabel: String
    public let message: String
    public let value: MonitoringValue
    public let timestamp: Date

    public init(ruleID: UUID, ruleLabel: String, message: String, value: MonitoringValue, timestamp: Date = Date()) {
        self.ruleID = ruleID
        self.ruleLabel = ruleLabel
        self.message = message
        self.value = value
        self.timestamp = timestamp
    }
}

// MARK: - Execution report

/// Result of executing one or more DeviceActions through the StateAwareExecutor.
public struct ExecutionReport: Sendable {
    public let executed: [DeviceAction]
    public let skipped: [DeviceAction]
    public let failed: [FailedAction]
    public let confirmationText: String
    public let results: [ActionResult]

    public init(executed: [DeviceAction], skipped: [DeviceAction], failed: [FailedAction],
                confirmationText: String, results: [ActionResult] = []) {
        self.executed = executed
        self.skipped = skipped
        self.failed = failed
        self.confirmationText = confirmationText
        self.results = results
    }

    public struct FailedAction: Sendable {
        public let action: DeviceAction
        public let error: String
        public init(action: DeviceAction, error: String) {
            self.action = action
            self.error = error
        }
    }

    public enum ActionResult: Sendable {
        case stateUpdate([String: Bool])
        case digitalRead(pin: Int, value: Bool)
        case analogRead(pin: Int, raw: Int, voltage: Double)
        case servoAngle(Int)
        case capabilities(String)
        case pinmap(String)
    }
}

// MARK: - Hardware snapshot

/// Point-in-time snapshot of all known hardware state.
public struct HardwareSnapshot: Sendable {
    public var leds: [String: Bool]
    public var servoAngle: Int?
    public var pinStates: [Int: GenericPinState]
    public var activePWM: [Int: PWMConfig]
    public var lastUpdated: Date?

    public init(leds: [String: Bool] = [:], servoAngle: Int? = nil,
                pinStates: [Int: GenericPinState] = [:], activePWM: [Int: PWMConfig] = [:],
                lastUpdated: Date? = nil) {
        self.leds = leds
        self.servoAngle = servoAngle
        self.pinStates = pinStates
        self.activePWM = activePWM
        self.lastUpdated = lastUpdated
    }
}

public enum GenericPinState: Sendable, Equatable {
    case high
    case low
    case input
    case unknown
}

public struct PWMConfig: Sendable, Equatable {
    public let frequency: Int
    public let duty: Int
    public init(frequency: Int, duty: Int) {
        self.frequency = frequency
        self.duty = duty
    }
}
