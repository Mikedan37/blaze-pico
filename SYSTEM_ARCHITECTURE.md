# System Architecture: Full 7-Layer Pipeline Audit

## Executive Summary

The Blaze Pico system is a voice/text-controlled LED hardware controller built across 7 distinct layers spanning a macOS SwiftUI application, a local AI agent daemon, and a Raspberry Pi Pico microcontroller connected via USB CDC serial.

**Pipeline flow:** User speaks or types a command → VoiceAgentController UI → VoiceDaemonBridge (RPC client) → Unix domain socket → DaemonServer → AgentRequestRouter (fast-path / LLM planner / chatbot) → DeviceManager → PicoSession → SerialPort → USB CDC → Pico firmware → GPIO → LEDs.

**State flows back:** Pico GPIO state → `STATE:` text response → SerialPort → PicoSession event reader → DeviceManager → ToolExecutor result → DaemonServer response → AgentDaemonClient → VoiceDaemonBridge → StateAuthorityManager → DeviceStateStore → SwiftUI DevicePanel.

---

## Table of Contents

1. [Layer 1: VoiceAgentController UI](#layer-1-voiceagentcontroller-ui)
2. [Layer 2: VoiceDaemonBridge](#layer-2-voicedaemonbridge)
3. [Layer 3: AgentDaemonClient (RPC)](#layer-3-agentdaemonclient-rpc)
4. [Layer 4: DaemonServer](#layer-4-daemonserver)
5. [Layer 5: Command Routing (IntentRouter + AgentRequestRouter)](#layer-5-command-routing)
6. [Layer 6: Serial Communication (DeviceManager + PicoSession + SerialPort)](#layer-6-serial-communication)
7. [Layer 7: Pico Firmware](#layer-7-pico-firmware)
8. [Cross-Cutting Concerns](#cross-cutting-concerns)
9. [Protocol Contracts](#protocol-contracts)
10. [Known Issues & Dead Code](#known-issues--dead-code)

---

## Layer 1: VoiceAgentController UI

**Technology:** macOS SwiftUI app  
**Entry point:** `VoiceAgentControllerApp.swift` → single `WindowGroup` → `ContentView`  
**SIGPIPE:** Ignored at app init (`signal(SIGPIPE, SIG_IGN)`) to survive socket disconnects.

### Layout

```
VStack
├── HSplitView (3 resizable panels)
│   ├── [LEFT]   DevicePanel     (min:200, ideal:240, max:300)
│   ├── [CENTER] ChatPanel + WaveformView + HeaderView
│   └── [RIGHT]  ConsolePanel    (min:200, ideal:260, max:360)
├── Divider
├── manualInputView  (TextField + Send button)
└── controlsView     (Record button + connection status)
```

**Minimum window:** 900×550

### Voice Input (ASR)

| Component | Technology |
|-----------|------------|
| `VoiceRecognizer` | `SFSpeechRecognizer` + `AVAudioEngine` |
| Partial transcripts | `shouldReportPartialResults = true` |
| Final transcripts | `result.isFinal` → `sendToAgent()` |
| Mic level | RMS → dB conversion from Float32/Int16 audio buffers |
| Error 1110 | "No speech detected" → auto-restart recognition, keep audio running |

### Manual Input

TextField with `onSubmit` → `sendManualCommand()` → `sendToAgent(text, isVoice: false)` → `bridge.sendVoiceCommand()` with selected model.

### State Ownership

| Property | Type | Owner |
|----------|------|-------|
| `bridge` | `@StateObject VoiceDaemonBridge` | ContentView |
| `recognizer` | `@StateObject VoiceRecognizer` | ContentView |
| `autoReadEnabled` | `@State Bool` | ContentView |
| `manualInput` | `@State String` | ContentView |
| `selectedModel` | `@State ModelSize` | ContentView |

### Panels

| Panel | Observes | Purpose |
|-------|----------|---------|
| `DevicePanel` | `bridge.deviceStateStore` | LED state map (5 buttons: R/G/Y/B/Multi), Query State, All Off, Reconnect |
| `ChatPanel` | `bridge.messages` | Chat bubbles (user/assistant), execution events, status messages |
| `ConsolePanel` | `bridge.debugMessages` | Debug/event console log |

### Key Types

- **`ChatMessage`** — `id`, `requestID`, `text`, `isUser`, `isPending`, `modelUsed`, `startTime`, `actualDuration`, `executionPath` (.fastPath/.planner), `isError`, `isStatusMessage`, `isFinalResponse`, `stepNumber`, `isMinimized`
- **`DeviceStateStore`** — `leds: [LEDColor: Bool?]`, `hasValidState`, `lastUpdated`; updated via Combine from `StateAuthorityManager`
- **`LEDColor`** — `.red`, `.yellow`, `.green`, `.blue`, `.white` (display name "Multi", color purple)

---

## Layer 2: VoiceDaemonBridge

**File:** `VoiceDaemonBridge.swift`  
**Type:** `@MainActor final class VoiceDaemonBridge: ObservableObject`  
**Role:** Client-side bridge between SwiftUI UI and the daemon. Manages connection, command sending, state authority, and UI state.

### Connection Lifecycle

```
connect()
├── Guard: not already connected/connecting
├── Create AgentDaemonClient(socketPath: "/tmp/blaze_agent.sock", timeout: 180s)
├── Probe: planWork("query state") with 5s timeout
├── On success: parseAndApplyState(), startPeriodicStateSync(), startHeartbeatWarmLoop()
└── On failure: stateAuthority → .disconnected, schedule reconnect after 1s
```

### Command Paths

| Method | Command Text | Lock | Response Handling |
|--------|-------------|------|-------------------|
| `sendVoiceCommand()` | User text | `acquireCommandLock` | Full event handling, plan execution, state parsing |
| `toggleLED(color:)` | `"red on"` / `"red off"` | `acquireCommandLock` | `parseAndApplyState(from: response.message)` |
| `allOff()` | `"all lights off"` | `acquireCommandLock` | `parseAndApplyState(from: response.message)` |
| `queryState()` | `"query state"` | `acquireCommandLock` | `parseAndApplyState(from: response.message)` |

### Progressive Execution Architecture

```
sendVoiceCommand(text, isPartial:)
├── Partial transcript → extractImmediateAction() → prepare packet (no send)
├── Final transcript:
│   ├── If matches prior partial action → skip (dedup)
│   ├── If new immediate action → executeFastPathAsync() → optimistic UI update
│   │   └── After fast-path: pendingFastPathResult → generateReply() → chat message
│   └── If no immediate action → full planWork() → event handling → plan execution
```

### State Authority Chain

```
daemon response.message
    → parseAndApplyState()
    → updateDeviceStateFromResponse()  // parses "STATE: R=1 G=0 ..."
    → stateAuthority.updateStateFromEvent(stateDict)  // dedup, reconnect handling
    → stateAuthority.$authoritativeState (Combine)
    → Sink: self.deviceState = newState, self.deviceStateStore.updateFromStateChange()
    → DevicePanel re-renders (observes bridge via @ObservedObject)
```

### Background Tasks

| Task | Interval | Purpose |
|------|----------|---------|
| Heartbeat warm loop | 25s | `planWork("query state")` to keep daemon/USB/model warm |
| Periodic state sync | 3s (until valid state) | `queryDeviceState()` until `hasValidDeviceState` |

### Command Lock

- `commandInFlight: Bool` — single boolean, not a semaphore
- `acquireCommandLock()` returns `false` if already held
- `releaseCommandLock()` in `defer` after every command task
- Heartbeat and state sync check `!commandInFlight` before querying

### @Published Properties

| Property | Consumers |
|----------|-----------|
| `isConnected` | ContentView, DevicePanel, input bar disable state |
| `messages: [ChatMessage]` | ChatPanel |
| `deviceState: DeviceStateModel` | (mirror; UI uses deviceStateStore) |
| `hasValidDeviceState` | DevicePanel button enable state |
| `pendingLEDOps: Set<LEDColor>` | DevicePanel spinner overlays |
| `debugMessages: [String]` | ConsolePanel |
| `lastError: String?` | ContentView error display |

---

## Layer 3: AgentDaemonClient (RPC)

**Package:** `AgentDaemonClient` (Swift package)  
**Dependencies:** `BlazeShared`, `BlazeBinary`  
**Transport:** Unix domain socket (`AF_UNIX`, `SOCK_STREAM`)

### Connection

| Aspect | Detail |
|--------|--------|
| Socket path | `/tmp/blaze_agent.sock` (or `AGENTD_SOCKET_PATH`) |
| Connect | Lazy via `ensureConnected()` on first request |
| Retry | Up to 3 attempts, exponential backoff (0.5s → 0.75s → 1.125s, cap 2s) |
| Timeout | `SO_RCVTIMEO` from `connectionTimeout` parameter |
| Reconnect | On error: `connection = nil`, next request retries |

### Frame Protocol

```
┌──────────────────┬───────────────────┐
│ 4 bytes (LE)     │ Payload           │
│ payload length   │ (BlazeBinary)     │
└──────────────────┴───────────────────┘
Max frame: 8 MB
```

### Request Types

| Type | Enum | Payload |
|------|------|---------|
| Plan | `.plan` (3) | `PlanWorkRequest { workspacePath, goal, model? }` |
| Execute | `.executePlan` (2) | `ExecuteWorkPlanRequest { workspacePath, plan: Data }` |
| Generate Reply | `.generateReply` (12) | `GenerateReplyRequest { transcript, toolResult }` |
| Fix Error | `.fixError` (0) | `FixErrorRequest { ... }` |
| Analyze | `.analyze` (1) | `AnalyzeRequest { ... }` |

### planWork() Flow

```
1. Encode PlanWorkRequest → wrap in AgentRequest(type: .plan)
2. Encode AgentRequest → send frame
3. Loop:
   a. Receive frame
   b. Try decode as ExecutionEventResponse → call eventHandler(event), continue
   c. Try decode as PlanWorkResponse → return as final response
   d. Else throw invalidResponse
```

### Event Streaming

Events are interleaved with the final response on the same socket. The client loop distinguishes them by attempting to decode as `ExecutionEventResponse` first, then `PlanWorkResponse`.

Event types: `thinking`, `plannerStarted`, `toolSelected`, `toolRunning`, `toolFinished`, `reasoning`, `completed`, `error`.

---

## Layer 4: DaemonServer

**File:** `DaemonServer.swift`  
**Type:** `public final class DaemonServer: @unchecked Sendable`  
**Role:** BSD Unix socket server. Accepts connections, parses BlazeBinary frames, routes to `AgentRequestRouter`, streams events back.

### Socket Setup

```
socket(AF_UNIX, SOCK_STREAM, 0)
    → setsockopt(SO_REUSEADDR)
    → bind(sockaddr_un("/tmp/blaze_agent.sock"))
    → listen(sock, 10)
    → acceptLoop() [blocking]
```

### Per-Connection Handling

```
accept() → Task { handleConnection(clientSocket) }
├── Optional auth (32-byte token if AGENTD_AUTH=1)
├── Read loop: recv() on ioQueue (concurrent DispatchQueue, not cooperative pool)
├── Parse: 4-byte LE length + payload → BlazeBinaryDecoder → AgentRequest
├── Route: router.routeAndEncode(request, eventEmitter: closure)
├── Events: eventEmitter sends ExecutionEventResponse frames during processing
├── Response: sendResponse(clientSocket, data) via per-socket write queue
└── Cleanup: close(clientSocket), remove write queue
```

### Concurrency

| Mechanism | Detail |
|-----------|--------|
| Max connections | 64 (`DispatchSemaphore`) |
| I/O offload | `ioQueue` (concurrent `DispatchQueue`) for blocking `recv()` |
| Write serialization | Per-socket `DispatchQueue` in `writeQueues` dictionary |
| Partial writes | Retry loop until complete; `EINTR` retried; `EPIPE`/`ECONNRESET` → fail |

### Process Lock

```
open("/tmp/agentdaemon.lock", O_CREAT | O_WRONLY)
flock(fd, LOCK_EX | LOCK_NB)  // non-blocking exclusive
    → Success: write PID, keep fd open for process lifetime
    → Failure: "Another instance running (PID: X)"
OS releases flock on ANY exit (including SIGKILL)
```

### Authentication (Optional)

- Enabled via `AGENTD_AUTH=1`
- Client sends 32-byte token before any frames
- Server validates with constant-time comparison
- Invalid token → connection closed

---

## Layer 5: Command Routing

**Files:** `AgentRequestRouter.swift`, `IntentRouter.swift`  
**Role:** Central decision point. Routes commands to fast-path hardware execution, LLM planner, or conversational chatbot.

### Architecture: Three-Tier Routing

```
User command arrives
    │
    ▼
┌─────────────────────────────────┐
│  Tier 0: IntentRouter           │  < 5ms
│  Keyword/regex matching         │
│  Confidence ≥ 0.95 → execute    │
└──────────┬──────────────────────┘
           │ .plannerRequired
           ▼
┌─────────────────────────────────┐
│  Tier 1: LLM Planner           │  5-30s
│  runtime.run(goal:)             │
│  Ollama qwen2.5-coder:7b       │
└──────────┬──────────────────────┘
           │ throws (empty plan, decode error)
           ▼
┌─────────────────────────────────┐
│  Fallback A: Fast-path retry    │  < 5ms
│  Re-check IntentRouter for      │
│  light commands                 │
└──────────┬──────────────────────┘
           │ no match
           ▼
┌─────────────────────────────────┐
│  Fallback B: Chatbot            │  1-5s
│  OllamaProvider.chat()          │
│  Conversational LLM reply       │
│  Chat history (max 20 messages) │
└──────────┬──────────────────────┘
           │ fails
           ▼
┌─────────────────────────────────┐
│  Last Resort: Error response    │
│  PlanWorkResponse(success:false)│
└─────────────────────────────────┘
```

### IntentRouter — Fast-Path Patterns

| Pattern | Action | Confidence |
|---------|--------|------------|
| Pronouns (it, them, that, same...) | `.plannerRequired` | — |
| `query`/`what`/`check` + `state`/`lights` | `.queryState` | 0.95 |
| Color + on/off/toggle | `.light(color, state)` | 0.95-0.98 |
| `all` + `off` | `.lightOff` | 1.0 |
| `orange` | `.mixColor([.multiRed: on, .multiGreen: on])` | 0.98 |
| `purple`/`violet` | `.mixColor([.multiRed: on, .multiBlue: on])` | 0.98 |
| `cyan`/`teal`/`aqua` | `.mixColor([.multiGreen: on, .multiBlue: on])` | 0.98 |
| `pink`/`magenta` | `.mixColor([.multiRed: on, .multiBlue: on])` | 0.98 |
| Blink + duration | `.blink(color, seconds)` | 0.95 |
| `turn on` (no color) | `.smartToggleOn` | 0.85 |
| `bootloader`/`flash firmware` | `.enterBootloader` | 0.98 |
| Everything else | `.plannerRequired` | — |

### LLM Planner Path

```
handlePlanWork(request)
├── IntentRouter.route(goal) → if .deterministic → fast-path execution
├── Status commands ("status", "agent status") → immediate version response
├── getOrCreateRuntime(workspacePath)
├── runtime.run(goal: enhancedGoal)  [120s timeout]
│   ├── AgentStrategy.generatePlan() → Ollama structured JSON output
│   │   └── Prompt: "Goal: X. Create 1-3 step plan. Return JSON: {steps: [...]}"
│   ├── Plan refinement (skip for simple goals)
│   └── FSM execution loop
├── PlanExecutor.execute(plan, runtime) → step-by-step with event streaming
└── Build PlanWorkResponse with execution results
```

### ToolExecutor

| Aspect | Detail |
|--------|--------|
| Execution | `hardwareExecutionQueue` (serial DispatchQueue) |
| Coalescing | Duplicate commands within 100ms pruned |
| Backpressure | Max 100 queued ops; rejects beyond |
| Hardware | `DeviceManagerCommandHelper.sendCommand()` → DeviceManager → PicoSession |

### LLM Integration

| Component | Endpoint | Purpose |
|-----------|----------|---------|
| `OllamaProvider.generate()` | `POST /api/generate` | JSON-structured plan generation |
| `OllamaProvider.generateText()` | `POST /api/generate` | Free-form text (no JSON constraint) |
| `OllamaProvider.chat()` | `POST /api/chat` | Conversational chatbot with history |
| `OllamaProvider.healthCheck()` | `GET /api/tags` | Verify Ollama is running |
| `OllamaProvider.prewarmModel()` | `POST /api/generate` (1 token) | Load model into GPU memory |

**Model:** `qwen2.5-coder:7b` (default, via `OLLAMA_MODEL` env)  
**Options:** `stream: false`, `keep_alive: "5m"`, `format: "json"` for structured output  
**Limits:** 2 MB max response, 180s request timeout

---

## Layer 6: Serial Communication

**Files:** `DeviceManager.swift`, `PicoSession.swift`, `SerialPort.swift`, `PicoLEDController.swift`  
**Location:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/`

### DeviceManager

| Aspect | Detail |
|--------|--------|
| Port scan | `/dev/cu.usbmodem*` glob, cached 60s |
| Session | Single `persistentSession` (one Pico) |
| Warm start | Scan → open PicoSession → connect → start keepalive + monitor |
| Reconnect | `handleHardFailure()` → invalidate → `warmStart()` |
| Device monitor | Background task, 2s poll when disconnected |
| Keepalive | `QUERY_STATE` every 30s if idle |

### PicoSession Connection Flow

```
connect()
├── SerialPort.open(portPath, baudRate: 115200)
├── waitForReady(timeout: 5000ms)
│   ├── Read lines until "BLAZE_READY" or "HEARTBEAT:...READY:1"
│   └── Late-join: plain "HEARTBEAT:" also accepted
├── verifyTransport() — STATUS probe
│   ├── Send CMD_STATUS (21) binary packet
│   ├── Read response, check for "STATUS: ready=1"
│   └── Up to 3 attempts, 500ms between
├── startEventReader() — background Task
│   └── Loop: serialPort.read(512, timeout:150ms) → parse lines → emit events
└── startHeartbeatMonitor()
```

### SerialPort (POSIX)

| Setting | Value |
|---------|-------|
| Baud rate | 115200 |
| Mode | Raw (`cfmakeraw`), `CLOCAL \| CREAD` |
| Flow control | None (CRTSCTS disabled) |
| VMIN/VTIME | 0/1 (100ms read timeout) |
| Open flags | `O_RDWR \| O_NOCTTY \| O_NONBLOCK` |
| Read | `poll(POLLIN, 100ms)` → `Darwin.read()` |
| Write | Non-blocking, retry on `EAGAIN` with exponential backoff (0.5ms→50ms), 2s max |
| SIGPIPE | Ignored |

### Binary Packet Protocol (Host → Pico)

```
┌──────────────┬──────────────────────────────────┬──────────────────────┐
│ Magic (4B)   │ Header (16B)                      │ Payload (11B)        │
│ "BLAZ"       │ ver│flg│connID│pktNum│streamID│len│ type│traceID│cmd│val │
└──────────────┴──────────────────────────────────┴──────────────────────┘
Total: 31 bytes per single command
```

**Header fields (16 bytes, big-endian):**

| Field | Size | Description |
|-------|------|-------------|
| version | 1B | Protocol version |
| flags | 1B | Reserved |
| connectionID | 4B | Session identifier |
| packetNumber | 4B | Monotonic counter |
| streamID | 4B | Stream identifier |
| payloadLength | 2B | Payload size |

**Single command payload (11 bytes):**

| Field | Size | Description |
|-------|------|-------------|
| frameType | 1B | Always 0 |
| traceID | 8B | 64-bit UUID-based trace identifier |
| commandID | 1B | See CommandID table |
| value | 1B | 0=OFF, 1=ON |

### CommandID Table

| ID | Name | GPIO | Description |
|----|------|------|-------------|
| 1 | `CMD_RED` | 14 | Red LED |
| 2 | `CMD_GREEN` | 15 | Green LED |
| 3 | `CMD_YELLOW` | 16 | Yellow LED |
| 4 | `CMD_BLUE` | 17 | Blue LED |
| 5 | `CMD_MULTI` | 18,19,20 | All RGB channels together |
| 6 | `CMD_MULTI_RED` | 18 | RGB red channel |
| 7 | `CMD_MULTI_GREEN` | 19 | RGB green channel |
| 8 | `CMD_MULTI_BLUE` | 20 | RGB blue channel |
| 10 | `CMD_ALL` | All | All 7 channels |
| 20 | `CMD_QUERY_STATE` | — | Query current GPIO state |
| 21 | `CMD_STATUS` | — | Health/readiness probe |
| 30 | `CMD_ENTER_BOOTLOADER` | — | Enter USB bootloader mode |

### Command Flow (End-to-End)

```
IntentRouter → ToolExecutor.execute(action)
    → DeviceManagerCommandHelper.sendCommand("RED ON")
    → DeviceManager.shared.getSession()
    → session.sendCommandWithCompletion(commandID: .red, value: 1)
    → PicoSession._sendCommand() → flushCommandQueue()
    → buildBlazePacket(payload) → PacketEncoder.encode()
    → sendPacketNonBlocking() [writeLock]
    → serialPort.write(fullPacket)  // "BLAZ" + header + payload
    → USB CDC serial → Pico firmware
```

---

## Layer 7: Pico Firmware

**File:** `main.c` (1284 lines)  
**Platform:** Raspberry Pi Pico (RP2040), C, `pico-sdk`  
**Interface:** USB CDC serial (stdio)

### Boot Sequence

```
1. stdio_init_all()
2. GPIO init: pins 14-20 as output, drive LOW
3. Boot animation: 5× 500ms all-LED blink
4. wait_for_usb_connection() — poll 50ms until stdio_usb_connected()
5. CDC stability delay: 200ms
6. start_usb_session(is_reconnect=false)
   ├── generate_session_uuid() — timestamp + monotonic counter
   ├── Print "SESSION: <uuid>"
   ├── Print "STATE: seq=0 R=0 G=0 Y=0 B=0 MR=0 MG=0 MB=0"
   └── Print "[READY] Device ready\nBLAZE_READY"
7. Main loop: read USB → parse → dispatch → heartbeat
```

### Parser State Machine

```
MODE_TEXT ──'B'──→ MODE_MAGIC_B ──'L'──→ MODE_MAGIC_BL ──'A'──→ MODE_MAGIC_BLA ──'Z'──→ MODE_BLAZE
    ↑                   │ (other)           │ (other)              │ (other)
    └───────────────────┴───────────────────┴──────────────────────┘
    
MODE_BLAZE: Read 16-byte header → payloadLength from header[14:15]
    → if payloadLength ≤ 64: read payload → dispatch_command()
    → if payloadLength > 64: MODE_DRAIN (discard oversized)
    
MODE_TEXT: Collect ASCII until \n or \r → exec(text_command)
```

### Command Dispatch

| CMD | Action | Response |
|-----|--------|----------|
| `CMD_RED` (1) | `set_led_state(0, val)` → `gpio_put(14, val)` | `ACK trace=<id> cmd=1 val=<v>` + `STATE_CHANGE:` |
| `CMD_GREEN` (2) | `set_led_state(1, val)` → `gpio_put(15, val)` | Same pattern |
| `CMD_YELLOW` (3) | `set_led_state(2, val)` → `gpio_put(16, val)` | Same pattern |
| `CMD_BLUE` (4) | `set_led_state(3, val)` → `gpio_put(17, val)` | Same pattern |
| `CMD_MULTI` (5) | Set MR, MG, MB together | ACK + STATE_CHANGE |
| `CMD_MULTI_RED` (6) | `set_led_state(4, val)` → `gpio_put(18, val)` | Same pattern |
| `CMD_MULTI_GREEN` (7) | `set_led_state(5, val)` → `gpio_put(19, val)` | Same pattern |
| `CMD_MULTI_BLUE` (8) | `set_led_state(6, val)` → `gpio_put(20, val)` | Same pattern |
| `CMD_ALL` (10) | All 7 channels on/off | ACK + STATE_CHANGE |
| `CMD_QUERY_STATE` (20) | Read all GPIOs | `STATE: seq=<n> R=... G=... Y=... B=... MR=... MG=... MB=...` |
| `CMD_STATUS` (21) | Health probe | `STATUS: ready=<0\|1> session=<hex> uptime=<ms> seq=<n> fw=<ver> proto=<n> model=<name>` |
| `CMD_ENTER_BOOTLOADER` (30) | ACK → flush → `reset_usb_boot(0, 0)` | Does not return |

### GPIO Pin Map

| Channel | GPIO Pin | Array Index |
|---------|----------|-------------|
| R (Red) | 14 | 0 |
| G (Green) | 15 | 1 |
| Y (Yellow) | 16 | 2 |
| B (Blue) | 17 | 3 |
| MR (Multi Red) | 18 | 4 |
| MG (Multi Green) | 19 | 5 |
| MB (Multi Blue) | 20 | 6 |

### Response Formats

```
ACK trace=<traceID> cmd=<cmdID> val=<value>
STATE: seq=<n> R=<0|1> G=<0|1> Y=<0|1> B=<0|1> MR=<0|1> MG=<0|1> MB=<0|1>
STATE_CHANGE: trace=<traceID> seq=<n> R=<0|1> G=<0|1> Y=<0|1> B=<0|1> MR=<0|1> MG=<0|1> MB=<0|1>
STATUS: ready=<0|1> session=<hex8> uptime=<ms> seq=<n> fw=<ver> proto=<n> model=<name>
HEARTBEAT: UPTIME:<ms> READY:<0|1> R=<0|1> G=... Y=... B=... MR=... MG=... MB=...
```

### Heartbeat

- Every 2 seconds
- Includes full GPIO state and readiness
- Host uses `HEARTBEAT: ... READY:1` for late-join detection (device already running when host connects)

### USB Disconnect Handling

```
stdio_usb_connected() returns false
    → handle_usb_disconnect()
    → Reset parser state to MODE_TEXT
    → wait_for_usb_connection() (50ms poll)
    → start_usb_session(is_reconnect=true)
    → Print "BOOT:USB_RECONNECT"
    → Anti-spam: minimum 300ms between session starts
```

### Debug Logging (Compile-Time Flags)

| Flag | Default | Content |
|------|---------|---------|
| `ENABLE_USB_LIFECYCLE_LOGS` | 1 | USB/BOOT/SESSION/READY |
| `ENABLE_DEBUG_LOGS` | 0 | Before/after GPIO state |
| `ENABLE_TELEMETRY_LOGS` | 1 | GPIO_SET_START/DONE, GPIO_READBACK, TRACE |
| Protocol logs | Always | SESSION, STATE, BLAZE_READY, ACK, STATE_CHANGE, ERROR |

---

## Cross-Cutting Concerns

### State Contract

Every daemon response to a light/hardware command MUST include a `STATE:` line with all LED channels. This is enforced at multiple points:
- ToolExecutor includes STATE in success results
- AgentRequestRouter extracts STATE from error messages
- Fallback: `STATE: R=0 G=0 Y=0 B=0 M=0` if no state found (defensive)

### Error Recovery Chain

```
Layer 1 (UI): Connection lost → stateAuthority → .reconnecting → retry after 1s
Layer 2 (Bridge): Socket error → client = nil → reconnect()
Layer 3 (Client): SocketConnectionError → connection = nil → retry on next request
Layer 4 (Server): Read error → close client socket, server continues
Layer 5 (Router): Planner error → fast-path fallback → chatbot fallback → error response
Layer 6 (Serial): Write/read error → invalidate session → warmStart()
Layer 7 (Firmware): USB disconnect → reset parser → wait → reconnect session
```

### Concurrency Model

| Layer | Model |
|-------|-------|
| 1 (UI) | `@MainActor`, SwiftUI observation |
| 2 (Bridge) | `@MainActor`, `Task { }`, single `commandInFlight` lock |
| 3 (Client) | `NSLock` for connection, `isRequestInFlight` flag |
| 4 (Server) | GCD (`DispatchQueue`), `DispatchSemaphore`, per-socket write queues |
| 5 (Router) | Swift concurrency (`async/await`), serial `hardwareExecutionQueue` |
| 6 (Serial) | `writeLock` (NSLock), `commandSerializationQueue`, `readerTask` (Task) |
| 7 (Firmware) | Single-threaded main loop, no OS/RTOS |

---

## Protocol Contracts

### Unix Socket (Layer 3 ↔ Layer 4)

```
Frame: [4-byte LE length][payload]
Max: 8 MB
Direction: Full duplex
Events: Server → Client (interleaved with response during planWork)
Auth: Optional 32-byte token prefix
```

### USB Serial (Layer 6 ↔ Layer 7)

```
Host → Pico: "BLAZ" + 16-byte header + 11-byte payload (31 bytes total)
Pico → Host: ASCII text lines (\n terminated)
    - BLAZE_READY, SESSION:, STATE:, STATE_CHANGE:, ACK, HEARTBEAT:, STATUS:, ERROR:
Baud: 115200, 8N1, no flow control
```

---

## Known Issues & Dead Code

### Dead/Unused Code

| Item | Location | Status |
|------|----------|--------|
| `startBackgroundPlanning()` | VoiceDaemonBridge | Defined but never called from sendVoiceCommand; fast-path reply generated inline |
| `lastResponse` | VoiceDaemonBridge | Set but no consumer reads it |
| `showDebugLogs` | VoiceDaemonBridge | Published but no UI toggle found |
| `lastFrameData` | VoiceDaemonBridge | Set for debug overlay, no consumer |
| `LiveTranscriptState` | UIStateModels | Defined, not wired into ContentView |
| `AgentStatusState` | UIStateModels | Defined, not wired into ContentView |
| `ExecutionProgressState` | UIStateModels | Defined, not wired into ContentView |
| `DeviceStateView` | Separate file | Superseded by DevicePanel + DeviceStateStore |
| ChatPanel bindings | `manualInput`, `selectedModel`, `recognizer` | Passed as bindings but never used inside ChatPanel |

### Redundant State

- `bridge.deviceState` (DeviceStateModel) and `bridge.deviceStateStore` (DeviceStateStore) both exist; UI only uses `deviceStateStore`
- `stateAuthority` manages dedup/reconnect but adds a Combine hop that could be eliminated

### GPIO Comment Mismatch

- `main.c` comments mention GPIO 24/25/26 for multi-color LEDs; actual code uses GPIO 18/19/20

### Architectural Risks

1. **Single command lock** — `commandInFlight` boolean means button clicks silently dropped if heartbeat/sync is in-flight
2. **Debug asserts removed** — All `assert()` in AgentRequestRouter converted to guard/throw (correct, but plan generation failures now return errors instead of crashing, meaning the chatbot fallback chain must handle them)
3. **No backpressure on messages** — `bridge.messages` array grows without bound during a session
4. **Heartbeat warm loop** — 25s `planWork("query state")` can contend with user commands via the daemon socket

---

*Document generated: Feb 21, 2026*  
*Audit scope: VoiceAgentController, AgentDaemon, AgentKit, AgentDaemonClient, PicoLEDControlSwift, blaze-pico firmware*
