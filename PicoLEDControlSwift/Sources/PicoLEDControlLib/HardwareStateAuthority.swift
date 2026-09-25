import Foundation
import Combine

/// Authoritative source of truth for all known hardware state.
///
/// Subscribes to ``DeviceManager/allEvents`` and maintains a live
/// ``HardwareSnapshot`` updated from ACKs, STATUS responses,
/// STATE_CHANGE events, and command results. Both the daemon and
/// any direct SDK consumer can use this to check idempotency,
/// resolve toggles, and drive monitoring alerts.
///
/// Usage:
///
///     let snapshot = await HardwareStateAuthority.shared.snapshot()
///     let isRedundant = await HardwareStateAuthority.shared.wouldBeRedundant(.led(target: .red, state: .on))
///
public actor HardwareStateAuthority {

    public static let shared = HardwareStateAuthority()

    // MARK: - State

    private var _snapshot = HardwareSnapshot()
    private var cancellables = Set<AnyCancellable>()
    private var subscribed = false

    /// Stream of state-change deltas consumers can observe.
    private let changeContinuation: AsyncStream<StateChange>.Continuation
    public let changes: AsyncStream<StateChange>

    private init() {
        var cont: AsyncStream<StateChange>.Continuation!
        changes = AsyncStream { cont = $0 }
        changeContinuation = cont
    }

    // MARK: - Public API

    public func snapshot() -> HardwareSnapshot {
        _snapshot
    }

    /// Checks whether executing `action` would be redundant given current known state.
    public func wouldBeRedundant(_ action: DeviceAction) -> Bool {
        switch action {
        case .led(let target, let state):
            let key = target.stateKey
            guard let current = _snapshot.leds[key] else { return false }
            switch state {
            case .on:     return current == true
            case .off:    return current == false
            case .toggle: return false
            }

        case .gpioSet(let pin, let value):
            guard let current = _snapshot.pinStates[pin] else { return false }
            return (value && current == .high) || (!value && current == .low)

        case .pwmStart(let pin, let freq, let duty):
            guard let current = _snapshot.activePWM[pin] else { return false }
            return current.frequency == freq && current.duty == duty

        case .pwmStop(let pin):
            return _snapshot.activePWM[pin] == nil

        case .servoSet(let angle):
            return _snapshot.servoAngle == angle

        case .setLEDColor:
            return false

        default:
            return false
        }
    }

    /// Begin subscribing to DeviceManager events. Call once during startup.
    public func startListening() {
        guard !subscribed else { return }
        subscribed = true

        let eventsPublisher = DeviceManager.shared.allEvents
        let authority = self

        eventsPublisher
            .sink { pair in
                Task { await authority.handleEvent(pair.event) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Manual updates (for command results not covered by events)

    public func applyAction(_ action: DeviceAction) {
        switch action {
        case .led(let target, let state):
            if target == .all {
                let on = state == .on
                for t in LEDTarget.allCases where t != .all {
                    let old = _snapshot.leds[t.stateKey]
                    _snapshot.leds[t.stateKey] = on
                    if old != on { emitChange(.led(target: t, on: on)) }
                }
            } else {
                let on: Bool
                switch state {
                case .on: on = true
                case .off: on = false
                case .toggle: on = !(_snapshot.leds[target.stateKey] ?? false)
                }
                let old = _snapshot.leds[target.stateKey]
                _snapshot.leds[target.stateKey] = on
                if old != on { emitChange(.led(target: target, on: on)) }
            }

        case .gpioSet(let pin, let value):
            let newState: GenericPinState = value ? .high : .low
            let old = _snapshot.pinStates[pin]
            _snapshot.pinStates[pin] = newState
            if old != newState { emitChange(.pin(pin: pin, state: newState)) }

        case .pwmStart(let pin, let freq, let duty):
            let cfg = PWMConfig(frequency: freq, duty: duty)
            _snapshot.activePWM[pin] = cfg
            emitChange(.pwm(pin: pin, config: cfg))

        case .pwmStop(let pin):
            if _snapshot.activePWM.removeValue(forKey: pin) != nil {
                emitChange(.pwmStopped(pin: pin))
            }

        case .servoSet(let angle):
            let old = _snapshot.servoAngle
            _snapshot.servoAngle = angle
            if old != angle { emitChange(.servo(angle: angle)) }

        case .setLEDColor:
            // Multi-LED on/off state is tracked via the individual .led() commands
            // that the executor sends for each channel. No additional tracking needed.
            break

        default:
            break
        }
        _snapshot.lastUpdated = Date()
    }

    /// Bulk-update LED state from a firmware status dict (e.g. `["R": true, "G": false]`).
    public func applyStatusDict(_ dict: [String: Bool]) {
        for (key, value) in dict {
            let old = _snapshot.leds[key]
            _snapshot.leds[key] = value
            if old != value {
                if let target = ledTargetForKey(key) {
                    emitChange(.led(target: target, on: value))
                }
            }
        }
        _snapshot.lastUpdated = Date()
    }

    /// Reset all state to unknown (after disconnect / reboot).
    public func invalidate() {
        _snapshot = HardwareSnapshot()
        emitChange(.invalidated)
    }

    // MARK: - Event processing

    private func handleEvent(_ event: PicoEventType) {
        switch event {
        case .status(let status):
            applyStatusDict(status.gpio)

        case .gpio(let gpio):
            let newState: GenericPinState = gpio.state ? .high : .low
            let old = _snapshot.pinStates[gpio.pin]
            _snapshot.pinStates[gpio.pin] = newState
            _snapshot.lastUpdated = Date()
            if old != newState { emitChange(.pin(pin: gpio.pin, state: newState)) }

        case .ack(let ack):
            if ack.commandID == CommandID.servoSet.rawValue {
                let angle = Int(ack.value)
                let old = _snapshot.servoAngle
                _snapshot.servoAngle = angle
                if old != angle { emitChange(.servo(angle: angle)) }
            }
            _snapshot.lastUpdated = Date()

        case .boot:
            invalidate()

        case .error:
            break

        case .heartbeat, .trace:
            break
        }
    }

    // MARK: - Helpers

    private func emitChange(_ change: StateChange) {
        changeContinuation.yield(change)
    }

    private func ledTargetForKey(_ key: String) -> LEDTarget? {
        switch key {
        case "R":  return .red
        case "G":  return .green
        case "Y":  return .yellow
        case "B":  return .blue
        case "MR": return .multiRed
        case "MG": return .multiGreen
        case "MB": return .multiBlue
        default:   return nil
        }
    }
}

// MARK: - State change events

public enum StateChange: Sendable {
    case led(target: LEDTarget, on: Bool)
    case pin(pin: Int, state: GenericPinState)
    case pwm(pin: Int, config: PWMConfig)
    case pwmStopped(pin: Int)
    case servo(angle: Int)
    case invalidated
}
