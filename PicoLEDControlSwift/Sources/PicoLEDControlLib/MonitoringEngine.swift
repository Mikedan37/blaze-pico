import Foundation

/// Reactive monitoring engine for hardware state.
///
/// Manages subscriptions to ``HardwareStateAuthority`` changes and ADC
/// polling, emitting ``MonitoringAlert``s when conditions are met.
///
/// Usage:
///
///     let engine = MonitoringEngine.shared
///     let rule = MonitoringRule(label: "Hot motor", condition: .adcAbove(pin: 26, threshold: 2.5), pollInterval: 1.0)
///     await engine.subscribe(rule)
///
///     for await alert in await engine.alertStream {
///         print("ALERT: \(alert.message)")
///     }
///
public actor MonitoringEngine {

    public static let shared = MonitoringEngine()

    // Active rules keyed by UUID
    private var rules: [UUID: MonitoringRule] = [:]
    // Polling tasks for ADC-based rules
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    // State-change observation task
    private var stateObserverTask: Task<Void, Never>?

    private let alertContinuation: AsyncStream<MonitoringAlert>.Continuation
    public let alertStream: AsyncStream<MonitoringAlert>

    private let stateAuthority: HardwareStateAuthority

    private init(stateAuthority: HardwareStateAuthority = .shared) {
        self.stateAuthority = stateAuthority
        var cont: AsyncStream<MonitoringAlert>.Continuation!
        alertStream = AsyncStream { cont = $0 }
        alertContinuation = cont
    }

    // MARK: - Public API

    /// Add a monitoring subscription. Returns the rule ID.
    @discardableResult
    public func subscribe(_ rule: MonitoringRule) -> UUID {
        rules[rule.id] = rule

        switch rule.condition {
        case .adcAbove, .adcBelow:
            startADCPolling(rule: rule)

        case .pinChanged, .ledChanged, .servoMoved:
            ensureStateObserver()
        }

        return rule.id
    }

    /// Remove a specific subscription.
    public func unsubscribe(_ id: UUID) {
        rules.removeValue(forKey: id)
        pollingTasks[id]?.cancel()
        pollingTasks.removeValue(forKey: id)
    }

    /// Remove all subscriptions.
    public func unsubscribeAll() {
        rules.removeAll()
        for task in pollingTasks.values { task.cancel() }
        pollingTasks.removeAll()
        stateObserverTask?.cancel()
        stateObserverTask = nil
    }

    /// Current active rule count.
    public var activeRuleCount: Int { rules.count }

    /// List active rules.
    public var activeRules: [MonitoringRule] { Array(rules.values) }

    // MARK: - ADC polling

    private func startADCPolling(rule: MonitoringRule) {
        let interval = rule.pollInterval ?? 1.0
        let ruleID = rule.id
        let label = rule.label
        let condition = rule.condition

        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }

                guard let self = self else { break }
                let stillActive = await self.rules[ruleID] != nil
                guard stillActive else { break }

                do {
                    let pin: Int
                    switch condition {
                    case .adcAbove(let p, _), .adcBelow(let p, _):
                        pin = p
                    default:
                        continue
                    }

                    let raw = try await DeviceManagerCommandHelper.adcRead(pin: pin)
                    let voltage = Double(raw) * 3.3 / 4095.0

                    var shouldAlert = false
                    var message = ""

                    switch condition {
                    case .adcAbove(_, let threshold):
                        if voltage > threshold {
                            shouldAlert = true
                            message = "\(label): voltage on pin \(pin) is \(String(format: "%.2f", voltage))V (above \(String(format: "%.2f", threshold))V)"
                        }
                    case .adcBelow(_, let threshold):
                        if voltage < threshold {
                            shouldAlert = true
                            message = "\(label): voltage on pin \(pin) is \(String(format: "%.2f", voltage))V (below \(String(format: "%.2f", threshold))V)"
                        }
                    default:
                        break
                    }

                    if shouldAlert {
                        let alert = MonitoringAlert(
                            ruleID: ruleID,
                            ruleLabel: label,
                            message: message,
                            value: .analog(raw: raw, voltage: voltage)
                        )
                        await self.emitAlert(alert)
                    }
                } catch {
                    // ADC read failed -- skip this cycle
                }
            }
        }
        pollingTasks[ruleID] = task
    }

    // MARK: - State-change observation

    private func ensureStateObserver() {
        guard stateObserverTask == nil else { return }

        let authority = stateAuthority
        stateObserverTask = Task { [weak self] in
            for await change in authority.changes {
                guard !Task.isCancelled else { break }
                guard let self = self else { break }
                await self.processStateChange(change)
            }
        }
    }

    private func processStateChange(_ change: StateChange) {
        for (ruleID, rule) in rules {
            switch (rule.condition, change) {
            case (.pinChanged(let pin), .pin(let changedPin, let state)) where pin == changedPin:
                let isHigh = state == .high
                let alert = MonitoringAlert(
                    ruleID: ruleID,
                    ruleLabel: rule.label,
                    message: "\(rule.label): pin \(pin) changed to \(isHigh ? "HIGH" : "LOW")",
                    value: .digital(isHigh)
                )
                emitAlert(alert)

            case (.ledChanged(let target), .led(let changedTarget, let on)) where target == changedTarget:
                let alert = MonitoringAlert(
                    ruleID: ruleID,
                    ruleLabel: rule.label,
                    message: "\(rule.label): \(target.rawValue) LED turned \(on ? "on" : "off")",
                    value: .led(target: target, on: on)
                )
                emitAlert(alert)

            case (.servoMoved, .servo(let angle)):
                let alert = MonitoringAlert(
                    ruleID: ruleID,
                    ruleLabel: rule.label,
                    message: "\(rule.label): servo moved to \(angle) degrees",
                    value: .servo(angle: angle)
                )
                emitAlert(alert)

            default:
                break
            }
        }
    }

    // MARK: - Alert emission

    private func emitAlert(_ alert: MonitoringAlert) {
        alertContinuation.yield(alert)
    }
}
