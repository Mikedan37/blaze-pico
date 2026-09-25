# Boot Reliability & Health Checking

## What Was Added

### 1. Boot State Machine 

**Firmware (`main.c`):**

The firmware now follows a proper boot sequence:

```
BOOT:GPIO_INIT
BOOT:GPIO_TEST      (LEDs flash for 1s)
BOOT:GPIO_OK
BOOT:USB_WAIT       (waits for USB enumeration)
BOOT:USB_OK
BOOT_TS:<timestamp>
READY_TS:<timestamp>
BLAZE_READY         ← Host waits for this
```

**Key improvements:**
-  Proper USB connection detection (not hard-coded 2s delay)
-  Boot timestamps for telemetry (`BOOT_TS`, `READY_TS`)
-  Explicit readiness signal (`BLAZE_READY`)
-  Commands rejected if device not ready (`ERROR:NOT_READY`)

### 2. Readiness Handshake 

**Swift Controller (`PicoLEDController.swift`):**

- `waitForReady(timeoutMs:)` - Waits for `BLAZE_READY` before sending commands
- Automatically called before first command
- Parses boot timestamps for telemetry
- Prevents race conditions

**Usage:**
```swift
let controller = PicoLEDController(portPath: "/dev/cu.usbmodem1101")
try controller.waitForReady()  // Waits for BLAZE_READY
try controller.sendCommand("RED ON")
```

### 3. STATUS Command 

**Firmware:**
```
STATUS
 STATUS:OK
 GPIO:R=0 G=1 Y=0 B=1 M=0
 UPTIME:5321ms
 FW:1.0
 READY:YES
```

**Swift:**
```swift
if let status = try controller.queryStatus() {
    print("Status: \(status["status"] ?? "unknown")")
    print("Uptime: \(status["uptime_ms"] ?? "0")ms")
    print("GPIO: \(status["gpio"] ?? "unknown")")
    print("Firmware: \(status["firmware"] ?? "unknown")")
}
```

### 4. PING/PONG Handshake 

**Firmware:**
```
PING
 PONG
```

**Swift:**
```swift
if try controller.ping() {
    print("Device is alive")
}
```

### 5. Command Rejection 

All commands (text, binary, legacy) are rejected if device is not ready:

```
ERROR:NOT_READY Device still booting
```

This prevents:
- Commands sent before USB enumeration
- Commands lost during boot sequence
- Race conditions

## Boot Sequence Flow

### Firmware Side:
1. `stdio_init_all()` - Initialize USB
2. `BOOT:GPIO_INIT` - Initialize GPIO pins
3. `BOOT:GPIO_TEST` - Flash all LEDs (1s)
4. `BOOT:GPIO_OK` - GPIO test passed
5. `BOOT:USB_WAIT` - Wait for USB connection
6. `BOOT:USB_OK` - USB ready
7. `BOOT_TS:<ms>` - Boot timestamp
8. `READY_TS:<ms>` - Ready timestamp
9. `BLAZE_READY` - **Device ready for commands**
10. `accept_commands = true` - Enable command processing

### Host Side:
1. Open serial port
2. Read boot messages
3. Wait for `BLAZE_READY` (up to 5s timeout)
4. Parse `BOOT_TS` and `READY_TS` for telemetry
5. Send commands (now guaranteed to be accepted)

## Benefits

###  Eliminates Race Conditions
- Host never sends before device is ready
- No more "lost commands" during boot

###  Health Checking
- `STATUS` command provides full device state
- `PING` for quick connection verification
- Uptime tracking for reliability metrics

###  Observability
- Boot timestamps (`BOOT_TS`, `READY_TS`)
- Can measure Mac  Pico ready latency
- Full device state query

###  Production-Ready
- Proper state machine (not just prints)
- Error handling (NOT_READY rejection)
- Health check commands
- Connection verification

## Testing

### Test Boot Sequence:
```bash
screen /dev/cu.usbmodem1101 115200
# Reset Pico (or unplug/replug)
# Should see:
# BOOT:GPIO_INIT
# BOOT:GPIO_TEST
# BOOT:GPIO_OK
# BOOT:USB_WAIT
# BOOT:USB_OK
# BOOT_TS:1234
# READY_TS:2345
# BLAZE_READY
```

### Test STATUS Command:
```bash
screen /dev/cu.usbmodem1101 115200
# Type: STATUS
# Should see:
# STATUS:OK
# GPIO:R=0 G=0 Y=0 B=0 M=0
# UPTIME:12345ms
# FW:1.0
# READY:YES
```

### Test PING:
```bash
screen /dev/cu.usbmodem1101 115200
# Type: PING
# Should see: PONG
```

### Test Swift Tool:
```bash
cd PicoLEDControlSwift
swift run PicoLEDControl RED ON
# Should automatically wait for BLAZE_READY
# Then send command
```

## What This Enables

### 1. Auto-Recovery
AgentDaemon can:
- Detect device not ready
- Wait for readiness
- Retry commands

### 2. Health Monitoring
- Periodic STATUS checks
- Uptime tracking
- GPIO state verification

### 3. Telemetry Integration
- Boot  Ready latency measurement
- Device health metrics
- Connection reliability tracking

### 4. Multi-Device Support
- Each device reports readiness independently
- Can query status of all devices
- Health check before routing commands

## Next Steps

1.  Boot state machine
2.  Readiness handshake
3.  STATUS command
4.  PING/PONG
5.  Wire into AgentDaemon (health checks)
6.  Add to telemetry pipeline
7.  Multi-device support

## Files Modified

- `main.c` - Boot state machine, STATUS/PING commands, readiness checks
- `PicoLEDController.swift` - `waitForReady()`, `queryStatus()`, `ping()` methods

## Notes

- Boot sequence is **non-blocking** - USB wait is adaptive (not hard-coded)
- Commands are **rejected** if device not ready (prevents silent failures)
- STATUS command provides **full device state** (not just LED states)
- PING/PONG is **lightweight** for connection verification

This transforms the Pico from a "blink demo" into a **production-ready embedded control node** with proper state management and health checking.
