import Foundation

/// A single GPIO pin on a hardware device.
///
/// Provides a fluent, object-oriented interface for digital I/O, PWM, and ADC
/// operations instead of bare procedural calls. Capability introspection lets
/// callers (and LLM planners) query what a pin can do before attempting it.
///
/// Usage:
///
///     let pin = board.pin(5)
///     try await pin.setHigh()
///     let value = try await pin.read()
///
///     if pin.supportsPWM {
///         try await pin.pwm(frequency: 1000, duty: 50)
///     }
///
///     if pin.supportsADC {
///         let raw = try await pin.analog.read()
///     }
///
public final class HardwarePin: @unchecked Sendable {

    public let number: Int

    private let session: @Sendable () async throws -> PicoSession

    // MARK: - RP2350 pin capability map

    /// ADC-capable pins on RP2350 (GP26–GP29).
    public static let adcPins: Set<Int> = [26, 27, 28, 29]

    /// All RP2350 GPIO pins support hardware PWM via paired slices.
    /// Reserved pins are excluded at the firmware level, not here.
    public static let pwmPins: Set<Int> = Set(0...29)

    /// Pins reserved by the blaze-pico firmware for LEDs and servo.
    /// GPIO 14–17: single-color LEDs, 18–20: RGB LED, 21: servo.
    public static let reservedPins: Set<Int> = [14, 15, 16, 17, 18, 19, 20, 21]

    /// Valid GPIO range for RP2350.
    public static let validRange: ClosedRange<Int> = 0...29

    // MARK: - Init

    /// Internal initializer — callers use `HardwareDevice.pin(_:)`.
    init(number: Int, session: @escaping @Sendable () async throws -> PicoSession) {
        self.number = number
        self.session = session
    }

    // MARK: - Capability introspection

    public var supportsPWM: Bool { Self.pwmPins.contains(number) && !isReserved }
    public var supportsADC: Bool { Self.adcPins.contains(number) }
    public var isReserved: Bool  { Self.reservedPins.contains(number) }
    public var isValid: Bool     { Self.validRange.contains(number) }

    // MARK: - Digital I/O

    /// Drive the pin high.
    public func setHigh() async throws {
        try await setDigital(true)
    }

    /// Drive the pin low.
    public func setLow() async throws {
        try await setDigital(false)
    }

    /// Set the pin to a digital value.
    public func set(_ value: Bool) async throws {
        try await setDigital(value)
    }

    /// Read the digital state of the pin (true = high).
    public func read() async throws -> Bool {
        try guardValid()
        let s = try await session()
        let cmd = "GPIO GET \(number)"
        let response = try await s.sendTextCommand(cmd, responsePrefix: "GPIO_READ:", timeoutMs: 2000)
        guard let resp = response else {
            throw HardwareError.timeout("GPIO GET", pin: number)
        }
        if resp.hasPrefix("ERROR:") {
            throw HardwareError.firmware(resp, pin: number)
        }
        guard let range = resp.range(of: "value="),
              let val = Int(String(resp[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HardwareError.malformedResponse(resp, pin: number)
        }
        return val != 0
    }

    /// Configure the pin direction and pull.
    public func setMode(_ mode: PinMode) async throws {
        try guardValid()
        let s = try await session()
        let cmd = "GPIO MODE \(number) \(mode.wireValue)"
        let response = try await s.sendTextCommand(cmd, responsePrefix: "OK", timeoutMs: 2000)
        if let resp = response, resp.hasPrefix("ERROR:") {
            throw HardwareError.firmware(resp, pin: number)
        }
        guard response != nil else {
            throw HardwareError.timeout("GPIO MODE", pin: number)
        }
    }

    // MARK: - PWM

    /// Start PWM output on this pin.
    /// - Parameters:
    ///   - frequency: Frequency in Hz (1–62_500_000).
    ///   - duty: Duty cycle percentage (0–100).
    public func pwm(frequency: Int, duty: Int) async throws {
        try guardValid()
        guard supportsPWM else {
            throw HardwareError.unsupportedCapability("PWM", pin: number)
        }
        let s = try await session()
        let cmd = "PWM SET \(number) \(frequency) \(duty)"
        let response = try await s.sendTextCommand(cmd, responsePrefix: "OK", timeoutMs: 2000)
        if let resp = response, resp.hasPrefix("ERROR:") {
            throw HardwareError.firmware(resp, pin: number)
        }
        guard response != nil else {
            throw HardwareError.timeout("PWM SET", pin: number)
        }
    }

    /// Stop PWM output and return the pin to GPIO mode.
    public func stopPWM() async throws {
        try guardValid()
        let s = try await session()
        let cmd = "PWM STOP \(number)"
        let response = try await s.sendTextCommand(cmd, responsePrefix: "OK", timeoutMs: 2000)
        if let resp = response, resp.hasPrefix("ERROR:") {
            throw HardwareError.firmware(resp, pin: number)
        }
        guard response != nil else {
            throw HardwareError.timeout("PWM STOP", pin: number)
        }
    }

    // MARK: - ADC

    /// Analog sub-interface — only meaningful on ADC-capable pins (GP26–GP29).
    public var analog: AnalogPin {
        AnalogPin(pinNumber: number, session: session)
    }

    // MARK: - Private helpers

    private func setDigital(_ value: Bool) async throws {
        try guardValid()
        let s = try await session()
        let cmd = "GPIO SET \(number) \(value ? 1 : 0)"
        let response = try await s.sendTextCommand(cmd, responsePrefix: "OK", timeoutMs: 2000)
        if let resp = response, resp.hasPrefix("ERROR:") {
            throw HardwareError.firmware(resp, pin: number)
        }
        guard response != nil else {
            throw HardwareError.timeout("GPIO SET", pin: number)
        }
    }

    private func guardValid() throws {
        guard isValid else {
            throw HardwareError.invalidPin(number)
        }
    }
}

// MARK: - Pin mode

extension HardwarePin {
    public enum PinMode: String, Sendable, CaseIterable {
        case output
        case input
        case inputPullUp
        case inputPullDown

        var wireValue: String {
            switch self {
            case .output:       return "OUT"
            case .input:        return "IN"
            case .inputPullUp:  return "IN_PU"
            case .inputPullDown: return "IN_PD"
            }
        }
    }
}

// MARK: - AnalogPin

/// ADC sub-interface for reading analog values.
///
/// Usage:
///
///     let raw = try await board.pin(26).analog.read()       // 0–4095
///     let volts = try await board.pin(26).analog.readVoltage() // 0.0–3.3
///
public struct AnalogPin: Sendable {

    let pinNumber: Int
    private let session: @Sendable () async throws -> PicoSession

    init(pinNumber: Int, session: @escaping @Sendable () async throws -> PicoSession) {
        self.pinNumber = pinNumber
        self.session = session
    }

    /// Read raw 12-bit ADC value (0–4095).
    public func read() async throws -> Int {
        guard HardwarePin.adcPins.contains(pinNumber) else {
            throw HardwareError.unsupportedCapability("ADC", pin: pinNumber)
        }
        let s = try await session()
        let cmd = "ADC READ \(pinNumber)"
        let response = try await s.sendTextCommand(cmd, responsePrefix: "ADC_READ:", timeoutMs: 2000)
        guard let resp = response else {
            throw HardwareError.timeout("ADC READ", pin: pinNumber)
        }
        if resp.hasPrefix("ERROR:") {
            throw HardwareError.firmware(resp, pin: pinNumber)
        }
        guard let range = resp.range(of: "value="),
              let val = Int(String(resp[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HardwareError.malformedResponse(resp, pin: pinNumber)
        }
        return val
    }

    /// Read analog value as voltage (assumes 3.3V reference, 12-bit ADC).
    public func readVoltage(referenceVoltage: Double = 3.3) async throws -> Double {
        let raw = try await read()
        return (Double(raw) / 4095.0) * referenceVoltage
    }
}

// MARK: - Errors

/// Typed errors for the hardware API.
public enum HardwareError: Error, LocalizedError {
    case invalidPin(Int)
    case unsupportedCapability(String, pin: Int)
    case timeout(String, pin: Int)
    case firmware(String, pin: Int)
    case malformedResponse(String, pin: Int)
    case noDeviceFound

    public var errorDescription: String? {
        switch self {
        case .invalidPin(let n):
            return "Pin \(n) is outside the valid GPIO range (0–29)"
        case .unsupportedCapability(let cap, let n):
            return "Pin \(n) does not support \(cap)"
        case .timeout(let op, let n):
            return "Timeout waiting for \(op) response on pin \(n)"
        case .firmware(let msg, let n):
            return "Firmware error on pin \(n): \(msg)"
        case .malformedResponse(let msg, let n):
            return "Malformed response for pin \(n): \(msg)"
        case .noDeviceFound:
            return "No hardware device found"
        }
    }
}
