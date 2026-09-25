# ProjectBlaze Telemetry System

Production-grade end-to-end observability for the voice  LLM  agent  hardware pipeline.

## Overview

Every user command generates a **64-bit trace ID** that propagates through every stage:
- Voice detection
- Speech transcription
- LLM processing
- Agent routing
- Tool invocation
- Serial transport
- Pico firmware execution
- GPIO activation

Each stage emits structured telemetry events to:
1. **Unified Logging** (`os.Logger`) - visible in Console.app
2. **JSONL files** - `~/Library/Logs/ProjectBlaze/telemetry-YYYY-MM-DD.jsonl`
3. **Signposts** (`os.signpost`) - visible in Instruments.app

## Event Schema

### TelemetryEvent

```swift
struct TelemetryEvent {
    traceID: UInt64              // 64-bit correlation ID
    tsWall: String                // ISO8601 wall clock time
    tsMonoNs: UInt64              // Monotonic timestamp (nanoseconds)
    component: TelemetryComponent // voice_app | agent_daemon | tool_serial | pico_firmware
    stage: String                 // Stage name (e.g., "voice_detected", "llm_start")
    durationMs: Double?            // Optional duration for this stage
    outcome: TelemetryOutcome      // ok | error | timeout
    metadata: [String: String]     // Additional context
}
```

### Components

- **`voice_app`**: VoiceAgentController (SwiftUI app)
- **`agent_daemon`**: AgentDaemon runtime
- **`tool_serial`**: PicoLEDControl Swift tool
- **`pico_firmware`**: RP2040 firmware (via telemetry prints)

### Stages

**Voice Pipeline:**
- `voice_detected` - Voice input detected
- `speech_transcribed` - Speech-to-text completed
- `llm_start` - LLM request initiated
- `llm_done` - LLM response received
- `route_decision` - Agent routing decision made
- `tool_invoked` - Tool selected for execution
- `agent_dispatch` - Agent dispatched command

**Serial Pipeline:**
- `packet_built` - BlazeTransport packet constructed
- `serial_write_start` - Serial write initiated
- `serial_write_done` - Serial write completed
- `packet_received` - Pico received packet (from firmware)
- `command_parsed` - Pico parsed command (from firmware)
- `gpio_set_start` - GPIO write started (from firmware)
- `gpio_set_done` - GPIO write completed (from firmware)
- `gpio_readback` - GPIO state read back (from firmware)
- `firmware_execution` - Complete firmware execution (from firmware)
- `ack_received` - ACK received from Pico
- `ack_timeout` - ACK timeout (no response)

## Log Locations

### JSONL Files

**Location:** `~/Library/Logs/ProjectBlaze/telemetry-YYYY-MM-DD.jsonl`

One file per day, append-only format. Each line is a JSON object:

```json
{"trace_id":928347239847,"ts_wall":"2026-02-18T14:23:45.123Z","ts_mono_ns":1234567890123456789,"component":"tool_serial","stage":"serial_write_start","duration_ms":null,"outcome":"ok","metadata":{}}
```

### Unified Logging

**Subsystem:** `com.danylchukstudios.projectblaze`  
**Category:** `telemetry`

View in Console.app:
```bash
log stream --predicate 'subsystem == "com.danylchukstudios.projectblaze"'
```

### Signposts

**Subsystem:** `com.danylchukstudios.projectblaze`  
**Category:** `.pointsOfInterest`

View in Instruments.app:
1. Open Instruments
2. Select "Time Profiler" or "System Trace"
3. Filter by subsystem: `com.danylchukstudios.projectblaze`
4. Look for signpost spans: `voice_processing`, `llm_call`, `agent_dispatch`, `serial_write`, `wait_for_ack`

## Usage

### Generating Telemetry

Telemetry is automatically generated when using `PicoLEDController`:

```swift
let controller = PicoLEDController(portPath: "/dev/cu.usbmodem1101")

// Mark voice detection (generates trace ID)
controller.markVoiceDetected()

// Mark LLM stages
controller.markLLMStart()
controller.markLLMDone(voicePhrase: "turn on red light", llmCommand: "RED ON")

// Mark agent dispatch
controller.markAgentDispatch()

// Send command (automatically marks serial stages)
try controller.sendCommand("RED ON")
```

### Analyzing Metrics

Use the `blaze-metrics` CLI tool:

```bash
# Analyze last 60 minutes (default)
swift run BlazeMetrics

# Analyze last 2 hours
swift run BlazeMetrics --minutes 120

# Analyze specific file
swift run BlazeMetrics --file ~/Library/Logs/ProjectBlaze/telemetry-2026-02-18.jsonl

# Output JSON
swift run BlazeMetrics --json

# Verbose output
swift run BlazeMetrics --verbose
```

### Metrics Output

**Human-readable:**
```
═══════════════════════════════════════════════════════════════════════════════
TELEMETRY METRICS ROLLUP
═══════════════════════════════════════════════════════════════════════════════
Time window: 60 minutes
Total events: 142
Total traces: 23

 SUCCESS RATE
────────────────────────────────────────────────────────────────────────────────
  Overall: 95.8% (136/142)
  Errors: 4
  Timeouts: 2

⏱  STAGE LATENCIES
────────────────────────────────────────────────────────────────────────────────
  llm_start  llm_done:
    p50: 201.3 ms  p95: 345.7 ms  p99: 412.1 ms
  serial_write_start  ack_received:
    p50: 1210.5 ms  p95: 1234.2 ms  p99: 1256.8 ms

 SERIAL ROUND-TRIP TIME
────────────────────────────────────────────────────────────────────────────────
  p50: 1210.5 ms  p95: 1234.2 ms  p99: 1256.8 ms
```

**JSON summary** (written to `summary.json`):
```json
{
  "timeWindowMinutes": 60,
  "totalEvents": 142,
  "totalTraces": 23,
  "successRate": 0.958,
  "stageStatistics": {
    "llm_start  llm_done": {
      "p50": 201.3,
      "p95": 345.7,
      "p99": 412.1
    }
  },
  "serialRTTStats": {
    "p50": 1210.5,
    "p95": 1234.2,
    "p99": 1256.8
  }
}
```

## Trace ID Propagation

### VoiceAgentController

```swift
// Generate trace ID at voice detection
let traceID = generateTraceID()

// Include in request to AgentDaemon
let request = BlazeRequest(
    text: transcript,
    traceID: traceID  // Add this field
)
```

### AgentDaemon

```swift
// Receive trace ID from VoiceAgentController
func handleRequest(_ request: BlazeRequest) {
    let traceID = request.traceID
    
    // Forward to tool
    tool.invoke(input: command, traceID: traceID)
}
```

### PicoLEDTool

```swift
// Receive trace ID from AgentDaemon
func invoke(input: String, traceID: UInt64) {
    controller.markAgentDispatch()  // Uses trace ID from controller
    
    // Send command with trace ID embedded in packet
    try controller.sendCommand(input)  // Trace ID in binary payload
}
```

### Pico Firmware

The firmware receives the trace ID in the binary payload:
```
Payload: [frameType(1), traceID(8 bytes), commandID(1), value(1)]
```

And includes it in all telemetry prints:
```
TRACE:928347239847 CMD:1 VAL:1 EXEC_US:2000 GPIO:1
ACK TRACE:928347239847 CMD:1 VAL:1 GPIO:1
```

## Integration Checklist

- [x] Telemetry.swift with standardized schema
- [x] JSONL logging to ~/Library/Logs/ProjectBlaze/
- [x] Unified Logging integration
- [x] Signpost spans for Instruments
- [x] blaze-metrics CLI tool
- [x] Trace ID propagation in PicoLEDController
- [ ] Trace ID propagation in VoiceAgentController (separate repo)
- [ ] Trace ID propagation in AgentDaemon (separate repo)
- [ ] Firmware telemetry parsing (already implemented)

## Viewing Telemetry

### Real-time Logs

```bash
# Unified Logging
log stream --predicate 'subsystem == "com.danylchukstudios.projectblaze"'

# JSONL tail
tail -f ~/Library/Logs/ProjectBlaze/telemetry-$(date +%Y-%m-%d).jsonl | jq
```

### Historical Analysis

```bash
# Generate metrics report
swift run BlazeMetrics --minutes 1440  # Last 24 hours

# Query specific traces
grep "928347239847" ~/Library/Logs/ProjectBlaze/telemetry-*.jsonl | jq

# Find slow commands
jq 'select(.duration_ms > 1500)' ~/Library/Logs/ProjectBlaze/telemetry-*.jsonl
```

### Instruments.app

1. Record a trace:
   ```bash
   xcrun xctrace record --template "Time Profiler" --launch -- /path/to/PicoLEDControl RED ON
   ```

2. Open in Instruments
3. Filter by subsystem: `com.danylchukstudios.projectblaze`
4. View signpost spans in timeline

## Performance Insights

From initial measurements:

- **Voice  LLM**: ~50ms (negligible)
- **LLM Processing**: ~200ms (model inference)
- **LLM  Agent**: ~12ms (routing)
- **Agent  Serial**: ~5ms (packet construction)
- **Serial  ACK**: ~1210ms (**81.5% of total** - USB CDC bottleneck)

**Bottleneck:** USB serial round-trip dominates latency. To improve:
- Use write-only mode for most commands (don't wait for ACK)
- Batch multiple commands in one packet
- Consider alternative transport (not USB CDC)

## Troubleshooting

### No telemetry files

Check log directory exists:
```bash
ls -la ~/Library/Logs/ProjectBlaze/
```

### Missing trace IDs

Ensure `markVoiceDetected()` is called before other stages.

### Signposts not visible

Ensure Instruments is filtering by subsystem: `com.danylchukstudios.projectblaze`

### JSONL parsing errors

Validate JSONL format:
```bash
cat ~/Library/Logs/ProjectBlaze/telemetry-*.jsonl | jq -s .
```
