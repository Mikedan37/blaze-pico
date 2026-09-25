import Foundation

/// A connected hardware device (Pico board).
///
/// The device is the root object in the hardware hierarchy. It vends `HardwarePin`
/// instances for individual GPIO pins and provides device-level operations like
/// state queries and bootloader entry.
///
/// Usage:
///
///     let board = try await Hardware.first()
///
///     try await board.pin(5).setHigh()
///     try await board.pin(9).pwm(frequency: 1000, duty: 50)
///     let volts = try await board.pin(26).analog.readVoltage()
///
///     for pin in board.availablePins where pin.supportsADC {
///         let v = try await pin.analog.read()
///         print("Pin \(pin.number): \(v)")
///     }
///
public final class HardwareDevice: @unchecked Sendable {

    /// Opaque device identifier (port path).
    public let id: String

    /// Serial port path this device is connected on.
    public let portPath: String

    private let manager: DeviceManager

    // Pin cache — pins are lightweight value-like objects, but caching avoids
    // creating duplicate closures for the same pin number.
    private var pinCache: [Int: HardwarePin] = [:]
    private let pinCacheLock = NSLock()

    // MARK: - Init

    init(id: String, portPath: String, manager: DeviceManager) {
        self.id = id
        self.portPath = portPath
        self.manager = manager
    }

    // MARK: - Pin access

    /// Get a pin object for the given GPIO number (0–29).
    ///
    /// Pin objects are cached per device — calling `pin(5)` twice returns the
    /// same instance.
    public func pin(_ number: Int) -> HardwarePin {
        pinCacheLock.lock()
        defer { pinCacheLock.unlock() }

        if let cached = pinCache[number] {
            return cached
        }

        let mgr = self.manager
        let p = HardwarePin(number: number, session: { try await mgr.getSession() })
        pinCache[number] = p
        return p
    }

    /// All valid GPIO pins on this device (0–29).
    public var pins: [HardwarePin] {
        (HardwarePin.validRange).map { pin($0) }
    }

    /// Non-reserved pins available for general use.
    public var availablePins: [HardwarePin] {
        pins.filter { !$0.isReserved }
    }

    /// Pins that support ADC (GP26–GP29).
    public var adcPins: [HardwarePin] {
        pins.filter { $0.supportsADC }
    }

    /// Pins that support general-purpose PWM (non-reserved).
    public var pwmPins: [HardwarePin] {
        pins.filter { $0.supportsPWM }
    }

    // MARK: - Built-in LED cluster

    /// Named access to the board's built-in LEDs (GPIO 14–17, 18–20).
    public var leds: LEDCluster {
        LEDCluster(device: self)
    }

    // MARK: - Servo (GPIO 21)

    /// Set the built-in servo angle (0–180).
    public func setServo(angle: Int) async throws {
        let result = try await DeviceManagerCommandHelper.sendServoCommand(angle: angle)
        guard result.success else {
            throw HardwareError.timeout("SERVO SET", pin: 21)
        }
    }

    /// Get the last known servo angle, if available.
    public func servoAngle() async throws -> Int? {
        try await DeviceManagerCommandHelper.getServoAngle()
    }

    // MARK: - Device state

    /// Query the full GPIO state of the device.
    public func queryState() async throws -> [String: Bool]? {
        try await DeviceManagerCommandHelper.queryState()
    }

    /// Send a raw LED/binary command (e.g. "RED ON", "ALL OFF").
    /// Provided for backward compatibility and LLM text-mode integration.
    public func sendCommand(_ command: String) async throws -> (success: Bool, state: [String: Bool]?) {
        try await DeviceManagerCommandHelper.sendCommand(command)
    }

    // MARK: - System

    /// Reboot into USB bootloader for firmware flashing.
    @discardableResult
    public func enterBootloader() async throws -> Bool {
        try await DeviceManagerCommandHelper.enterBootloader()
    }

    /// True if the device session is connected and ready for commands.
    public var isReady: Bool {
        get async {
            guard let session = try? await manager.getSession() else { return false }
            return session.isConnected && session.isReady
        }
    }
}

// MARK: - LED Cluster

/// Named access to the board's built-in LEDs.
///
/// LED pins are reserved — they cannot be controlled via generic GPIO text
/// commands. This cluster routes through the binary command protocol instead.
///
///     try await board.leds.red.on()
///     try await board.leds.multiGreen.off()
///     try await board.leds.allOff()
///
public struct LEDCluster: Sendable {

    private let device: HardwareDevice

    init(device: HardwareDevice) {
        self.device = device
    }

    public var red: LED         { LED(command: "RED", device: device) }
    public var green: LED       { LED(command: "GREEN", device: device) }
    public var yellow: LED      { LED(command: "YELLOW", device: device) }
    public var blue: LED        { LED(command: "BLUE", device: device) }

    public var multiRed: LED    { LED(command: "MULTIRED", device: device) }
    public var multiGreen: LED  { LED(command: "MULTIGREEN", device: device) }
    public var multiBlue: LED   { LED(command: "MULTIBLUE", device: device) }

    /// Turn all LEDs off via the binary protocol.
    public func allOff() async throws {
        _ = try await device.sendCommand("ALL OFF")
    }

    /// Turn all LEDs on via the binary protocol.
    public func allOn() async throws {
        _ = try await device.sendCommand("ALL ON")
    }

    /// A single LED controlled via the binary command protocol.
    public struct LED: Sendable {
        let command: String
        private let device: HardwareDevice

        init(command: String, device: HardwareDevice) {
            self.command = command
            self.device = device
        }

        /// Turn this LED on.
        public func on() async throws {
            let result = try await device.sendCommand("\(command) ON")
            guard result.success else {
                throw HardwareError.timeout("\(command) ON", pin: 0)
            }
        }

        /// Turn this LED off.
        public func off() async throws {
            let result = try await device.sendCommand("\(command) OFF")
            guard result.success else {
                throw HardwareError.timeout("\(command) OFF", pin: 0)
            }
        }

        /// Whether this LED supports PWM brightness control (multi-color LEDs only).
        public var supportsBrightness: Bool {
            ["MULTIRED", "MULTIGREEN", "MULTIBLUE"].contains(command)
        }

        /// Set brightness via PWM (0 = off, 1-100 = brightness %).
        /// Only supported on multi-color LED channels. Standard LEDs are on/off only.
        public func brightness(_ percent: Int) async throws {
            guard supportsBrightness else {
                throw HardwareError.unsupportedCapability("PWM brightness", pin: 0)
            }
            let clamped = max(0, min(100, percent))
            let result = try await device.sendCommand("\(command) \(clamped)")
            guard result.success else {
                throw HardwareError.timeout("\(command) \(clamped)", pin: 0)
            }
        }

        /// Check the current state of this LED from the device state cache.
        public func isOn() async throws -> Bool? {
            guard let state = try await device.queryState() else { return nil }
            let key: String
            switch command {
            case "RED": key = "R"
            case "GREEN": key = "G"
            case "YELLOW": key = "Y"
            case "BLUE": key = "B"
            case "MULTIRED": key = "MR"
            case "MULTIGREEN": key = "MG"
            case "MULTIBLUE": key = "MB"
            default: return nil
            }
            return state[key]
        }
    }
}
