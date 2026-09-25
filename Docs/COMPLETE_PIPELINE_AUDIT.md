# Complete End-to-End Pipeline Audit: Voice  Hardware Control

## Executive Summary

This document provides a **comprehensive end-to-end audit** of the entire pipeline from voice input to hardware GPIO control. The system implements a **production-grade distributed control runtime** with:

- **Multi-tier routing** (keyword  regex  LLM planner)
- **Progressive execution** (immediate actions + background planning)
- **Deterministic lifecycle management** (session epochs, readiness gates)
- **Causal command confirmation** (ACK + STATE_CHANGE)
- **State authority model** (hardware is source of truth)
- **Full observability** (trace IDs, telemetry, structured logging)

**Complete Pipeline:**
```
User Voice Input
    
VoiceAgentController (macOS SwiftUI App)
     [Speech Recognition]
Transcribed Text
    
AgentDaemonClient (Swift Library)
     [Unix Socket /tmp/blaze_agent.sock]
AgentDaemon (Swift Runtime)
     [IntentRouter / LLM Planner]
PicoLEDTool (Hardware Tool)
    
DeviceManager (Session Manager)
    
PicoSession (Serial Communication)
     [USB CDC Serial]
Pico Firmware (C Runtime)
     [GPIO Control]
Hardware LEDs
```

---

## 1. VoiceAgentController Layer (macOS SwiftUI App)

### Component: VoiceAgentController

**Location:** `/Users/mdanylchuk/Developer/ProjectBlaze/VoiceAgentController`

**Architecture:**
- SwiftUI macOS application
- Real-time speech recognition (Apple Speech Framework)
- Progressive execution coordinator
- State authority manager
- Phase machine for UI state
- AgentDaemonClient integration

### 1.1 Speech Recognition

**Implementation:**
- Uses `SFSpeechRecognizer` (Apple Speech Framework)
- Real-time transcription with partial results
- Final transcription when speech ends
- Handles recognition errors gracefully

**Flow:**
1. User presses "Start Recording" button
2. `SFSpeechRecognizer` captures audio
3. Partial results: `sendVoiceCommand(text: "Green", isPartial: true)`
4. Final result: `sendVoiceCommand(text: "Green light", isPartial: false)`

**Key Behaviors:**
- Partial transcripts trigger immediate action extraction (if high confidence)
- Final transcript triggers full daemon request
- Duplicate prevention (ignores identical pending commands)

### 1.2 Progressive Execution Coordinator

**Location:** `VoiceAgentController/ProgressiveExecutionCoordinator.swift`

**Purpose:** Execute immediate actions while planning remaining steps in background

**Flow:**
1. Extract immediate action from transcript (e.g., "turn green light on")
2. If confidence ≥ threshold  execute immediately via fast-path
3. Start background planning for remaining steps
4. Update UI optimistically (before hardware confirmation)
5. Correct UI if hardware fails

**Features:**
- Intent locking (prepares command packet during partial transcript)
- Packet pre-building (zero-prep-time execution on final transcript)
- Duplicate detection (prevents double-execution)
- Telemetry tracking (latency measurements at each stage)

### 1.3 KeywordFastPath (Tier 0 Router)

**Location:** `VoiceAgentController/KeywordFastPath.swift`

**Purpose:** Bypass daemon entirely for simple commands (<5ms vs ~150ms LLM)

**Matching Logic:**
- Exact phrase match: confidence 0.95
- Keyword set match: confidence 0.85-0.92
- Ambiguous: <0.75  send to daemon

**Patterns:**
- `"all lights off"`  `.allLightsOff` (0.95)
- `"turn red on"`  `.redOn` (0.88)
- `"green light"`  `.greenOn` (0.82, assumes ON)

**Benefits:**
- ~800ms-2s latency reduction for common commands
- No LLM overhead for deterministic actions
- Lower daemon load

### 1.4 AssistantPhaseMachine

**Location:** `VoiceAgentController/AssistantPhaseMachine.swift`

**Purpose:** Single authoritative state machine for UI transitions

**Phases:**
- `.idle`  `.listening`  `.interpreting(partialText:)`  `.intentLocked(summary:)`  `.intentRecognized(summary:)`  `.executing(summary:)`  `.waitingForDevice(summary:, startTime:)`  `.success(summary:)` / `.failure(message:)`

**Features:**
- Minimum duration enforcement (success: 800ms, failure: 1.5s)
- Watchdog for WAITING_FOR_DEVICE phase (3s timeout)
- Backend event queue (prevents race conditions)
- Telemetry tracking (latency at each phase)

**Production Hardening:**
- Temporal identity ownership (command IDs, trace IDs)
- Device state confirmation tracking
- Backpressure limits (max 50 pending events)

### 1.5 StateAuthorityManager

**Location:** `VoiceAgentController/StateAuthorityManager.swift`

**Purpose:** Reconnect-safe state authority pattern (single source of truth)

**Features:**
- **State Deduplication:** 100ms window (debounces rapid changes)
- **Event Deduplication:** 500ms window (prevents duplicate STATE_CHANGE events)
- **Reconnect Recovery:** Marks state unknown on disconnect, recovers after first command
- **State Caching:** 30s validity (survives reconnects)

**Flow:**
```
STATE_CHANGE event received
    
Event deduplication check (500ms window)
    
State deduplication check (100ms window)
    
Apply state update
    
Update authoritativeState (published)
    
VoiceDaemonBridge.deviceState updated (via Combine)
    
UI updates automatically
```

**Reconnect Recovery:**
```
Disconnect detected
    
Save last known state to cache
    
Enter recovery mode (state = unknown)
    
Reconnect detected
    
Load cached state (if < 30s old)
    
Wait for first command
    
First STATE_CHANGE received
    
Exit recovery mode
    
State is now valid
```

### 1.6 VoiceDaemonBridge

**Location:** `VoiceAgentController/VoiceDaemonBridge.swift`

**Purpose:** Bridge between UI and AgentDaemon

**Responsibilities:**
- Manages AgentDaemonClient connection
- Sends voice commands to daemon
- Receives responses and execution events
- Updates device state from STATE_CHANGE events
- Handles reconnection logic
- Periodic state sync (every 5 seconds)

**Connection Management:**
- Creates single `AgentDaemonClient` instance (reused forever)
- Probes daemon with "agent status" command on connect
- 150s timeout for long-running commands
- Automatic reconnection on daemon restart

**State Updates:**
- Parses STATE_CHANGE from tool output events
- Parses STATE: from daemon responses
- Updates StateAuthorityManager
- UI updates automatically via Combine publishers

**Event Handling:**
- Real-time execution events (thinking, plannerStarted, toolSelected, toolRunning, toolFinished)
- Event deduplication
- Status message management (minimize after completion)

### 1.7 UnixDomainSocketClient

**Location:** `VoiceAgentController/UnixDomainSocketClient.swift`

**Purpose:** Low-level Unix socket communication

**Protocol:**
- BlazeTransport-style framing: `[length(4 bytes)] + [payload]`
- Native 32-bit length prefix (host byte order)
- Full send/receive with retry logic

**Features:**
- Frame-safe communication (length prefix prevents fragmentation)
- Error handling (connection failures, timeouts)
- macOS-specific socket handling (sun_len required)

---

## 2. AgentDaemonClient Layer (Swift Library)

### Component: AgentDaemonClient

**Location:** `/Users/mdanylchuk/Developer/ProjectBlaze/AgentDaemonClient`

**Architecture:**
- Swift library for communicating with AgentDaemon
- Handles connection management, retries, frame-safe communication
- Request/response encoding via BlazeBinary

### 2.1 Client Architecture

**Connection Management:**
- Automatic reconnection with exponential backoff
- Connection pooling (reuses single connection)
- Timeout handling (configurable per request)

**Request Types:**
- `planWork` - Generate and execute work plan
- `fixError` - Fix compilation errors
- `analyzeWorkspace` - Analyze workspace structure
- `executePlan` - Execute pre-generated plan
- `getMemoryLog` - Retrieve operational memory

### 2.2 planWork() Method

**Purpose:** Generate work plan from natural language goal

**Flow:**
1. Encode `PlanWorkRequest` (workspacePath, goal, model)
2. Send via Unix socket with BlazeBinary encoding
3. Read responses in loop:
   - `ExecutionEventResponse`  call event handler (streaming events)
   - `PlanWorkResponse`  final response (contains plan)
4. Return final response

**Event Streaming:**
- Real-time events during execution:
  - `.thinking` - LLM reasoning
  - `.plannerStarted` - Planning phase started
  - `.toolSelected` - Tool chosen
  - `.toolRunning` - Tool executing
  - `.toolFinished` - Tool completed
  - `.reasoning` - Agent reasoning
  - `.completed` - Execution complete
  - `.error` - Error occurred

**Timeout:** 150 seconds (allows for long-running plans)

### 2.3 Error Handling

**Error Types:**
- `daemonUnavailable` - Daemon not running
- `connectionFailed` - Socket connection failed
- `decodeError` - Response decode failed
- `invalidResponse` - Response doesn't match request
- `timeout` - Request timed out

**Retry Logic:**
- Max 3 retries with exponential backoff
- Initial delay: 0.5s
- Max backoff: 2.0s
- Retries only on transient errors (socketClosed, connectionFailed)

---

## 3. AgentDaemon Layer (Swift Runtime)

### Component: AgentDaemon

**Location:** `/Users/mdanylchuk/Developer/ProjectBlaze/AgentDaemon`

**Architecture:**
- Unix socket server (`/tmp/blaze_agent.sock`)
- LLM integration (Ollama local or OpenAI)
- Tool registry for hardware/software control
- IntentRouter for fast-path routing
- AgentRequestRouter for request handling
- Autonomous mode (background task execution)
- Fix pipeline orchestrator (error recovery)
- Operational memory (metrics, failure history)

### 3.1 DaemonServer

**Initialization Sequence:**
1. Acquire process lock (prevents multiple instances)
2. Setup authentication (if enabled)
3. Initialize AgentRequestRouter
4. Health check LLM provider (fail loudly if unavailable)
5. Pre-warm model (load into GPU if available)
6. Initialize DeviceManager (persistent serial session)
7. Start Unix socket listener
8. Begin accept loop (blocks forever)

**Socket Protocol:**
- BlazeBinary encoding (binary protocol)
- Frame-safe communication (length prefix)
- Request/response matching via requestID
- Streaming events during execution

### 3.2 AgentRequestRouter

**Purpose:** Routes incoming requests to appropriate handlers

**Request Types:**
- `.plan`  `planWork()` handler
- `.fixError`  `fixError()` handler
- `.analyze`  `analyzeWorkspace()` handler
- `.executePlan`  `executePlan()` handler
- `.getMemoryLog`  `getMemoryLog()` handler

**planWork() Handler:**
1. Decode `PlanWorkRequest`
2. Check IntentRouter for fast-path match
3. If fast-path  execute immediately, return response
4. If not  call LLM planner
5. Generate work plan
6. Execute plan (if auto-execute enabled)
7. Stream execution events
8. Return final response

### 3.3 IntentRouter (Fast-Path Router)

**Location:** `AgentDaemon/Sources/AgentDaemon/Core/IntentRouter.swift`

**Purpose:** Bypass LLM for deterministic commands (<5ms vs ~150ms)

**Architecture:**
- Tier 0: Regex/keyword matching (<5ms) - handles 80% of commands
- Tier 1: Small LLM classifier (~150ms) - future enhancement
- Tier 2: Full planner (~5s) - only when needed

**Matching Logic:**
- Regex patterns for common commands:
  - `"turn (red|green|yellow|blue|all) (on|off)"`
  - `"turn (all )?lights? off"`
  - `"blink (red|green|yellow|blue)"`
  - `"what lights? (are )?(on|off)?"`
- Confidence threshold: ≥0.95  deterministic execution
- <0.95  fallback to full LLM planner

**Command Coalescing:**
- Duplicate commands coalesced (keep only last one)
- 100ms window for duplicate detection
- Prevents "I repeated myself" lag and flicker

**Hardware Execution Queue:**
- Serial queue for hardware access (prevents USB port contention)
- Max queue depth: 10 commands
- Backpressure: rejects if queue full

**Execution Flow:**
1. Parse command  `ToolAction` enum
2. Check for duplicates (coalesce if found)
3. Check queue depth (reject if full)
4. Enqueue on hardware execution queue
5. Execute: `executeLight()`, `executeLightOff()`, `executeBlink()`, or `executeQueryState()`
6. Each calls `PicoLEDTool.invoke()` with parsed arguments
7. Returns `ToolExecutionResult` with success/error message

**State Management:**
- DeviceStateManager tracks device state
- Idempotency checks (skip redundant commands)
- Optimistic updates (update state before ACK)
- Background state sync (non-blocking)

### 3.4 PicoLEDTool

**Location:** `AgentDaemon/Sources/AgentDaemon/Tools/Hardware/PicoLEDTool.swift`

**Purpose:** Hardware tool for controlling Pico LEDs

**Implementation:**
- Uses `DeviceManagerCommandHelper` (no port conflicts)
- Parses command arguments (color, state, query)
- Sends commands via persistent session
- Captures STATE_CHANGE events for state updates

**Command Formats:**
- `{"command": "RED ON"}` - Direct command string
- `{"color": "RED", "state": "ON"}` - Structured arguments
- `{"query": "true"}` - State query

**Features:**
- Idempotent (no initialization needed)
- Automatic state sync after commands
- Error handling with detailed messages
- Telemetry logging (latency tracking)

### 3.5 LLM Planner (Full Agent)

**Purpose:** Generate work plans for complex commands

**Capabilities:**
- Natural language understanding
- Multi-step plan generation
- Tool selection and orchestration
- Error recovery (fix pipeline)
- Autonomous mode (background execution)

**Workflow:**
1. Analyze user goal
2. Generate step-by-step plan
3. Select appropriate tools
4. Execute plan steps sequentially
5. Handle errors (retry, fix, or abort)
6. Return execution results

**Tools Available:**
- `pico_led_control` - Hardware LED control
- File system tools (read, write, search)
- Code analysis tools
- Build/execution tools
- And more...

### 3.6 Autonomous Mode

**Purpose:** Background task execution without user interaction

**Features:**
- Periodic workspace scanning
- Automatic error detection
- Fix pipeline execution
- Approval gates (if configured)
- Operational memory tracking

**Configuration:**
- Enable/disable via config file
- Interval: configurable (default: 30s)
- Require approval: yes/no
- Workspace scope: single or multiple

### 3.7 Fix Pipeline Orchestrator

**Purpose:** Automated error recovery and fix generation

**Flow:**
1. Detect error (compilation, runtime, etc.)
2. Analyze error context
3. Generate fix plan
4. Execute fix
5. Verify fix (compile, test)
6. Record to failure memory

**Failure Memory:**
- Persistent fix history
- Pattern recognition
- Avoid repeating failed fixes

---

## 4. DeviceManager Layer (Session Management)

### Component: DeviceManager

**Location:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManager.swift`

**Architecture:**
- Singleton actor (`DeviceManager.shared`)
- Maintains persistent `PicoSession` (single serial port connection)
- Handles reconnects and session lifecycle
- Caches port paths (60s validity)

### 4.1 Warm Start (Initialization)

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

### 4.2 Session Management

**getSession() Flow:**
1. If `persistentSession` exists and `isConnected`  return immediately (fast path)
2. If missing/disconnected  call `warmStart()` with 5s timeout
3. Return session or throw error

**Reconnect Handling:**
- Detects USB disconnect via `session.isConnected` check
- Invalidates session on hard failure (write/read errors)
- Automatically reconnects on next `getSession()` call
- Queries state on reconnect to establish authoritative state

### 4.3 DeviceManagerCommandHelper

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

## 5. PicoSession Layer (Serial Communication)

### Component: PicoSession

**Location:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift`

**Architecture:**
- Wraps `SerialPort` for USB CDC communication
- Implements binary protocol (BlazeTransport)
- Event-driven state machine
- Session identity tracking (UUID-based)

### 5.1 Connection Lifecycle

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

### 5.2 Binary Protocol

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

### 5.3 Command Execution

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

### 5.4 Event Processing

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

## 6. Serial Port Layer

### Component: SerialPort

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

## 7. Firmware Layer

### Component: main.c (C Firmware)

**Location:** `/Users/mdanylchuk/pico/blaze-pico/main.c`

**Architecture:**
- Raspberry Pi Pico firmware (RP2040)
- USB CDC serial interface
- Dual-mode protocol (text + binary)
- Production-grade lifecycle management

### 7.1 Boot Sequence

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

### 7.2 Command Processing Loop

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

### 7.3 Command Execution

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

### 7.4 State Management

**State Sequence:**
- Monotonic counter: `state_sequence` (increments on every command)
- Included in STATE and STATE_CHANGE messages
- Host uses this to detect stale state updates

**Session UUID:**
- Generated on every session start (boot or reconnect)
- Format: `timestamp(high 20 bits) | counter(low 12 bits)`
- Ensures uniqueness even on rapid reconnects
- Host uses this to detect device reboots

### 7.5 Logging Architecture (Production-Ready)

**Batched Logging:**
- Accumulates messages in `log_buffer[512]`
- Flushes when buffer fills or explicitly
- Reduces USB CDC fragmentation

**Log Levels:**
- `PROTOCOL_LOG()` - Critical messages (always flushed immediately)
- `TELEMETRY_LOG()` - Telemetry data (batched, can disable)
- `DEBUG_LOG()` - Debug info (batched, disabled by default)
- `USB_LOG()`, `BOOT_LOG()`, `SESSION_LOG()`, `READY_LOG()` - Lifecycle logs (batched)

**Compile-Time Controls:**
- `ENABLE_DEBUG_LOGS=0` - Disable verbose debug logs
- `ENABLE_TELEMETRY_LOGS=1` - Enable telemetry
- `ENABLE_USB_LIFECYCLE_LOGS=1` - Enable lifecycle logs

---

## 8. Hardware Layer

### Component: GPIO  LEDs

**GPIO Mapping:**
- RED  GPIO 14
- GREEN  GPIO 15
- YELLOW  GPIO 16
- BLUE  GPIO 17
- MULTI_RED  GPIO 18
- MULTI_GREEN  GPIO 19
- MULTI_BLUE  GPIO 20
- FEEDBACK  GPIO 19 (photodiode/loopback)

**Physical Control:**
- `gpio_put(pin, 1)`  LED ON
- `gpio_put(pin, 0)`  LED OFF
- State stored in `led_state[]` array for query

---

## 9. Complete End-to-End Flow Example

### Example: "Turn green light on"

**Stage 1: Voice Input (VoiceAgentController)**
```
User speaks: "Turn green light on"
    
SFSpeechRecognizer captures audio
    
Partial transcript: "Turn green" (isPartial: true)
    
KeywordFastPath.match("Turn green")  .greenOn (confidence: 0.82)
    
Intent locked: Prepare command packet (non-blocking)
    
Final transcript: "Turn green light on" (isPartial: false)
    
KeywordFastPath.match("Turn green light on")  .greenOn (confidence: 0.88)
    
Immediate action extracted: Execute via fast-path
```

**Stage 2: Fast-Path Execution (VoiceAgentController)**
```
executeFastPath(action: .greenOn, originalText: "Turn green light on")
    
Optimistic UI update: " Green light on"
    
executeFastPathAsync()  calls AgentDaemonClient
```

**Stage 3: Daemon Request (AgentDaemonClient)**
```
AgentDaemonClient.planWork(workspacePath, goal: "Turn green light on")
    
Encode PlanWorkRequest via BlazeBinary
    
Send via Unix socket (/tmp/blaze_agent.sock)
    
Frame: [length(4)] + [BlazeBinary payload]
```

**Stage 4: Daemon Routing (AgentDaemon)**
```
AgentRequestRouter receives request
    
IntentRouter.route("Turn green light on")
    
Match: .deterministic(.light(color: .green, state: .on), confidence: 0.95)
    
ToolExecutor.execute(.light(color: .green, state: .on))
    
Check duplicate (coalesce if found)
    
Check queue depth (reject if full)
    
Enqueue on hardware execution queue
```

**Stage 5: Tool Execution (PicoLEDTool)**
```
PicoLEDTool.invoke(arguments: ["color": "GREEN", "state": "ON"])
    
DeviceManagerCommandHelper.sendCommand("GREEN ON")
    
Parse: commandID = .green, value = 1
    
DeviceManager.shared.getSession()
    
Returns persistent session (fast path)
```

**Stage 6: Command Sending (PicoSession)**
```
session.sendCommandWithCompletion(commandID: .green, value: 1)
    
Generate trace ID: 1234567890123456
    
Build binary packet:
   [BLAZ] + [header(16)] + [frameType(1)][traceID(8)][commandID(1)][value(1)]
    
Write to serial port (non-blocking)
    
Wait for ACK event (500ms timeout)
    
ACK received: "ACK TRACE:1234567890123456 cmdID=2 value=1"
    
Wait for STATE_CHANGE event (1500ms timeout)
    
STATE_CHANGE received: "STATE_CHANGE: trace=1234567890123456 seq=42 R=0 G=1 Y=0 B=0 MR=0 MG=0 MB=0"
    
Parse state: {"R": false, "G": true, "Y": false, "B": false, "MR": false, "MG": false, "MB": false}
    
Return: (success: true, state: {...})
```

**Stage 7: USB Transmission**
```
SerialPort.write(packet)
    
USB CDC frame scheduling (~1ms per frame)
    
Firmware receives packet
```

**Stage 8: Firmware Execution**
```
Firmware detects "BLAZ" magic
    
Switches to binary mode
    
Parses header (16 bytes)
    
Parses payload: traceID=1234567890123456, commandID=2, value=1
    
exec_binary_with_trace(traceID, CMD_GREEN, 1)
    
execute_command(CMD_GREEN, 1)
    
set_led_state(1, true)  // GREEN = index 1
    
gpio_put(GREEN_PIN, 1)  // Physical GPIO write
    
state_sequence++  // Increment to 42
    
emit_ack(traceID, CMD_GREEN, 1)
    
PROTOCOL_LOG("ACK TRACE:1234567890123456 cmdID=2 value=1")
    
emit_state_change(traceID)
    
PROTOCOL_LOG("STATE_CHANGE: trace=1234567890123456 seq=42 R=0 G=1 Y=0 B=0 MR=0 MG=0 MB=0")
```

**Stage 9: Response Path**
```
PicoSession event reader receives ACK
    
Emits .ack event via PassthroughSubject
    
sendCommandWithCompletion() receives ACK
    
PicoSession event reader receives STATE_CHANGE
    
Emits state update (via event stream)
    
sendCommandWithCompletion() receives STATE_CHANGE
    
Returns (success: true, state: {...})
    
PicoLEDTool returns success
    
IntentRouter returns ToolExecutionResult.success
    
AgentRequestRouter formats response
    
Sends PlanWorkResponse via Unix socket
```

**Stage 10: UI Update (VoiceAgentController)**
```
AgentDaemonClient receives response
    
Parses STATE_CHANGE from response message
    
VoiceDaemonBridge.updateDeviceStateFromResponse()
    
StateAuthorityManager.updateStateFromEvent()
    
Event deduplication check (500ms window)
    
State deduplication check (100ms window)
    
Apply state update
    
Update authoritativeState (published)
    
VoiceDaemonBridge.deviceState updated (via Combine)
    
UI updates automatically
    
Optimistic message updated: " Green light on"
```

**Total Latency Breakdown:**
- Voice recognition: ~500-1000ms (varies)
- KeywordFastPath matching: <5ms
- Daemon routing: <5ms
- Tool execution: ~10ms
- Serial write: ~1-5ms
- USB CDC transmission: ~10-20ms
- Firmware execution: <1ms
- ACK response: ~50-100ms (USB scheduling)
- STATE_CHANGE: ~50-100ms (USB scheduling)
- Response parsing: ~5ms
- UI update: <1ms
- **Total: ~200-300ms** (excluding voice recognition)

---

## 10. Agent Capabilities

### 10.1 LLM Planner

**Purpose:** Generate multi-step plans for complex commands

**Capabilities:**
- Natural language understanding
- Context awareness (workspace state, file contents)
- Tool selection and orchestration
- Error recovery planning
- Multi-step execution

**Example:**
```
User: "Make the lights blink red and green alternately"
    
LLM generates plan:
    1. Turn red light on
    2. Wait 500ms
    3. Turn red light off
    4. Turn green light on
    5. Wait 500ms
    6. Turn green light off
    7. Repeat 5 times
    
Execute plan steps sequentially
```

### 10.2 Autonomous Mode

**Purpose:** Background task execution without user interaction

**Features:**
- Periodic workspace scanning
- Automatic error detection
- Fix pipeline execution
- Approval gates (if configured)
- Operational memory tracking

**Use Cases:**
- Continuous code quality monitoring
- Automatic bug fixes
- Dependency updates
- Code refactoring

### 10.3 Fix Pipeline

**Purpose:** Automated error recovery

**Flow:**
1. Detect error (compilation, runtime, test failure)
2. Analyze error context (file, line, error message)
3. Generate fix plan (using LLM)
4. Execute fix (apply patches)
5. Verify fix (compile, test)
6. Record to failure memory

**Failure Memory:**
- Persistent fix history
- Pattern recognition
- Avoid repeating failed fixes
- Learn from successful fixes

### 10.4 Operational Memory

**Purpose:** Track system behavior and performance

**Metrics:**
- Command latency (P50, P99)
- Success rates
- Error patterns
- Tool usage statistics
- Workspace health

**Use Cases:**
- Performance optimization
- Error pattern detection
- Capacity planning
- Quality metrics

---

## 11. Critical Invariants

### 11.1 Session Lifecycle Order

**MUST ALWAYS BE:**
1. `SESSION:<uuid>`
2. `STATE: seq=... R=... G=...`
3. `BLAZE_READY`

**Why:** Host session correlation depends on this exact sequence. Breaking it causes:
- Session tracking failures
- Stale state correlation
- Ghost ACK problems
- Sequence desynchronization

### 11.2 Readiness Gates

**Firmware:**
- `session_active && accept_commands && stdio_usb_connected()`

**Host:**
- `isConnected && isReady`

**Why:** Commands must never execute before device is ready. This prevents:
- Commands sent before USB enumeration
- Commands during boot sequence
- Commands after disconnect

### 11.3 Command Confirmation

**Every command MUST:**
1. Emit ACK (confirms execution)
2. Emit STATE_CHANGE (confirms state update)

**Host MUST:**
- Wait for ACK before considering command successful
- Use STATE_CHANGE for state updates (not queryState)
- Handle timeouts gracefully (return nil, don't throw)

**Why:** USB CDC can silently drop writes. ACK confirms execution. STATE_CHANGE provides causal state.

### 11.4 Session Identity

**Firmware:**
- New UUID on every session start (boot or reconnect)
- Never reuse previous UUID

**Host:**
- Track `currentSessionID`
- Invalidate pending commands on session change
- Reset sequence tracking on session change

**Why:** Prevents ghost ACKs from previous sessions. Epoch-based identity ensures clean state.

### 11.5 State Authority

**Hardware is the source of truth:**
- UI state mirrors hardware state
- STATE_CHANGE events update UI
- Reconnect recovery queries hardware state
- Never replay UI state to hardware

**Why:** Prevents state desynchronization after reconnects or reboots.

---

## 12. Error Handling & Recovery

### 12.1 USB Disconnect

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

**VoiceAgentController:**
- Detects daemon disconnect
- Enters recovery mode (state = unknown)
- Attempts reconnection
- Recovers state after first command

### 12.2 Timeout Handling

**Command Timeouts:**
- ACK timeout: 500ms (fast failure detection)
- STATE_CHANGE timeout: 1500ms (allows USB hiccups)
- Returns `success = false`, `state = nil` (doesn't throw)

**Connection Timeouts:**
- `warmStart()` timeout: 5s (allows boot time)
- `connect()` timeout: 5s (allows USB enumeration)
- Throws error if timeout (device not available)

**Daemon Request Timeouts:**
- `planWork()` timeout: 150s (allows for long-running plans)
- Streaming events during execution
- Graceful timeout handling

### 12.3 Retry Logic

**Transport Verification:**
- QUERY_STATE probe retries: 3 attempts
- 200ms delay between retries

**Reconnection:**
- Automatic on next `getSession()` call
- No fixed retry limit (relies on user retry)

**Daemon Connection:**
- Max 3 retries with exponential backoff
- Initial delay: 0.5s
- Max backoff: 2.0s

---

## 13. Performance Characteristics

### 13.1 Latency Breakdown

**Typical Command Latency (Fast-Path):**
- Voice recognition: ~500-1000ms (varies)
- KeywordFastPath matching: <5ms
- IntentRouter matching: <5ms
- Tool execution: ~10ms
- Serial write: ~1-5ms
- USB CDC transmission: ~10-20ms
- Firmware execution: <1ms
- ACK response: ~50-100ms (USB scheduling)
- STATE_CHANGE: ~50-100ms (USB scheduling)
- **Total: ~200-300ms** (excluding voice recognition)

**LLM Planner Path:**
- Voice recognition: ~500-1000ms
- LLM processing: ~150-500ms (varies by model)
- Plan generation: ~1-5s
- Plan execution: ~200-300ms per step
- **Total: ~2-10s** (depending on plan complexity)

### 13.2 Throughput

**Single Command:**
- ~5-10 commands/second (limited by ACK wait)

**Batch Commands:**
- Up to 8 commands batched
- ~20-30 commands/second (with batching)

**Limitations:**
- USB CDC frame scheduling (~1ms per frame)
- ACK wait time (500ms timeout)
- Host pacing (no backpressure currently)

### 13.3 Benchmark Results

**From `docs/BENCHMARK_RESULTS_DETAILED.md`:**
- P50 ACK latency: ~79ms
- P50 total latency: ~158ms
- P99 latency: ~2.2s (USB spikes)
- Zero write errors (after fixes)
- Session survives reconnects
- Batch failure at ~21 commands (backpressure needed)

---

## 14. Agent Capabilities Deep Dive

### 14.1 Multi-Tier Routing

**Tier 0: KeywordFastPath (VoiceAgentController)**
- Keyword matching: <5ms
- Confidence: 0.82-0.95
- Bypasses daemon entirely

**Tier 1: IntentRouter (AgentDaemon)**
- Regex matching: <5ms
- Confidence: ≥0.95  deterministic execution
- Bypasses LLM planner

**Tier 2: LLM Planner (AgentDaemon)**
- Full natural language understanding
- Multi-step plan generation
- Tool orchestration
- Error recovery

**Routing Decision:**
```
KeywordFastPath.match()  matched?  Execute immediately
     no match
IntentRouter.route()  confidence ≥0.95?  Execute deterministically
     confidence <0.95
LLM Planner  Generate plan  Execute plan
```

### 14.2 Progressive Execution

**Phase A: Immediate Action Extraction**
- Extract high-confidence action from transcript
- Execute immediately (don't wait for full plan)
- Update UI optimistically

**Phase B: Background Planning**
- Generate full plan in background
- Execute remaining steps
- Update UI with plan progress

**Benefits:**
- Perceived latency: ~200ms (immediate action)
- Actual latency: ~2-10s (full plan)
- Better user experience (instant feedback)

### 14.3 State Authority Model

**Hardware is Source of Truth:**
- UI state mirrors hardware state
- STATE_CHANGE events update UI
- Reconnect recovery queries hardware
- Never replay UI state to hardware

**StateAuthorityManager:**
- Single source of truth for device state
- Deduplication (prevents UI spam)
- Reconnect recovery (marks unknown on disconnect)
- State caching (survives reconnects)

### 14.4 Telemetry & Observability

**Trace IDs:**
- 64-bit identifier follows command through entire pipeline
- Generated in Swift tool
- Embedded in binary payload
- Logged at every stage
- Correlated across host and firmware logs

**Structured Logging:**
- OSLog integration (macOS)
- Structured JSONL logging
- Unified Logging framework
- Signpost instrumentation

**Metrics:**
- Command latency (P50, P99)
- Success rates
- Error patterns
- Tool usage statistics

---

## 15. Known Limitations & Future Improvements

### 15.1 Current Limitations

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

4. **LLM Latency:**
   - Full planner takes 2-10s
   - Solution: Progressive execution already implemented

### 15.2 Future Improvements

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

5. **BlazeFSM Integration:**
   - Formal state machine for agent workflows
   - Better error recovery
   - Workflow orchestration

---

## 16. Testing & Validation

### 16.1 Test Scenarios

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

**Agent Tests:**
-  Fast-path routing (keyword matching)
-  IntentRouter routing (regex matching)
-  LLM planner (complex commands)
-  Progressive execution (immediate + background)
-  State authority (reconnect recovery)

### 16.2 Benchmark Results

**From `docs/BENCHMARK_RESULTS_DETAILED.md`:**
- P50 ACK latency: ~79ms
- P50 total latency: ~158ms
- P99 latency: ~2.2s (USB spikes)
- Zero write errors (after fixes)
- Session survives reconnects
- Batch failure at ~21 commands (backpressure needed)

---

## 17. Conclusion

This pipeline implements a **production-grade distributed control runtime** with:

 **Multi-tier routing** (keyword  regex  LLM)  
 **Progressive execution** (immediate actions + background planning)  
 **Deterministic lifecycle management**  
 **Epoch-based session identity**  
 **Causal command confirmation**  
 **Robust error handling**  
 **Automatic reconnection**  
 **State authority model**  
 **Full observability**  

The system is **architecturally sound** and ready for production use. Remaining work is primarily **operational improvements** (backpressure, telemetry, optimization) rather than architectural fixes.

**This is not a hobby project. This is a production-grade device control runtime.**

---

## Appendix: Key Files Reference

**VoiceAgentController:**
- `VoiceAgentController/VoiceDaemonBridge.swift` - Bridge to daemon
- `VoiceAgentController/ProgressiveExecutionCoordinator.swift` - Progressive execution
- `VoiceAgentController/AssistantPhaseMachine.swift` - UI state machine
- `VoiceAgentController/StateAuthorityManager.swift` - State authority
- `VoiceAgentController/KeywordFastPath.swift` - Tier 0 router
- `VoiceAgentController/UnixDomainSocketClient.swift` - Socket client

**AgentDaemonClient:**
- `AgentDaemonClient/Sources/AgentDaemonClient/Client.swift` - Client library

**AgentDaemon:**
- `AgentDaemon/Sources/AgentDaemon/AgentDaemonMain.swift` - Daemon entry point
- `AgentDaemon/Sources/AgentDaemon/Core/IntentRouter.swift` - Fast-path routing
- `AgentDaemon/Sources/AgentDaemon/Tools/Hardware/PicoLEDTool.swift` - Hardware tool

**DeviceManager:**
- `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManager.swift` - Session management
- `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift` - Serial communication
- `PicoLEDControlSwift/Sources/PicoLEDControlLib/SerialPort.swift` - Low-level I/O

**Firmware:**
- `main.c` - Pico firmware (C)

**Documentation:**
- `docs/SYSTEM_ARCHITECTURE.md` - **Architectural deep-dive with design decisions, tradeoffs, and function call boundaries**
- `docs/PIPELINE_AUDIT.md` - Previous pipeline audit
- `docs/PRODUCTION_RULES.md` - Critical rules
- `docs/HARDWARE_RUNTIME_ARCHITECTURE.md` - Architecture overview
- `docs/FIRMWARE_REVIEW_FIXES.md` - Recent firmware improvements

---

## Function Call Boundary Map

### Boundary 1: VoiceAgentController  AgentDaemonClient

**Call Site:** `VoiceDaemonBridge.swift:680`
```swift
let response = try await client.planWork(
    workspacePath: workspace,
    goal: cleaned,
    model: modelName,
    eventHandler: { event in ... }
)
```

**Implementation:** `AgentDaemonClient/Client.swift:234`
```swift
public func planWork(
    workspacePath: String,
    goal: String,
    model: String? = nil,
    eventHandler: ((BlazeShared.ExecutionEvent) -> Void)? = nil
) async throws -> PlanWorkResponse
```

**Protocol:** BlazeBinary over Unix socket (`/tmp/blaze_agent.sock`)

---

### Boundary 2: AgentDaemonClient  AgentDaemon (Unix Socket)

**Call Site:** `AgentDaemonClient/Client.swift:260`
```swift
let encoded = try Codec.encode(agentRequest)
try await connection.send(encoded)
```

**Receive Site:** `AgentDaemon/Sources/AgentDaemon/Core/DaemonServer.swift` (socket accept loop)

**Protocol:** BlazeBinary frame: `[length(4)] + [payload]`

---

### Boundary 3: AgentRequestRouter  IntentRouter

**Call Site:** `AgentDaemon/Sources/AgentDaemon/Core/AgentRequestRouter.swift`
```swift
let decision = IntentRouter.route(text: request.goal)
switch decision {
case .deterministic(let action, let confidence):
    // Execute fast-path
case .plannerRequired:
    // Call LLM planner
}
```

**Implementation:** `AgentDaemon/Sources/AgentDaemon/Core/IntentRouter.swift:85`
```swift
public static func route(_ text: String) -> RouteDecision
```

**Protocol:** In-process function call (no serialization)

---

### Boundary 4: IntentRouter  ToolExecutor

**Call Site:** `AgentDaemon/Sources/AgentDaemon/Core/IntentRouter.swift:456`
```swift
let result = try await executor.execute(action)
```

**Implementation:** `AgentDaemon/Sources/AgentDaemon/Core/IntentRouter.swift:456`
```swift
public func execute(_ action: IntentRouter.ToolAction) async throws -> ToolExecutionResult
```

**Protocol:** In-process async function call

---

### Boundary 5: ToolExecutor  DeviceManager

**Call Site:** `AgentDaemon/Sources/AgentDaemon/Core/IntentRouter.swift:525`
```swift
let session = try await deviceManager.getSession()
```

**Implementation:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManager.swift:200`
```swift
public func getSession() async throws -> PicoSession
```

**Protocol:** Swift actor (concurrency-safe)

---

### Boundary 6: DeviceManager  PicoSession

**Call Site:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManager.swift:110`
```swift
try await session.connect(timeoutMs: 5000)
```

**Implementation:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift:143`
```swift
public func connect(timeoutMs: Int = 2000) async throws
```

**Protocol:** Swift class method (async/await)

---

### Boundary 7: PicoSession  SerialPort

**Call Site:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift:850`
```swift
try serialPort.write(data: packet)
```

**Implementation:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/SerialPort.swift:120`
```swift
public func write(_ data: Data) throws
```

**Protocol:** File descriptor I/O (POSIX)

---

### Boundary 8: SerialPort  USB CDC (Kernel)

**Call Site:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/SerialPort.swift:125`
```swift
let bytesWritten = write(fd, buffer.baseAddress, data.count)
```

**System Call:** `write(fd, buffer, length)`  `ssize_t`

**Protocol:** USB CDC serial (kernel driver)

---

### Boundary 9: USB CDC  Firmware (Hardware)

**Receive Site:** `main.c:950` (firmware main loop)
```c
int c = getchar_timeout_us(1000);
```

**Protocol:** USB CDC serial (text + binary)

---

### Boundary 10: Firmware  GPIO (Hardware)

**Call Site:** `main.c:650` (exec_binary_with_trace)
```c
gpio_put(GREEN_PIN, value);
```

**Hardware:** RP2040 GPIO controller (direct register write)

---

## Complete Call Chain Example

**Command:** "Turn green light on"

```
1. VoiceAgentController.sendVoiceCommand("Turn green light on")
   
2. KeywordFastPath.match("Turn green light on")
    .matched(.greenOn, confidence: 0.88)
   
3. VoiceDaemonBridge.executeFastPathAsync(action: .greenOn)
   
4. AgentDaemonClient.planWork(workspacePath, goal: "Turn green light on")
   
5. Unix Socket: send BlazeBinary frame
   
6. AgentDaemon.DaemonServer.acceptLoop() receives frame
   
7. AgentRequestRouter.handleRequest() decodes PlanWorkRequest
   
8. IntentRouter.route("Turn green light on")
    .deterministic(.light(color: .green, state: .on), confidence: 0.95)
   
9. ToolExecutor.execute(.light(color: .green, state: .on))
   
10. DeviceManager.getSession()
     Returns persistentSession
    
11. PicoSession.sendCommand(commandID: .green, value: 1, traceID: 1234567890123456)
    
12. SerialPort.write(packet: Data)
    
13. write(fd, buffer, length) [POSIX system call]
    
14. USB CDC kernel driver transmits frame
    
15. Firmware.getchar_timeout_us() receives bytes
    
16. Firmware.parse_binary_packet() extracts commandID=2, value=1
    
17. Firmware.exec_binary_with_trace(traceID, CMD_GREEN, 1)
    
18. Firmware.execute_command(CMD_GREEN, 1)
    
19. Firmware.gpio_put(GREEN_PIN, 1) [Hardware register write]
    
20. GPIO hardware: LED turns on
    
21. Firmware.emit_ack(traceID, CMD_GREEN, 1)
     printf("ACK TRACE:1234567890123456 cmdID=2 value=1\n")
    
22. Firmware.emit_state_change(traceID)
     printf("STATE_CHANGE: trace=1234567890123456 seq=42 R=0 G=1 Y=0 B=0 ...\n")
    
23. USB CDC: ACK frame transmitted
    
24. PicoSession.eventReader receives "ACK TRACE:..."
    
25. PicoSession.events.send(.ack(AckEvent(...)))
    
26. DeviceManager.allEvents.send((deviceID, .ack(...)))
    
27. VoiceDaemonBridge receives ACK event
    
28. StateAuthorityManager.updateStateFromEvent({"G": true})
    
29. UI updates: Green LED indicator turns on
```

**Total Function Calls:** ~29 function calls across 7 layers

**Total Latency:** ~200-300ms (excluding voice recognition)
