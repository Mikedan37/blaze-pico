# Complete Pipeline Audit: Voice  Hardware Control

## Executive Summary

This document provides a comprehensive audit of the entire pipeline from voice input to hardware GPIO control. The system implements a production-grade hardware control runtime with deterministic lifecycle management, epoch-based session identity, and causal command confirmation.

**Pipeline Overview:**
```
Voice Input  Speech Recognition  Voice Agent App  AgentDaemon  IntentRouter  
PicoLEDTool  DeviceManager  PicoSession  USB Serial  Firmware  GPIO  LEDs
```

---

## 1. Voice Input Layer

### Component: Voice Agent Controller (macOS App)

**Location:** External app (not in this repo)

**Responsibilities:**
- Captures microphone audio
- Performs speech-to-text conversion (Apple Speech Framework)
- Sends transcribed text to AgentDaemon via Unix socket
- Displays UI feedback and command status

**Protocol:**
- Connects to `/tmp/blaze_agent.sock`
- Sends JSON messages with `requestID`, `messageID`, and `text` fields
- Waits for response with timeout (150s default)
- Handles reconnection on daemon restart

**Key Behaviors:**
- Real-time transcription updates (partial results)
- Final transcription sent when speech ends
- Error handling for daemon unavailability
- Retry logic for transient failures

---

## 2. AgentDaemon Layer

### Component: AgentDaemon (Swift Runtime)

**Location:** `/Users/mdanylchuk/Developer/ProjectBlaze/AgentDaemon`

**Architecture:**
- Unix socket server (`/tmp/blaze_agent.sock`)
- LLM integration (Ollama local or OpenAI)
- Tool registry for hardware control
- IntentRouter for fast-path command routing

### 2.1 Socket Server

**Initialization:**
1. Starts Unix socket listener
2. Calls `DeviceManagerCommandHelper.initialize()`  `DeviceManager.warmStart()`
3. Opens persistent serial session to Pico device
4. Waits for `BLAZE_READY` (5s timeout)
5. Begins accepting client connections

**Request Handling:**
- Accepts JSON messages via Unix socket
- Routes to `planWork()` or `IntentRouter.routeAndEncode()`
- Returns JSON responses with execution results

### 2.2 IntentRouter (Fast-Path Routing)

**Purpose:** Bypass LLM for deterministic commands (<5ms vs ~150ms)

**Matching Logic:**
- Regex patterns for common commands:
  - `"turn (red|green|yellow|blue|all) (on|off)"`
  - `"turn (all )?lights? off"`
  - `"blink (red|green|yellow|blue)"`
  - `"what lights? (are )?(on|off)?"`
- Confidence threshold: ≥0.95  deterministic execution
- <0.95  fallback to full LLM planner

**Execution Flow:**
1. Parse command  `ToolAction` enum
2. Call `executeLight()`, `executeLightOff()`, `executeBlink()`, or `executeQueryState()`
3. Each calls `PicoLEDTool.invoke()` with parsed arguments
4. Returns `ToolExecutionResult` with success/error message

### 2.3 PicoLEDTool

**Location:** `AgentDaemon/Sources/AgentDaemon/Tools/Hardware/PicoLEDTool.swift`

**Responsibilities:**
- Wraps `DeviceManagerCommandHelper` for hardware control
- Parses command arguments (color, state, query)
- Sends commands via persistent session
- Captures STATE_CHANGE events for state updates

**Implementation:**
```swift
// Uses DeviceManager's persistent session (no port conflicts)
let result = try await DeviceManagerCommandHelper.sendCommand("GREEN ON")
// Returns: (success: Bool, state: [String: Bool]?)
```

**Key Features:**
- Idempotent initialization (checks if already initialized)
- Automatic state sync after commands
- Error handling with detailed messages
- Supports multiple command formats:
  - `{"command": "RED ON"}`
  - `{"color": "RED", "state": "ON"}`
  - `{"query": "true"}`

---

## 3. DeviceManager Layer

### Component: DeviceManager (Swift Actor)

**Location:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManager.swift`

**Architecture:**
- Singleton actor (`DeviceManager.shared`)
- Maintains persistent `PicoSession` (single serial port connection)
- Handles reconnects and session lifecycle
- Caches port paths (60s validity)

### 3.1 Warm Start (Initialization)

**Process:**
1. Scans for Pico ports (`/dev/cu.usbmodem*`)
2. Caches port list (60s validity)
3. Creates `PicoSession` for first port
4. Calls `session.connect(timeoutMs: 5000)`:
   - Opens serial port (115200 baud)
   - Waits for `BLAZE_READY` signal
   - Verifies transport with QUERY_STATE probe
   - Starts event reader and heartbeat monitor
5. Stores session as `persistentSession`
6. Starts keepalive ping (every 30s)
7. Starts periodic state sync (every 30s)

**Timeout:** 5 seconds (allows for USB enumeration + CDC stability + boot messages)

### 3.2 Session Management

**getSession() Flow:**
1. If `persistentSession` exists and `isConnected`  return immediately (fast path)
2. If missing/disconnected  call `warmStart()` with 5s timeout
3. Return session or throw error

**Reconnect Handling:**
- Detects USB disconnect via `session.isConnected` check
- Invalidates session on hard failure (write/read errors)
- Automatically reconnects on next `getSession()` call
- Queries state on reconnect to establish authoritative state

### 3.3 DeviceManagerCommandHelper

**Location:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManagerCommandHelper.swift`

**Purpose:** Simplified API wrapper for DeviceManager

**Functions:**
- `initialize()`  calls `DeviceManager.shared.warmStart()`
- `sendCommand(_ command: String)`  parses text, sends via session
- `queryState()`  queries device state via session

**Command Parsing:**
- Supports: `"RED ON"`, `"GREEN OFF"`, `"ALL ON"`, etc.
- Parses to `(CommandID, UInt8)` tuple
- Handles multiple commands (semicolon-separated)

---

## 4. PicoSession Layer

### Component: PicoSession (Swift Class)

**Location:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift`

**Architecture:**
- Wraps `SerialPort` for USB CDC communication
- Implements binary protocol (BlazeTransport)
- Event-driven state machine
- Session identity tracking (UUID-based)

### 4.1 Connection Lifecycle

**connect(timeoutMs: 5000) Process:**
1. Opens serial port (`SerialPort.open(baudRate: 115200)`)
2. Waits for `BLAZE_READY` signal:
   - Reads serial data in 100ms chunks
   - Parses text for "BLAZE_READY" string
   - Timeout: 5 seconds
3. Transport verification:
   - Sends QUERY_STATE probe packet
   - Waits for STATE: or ACK response
   - Retries up to 3 times
4. Sets `isConnected = true`, `isReady = true`
5. Starts `startEventReader()` task
6. Starts `startHeartbeatMonitor()` task

**Readiness Gates:**
- `isConnected`: Serial port opened
- `isReady`: `BLAZE_READY` received + transport verified
- Commands blocked until `isReady == true`

### 4.2 Binary Protocol

**Packet Format:**
```
[BLAZ] + [16-byte header] + [payload]
```

**Header (16 bytes, big-endian):**
- byte 0: version (UInt8) = 1
- byte 1: flags (UInt8) = 0
- bytes 2-5: connectionID (UInt32)
- bytes 6-9: packetNumber (UInt32)
- bytes 10-13: streamID (UInt32)
- bytes 14-15: payloadLength (UInt16)

**Payload (for DATA frames):**
- byte 0: frameType (UInt8) = 0
- bytes 1-8: traceID (UInt64, big-endian)
- byte 9: commandID (UInt8)
- byte 10: value (UInt8)

**Command IDs:**
- 1 = RED, 2 = GREEN, 3 = YELLOW, 4 = BLUE
- 5 = MULTI (all RGB), 6 = MULTI_RED, 7 = MULTI_GREEN, 8 = MULTI_BLUE
- 10 = ALL, 20 = QUERY_STATE

### 4.3 Command Execution

**sendCommand() Flow:**
1. Check `isInvalidated` (session still valid?)
2. Check `isConnected` and `isReady` (device ready?)
3. Generate trace ID (if not provided)
4. Add to command queue (adaptive batching)
5. Flush queue if full or timeout
6. Build binary packet with "BLAZ" magic
7. Write to serial port (non-blocking)
8. Return immediately (no waiting)

**sendCommandWithCompletion() Flow:**
1. Call `sendCommand()` (sends packet)
2. Wait for ACK event (500ms timeout):
   - Listens to `events` PassthroughSubject
   - Filters for ACK with matching trace ID
   - Returns `success = false` if timeout
3. Wait for STATE_CHANGE event (1500ms timeout):
   - Filters for STATE_CHANGE with matching trace ID or seq > lastSeq
   - Parses GPIO state from STATE_CHANGE message
   - Returns `state: [String: Bool]?` (nil if timeout)
4. Returns `(success: Bool, state: [String: Bool]?)`

**Key Features:**
- Trace ID correlation (prevents ghost ACKs)
- Sequence number tracking (prevents stale state)
- Automatic batching (up to 8 commands)
- Graceful timeout handling (returns nil, doesn't throw)

### 4.4 Event Processing

**Event Reader Task:**
- Continuously reads serial data (line-by-line)
- Parses text events:
  - `SESSION:<uuid>`  session identity change
  - `STATE: seq=... R=... G=...`  initial state
  - `BLAZE_READY`  device ready signal
  - `ACK TRACE:<id>`  command acknowledgment
  - `STATE_CHANGE: trace=<id> seq=...`  state update
  - `ERROR:...`  error events
- Emits events via `events` PassthroughSubject
- Handles session invalidation (stops on disconnect)

**Session Identity Tracking:**
- Detects `SESSION:` messages
- Compares with `currentSessionID`
- If changed  device rebooted/reconnected
- Invalidates pending commands
- Resets sequence tracking

**Sequence Tracking:**
- Tracks `lastAppliedSequence`
- STATE_CHANGE events include `seq` number
- Only applies state if `seq > lastAppliedSequence`
- Prevents applying stale state updates

---

## 5. Serial Port Layer

### Component: SerialPort (Swift Class)

**Location:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/SerialPort.swift`

**Responsibilities:**
- Low-level USB CDC serial communication
- File descriptor management
- Termios configuration (115200 baud, 8N1)
- Non-blocking I/O with timeouts

**Key Functions:**
- `open(baudRate:)`  opens `/dev/cu.usbmodem*` with termios
- `write(_ data: Data)`  writes to file descriptor
- `read(maxBytes:timeoutMs:)`  reads with timeout
- `close()`  closes file descriptor

**Error Handling:**
- Distinguishes fatal vs transient errors
- Fatal: device disconnected, permission denied
- Transient: EAGAIN (buffer full), timeout

---

## 6. Firmware Layer

### Component: main.c (C Firmware)

**Location:** `/Users/mdanylchuk/pico/blaze-pico/main.c`

**Architecture:**
- Raspberry Pi Pico firmware (RP2040)
- USB CDC serial interface
- Dual-mode protocol (text + binary)
- Production-grade lifecycle management

### 6.1 Boot Sequence

**Initialization:**
1. `stdio_init_all()`  USB CDC initialization
2. GPIO setup (LED pins configured)
3. Diagnostic LED blink sequence
4. **Wait for USB connection:**
   ```c
   while (!stdio_usb_connected()) {
       sleep_ms(50);  // Poll every 50ms
   }
   ```
5. **Wait for CDC stability:** `sleep_ms(200)`
6. **Generate session UUID:** timestamp + monotonic counter
7. **Emit lifecycle messages (CRITICAL ORDER):**
   ```c
   printf("SESSION:%08X\n", session_uuid);
   printf("STATE: seq=%llu R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d\n", ...);
   printf("BLAZE_READY\n");
   ```
8. Set `session_active = true`, `accept_commands = true`

**Reconnect Handling:**
- Detects USB disconnect: `if (!stdio_usb_connected())`
- Invalidates session: `session_active = false`
- Waits for reconnect: `wait_for_usb_connection()`
- Restarts session: `start_usb_session(true)` (new UUID)

### 6.2 Command Processing Loop

**Main Loop:**
```c
while(true) {
    // Check USB connection
    if (!stdio_usb_connected()) {
        handle_usb_disconnect();
        wait_for_usb_connection();
        start_usb_session(true);
        continue;
    }
    
    // Only process commands when ready
    if (!session_active || !accept_commands || !stdio_usb_connected()) {
        sleep_ms(50);
        continue;
    }
    
    // Read serial data
    int c = getchar_timeout_us(1000);
    // ... parse packet ...
}
```

**Protocol Detection:**
- Text mode: Reads characters until newline
- Binary mode: Detects "BLAZ" magic header (4 bytes)
- Switches to binary parser on magic detection

**Binary Packet Parsing:**
1. Reads 16-byte header
2. Extracts payload length
3. Reads payload
4. Parses: `[frameType][traceID(8)][commandID][value]`
5. Executes command: `exec_binary_with_trace(commandID, value, traceID)`

### 6.3 Command Execution

**exec_binary_with_trace() Flow:**
1. Validates `accept_commands` flag
2. Executes command:
   ```c
   switch(commandID) {
       case CMD_RED: set_led_state(0, value); break;
       case CMD_GREEN: set_led_state(1, value); break;
       // ... etc
       case CMD_ALL:
           for(int i = 0; i < 7; i++) {
               set_led_state(i, value);
           }
           // Force explicit GPIO write for ALL OFF
           if (!value) {
               gpio_put(RED_PIN, 0);
               gpio_put(GREEN_PIN, 0);
               // ... all pins
           }
           break;
   }
   ```
3. Increments `state_sequence`
4. Emits ACK: `printf("ACK TRACE:%llu cmdID=%d value=%d\n", traceID, commandID, value)`
5. Emits STATE_CHANGE: `printf("STATE_CHANGE: trace=%llu seq=%llu R=%d G=%d ...\n", ...)`
6. Flushes stdout

**GPIO Control:**
- `set_led_state(index, value)`  updates `led_state[]` array
- `gpio_put(pin, value)`  physical GPIO write
- Explicit GPIO writes for ALL OFF to ensure physical state matches logic

### 6.4 State Management

**State Sequence:**
- Monotonic counter: `state_sequence` (increments on every command)
- Included in STATE and STATE_CHANGE messages
- Host uses this to detect stale state updates

**Session UUID:**
- Generated on every session start (boot or reconnect)
- Format: `timestamp(high 20 bits) | counter(low 12 bits)`
- Ensures uniqueness even on rapid reconnects
- Host uses this to detect device reboots

---

## 7. Hardware Layer

### Component: GPIO  LEDs

**GPIO Mapping:**
- RED  GPIO 14
- GREEN  GPIO 15
- YELLOW  GPIO 16
- BLUE  GPIO 17
- MULTI_RED  GPIO 24
- MULTI_GREEN  GPIO 25
- MULTI_BLUE  GPIO 26
- FEEDBACK  GPIO 19 (photodiode/loopback)

**Physical Control:**
- `gpio_put(pin, 1)`  LED ON
- `gpio_put(pin, 0)`  LED OFF
- State stored in `led_state[]` array for query

---

## 8. Critical Invariants

### 8.1 Session Lifecycle Order

**MUST ALWAYS BE:**
1. `SESSION:<uuid>`
2. `STATE: seq=... R=... G=...`
3. `BLAZE_READY`

**Why:** Host session correlation depends on this exact sequence. Breaking it causes:
- Session tracking failures
- Stale state correlation
- Ghost ACK problems
- Sequence desynchronization

### 8.2 Readiness Gates

**Firmware:**
- `session_active && accept_commands && stdio_usb_connected()`

**Host:**
- `isConnected && isReady`

**Why:** Commands must never execute before device is ready. This prevents:
- Commands sent before USB enumeration
- Commands during boot sequence
- Commands after disconnect

### 8.3 Command Confirmation

**Every command MUST:**
1. Emit ACK (confirms execution)
2. Emit STATE_CHANGE (confirms state update)

**Host MUST:**
- Wait for ACK before considering command successful
- Use STATE_CHANGE for state updates (not queryState)
- Handle timeouts gracefully (return nil, don't throw)

**Why:** USB CDC can silently drop writes. ACK confirms execution. STATE_CHANGE provides causal state.

### 8.4 Session Identity

**Firmware:**
- New UUID on every session start (boot or reconnect)
- Never reuse previous UUID

**Host:**
- Track `currentSessionID`
- Invalidate pending commands on session change
- Reset sequence tracking on session change

**Why:** Prevents ghost ACKs from previous sessions. Epoch-based identity ensures clean state.

---

## 9. Error Handling & Recovery

### 9.1 USB Disconnect

**Firmware:**
- Detects via `stdio_usb_connected()`
- Invalidates session
- Waits for reconnect
- Generates new session UUID

**Host:**
- Detects via `session.isConnected` check
- Invalidates session on hard failure
- Automatically reconnects on next `getSession()` call
- Queries state on reconnect

### 9.2 Timeout Handling

**Command Timeouts:**
- ACK timeout: 500ms (fast failure detection)
- STATE_CHANGE timeout: 1500ms (allows USB hiccups)
- Returns `success = false`, `state = nil` (doesn't throw)

**Connection Timeouts:**
- `warmStart()` timeout: 5s (allows boot time)
- `connect()` timeout: 5s (allows USB enumeration)
- Throws error if timeout (device not available)

### 9.3 Retry Logic

**Transport Verification:**
- QUERY_STATE probe retries: 3 attempts
- 200ms delay between retries

**Reconnect:**
- Automatic on next `getSession()` call
- No fixed retry limit (relies on user retry)

---

## 10. Performance Characteristics

### 10.1 Latency Breakdown

**Typical Command Latency:**
- Voice recognition: ~500-1000ms (varies)
- IntentRouter matching: <5ms (fast path)
- LLM processing: ~150ms (if needed)
- Tool execution: ~10ms (DeviceManager call)
- Serial write: ~1-5ms
- USB CDC transmission: ~10-20ms
- Firmware execution: <1ms
- ACK response: ~50-100ms (USB scheduling)
- STATE_CHANGE: ~50-100ms (USB scheduling)
- **Total: ~200-300ms** (excluding voice recognition)

**P50 Latency:** ~158ms (from benchmarks)
**P99 Latency:** ~2.2s (USB scheduling spikes)

### 10.2 Throughput

**Single Command:**
- ~5-10 commands/second (limited by ACK wait)

**Batch Commands:**
- Up to 8 commands batched
- ~20-30 commands/second (with batching)

**Limitations:**
- USB CDC frame scheduling (~1ms per frame)
- ACK wait time (500ms timeout)
- Host pacing (no backpressure currently)

---

## 11. Known Limitations & Future Improvements

### 11.1 Current Limitations

1. **No Host Backpressure:**
   - Host can send unlimited commands
   - Firmware queue limited (no explicit limit)
   - Solution: Add max pending commands check

2. **USB CDC Quirks:**
   - Occasional TX stalls (200-400ms)
   - First packet may be dropped after port open
   - Solution: Already handled with retries/timeouts

3. **No Flow Control:**
   - Host doesn't wait for ACK before next command
   - Solution: Implement sequential command sending

### 11.2 Future Improvements

1. **Heartbeat Monitoring:**
   - Already implemented but could be more aggressive
   - Detect dead sessions faster

2. **State Caching:**
   - Cache state on host side
   - Reduce queryState() calls

3. **Command Batching:**
   - Already implemented but could be optimized
   - Reduce USB frame overhead

4. **Telemetry:**
   - Add latency metrics
   - Track command success rates
   - Monitor USB errors

---

## 12. Testing & Validation

### 12.1 Test Scenarios

**Connection Tests:**
-  Plug Pico after host started
-  Start host after Pico already plugged
-  Unplug Pico mid-command
-  Replug Pico repeatedly
-  Sleep/wake Mac with Pico connected

**Command Tests:**
-  Single command execution
-  Multiple rapid commands
-  Batch commands
-  State queries
-  Error handling (device disconnected)

**Lifecycle Tests:**
-  Session UUID changes on reconnect
-  Sequence resets on reconnect
-  STATE emitted on every session start
-  BLAZE_READY gates command execution

### 12.2 Benchmark Results

**From `docs/BENCHMARK_RESULTS_DETAILED.md`:**
- P50 ACK latency: ~79ms
- P50 total latency: ~158ms
- P99 latency: ~2.2s (USB spikes)
- Zero write errors (after fixes)
- Session survives reconnects
- Batch failure at ~21 commands (backpressure needed)

---

## 13. Conclusion

This pipeline implements a **production-grade hardware control runtime** with:

 **Deterministic lifecycle management**
 **Epoch-based session identity**
 **Causal command confirmation**
 **Robust error handling**
 **Automatic reconnection**
 **State authority model**

The system is **architecturally sound** and ready for production use. Remaining work is primarily **operational improvements** (backpressure, telemetry, optimization) rather than architectural fixes.

---

## Appendix: Key Files Reference

**Firmware:**
- `main.c` - Pico firmware (C)
- `docs/FLASH_PROCESS.md` - Build/flash instructions

**Host Library:**
- `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManager.swift` - Session management
- `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift` - Serial communication
- `PicoLEDControlSwift/Sources/PicoLEDControlLib/SerialPort.swift` - Low-level I/O

**AgentDaemon:**
- `AgentDaemon/Sources/AgentDaemon/AgentDaemonMain.swift` - Daemon entry point
- `AgentDaemon/Sources/AgentDaemon/Core/IntentRouter.swift` - Fast-path routing
- `AgentDaemon/Sources/AgentDaemon/Tools/Hardware/PicoLEDTool.swift` - Hardware tool

**Documentation:**
- `docs/PRODUCTION_RULES.md` - Critical rules
- `docs/HARDWARE_RUNTIME_ARCHITECTURE.md` - Architecture overview
- `docs/AGENT_DAEMON_INTEGRATION.md` - Integration guide
