# AgentDaemon Integration: Using DeviceManager Instead of CLI Processes

## Problem Solved

**Port Conflict Eliminated**: AgentDaemon's `PicoLEDTool` was spawning separate CLI processes (`pico-led-control`) for each command, causing port conflicts with `DeviceManager`'s persistent session.

## Solution

Use `DeviceManagerCommandHelper` which leverages `DeviceManager.shared`'s persistent session. This:
-  Eliminates port conflicts
-  Faster (no process spawn overhead)
-  Automatic STATE_CHANGE event streaming
-  Better error handling

## Implementation Steps

### 1. Update PicoLEDTool.swift

Replace the CLI process spawning code with `DeviceManagerCommandHelper`:

**Before ( Port Conflicts):**
```swift
import Foundation

public struct PicoLEDTool: Tool {
    public var name: String { "pico_led_control" }
    
    private let cliPath: String
    private let logger: Logger?
    
    public init(cliPath: String? = nil, logger: Logger? = nil) {
        self.cliPath = cliPath ?? "/path/to/pico-led-control"
        self.logger = logger
    }
    
    public func invoke(arguments: [String: String]) async throws -> String {
        //  BAD: Spawns CLI process, conflicts with DeviceManager
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["GREEN", "ON"]
        try process.run()
        process.waitUntilExit()
        // ...
    }
}
```

**After ( No Conflicts):**
```swift
import Foundation
import PicoLEDControlLib

public struct PicoLEDTool: Tool {
    public var name: String { "pico_led_control" }
    
    private let logger: Logger?
    private static var initialized = false
    
    public init(logger: Logger? = nil) {
        self.logger = logger
    }
    
    public func invoke(arguments: [String: String]) async throws -> String {
        //  Initialize DeviceManager once (idempotent)
        if !Self.initialized {
            try await DeviceManagerCommandHelper.initialize()
            Self.initialized = true
            logger?.info("DeviceManager initialized")
        }
        
        // Parse command from arguments
        let command: String
        if let cmd = arguments["command"] {
            command = cmd
        } else if let color = arguments["color"], let state = arguments["state"] {
            command = "\(color.uppercased()) \(state.uppercased())"
        } else if arguments["query"] == "true" || arguments["query-state"] != nil {
            // Query state
            let state = try await DeviceManagerCommandHelper.queryState()
            if let state = state {
                let stateStr = state.map { "\($0.key)=\($0.value ? 1 : 0)" }.joined(separator: " ")
                return "STATE: \(stateStr)"
            } else {
                return "STATE: unknown"
            }
        } else {
            throw NSError(
                domain: "PicoLEDTool",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid arguments. Use 'command', 'color'+'state', or 'query'"]
            )
        }
        
        //  Send command via DeviceManager (no port conflicts!)
        let result = try await DeviceManagerCommandHelper.sendCommand(command)
        
        if result.success {
            if let state = result.state {
                let stateStr = state.map { "\($0.key)=\($0.value ? 1 : 0)" }.joined(separator: " ")
                return " Command executed successfully. STATE_CHANGE: \(stateStr)"
            } else {
                return " Command executed successfully"
            }
        } else {
            return " Command failed: ACK timeout"
        }
    }
}
```

### 2. Initialize DeviceManager at AgentDaemon Startup

In your AgentDaemon's main initialization code:

```swift
import PicoLEDControlLib

// At daemon startup (before handling requests)
Task {
    do {
        try await DeviceManagerCommandHelper.initialize()
        print(" DeviceManager initialized - persistent session ready")
    } catch {
        print(" DeviceManager initialization failed: \(error)")
        // Device not connected - commands will fail gracefully
    }
}
```

### 3. Update Package Dependencies

Ensure AgentDaemon's `Package.swift` includes `PicoLEDControlLib`:

```swift
dependencies: [
    .package(path: "../blaze-pico/PicoLEDControlSwift"),
    // ...
],
targets: [
    .target(
        name: "AgentDaemon",
        dependencies: [
            .product(name: "PicoLEDControlLib", package: "PicoLEDControlSwift"),
            // ...
        ]
    ),
]
```

## API Reference

### `DeviceManagerCommandHelper.sendCommand(_:)`

Send a text command and get state from STATE_CHANGE event.

```swift
let result = try await DeviceManagerCommandHelper.sendCommand("GREEN ON")
// result.success: Bool - true if ACK received
// result.state: [String: Bool]? - GPIO state from STATE_CHANGE event
```

**Supported Commands:**
- `"RED ON"` / `"RED OFF"`
- `"GREEN ON"` / `"GREEN OFF"`
- `"YELLOW ON"` / `"YELLOW OFF"`
- `"BLUE ON"` / `"BLUE OFF"`
- `"ALL ON"` / `"ALL OFF"`
- `"RED ON GREEN ON BLUE ON"` (multiple commands)

### `DeviceManagerCommandHelper.queryState()`

Query current device state.

```swift
let state = try await DeviceManagerCommandHelper.queryState()
// Returns: [String: Bool]? - e.g., ["R": true, "G": false, "Y": false, "B": false]
```

### `DeviceManagerCommandHelper.initialize()`

Initialize DeviceManager's persistent session (call once at startup).

```swift
try await DeviceManagerCommandHelper.initialize()
```

## Benefits

1. **No Port Conflicts**: Single persistent session shared by all commands
2. **Faster**: No process spawn overhead (~50-100ms saved per command)
3. **Automatic State Updates**: STATE_CHANGE events stream automatically
4. **Better Error Messages**: Direct Swift error propagation with errno details
5. **Automatic Reconnection**: DeviceManager handles USB disconnects automatically

## Migration Checklist

- [ ] Update `PicoLEDTool.swift` to use `DeviceManagerCommandHelper`
- [ ] Remove CLI process spawning code
- [ ] Add `DeviceManagerCommandHelper.initialize()` to daemon startup
- [ ] Update `Package.swift` dependencies
- [ ] Test commands work without port conflicts
- [ ] Verify STATE_CHANGE events are captured
- [ ] Remove old CLI path configuration

## Testing

After migration, test:

```swift
// Single command
let result1 = try await DeviceManagerCommandHelper.sendCommand("GREEN ON")
assert(result1.success == true)
assert(result1.state?["G"] == true)

// Multiple commands
let result2 = try await DeviceManagerCommandHelper.sendCommand("RED ON GREEN ON BLUE ON")
assert(result2.success == true)

// Query state
let state = try await DeviceManagerCommandHelper.queryState()
assert(state != nil)
```

## Troubleshooting

**Error: "Device not connected"**
- Ensure Pico is plugged in via USB
- Check `/dev/cu.usbmodem*` exists
- Call `DeviceManagerCommandHelper.initialize()` at startup

**Error: "Failed to parse command"**
- Use format: `"COLOR STATE"` (e.g., `"GREEN ON"`)
- Supported colors: RED, GREEN, YELLOW, BLUE, ALL
- Supported states: ON, OFF

**State still shows "unknown"**
- Ensure firmware emits STATE_CHANGE events (already implemented)
- Check that `sendCommandWithCompletion()` is used (it waits for STATE_CHANGE)
- Verify serial port is not locked by another process
