# Production Rules for Hardware Control Runtime

##  Critical Rules (Never Violate)

### Rule 1: Daemon Owns Device Lifecycle

**Hardware initialization happens ONCE at daemon startup.**

```swift
//  CORRECT: AgentDaemonMain.swift
static func main() {
    Task.detached {
        try await DeviceManagerCommandHelper.initialize()
    }
}

//  WRONG: PicoLEDTool.swift
public func invoke(...) {
    try await DeviceManagerCommandHelper.initialize()  // NEVER!
}
```

**Why:** Prevents race conditions, partial initialization, and ghost failures.

### Rule 2: Tools Assume Hardware Exists

**Tools should NEVER initialize hardware. They should use existing sessions.**

```swift
//  CORRECT: Tool uses existing session
let session = try await DeviceManager.shared.getSession()
try await session.sendCommandWithCompletion(...)

//  WRONG: Tool initializes hardware
try await DeviceManagerCommandHelper.initialize()  // NO!
```

**Why:** Tools are stateless executors. Lifecycle management is daemon's job.

### Rule 3: Always Wait for Confirmation

**Every command MUST wait for ACK + STATE_CHANGE.**

```swift
//  CORRECT: Confirmation required
let result = try await session.sendCommandWithCompletion(
    commandID: .green,
    value: 1,
    ackTimeoutMs: 500,
    stateTimeoutMs: 500
)
guard result.success else { return .error("Command failed") }

//  WRONG: Fire and forget
try await session.sendCommand(commandID: .green, value: 1)
// Hope it worked...
```

**Why:** USB CDC can silently drop writes. ACK confirms execution.

### Rule 4: Heartbeat Watchdog Required

**Every persistent session MUST have heartbeat monitoring.**

```swift
//  CORRECT: Heartbeat monitoring
PicoSession.startHeartbeatMonitor() {
    if lastHeartbeat > 5 seconds {
        // Hard reset - session is dead
        handleReconnect()
    }
}
```

**Why:** USB CDC can appear alive but be dead. Heartbeat detects this.

### Rule 5: Timeout Everything

**Every operation MUST have a timeout.**

```swift
//  CORRECT: Timeout on all operations
let result = try await session.sendCommandWithCompletion(
    commandID: .green,
    value: 1,
    ackTimeoutMs: 500,      // ACK timeout
    stateTimeoutMs: 500     // STATE_CHANGE timeout
)

//  WRONG: Wait forever
let result = try await session.sendCommandWithCompletion(
    commandID: .green,
    value: 1
    // No timeouts = UI hangs forever
)
```

**Why:** Prevents UI from hanging forever on dead hardware.

##  Architecture Principles

### Single Source of Truth

**Firmware STATE_CHANGE events are the ONLY source of truth.**

```swift
//  CORRECT: Use STATE_CHANGE events
let result = try await session.sendCommandWithCompletion(...)
let state = result.state  // From STATE_CHANGE event

//  WRONG: Query state separately
try await session.sendCommand(...)
let state = try await session.queryState()  // Race condition!
```

### State Deduplication

**Rapid state changes must be deduplicated.**

```swift
//  CORRECT: Deduplicate rapid changes
private var lastStateUpdate: Date?
func updateState(_ newState: [String: Bool]) {
    let now = Date()
    if let last = lastStateUpdate, now.timeIntervalSince(last) < 0.1 {
        return  // Too rapid, ignore
    }
    applyState(newState)
    lastStateUpdate = now
}
```

### Reconnect Recovery

**On reconnect, state is unknown until first command.**

```swift
//  CORRECT: Handle reconnect
if session.wasReconnected {
    // State unknown - will update after first command
    return .text("State unknown - reconnect in progress")
}

//  WRONG: Assume state persists
let state = cachedState  // May be stale!
```

##  Anti-Patterns (Never Do These)

###  Spawn CLI Processes

```swift
//  WRONG: Spawn CLI for each command
let process = Process()
process.executableURL = URL(fileURLWithPath: "/path/to/cli")
try process.run()
```

**Why:** Causes port conflicts, dropped writes, race conditions.

###  Initialize Hardware in Tools

```swift
//  WRONG: Tool initializes hardware
public func invoke(...) {
    try await DeviceManagerCommandHelper.initialize()
}
```

**Why:** Race conditions, partial initialization, ghost failures.

###  Fire and Forget Commands

```swift
//  WRONG: No confirmation
try await session.sendCommand(commandID: .green, value: 1)
// Hope it worked...
```

**Why:** USB CDC can silently drop writes. No way to know if it worked.

###  No Timeouts

```swift
//  WRONG: Wait forever
let state = try await session.queryState()  // No timeout!
```

**Why:** UI hangs forever on dead hardware.

###  Assume State Persists

```swift
//  WRONG: Use cached state after reconnect
let state = cachedState  // May be stale!
```

**Why:** State is unknown after reconnect until first command.

##  Production Checklist

- [x] Daemon initializes hardware at startup
- [x] Tools never initialize hardware
- [x] All commands wait for ACK + STATE_CHANGE
- [x] Heartbeat monitoring (5s timeout)
- [x] Keepalive pings (25s interval)
- [x] Automatic reconnection
- [x] Timeouts on all operations
- [ ] State deduplication
- [ ] Reconnect state recovery
- [ ] State cache for UI

##  Next Steps

1.  Remove initialization from PicoLEDTool
2. Implement state deduplication
3. Add reconnect state recovery
4. Add state cache for UI
5. Prepare for multi-device routing
