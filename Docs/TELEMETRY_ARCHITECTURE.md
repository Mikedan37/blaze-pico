# End-to-End Telemetry Architecture

## Overview

This document describes the production-grade telemetry system for the Pico LED control pipeline. The system provides **end-to-end observability** from voice input to GPIO execution.

## Architecture

```
Voice Input
     [t0] voice_detected
LLM Processing
     [t1] llm_start  [t2] llm_done
Agent Runtime
     [t3] agent_dispatch
Serial Write
     [t4] serial_write
USB Transmission
     [t5] firmware_receive
Firmware Execution
     [t6] gpio_execution  [t7] gpio_feedback
ACK Response
     [t8] ack_received
```

## Trace ID System

Every command carries a **64-bit trace ID** that follows it through the entire pipeline:

1. **Generated** in Swift tool: `timestamp (microseconds) + random(0-999)`
2. **Embedded** in binary payload: `[frameType(1), traceID(8), commandID(1), value(1)]`
3. **Logged** at every stage with the same trace ID
4. **Correlated** across host and firmware logs

## Binary Protocol Update

### Old Protocol (3 bytes)
```
[frameType(1), commandID(1), value(1)]
```

### New Protocol (11 bytes)
```
[frameType(1), traceID(8), commandID(1), value(1)]
```

**Backward Compatibility:** Firmware still accepts 3-byte legacy packets (trace ID = 0).

## Pipeline Stages

### 1. Voice Detection (`voice_detected`)
- **Location:** VoiceAgentController
- **Action:** Call `controller.markVoiceDetected()`
- **Timestamp:** When speech input is detected

### 2. LLM Processing (`llm_start`  `llm_done`)
- **Location:** AgentDaemon LLM handler
- **Actions:** 
  - Call `controller.markLLMStart()` before LLM call
  - Call `controller.markLLMDone()` after LLM response
- **Latency:** `llm_done - llm_start`

### 3. Agent Dispatch (`agent_dispatch`)
- **Location:** AgentDaemon tool invocation
- **Action:** Call `controller.markAgentDispatch()`
- **Timestamp:** When tool is selected and dispatched

### 4. Serial Write (`serial_write`)
- **Location:** PicoLEDController.sendBinaryCommand()
- **Timestamp:** When packet is written to serial port
- **Telemetry:** Trace ID, command ID, value

### 5. Firmware Execution (`firmware_execution`)
- **Location:** Pico firmware exec_binary_with_trace()
- **Timestamps:** 
  - `start_ms`: When command received
  - `end_ms`: When GPIO updated
- **Latency:** `end_ms - start_ms` (milliseconds)
- **Output:** `TRACE:928347239847 CMD:1 VAL:1 EXEC:2 GPIO:1`

### 6. GPIO Feedback (`gpio_feedback`)
- **Location:** Pico firmware
- **Method:** Read actual LED pin state after execution
- **Confirmation:** Verifies LED actually changed state
- **Output:** Included in TRACE line as `GPIO:0` or `GPIO:1`

### 7. ACK Received (`ack_received`)
- **Location:** PicoLEDController.sendPacket()
- **Timestamp:** When ACK response received
- **Latency:** `ack_received - serial_write`

## Structured Logging

All telemetry events are logged as **JSON**:

```json
{
  "traceID": 928347239847,
  "stage": "serial_write",
  "timestamp": "2026-02-18T10:30:45.123Z",
  "command": "1:1",
  "latencyMs": null,
  "metadata": {
    "commandID": "1",
    "value": "1"
  }
}
```

### Event Stages

- `voice_detected`
- `llm_start`
- `llm_done`
- `agent_dispatch`
- `serial_write`
- `firmware_execution`
- `gpio_feedback`
- `ack_received`

## Pipeline Summary

After each command, a summary is printed:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TRACE 928347239847
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Voice  LLM           412.3 ms
LLM Processing        245.1 ms
LLM  Agent            12.4 ms
Agent  Serial          3.2 ms
Serial  ACK            7.8 ms
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TOTAL                 680.8 ms
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## GPIO Feedback

### Implementation

The firmware reads the **actual LED pin state** after execution to confirm:

1. Command executed (`exec_binary_with_trace()`)
2. GPIO pin updated (`gpio_put()`)
3. Pin state read back (`gpio_get()`)
4. Feedback logged (`GPIO:0` or `GPIO:1`)

### Pin Mapping

- **Red:** GPIO 14
- **Green:** GPIO 15
- **Yellow:** GPIO 16
- **Blue:** GPIO 17
- **Multi:** GPIO 18
- **Feedback:** GPIO 19 (reserved for photodiode/loopback - future use)

### Future Enhancement: Photodiode

For true optical feedback, connect a photodiode to GPIO 19:

1. Photodiode detects LED light
2. GPIO 19 reads photodiode output
3. Confirms LED is **actually emitting light** (not just GPIO high)

## Integration Points

### VoiceAgentController

```swift
controller.markVoiceDetected()
// ... speech recognition ...
controller.markLLMStart()
// ... LLM call ...
controller.markLLMDone()
```

### AgentDaemon

```swift
// In IntentRouter or ToolExecutor
controller.markAgentDispatch()
let result = try await toolRegistry.invoke(...)
```

### PicoLEDController

```swift
// Automatically captures:
// - serial_write timestamp
// - ack_received timestamp
// - Parses firmware telemetry
// - Prints pipeline summary
```

## Log Analysis

### Parse Telemetry Logs

```bash
# Extract all telemetry events
grep "TELEMETRY:" logs.txt | jq .

# Find slow commands
grep "TELEMETRY:" logs.txt | jq 'select(.latencyMs > 500)'

# Trace a specific command
grep "TRACE:928347239847" logs.txt
```

### Correlate Host + Firmware

```bash
# Host logs
grep "TRACE 928347239847" host.log

# Firmware logs  
grep "TRACE:928347239847" firmware.log
```

## Performance Targets

- **Voice  LLM:** < 50ms (local speech recognition)
- **LLM Processing:** < 500ms (local inference)
- **LLM  Agent:** < 20ms (routing)
- **Agent  Serial:** < 10ms (tool invocation)
- **Serial  ACK:** < 50ms (USB + firmware)
- **Firmware Execution:** < 5ms (GPIO update)
- **TOTAL:** < 650ms end-to-end

## Troubleshooting

### Missing Timestamps

If a stage timestamp is missing, check:
1. Is the stage being called? (check logs)
2. Is the controller instance shared? (must be same instance)
3. Are timestamps being reset? (check for `timestamps = PipelineTimestamps()`)

### Trace ID Mismatch

If trace IDs don't match:
1. Check firmware is receiving 11-byte packets (not 3-byte legacy)
2. Verify trace ID is being parsed correctly in firmware
3. Check for packet corruption (verify checksums if added)

### GPIO Feedback Always 0

If GPIO feedback is always 0:
1. Check LED wiring (GPIO  LED  GND)
2. Verify LED is actually turning on (visual check)
3. Check if reading wrong pin (verify pin mapping)

## Future Enhancements

1. **Distributed Tracing:** Export to OpenTelemetry/Jaeger
2. **Metrics Collection:** Prometheus metrics endpoint
3. **Alerting:** Alert on latency spikes > 1s
4. **Dashboard:** Real-time pipeline visualization
5. **Photodiode Integration:** True optical feedback
6. **Trace Sampling:** Sample 10% of commands for performance

## Files Modified

1.  `main.c` - Firmware telemetry and GPIO feedback
2.  `PicoLEDController.swift` - Host telemetry and trace IDs
3.  `PicoLEDTool.swift` - AgentDaemon integration
4.  `.cursorignore` - Ignore build artifacts

## Success Criteria

 Every command has a trace ID  
 Every stage logs timestamp  
 Firmware reports execution time  
 GPIO feedback confirms execution  
 Pipeline summary printed after each command  
 Structured JSON logs for analysis  
 Backward compatible with legacy 3-byte protocol  

**System is now fully observable end-to-end.**
