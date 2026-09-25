# Root Cause: Serial Port Write Failures

## Problem

Commands are failing with:
```
Write failed: wrote -1 bytes, expected 31
```

The UI shows "State unknown" and commands timeout with "Invalid response from daemon".

## Root Cause Analysis

### The Conflict

**Two processes are trying to access the same serial port simultaneously:**

1. **DeviceManager** (in PicoLEDControlLib) maintains a **persistent session** that keeps the serial port open
   - Location: `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManager.swift`
   - Opens port once on `warmStart()` and keeps it open permanently
   - Used for event streaming and state synchronization

2. **PicoLEDTool** (in AgentDaemon) spawns **separate CLI processes** (`PicoLEDControl`) for each command
   - Each CLI process tries to open the same serial port
   - Port is already locked by DeviceManager's persistent session
   - `Darwin.write()` returns -1 (EBADF or EAGAIN)  write fails

### Why This Happens

When `PicoLEDTool` executes:
```swift
// PicoLEDTool spawns: pico-led-control GREEN ON
Process.run("pico-led-control", ["GREEN", "ON"])
```

The CLI process (`PicoLEDControl`) does:
```swift
let controller = PicoLEDController(portPath: "/dev/cu.usbmodem1101")
controller.sendCommand("GREEN ON")  // Tries to open port
controller.close()  // Closes port
```

But `DeviceManager.shared` already has the port open:
```swift
persistentSession = PicoSession(portPath: "/dev/cu.usbmodem1101")
// Port stays open permanently for event streaming
```

**Result:** Port conflict  write fails  command fails  no STATE_CHANGE event  UI shows "unknown"

## Error Details

When `Darwin.write()` returns -1, `errno` indicates:
- **EBADF (9)**: Bad file descriptor (port closed/invalid)
- **EAGAIN/EWOULDBLOCK (11)**: Resource temporarily unavailable (port locked)
- **EIO (5)**: I/O error (device disconnected)

The original error handling didn't check `errno`, so we couldn't distinguish these cases.

## Solution

### Immediate Fix (Applied)

 **Improved error handling in `SerialPort.swift`:**
- Check `errno` when `bytesWritten == -1`
- Provide specific error messages for EBADF, EAGAIN, EIO
- Distinguish complete failure (-1) from partial writes

### Recommended Fix (For AgentDaemon)

**Use DeviceManager's persistent session instead of spawning CLI processes:**

Instead of:
```swift
//  BAD: Spawns CLI process, conflicts with DeviceManager
let process = Process()
process.executableURL = URL(fileURLWithPath: "/path/to/pico-led-control")
process.arguments = ["GREEN", "ON"]
try process.run()
```

Use:
```swift
//  GOOD: Use DeviceManager's persistent session
let session = try await DeviceManager.shared.getSession()
try await session.sendCommand("GREEN ON")
// STATE_CHANGE events automatically streamed via session.events
```

### Benefits

1. **No port conflicts**: Single persistent session
2. **Faster**: No process spawn overhead (~50-100ms saved per command)
3. **Event streaming**: Automatic STATE_CHANGE events via `session.events`
4. **Better error handling**: Direct Swift error propagation
5. **State synchronization**: DeviceManager handles reconnects automatically

## Current State

-  Error handling improved to show specific errno codes
-  PicoLEDTool still spawns CLI processes (needs AgentDaemon update)
-  Port conflicts will continue until AgentDaemon uses DeviceManager

## Next Steps

1. **Update AgentDaemon's PicoLEDTool** to use `DeviceManager.shared.getSession()` instead of spawning CLI processes
2. **Remove CLI spawning code** from PicoLEDTool
3. **Use `session.sendCommand()`** directly for all LED commands
4. **Subscribe to `session.events`** to capture STATE_CHANGE events automatically

## Verification

After fixing AgentDaemon:
- Commands should succeed (no port conflicts)
- STATE_CHANGE events should stream automatically
- UI should update immediately after commands
- No more "Write failed: wrote -1 bytes" errors
