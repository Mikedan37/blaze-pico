# System Architecture: Design Decisions, Tradeoffs & Layer Boundaries

## Executive Summary

This document provides **architectural deep-dive** into the Blaze Pico control system, explaining:
- **Why** each component is designed the way it is
- **Tradeoffs** made at each architectural boundary
- **Function call boundaries** between layers
- **Design rationale** for key decisions
- **Interface contracts** and protocol boundaries

**This is not just "what" the system does—it's "why" it works this way.**

---

## Table of Contents

1. [Architectural Principles](#architectural-principles)
2. [Layer-by-Layer Architecture](#layer-by-layer-architecture)
3. [Function Call Boundaries](#function-call-boundaries)
4. [Design Tradeoffs](#design-tradeoffs)
5. [Protocol Contracts](#protocol-contracts)
6. [Concurrency Model](#concurrency-model)
7. [State Management Strategy](#state-management-strategy)
8. [Error Handling Philosophy](#error-handling-philosophy)

---

## Architectural Principles

### Principle 1: Hardware is the Source of Truth

**Decision:** All state originates from hardware, UI mirrors hardware state.

**Rationale:**
- Hardware state can diverge from UI state after:
  - Device reboot (UI doesn't know)
  - USB disconnect/reconnect (state lost)
  - Firmware crash (state reset)
  - Manual GPIO manipulation (bypasses UI)

**Tradeoff:**
-  **Pro:** Prevents state desynchronization
-  **Pro:** Survives all failure modes
-  **Con:** Requires state queries (adds latency)
-  **Con:** More complex state reconciliation

**Implementation:**
- STATE_CHANGE events are authoritative
- UI state updates only from hardware events
- Reconnect recovery queries hardware state
- Never replay UI state to hardware

### Principle 2: Progressive Execution

**Decision:** Execute immediate actions while planning remaining steps in background.

**Rationale:**
- User perceives latency as time-to-first-action
- Full LLM planning takes 2-10s
- Most commands have obvious immediate action ("turn green on")

**Tradeoff:**
-  **Pro:** Perceived latency ~200ms (vs 2-10s)
-  **Pro:** Better UX (instant feedback)
-  **Con:** More complex execution model
-  **Con:** Risk of executing wrong action if intent misread

**Implementation:**
- KeywordFastPath extracts immediate action
- Execute immediately if confidence ≥ threshold
- Start background planning for remaining steps
- Optimistic UI updates (correct if wrong)

### Principle 3: Multi-Tier Routing

**Decision:** Three-tier routing: keyword  regex  LLM planner.

**Rationale:**
- 80% of commands are simple ("turn red on")
- LLM overhead unnecessary for deterministic commands
- Latency reduction: <5ms vs ~150ms vs ~5s

**Tradeoff:**
-  **Pro:** Massive latency reduction for common cases
-  **Pro:** Lower LLM costs
-  **Pro:** Better reliability (no LLM failures for simple commands)
-  **Con:** More routing logic to maintain
-  **Con:** Confidence thresholds need tuning

**Implementation:**
- Tier 0: KeywordFastPath (VoiceAgentController) - <5ms
- Tier 1: IntentRouter (AgentDaemon) - <5ms regex
- Tier 2: LLM Planner (AgentDaemon) - ~5s full planning

### Principle 4: Persistent Sessions

**Decision:** Maintain single persistent serial session, never close.

**Rationale:**
- Opening serial port: ~200-500ms overhead
- USB enumeration: ~100-200ms
- CDC stability wait: ~200ms
- Total cold-path cost: ~500-900ms per command

**Tradeoff:**
-  **Pro:** Eliminates cold-path overhead
-  **Pro:** Faster command execution (~10ms vs ~500ms)
-  **Pro:** Better reliability (session health monitoring)
-  **Con:** Resource usage (FD held open)
-  **Con:** More complex lifecycle management

**Implementation:**
- DeviceManager maintains `persistentSession`
- Session opened once at daemon startup
- Reconnects automatically on USB disconnect
- Never closes session (except daemon shutdown)

### Principle 5: Causal Command Confirmation

**Decision:** Every command emits ACK + STATE_CHANGE (two-phase confirmation).

**Rationale:**
- USB CDC can silently drop writes
- ACK confirms execution (packet received)
- STATE_CHANGE confirms state update (GPIO changed)
- Two-phase prevents ghost ACKs

**Tradeoff:**
-  **Pro:** Reliable confirmation (handles USB quirks)
-  **Pro:** Causal state updates (no stale state)
-  **Con:** Two messages per command (more USB traffic)
-  **Con:** More complex event handling

**Implementation:**
- Firmware emits ACK immediately after command execution
- Firmware emits STATE_CHANGE after GPIO update
- Host waits for both before considering command successful
- Sequence numbers prevent stale state application

### Principle 6: Epoch-Based Session Identity

**Decision:** New UUID on every session start (boot or reconnect).

**Rationale:**
- Device reboot invalidates all pending commands
- USB reconnect may lose in-flight commands
- Host needs to detect session changes

**Tradeoff:**
-  **Pro:** Prevents ghost ACKs from previous sessions
-  **Pro:** Clean state reset on reconnect
-  **Con:** UUID generation overhead (minimal)
-  **Con:** More complex session tracking

**Implementation:**
- Firmware generates UUID: `timestamp(high 20 bits) | counter(low 12 bits)`
- Emits `SESSION:<uuid>` on every session start
- Host tracks `currentSessionID`
- Invalidates pending commands on session change

---

## Layer-by-Layer Architecture

### Layer 1: VoiceAgentController (UI Layer)

**Purpose:** User interface, speech recognition, progressive execution.

**Design Decisions:**

#### 1.1 Progressive Execution Coordinator

**Why:** Execute immediate actions while planning in background.

**Function Boundary:**
```swift
// Boundary: VoiceDaemonBridge  ProgressiveExecutionCoordinator
progressiveExecution.extractImmediateAction(from: text, isPartial: Bool) 
     ImmediateAction?

// Boundary: ProgressiveExecutionCoordinator  VoiceDaemonBridge
executeFastPathAsync(action: FastPathAction, originalText: String, preparedPacket: Data?)
     async throws
```

**Tradeoff:**
-  **Pro:** Perceived latency ~200ms (vs 2-10s)
-  **Con:** Risk of wrong action if intent misread
- **Mitigation:** Confidence threshold (≥0.82), optimistic UI correction

#### 1.2 KeywordFastPath (Tier 0 Router)

**Why:** Bypass daemon entirely for simple commands.

**Function Boundary:**
```swift
// Boundary: VoiceDaemonBridge  KeywordFastPath
KeywordFastPath.match(text: String) 
     FastPathResult

// Internal: KeywordFastPath  VoiceDaemonBridge
executeFastPath(action: FastPathAction, originalText: String)
     void
```

**Tradeoff:**
-  **Pro:** <5ms latency (vs ~150ms daemon)
-  **Pro:** No daemon dependency for simple commands
-  **Con:** Duplicate routing logic (also in IntentRouter)
- **Mitigation:** Shared patterns, both use same confidence model

#### 1.3 StateAuthorityManager

**Why:** Single source of truth for device state, reconnect-safe.

**Function Boundary:**
```swift
// Boundary: VoiceDaemonBridge  StateAuthorityManager
stateAuthority.updateStateFromEvent(stateDict: [String: Bool], eventSource: String)
     void

// Boundary: StateAuthorityManager  VoiceDaemonBridge (via Combine)
@Published var authoritativeState: DeviceStateModel
     Published property (reactive)
```

**Tradeoff:**
-  **Pro:** Prevents state desynchronization
-  **Pro:** Reconnect recovery (marks unknown on disconnect)
-  **Con:** More complex state management
- **Mitigation:** Deduplication windows (100ms state, 500ms events)

#### 1.4 AssistantPhaseMachine

**Why:** Single authoritative state machine for UI transitions.

**Function Boundary:**
```swift
// Boundary: VoiceDaemonBridge  AssistantPhaseMachine
phaseMachine.transition(to: AssistantPhase)
     void

// Boundary: AssistantPhaseMachine  UI (via @Published)
@Published var currentPhase: AssistantPhase
     Published property (reactive)
```

**Tradeoff:**
-  **Pro:** Prevents UI race conditions
-  **Pro:** Minimum duration enforcement (success: 800ms, failure: 1.5s)
-  **Con:** More complex state machine
- **Mitigation:** Clear phase definitions, watchdog for WAITING_FOR_DEVICE

---

### Layer 2: AgentDaemonClient (Client Library)

**Purpose:** Client library for daemon communication.

**Design Decisions:**

#### 2.1 Connection Management

**Why:** Single connection reused forever, automatic reconnection.

**Function Boundary:**
```swift
// Boundary: VoiceDaemonBridge  AgentDaemonClient
AgentDaemonClient(socketPath: String, connectionTimeout: TimeInterval)
     AgentDaemonClient

// Internal: AgentDaemonClient  SocketConnection
ensureConnected() 
     async throws
```

**Tradeoff:**
-  **Pro:** Lower connection overhead (reuse single connection)
-  **Pro:** Automatic reconnection (exponential backoff)
-  **Con:** Connection state management complexity
- **Mitigation:** Connection pooling, retry logic with backoff

#### 2.2 Event Streaming

**Why:** Real-time execution events during plan execution.

**Function Boundary:**
```swift
// Boundary: VoiceDaemonBridge  AgentDaemonClient
planWork(workspacePath: String, goal: String, model: String?, 
         eventHandler: ((ExecutionEvent) -> Void)?)
     async throws PlanWorkResponse

// Internal: AgentDaemonClient  VoiceDaemonBridge (via callback)
eventHandler(event: ExecutionEvent)
     void
```

**Tradeoff:**
-  **Pro:** Real-time feedback (user sees progress)
-  **Pro:** Better UX (no "spinner of death")
-  **Con:** More complex response handling (streaming vs single response)
- **Mitigation:** Event handler optional, fallback to single response

---

### Layer 3: AgentDaemon (Server Runtime)

**Purpose:** Request routing, LLM integration, tool execution.

**Design Decisions:**

#### 3.1 IntentRouter (Fast-Path Router)

**Why:** Bypass LLM for deterministic commands (<5ms vs ~150ms).

**Function Boundary:**
```swift
// Boundary: AgentRequestRouter  IntentRouter
IntentRouter.route(text: String) 
     RouteDecision

// Internal: IntentRouter  ToolExecutor
ToolExecutor.execute(action: ToolAction)
     async throws ToolExecutionResult
```

**Tradeoff:**
-  **Pro:** Massive latency reduction (80% of commands)
-  **Pro:** Lower LLM costs
-  **Con:** Duplicate routing logic (also in KeywordFastPath)
- **Mitigation:** Shared patterns, both use same confidence model

#### 3.2 Hardware Execution Queue

**Why:** Serialize hardware access (prevents USB port contention).

**Function Boundary:**
```swift
// Boundary: IntentRouter  ToolExecutor
ToolExecutor.execute(action: ToolAction)
     async throws ToolExecutionResult

// Internal: ToolExecutor  Hardware Execution Queue
hardwareExecutionQueue.async { ... }
     void (serialized execution)
```

**Tradeoff:**
-  **Pro:** Prevents "device busy" errors
-  **Pro:** Guarantees sequential execution
-  **Con:** Queue depth limits (max 10 commands)
-  **Con:** Backpressure needed (rejects if queue full)
- **Mitigation:** Command coalescing (duplicates merged), queue depth monitoring

#### 3.3 Command Coalescing

**Why:** Prevent duplicate commands from rapid user input.

**Function Boundary:**
```swift
// Internal: ToolExecutor  Coalescing Queue
coalesceCommands(action: ToolAction) 
     Bool (true if coalesced)

// Internal: Coalescing Queue  ToolExecutor
pendingCommands.removeAll { actionsEqual($0.action, action) }
     void
```

**Tradeoff:**
-  **Pro:** Prevents "I repeated myself" lag
-  **Pro:** Reduces hardware load
-  **Con:** 100ms window (may coalesce legitimate rapid commands)
- **Mitigation:** Short window (100ms), keep last command

---

### Layer 4: DeviceManager (Session Management)

**Purpose:** Persistent session management, reconnection handling.

**Design Decisions:**

#### 4.1 Persistent Session Architecture

**Why:** Eliminate cold-path overhead (~500-900ms per command).

**Function Boundary:**
```swift
// Boundary: AgentDaemonMain  DeviceManager
DeviceManager.shared.warmStart()
     async throws

// Boundary: PicoLEDTool  DeviceManager
DeviceManager.shared.getSession()
     async throws PicoSession
```

**Tradeoff:**
-  **Pro:** Massive latency reduction (~10ms vs ~500ms)
-  **Pro:** Better reliability (session health monitoring)
-  **Con:** Resource usage (FD held open)
-  **Con:** More complex lifecycle management
- **Mitigation:** Single session per device, automatic reconnection

#### 4.2 Port Path Caching

**Why:** Avoid repeated port scans (expensive: ~100-200ms).

**Function Boundary:**
```swift
// Internal: DeviceManager  Port Scanner
findPicoPorts() 
     [String] (cached for 60s)

// Boundary: DeviceManager  Port Scanner
getPrimaryPortPath()
     async String? (from cache if valid)
```

**Tradeoff:**
-  **Pro:** Faster port lookup (~1ms vs ~100ms)
-  **Pro:** Reduces system calls
-  **Con:** Stale cache if device unplugged/replugged
- **Mitigation:** 60s cache validity, invalidate on disconnect

#### 4.3 Reconnect Recovery

**Why:** Automatic recovery from USB disconnects.

**Function Boundary:**
```swift
// Internal: DeviceManager  PicoSession
handleHardFailure()
     async void

// Internal: DeviceManager  PicoSession
session.connect(timeoutMs: 5000)
     async throws
```

**Tradeoff:**
-  **Pro:** Automatic recovery (no manual intervention)
-  **Pro:** State recovery (queries hardware state on reconnect)
-  **Con:** More complex error handling
- **Mitigation:** Recovery lock (prevents races), state query on reconnect

---

### Layer 5: PicoSession (Serial Communication)

**Purpose:** Binary protocol, event processing, command execution.

**Design Decisions:**

#### 5.1 Binary Protocol (BlazeTransport)

**Why:** Efficient binary protocol vs text (smaller packets, faster parsing).

**Function Boundary:**
```swift
// Boundary: DeviceManager  PicoSession
session.sendCommand(commandID: CommandID, value: UInt8, traceID: UInt64?)
     async throws

// Internal: PicoSession  SerialPort
serialPort.write(packet: Data)
     throws
```

**Tradeoff:**
-  **Pro:** Smaller packets (11 bytes vs ~20 bytes text)
-  **Pro:** Faster parsing (binary vs string parsing)
-  **Con:** Not human-readable (harder debugging)
- **Mitigation:** Text protocol still supported, debug logging includes hex dumps

#### 5.2 Event-Driven Architecture

**Why:** Asynchronous event processing (non-blocking).

**Function Boundary:**
```swift
// Internal: PicoSession  Event Reader Task
startEventReader()
     Task<Void, Never>

// Boundary: PicoSession  DeviceManager (via Combine)
events.send(event: PicoEventType)
     void (reactive)
```

**Tradeoff:**
-  **Pro:** Non-blocking (doesn't block command execution)
-  **Pro:** Reactive (UI updates automatically)
-  **Con:** More complex event handling
- **Mitigation:** PassthroughSubject (Combine), clear event types

#### 5.3 Command Batching

**Why:** Reduce USB frame overhead (batch multiple commands).

**Function Boundary:**
```swift
// Internal: PicoSession  Command Queue
commandQueue.append((commandID, value, traceID))
     void

// Internal: PicoSession  Batch Flush Task
flushCommandQueue()
     void (batches up to 16 commands)
```

**Tradeoff:**
-  **Pro:** Reduces USB overhead (fewer frames)
-  **Pro:** Better throughput (~20-30 commands/s vs ~5-10)
-  **Con:** Batching delay (3ms window)
-  **Con:** More complex queue management
- **Mitigation:** Short batch window (3ms), max batch size (16)

#### 5.4 Session Identity Tracking

**Why:** Detect device reboots (prevent ghost ACKs).

**Function Boundary:**
```swift
// Internal: PicoSession  Event Parser
parseSessionMessage(uuid: UInt32)
     void

// Internal: PicoSession  Pending Commands
invalidatePendingCommands()
     void (on session change)
```

**Tradeoff:**
-  **Pro:** Prevents ghost ACKs from previous sessions
-  **Pro:** Clean state reset on reboot
-  **Con:** More complex session tracking
- **Mitigation:** UUID comparison, sequence reset on session change

---

### Layer 6: SerialPort (Low-Level I/O)

**Purpose:** USB CDC serial communication.

**Design Decisions:**

#### 6.1 Non-Blocking I/O

**Why:** Don't block command execution on slow USB writes.

**Function Boundary:**
```swift
// Boundary: PicoSession  SerialPort
serialPort.write(data: Data)
     throws (non-blocking)

// Internal: SerialPort  File Descriptor
write(fd, buffer, length)
     ssize_t (may return EAGAIN)
```

**Tradeoff:**
-  **Pro:** Non-blocking (doesn't stall command execution)
-  **Pro:** Better concurrency
-  **Con:** EAGAIN handling needed (buffer full)
- **Mitigation:** Retry logic, timeout handling

#### 6.2 Termios Configuration

**Why:** Optimize serial port settings for low latency.

**Function Boundary:**
```swift
// Internal: SerialPort  Termios
configureTermios(baudRate: Int)
     void

// Internal: SerialPort  File Descriptor
tcsetattr(fd, TCSANOW, &termios)
     Int32
```

**Tradeoff:**
-  **Pro:** Low latency (115200 baud, no flow control)
-  **Pro:** Fast transmission (~1ms per frame)
-  **Con:** No hardware flow control (may drop frames)
- **Mitigation:** ACK confirmation, retry logic

---

### Layer 7: Firmware (C Runtime)

**Purpose:** Hardware control, state management, protocol handling.

**Design Decisions:**

#### 7.1 Dual-Mode Protocol

**Why:** Support both text (human-readable) and binary (efficient) protocols.

**Function Boundary:**
```c
// Boundary: Serial Input  Protocol Parser
int c = getchar_timeout_us(1000);
     int (character or PICO_ERROR_TIMEOUT)

// Internal: Firmware  Protocol Detector
if (is_binary_magic(buffer)) {
    parse_binary_packet(buffer);
} else {
    parse_text_command(buffer);
}
```

**Tradeoff:**
-  **Pro:** Human-readable debugging (text mode)
-  **Pro:** Efficient production (binary mode)
-  **Con:** More complex parser (two modes)
- **Mitigation:** Clear mode detection ("BLAZ" magic), separate parsers

#### 7.2 Deterministic Lifecycle

**Why:** Guarantee readiness before command execution.

**Function Boundary:**
```c
// Internal: Firmware  USB Connection Check
while (!stdio_usb_connected()) {
    sleep_ms(50);
}

// Internal: Firmware  Readiness Gates
if (!session_active || !accept_commands || !stdio_usb_connected()) {
    continue;  // Skip command processing
}
```

**Tradeoff:**
-  **Pro:** Prevents commands before device ready
-  **Pro:** Guarantees SESSION  STATE  READY sequence
-  **Con:** Boot delay (200ms CDC stability wait)
- **Mitigation:** Short wait (200ms), event-driven (no fixed delays)

#### 7.3 Batched Logging

**Why:** Reduce USB CDC fragmentation (improve performance).

**Function Boundary:**
```c
// Internal: Firmware  Log Buffer
log_append(fmt, ...)
     void (accumulates in buffer)

// Internal: Firmware  Log Flush
log_flush()
     void (flushes buffer to USB)
```

**Tradeoff:**
-  **Pro:** Reduces USB fragmentation (fewer frames)
-  **Pro:** Better performance (42% fewer fflush() calls)
-  **Con:** Delayed log output (batched)
- **Mitigation:** PROTOCOL_LOG() flushes immediately (critical messages)

#### 7.4 State Sequence Tracking

**Why:** Prevent stale state updates (sequence numbers).

**Function Boundary:**
```c
// Internal: Firmware  State Sequence
state_sequence++;  // Increment on every command

// Internal: Firmware  STATE_CHANGE Emission
printf("STATE_CHANGE: trace=%llu seq=%llu R=%d G=%d ...\n", 
       traceID, state_sequence, ...);
```

**Tradeoff:**
-  **Pro:** Prevents stale state application
-  **Pro:** Causal ordering (sequence numbers)
-  **Con:** Sequence tracking overhead (minimal)
- **Mitigation:** UInt64 counter (never wraps), reset on session start

---

## Function Call Boundaries

### Boundary 1: VoiceAgentController  AgentDaemonClient

**Interface Contract:**
```swift
// Request
AgentDaemonClient.planWork(
    workspacePath: String,
    goal: String,
    model: String?,
    eventHandler: ((ExecutionEvent) -> Void)?
) async throws -> PlanWorkResponse

// Response
struct PlanWorkResponse {
    let requestID: UUID
    let success: Bool
    let message: String
    let plan: Data?
    let error: String?
}
```

**Protocol:** BlazeBinary over Unix socket (`/tmp/blaze_agent.sock`)

**Error Handling:**
- `AgentDaemonClientError.daemonUnavailable`  Retry connection
- `AgentDaemonClientError.timeout`  Show timeout error
- `AgentDaemonClientError.decodeError`  Show decode error

**Tradeoffs:**
-  **Pro:** Type-safe interface (Swift structs)
-  **Pro:** Event streaming (real-time feedback)
-  **Con:** Binary protocol (not human-readable)
- **Mitigation:** Debug logging includes hex dumps

---

### Boundary 2: AgentDaemon  IntentRouter

**Interface Contract:**
```swift
// Request
IntentRouter.route(text: String) -> RouteDecision

// Response
enum RouteDecision {
    case deterministic(ToolAction, confidence: Double)
    case plannerRequired
}
```

**Protocol:** In-process function call (no serialization)

**Error Handling:**
- Always succeeds (returns `.plannerRequired` if no match)

**Tradeoffs:**
-  **Pro:** Zero overhead (in-process call)
-  **Pro:** Type-safe (Swift enums)
-  **Con:** Tight coupling (same process)
- **Mitigation:** Clear interface contract, confidence threshold

---

### Boundary 3: IntentRouter  DeviceManager

**Interface Contract:**
```swift
// Request
DeviceManager.shared.getSession() async throws -> PicoSession

// Response
class PicoSession {
    func sendCommand(commandID: CommandID, value: UInt8, traceID: UInt64?) async throws
    var events: PassthroughSubject<PicoEventType, Never>
}
```

**Protocol:** Swift actor (concurrency-safe)

**Error Handling:**
- `DeviceManagerError.noDevice`  No Pico found
- `DeviceManagerError.timeout`  Connection timeout
- `DeviceManagerError.sessionInvalid`  Session invalidated

**Tradeoffs:**
-  **Pro:** Concurrency-safe (Swift actor)
-  **Pro:** Persistent session (no per-command overhead)
-  **Con:** Actor overhead (minimal)
- **Mitigation:** Single session per device, cached port paths

---

### Boundary 4: PicoSession  SerialPort

**Interface Contract:**
```swift
// Request
serialPort.write(data: Data) throws

// Response
void (throws on error)
```

**Protocol:** File descriptor I/O (POSIX)

**Error Handling:**
- `SerialPortError.writeFailed`  Retry with backoff
- `SerialPortError.deviceDisconnected`  Invalidate session
- `SerialPortError.timeout`  Retry or fail

**Tradeoffs:**
-  **Pro:** Low-level control (termios, non-blocking I/O)
-  **Pro:** Fast (direct FD access)
-  **Con:** Platform-specific (macOS/Linux only)
- **Mitigation:** Abstracted interface, error handling

---

### Boundary 5: SerialPort  Firmware (USB CDC)

**Interface Contract:**
```
// Request (Binary Protocol)
[BLAZ] + [16-byte header] + [payload(11 bytes)]

Header:
- version: UInt8 = 1
- flags: UInt8 = 0
- connectionID: UInt32
- packetNumber: UInt32
- streamID: UInt32
- payloadLength: UInt16

Payload:
- frameType: UInt8 = 0
- traceID: UInt64
- commandID: UInt8
- value: UInt8

// Response (Text Protocol)
"ACK TRACE:<id> cmdID=<id> value=<v>\n"
"STATE_CHANGE: trace=<id> seq=<seq> R=<r> G=<g> Y=<y> B=<b> MR=<mr> MG=<mg> MB=<mb>\n"
```

**Protocol:** USB CDC serial (text + binary)

**Error Handling:**
- USB disconnect  Host detects via `isConnected` check
- Write failure  Retry with backoff
- Read timeout  Retry or fail

**Tradeoffs:**
-  **Pro:** Standard protocol (USB CDC)
-  **Pro:** Dual-mode (text + binary)
-  **Con:** USB quirks (TX stalls, enumeration delays)
- **Mitigation:** ACK confirmation, retry logic, timeout handling

---

### Boundary 6: Firmware  Hardware (GPIO)

**Interface Contract:**
```c
// Request
gpio_put(pin: int, value: bool) -> void

// Response
void (immediate, no confirmation)
```

**Protocol:** GPIO direct control (hardware)

**Error Handling:**
- GPIO write always succeeds (hardware level)
- No error return (hardware doesn't fail)

**Tradeoffs:**
-  **Pro:** Immediate execution (<1μs)
-  **Pro:** No protocol overhead
-  **Con:** No confirmation (relies on ACK/STATE_CHANGE)
- **Mitigation:** GPIO readback for telemetry, ACK confirmation

---

## Design Tradeoffs Summary

### Latency vs Complexity

**Decision:** Multi-tier routing (keyword  regex  LLM)

**Tradeoff:**
-  **Pro:** ~200ms latency (vs ~5s for LLM)
-  **Con:** More routing logic to maintain

**Mitigation:** Shared patterns, clear confidence thresholds

---

### Reliability vs Performance

**Decision:** Persistent sessions (never close)

**Tradeoff:**
-  **Pro:** ~10ms latency (vs ~500ms cold-path)
-  **Con:** Resource usage (FD held open)

**Mitigation:** Single session per device, automatic reconnection

---

### State Authority vs Latency

**Decision:** Hardware is source of truth (query state)

**Tradeoff:**
-  **Pro:** Prevents state desynchronization
-  **Con:** Adds latency (state queries)

**Mitigation:** STATE_CHANGE events (automatic), optimistic updates

---

### Simplicity vs Features

**Decision:** Dual-mode protocol (text + binary)

**Tradeoff:**
-  **Pro:** Human-readable debugging + efficient production
-  **Con:** More complex parser

**Mitigation:** Clear mode detection, separate parsers

---

## Protocol Contracts

### Contract 1: Session Lifecycle

**Invariant:** `SESSION  STATE  BLAZE_READY` (always in this order)

**Violation Impact:**
- Host session correlation fails
- State linked to wrong session
- READY interpreted for previous session

**Enforcement:**
- Firmware: Hard-coded sequence (never changes)
- Host: Parser expects exact sequence

---

### Contract 2: Command Confirmation

**Invariant:** Every command emits `ACK` then `STATE_CHANGE`

**Violation Impact:**
- Host thinks command failed (no ACK)
- Host applies stale state (no STATE_CHANGE)

**Enforcement:**
- Firmware: Always emits both (hard-coded)
- Host: Waits for both before success

---

### Contract 3: Session Identity

**Invariant:** New UUID on every session start

**Violation Impact:**
- Ghost ACKs from previous sessions
- Stale state correlation

**Enforcement:**
- Firmware: UUID generation on every session start
- Host: Invalidates pending commands on session change

---

## Concurrency Model

### Swift Concurrency (async/await)

**Why:** Type-safe concurrency, structured concurrency.

**Tradeoffs:**
-  **Pro:** Compiler-enforced safety
-  **Pro:** Structured concurrency (no leaks)
-  **Con:** Learning curve (Swift 6 strict)
- **Mitigation:** Clear actor boundaries, Sendable types

### Actor Isolation

**Why:** Prevent data races (DeviceManager is actor).

**Tradeoffs:**
-  **Pro:** Compiler-enforced isolation
-  **Pro:** No locks needed
-  **Con:** Actor overhead (minimal)
- **Mitigation:** Single actor per component, clear boundaries

### Serial Queues

**Why:** Hardware access must be sequential (USB port contention).

**Tradeoffs:**
-  **Pro:** Prevents "device busy" errors
-  **Pro:** Guarantees sequential execution
-  **Con:** Queue depth limits
- **Mitigation:** Command coalescing, backpressure handling

---

## State Management Strategy

### Hardware Authority Model

**Why:** Hardware state can diverge from UI state.

**Strategy:**
1. Hardware emits STATE_CHANGE events
2. Host applies state updates
3. UI mirrors hardware state
4. Never replay UI state to hardware

**Tradeoffs:**
-  **Pro:** Prevents desynchronization
-  **Pro:** Survives all failure modes
-  **Con:** Requires state queries (adds latency)
- **Mitigation:** STATE_CHANGE events (automatic), optimistic updates

### State Deduplication

**Why:** Prevent UI spam from rapid state changes.

**Strategy:**
- 100ms window for state deduplication
- 500ms window for event deduplication
- Keep last state after window

**Tradeoffs:**
-  **Pro:** Prevents UI flicker
-  **Pro:** Reduces update overhead
-  **Con:** May delay legitimate rapid updates
- **Mitigation:** Short windows, keep last state

---

## Error Handling Philosophy

### Fail Fast vs Retry

**Strategy:** Fail fast for fatal errors, retry for transient errors.

**Fatal Errors:**
- Device disconnected  Invalidate session
- Permission denied  Show error, don't retry
- Invalid command  Show error, don't retry

**Transient Errors:**
- EAGAIN (buffer full)  Retry with backoff
- Timeout  Retry up to 3 times
- USB stall  Retry with backoff

**Tradeoffs:**
-  **Pro:** Fast failure detection (fatal errors)
-  **Pro:** Automatic recovery (transient errors)
-  **Con:** More complex error classification
- **Mitigation:** Clear error types, retry limits

### Graceful Degradation

**Strategy:** Return partial results, don't throw on timeout.

**Example:** `sendCommandWithCompletion()` returns `(success: false, state: nil)` on timeout.

**Tradeoffs:**
-  **Pro:** System continues operating
-  **Pro:** Better UX (no crashes)
-  **Con:** May hide real errors
- **Mitigation:** Clear error messages, logging

---

## Conclusion

This architecture balances **performance, reliability, and complexity** through:

1. **Multi-tier routing** (latency reduction)
2. **Persistent sessions** (performance)
3. **Hardware authority** (reliability)
4. **Causal confirmation** (correctness)
5. **Epoch-based identity** (safety)

Each design decision has clear tradeoffs, and the system mitigates downsides through:
- Clear interface contracts
- Robust error handling
- Automatic recovery
- State deduplication
- Command coalescing

**This is production-grade architecture, not a hobby project.**
