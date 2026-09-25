# Pico LED Command Interface - Complete Guide

## Overview

The Pico firmware supports **two command protocols**:
1. **Text Protocol** - Human-readable commands (for debugging/testing)
2. **Binary Protocol** - Structured packets with trace IDs (for agent daemon)

Both protocols work simultaneously - the firmware automatically detects which format is being used.

---

## Command Methods

### Method 1: Python Script (Text Protocol)

**Location:** `/Users/mdanylchuk/pico/blaze-pico/pico_led_control.py`

**Usage:**
```bash
# Single command
python3 pico_led_control.py RED ON

# Multiple commands (joined as one)
python3 pico_led_control.py "RED ON" "GREEN ON"

# Specify port
python3 pico_led_control.py -p /dev/cu.usbmodem2101 "ALL ON"

# Auto-detect port
python3 pico_led_control.py "BLUE ON"
```

**Available Commands:**
- `RED ON` / `RED OFF`
- `GREEN ON` / `GREEN OFF`
- `YELLOW ON` / `YELLOW OFF`
- `BLUE ON` / `BLUE OFF`
- `MULTI ON` / `MULTI OFF` (RGB multicolor LED)
- `ALL ON` / `ALL OFF`

**Note:** The script joins all arguments into a single command string. Use quotes for multi-word commands.

---

### Method 2: Direct Serial (Text Protocol)

**For testing/debugging:**

```python
import serial
import time

port = '/dev/cu.usbmodem2101'
ser = serial.Serial(port, 115200, timeout=2)

# Send command (must include newline)
ser.write(b"RED ON\n")
time.sleep(0.1)

# Read response
if ser.in_waiting > 0:
    response = ser.read(ser.in_waiting).decode('utf-8')
    print(response)  # Will show ACK and STATE_CHANGE

ser.close()
```

**Response Format:**
```
ACK TRACE:0 cmdID=1 value=1
STATE_CHANGE: trace=0 seq=1 R=1 G=0 Y=0 B=0 MR=0 MG=0 MB=0
```

---

### Method 3: Agent Daemon Pipeline (Binary Protocol) ⭐ **RECOMMENDED**

**This is how your pipeline should send commands.**

The agent daemon uses the **DeviceManager** → **PicoSession** → **Binary Protocol** path:

#### Architecture

```
VoiceAgentController
    ↓
AgentDaemonClient (sendPlanWorkFireAndForget)
    ↓
AgentDaemon (IntentRouter → PicoLEDTool)
    ↓
DeviceManagerCommandHelper
    ↓
DeviceManager.getSession()
    ↓
PicoSession.sendCommand(commandID, value, traceID)
    ↓
Binary Protocol (BLAZ magic + structured packet)
    ↓
Pico Firmware
```

#### Swift API (Agent Daemon)

```swift
// In AgentDaemon (PicoLEDTool or IntentRouter)
import PicoLEDControlLib

// Get DeviceManager instance
let deviceManager = DeviceManager.shared

// Get session (handles connection/reconnection automatically)
let session = try await deviceManager.getSession()

// Send command with trace ID
try await session.sendCommand(
    commandID: .green,  // CommandID enum
    value: 1,           // 0 = OFF, 1 = ON
    traceID: traceID    // Optional: for end-to-end tracing
)

// Or use sendCommandWithCompletion (waits for ACK + STATE_CHANGE)
let result = try await session.sendCommandWithCompletion(
    commandID: .green,
    value: 1,
    ackTimeoutMs: 500,
    stateTimeoutMs: 1500
)

if result.success {
    print("Command executed successfully")
    if let state = result.state {
        print("Current state: \(state)")
    }
}
```

#### Command IDs (Binary Protocol)

```swift
enum CommandID: UInt8 {
    case red = 1
    case green = 2
    case yellow = 3
    case blue = 4
    case multi = 5          // All RGB channels together
    case multiRed = 6       // RGB Red channel (GPIO 18)
    case multiGreen = 7     // RGB Green channel (GPIO 19)
    case multiBlue = 8      // RGB Blue channel (GPIO 20)
    case all = 10           // All LEDs
    case queryState = 20    // Query current state (returns GPIO values)
    case status = 21        // Health probe (returns ready, session, uptime, seq)
    case enterBootloader = 30
}
```

#### Binary Packet Format

```
Magic: "BLAZ" (4 bytes)
Header: 16 bytes
    - version: 1 byte
    - flags: 1 byte
    - connection_id: 4 bytes (big-endian uint32)
    - packet_number: 4 bytes (big-endian uint32)
    - stream_id: 4 bytes (big-endian uint32)
    - payload_length: 2 bytes (big-endian uint16)
Payload:
    - frameType: 1 byte (0 = DATA)
    - traceID: 8 bytes (big-endian uint64)
    - commandID: 1 byte
    - value: 1 byte (0 = OFF, 1 = ON)
```

**Total packet size:** 4 + 16 + 11 = 31 bytes

#### CMD_STATUS Response

When the host sends `CMD_STATUS` (21), firmware responds with:

```
STATUS: ready=<0|1> session=<hex8> uptime=<ms> seq=<n> fw=<ver> proto=<n> model=<id>
```

| Field | Example | Meaning |
|-------|---------|---------|
| `ready` | `1` | 1 if `accept_commands` is true (post-BLAZE_READY) |
| `session` | `4AF20001` | 8-hex-char session UUID (changes on every boot/reconnect) |
| `uptime` | `120399` | Milliseconds since boot |
| `seq` | `44` | Monotonic state sequence (increments on every LED mutation) |
| `fw` | `1.0.0` | Firmware version — host can reject incompatible builds |
| `proto` | `2` | Binary protocol version — enables auto-migration |
| `model` | `blaze-pico` | Device model — supports multiple hardware types |

---

## Readiness Architecture

Three separate signals with distinct meanings — never merge them:

| Signal | Direction | Frequency | Meaning |
|--------|-----------|-----------|---------|
| `BLAZE_READY` | push (firmware → host) | once per session | Boot lifecycle complete — GPIO, timers, heartbeat, USB all initialized |
| `CMD_STATUS` | pull (host → firmware) | on demand | Health check — confirms liveness, readiness, session identity |
| `ACK TRACE:` | push (firmware → host) | per command | Command execution confirmed |

**Host readiness logic:**
1. If `BLAZE_READY` received → device is ready (authoritative lifecycle event)
2. If `BLAZE_READY` missed (late-join) → send `CMD_STATUS`, check `ready=1`
3. If both missed → event reader catches `HEARTBEAT READY:1` as fallback
4. ACK never implies readiness

---

## GPIO Pin Mapping

| LED | GPIO Pin | Physical Pin | Command ID |
|-----|----------|--------------|------------|
| Red | GPIO 14 | Pin 19 | 1 |
| Green | GPIO 15 | Pin 20 | 2 |
| Yellow | GPIO 16 | Pin 21 | 3 |
| Blue | GPIO 17 | Pin 22 | 4 |
| Multi Red | GPIO 18 | Pin 24 | 6 |
| Multi Green | GPIO 19 | Pin 25 | 7 |
| Multi Blue | GPIO 20 | Pin 26 | 8 |

---

## Response Format

### Text Protocol Response

```
ACK TRACE:<traceID> cmdID=<id> value=<value>
STATE_CHANGE: trace=<traceID> seq=<sequence> R=<0|1> G=<0|1> Y=<0|1> B=<0|1> MR=<0|1> MG=<0|1> MB=<0|1>
```

### Binary Protocol Response

The firmware sends the same text format responses even for binary commands. The `STATE_CHANGE` event includes:
- `trace`: Trace ID (for correlation)
- `seq`: Sequence number (monotonic, increments on each state change)
- GPIO states: `R`, `G`, `Y`, `B`, `MR`, `MG`, `MB`

---

## Pipeline Integration

### For VoiceAgentController → AgentDaemon

**Current Implementation:**
- VoiceAgentController sends voice commands via `sendPlanWorkFireAndForget()`
- AgentDaemon receives command, routes via `IntentRouter`
- `IntentRouter` detects light commands → `PicoLEDTool`
- `PicoLEDTool` calls `DeviceManagerCommandHelper.sendCommand()`
- Commands execute via binary protocol

**Example Flow:**
```
User: "Turn green light on"
    ↓
VoiceAgentController: sendPlanWorkFireAndForget("turn green light on")
    ↓
AgentDaemon: IntentRouter.route() → PicoLEDTool.invoke()
    ↓
PicoLEDTool: DeviceManagerCommandHelper.sendCommand(.green, value: 1)
    ↓
DeviceManager: getSession() → PicoSession.sendCommand()
    ↓
Pico Firmware: Executes command, sends ACK + STATE_CHANGE
    ↓
VoiceAgentController: Receives STATE_CHANGE event → Updates UI
```

---

## Testing Commands

### Quick Test Script

```bash
#!/bin/bash
PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)

if [ -z "$PORT" ]; then
    echo "❌ Pico not connected"
    exit 1
fi

echo "Testing LEDs on $PORT..."

python3 pico_led_control.py -p "$PORT" "ALL OFF"
sleep 0.3

for color in "RED ON" "GREEN ON" "YELLOW ON" "BLUE ON"; do
    python3 pico_led_control.py -p "$PORT" "$color"
    sleep 0.4
done

python3 pico_led_control.py -p "$PORT" "ALL ON"
sleep 0.5
python3 pico_led_control.py -p "$PORT" "ALL OFF"

echo "✅ Test complete!"
```

### Serial Monitor

```bash
# Monitor serial output
screen /dev/cu.usbmodem2101 115200

# Or with timeout
timeout 5 cat < /dev/cu.usbmodem2101
```

---

## Error Handling

### Common Issues

1. **Device Not Ready**
   - Error: `Device not ready - BLAZE_READY not received`
   - Solution: Wait for firmware to boot (check for `BLAZE_READY` in serial output)

2. **Port Not Found**
   - Error: `No such file or directory: '/dev/cu.usbmodem*'`
   - Solution: Check USB connection, unplug/replug Pico

3. **Command Not Executed**
   - Check serial output for `ACK` and `STATE_CHANGE` messages
   - Verify GPIO pins are correct (check wiring)

---

## Best Practices

### For Agent Daemon Pipeline

1. **Always use `sendCommandWithCompletion()`** for reliable command execution
   - Waits for ACK (confirms execution)
   - Waits for STATE_CHANGE (confirms state update)
   - Returns success/failure status

2. **Handle timeouts gracefully**
   - ACK timeout: Command may not have executed
   - STATE_CHANGE timeout: Command executed but state unknown

3. **Use trace IDs** for end-to-end correlation
   - Generate unique trace ID per command
   - Correlate with STATE_CHANGE events

4. **Check device readiness**
   - `session.isReady` must be `true` before sending commands
   - DeviceManager handles reconnection automatically

### For Testing/Debugging

1. **Use text protocol** for quick tests
2. **Monitor serial output** to see ACK/STATE_CHANGE
3. **Test one command at a time** to verify behavior

---

## Examples

### Example 1: Turn on Green LED (Agent Daemon)

```swift
// In PicoLEDTool or IntentRouter
let deviceManager = DeviceManager.shared
let session = try await deviceManager.getSession()

let result = try await session.sendCommandWithCompletion(
    commandID: .green,
    value: 1,
    ackTimeoutMs: 500,
    stateTimeoutMs: 1500
)

if result.success {
    // Command executed successfully
    // result.state contains current GPIO state
} else {
    // ACK timeout - command may not have executed
}
```

### Example 2: Flash Sequence (Python)

```python
import serial
import time

port = '/dev/cu.usbmodem2101'
ser = serial.Serial(port, 115200, timeout=2)

commands = [
    "ALL OFF\n",
    "RED ON\n",
    "GREEN ON\n",
    "YELLOW ON\n",
    "BLUE ON\n",
    "ALL ON\n",
]

for cmd in commands:
    ser.write(cmd.encode('ascii'))
    time.sleep(0.4)

ser.close()
```

### Example 3: Query State

```swift
// In Agent Daemon
let session = try await deviceManager.getSession()
let state = try await session.queryState(timeoutMs: 1000)

// Returns: [String: Bool]?
// Example: ["RED": true, "GREEN": false, "YELLOW": false, "BLUE": true]
```

---

## Summary

**For your pipeline (Agent Daemon):**
- ✅ Use **DeviceManager** → **PicoSession** → **Binary Protocol**
- ✅ Use `sendCommandWithCompletion()` for reliable execution
- ✅ Handle ACK and STATE_CHANGE events
- ✅ Check `session.isReady` before sending commands

**For testing/debugging:**
- ✅ Use `pico_led_control.py` script (text protocol)
- ✅ Monitor serial output for ACK/STATE_CHANGE
- ✅ Test commands individually

**Both protocols work simultaneously** - the firmware automatically detects the format and responds accordingly.
