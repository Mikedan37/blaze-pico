# 3-Layer Hardware Runtime Architecture

## Overview

Production-grade hardware control requires three distinct layers to prevent:
- Zombie serial sessions
- UI waiting forever
- Partial command execution
- Duplicate state events
- Reconnect desync
- Daemon restart corruption

## Architecture Layers

```
┌─────────────────────────────────────────────────────────┐
│ Layer 1: Device Lifecycle Manager (Daemon-Level)      │
│ - Owns device initialization                           │
│ - Manages session lifecycle                           │
│ - Handles reconnects                                   │
│ - Heartbeat/watchdog monitoring                        │
└─────────────────────────────────────────────────────────┘
                        
┌─────────────────────────────────────────────────────────┐
│ Layer 2: Command Execution Layer (Session-Level)      │
│ - Validates session health                             │
│ - Executes commands with timeouts                      │
│ - Waits for ACK confirmation                           │
│ - Captures STATE_CHANGE events                         │
└─────────────────────────────────────────────────────────┘
                        
┌─────────────────────────────────────────────────────────┐
│ Layer 3: State Management Layer (Application-Level)   │
│ - Aggregates state from multiple sources               │
│ - Deduplicates events                                  │
│ - Handles UI updates                                   │
│ - Manages state cache                                  │
└─────────────────────────────────────────────────────────┘
```

## Layer 1: Device Lifecycle Manager

**Responsibility:** Own device initialization and session lifecycle

**Rules:**
1.  Daemon startup initializes all devices
2.  Tools NEVER initialize hardware
3.  Single point of truth for device state
4.  Heartbeat watchdog detects dead sessions
5.  Automatic reconnection on failure

**Current Implementation:**
- `DeviceManager.warmStart()` - Called at daemon startup
- `DeviceManager.startKeepalivePing()` - 25s keepalive
- `PicoSession.startHeartbeatMonitor()` - 5s timeout detection
- `DeviceManager.handleHardFailure()` - Reconnection logic

**Status:**  Implemented

## Layer 2: Command Execution Layer

**Responsibility:** Execute commands with confirmation and state capture

**Rules:**
1.  Always use `sendCommandWithCompletion()` (waits for ACK + STATE_CHANGE)
2.  Timeout on ACK (500ms default)
3.  Timeout on STATE_CHANGE (500ms default)
4.  Return success/failure + state
5.  Never assume command succeeded without ACK

**Current Implementation:**
- `PicoSession.sendCommandWithCompletion()` - Command + ACK + STATE_CHANGE
- `PicoSession.waitForAck()` - ACK timeout handling
- `PicoSession.waitForStateEvent()` - STATE_CHANGE timeout handling

**Status:**  Implemented

## Layer 3: State Management Layer

**Responsibility:** Aggregate, deduplicate, and manage state

**Rules:**
1.  Single source of truth (firmware STATE_CHANGE events)
2.  Deduplicate rapid state changes
3.  Handle reconnect state recovery
4.  Cache state for UI
5.  Emit state updates to UI

**Current Implementation:**
- `DeviceManager.allEvents` - Event stream
- `VoiceDaemonBridge.updateDeviceStateFromResponse()` - State parsing
- `DeviceStateView` - UI state display

**Status:**  Partially implemented (needs deduplication and reconnect recovery)

## Critical Production Rules

### Rule 1: Daemon Owns Device Lifecycle

```swift
//  CORRECT: Daemon initializes
AgentDaemonMain.main() {
    try await DeviceManagerCommandHelper.initialize()
}

//  WRONG: Tool initializes
PicoLEDTool.invoke() {
    try await DeviceManagerCommandHelper.initialize()  // NO!
}
```

### Rule 2: Heartbeat Watchdog Required

```swift
//  CORRECT: Heartbeat monitoring
PicoSession.startHeartbeatMonitor() {
    if lastHeartbeat > 5 seconds {
        // Hard reset session
        handleReconnect()
    }
}
```

### Rule 3: Command Confirmation Required

```swift
//  CORRECT: Wait for ACK + STATE_CHANGE
let result = try await session.sendCommandWithCompletion(
    commandID: .green,
    value: 1,
    ackTimeoutMs: 500,
    stateTimeoutMs: 500
)

//  WRONG: Fire and forget
try await session.sendCommand(commandID: .green, value: 1)
```

### Rule 4: State Deduplication Required

```swift
//  CORRECT: Deduplicate rapid changes
private var lastStateUpdate: Date?
private var pendingState: [String: Bool]?

func updateState(_ newState: [String: Bool]) {
    let now = Date()
    if let last = lastStateUpdate, now.timeIntervalSince(last) < 0.1 {
        // Deduplicate - too rapid
        pendingState = newState
        return
    }
    // Apply state
    applyState(newState)
    lastStateUpdate = now
}
```

## Multi-Device Future

When you have 10 Picos:

1. **DeviceManager** manages all 10 sessions
2. **Each session** has independent heartbeat
3. **Command routing** uses deviceID
4. **State aggregation** merges all device states
5. **UI** shows all devices

## Implementation Checklist

- [x] Layer 1: Device lifecycle at daemon startup
- [x] Layer 1: Heartbeat monitoring (5s timeout)
- [x] Layer 1: Keepalive pings (25s interval)
- [x] Layer 1: Automatic reconnection
- [x] Layer 2: Command confirmation (ACK + STATE_CHANGE)
- [x] Layer 2: Timeout handling
- [ ] Layer 3: State deduplication
- [ ] Layer 3: Reconnect state recovery
- [ ] Layer 3: State cache for UI
- [ ] Multi-device routing

## Next Steps

1. Remove initialization from PicoLEDTool (move to daemon only)
2. Implement state deduplication in VoiceDaemonBridge
3. Add reconnect state recovery
4. Add state cache for UI
5. Prepare for multi-device routing
