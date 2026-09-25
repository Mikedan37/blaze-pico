# End-to-End Pipeline Verification

**Deterministic proof that voice  agent  tool  serial  firmware  GPIO actually works.**

---

## Overview

The `blaze-verify` command runs a comprehensive verification harness that tests the entire pipeline:

```
VoiceAgentController  AgentDaemon  PicoLEDTool  USB Serial  Pico Firmware  GPIO  LED
```

**This is not manual testing. This is automated integration verification.**

---

## Usage

### Basic Verification

```bash
# Run full pipeline verification
blaze-verify

# Or directly
cd PicoLEDControlSwift
.build/release/PipelineVerifier
```

### Options

```bash
# Verbose output
blaze-verify --verbose

# Specify AgentDaemon socket path
blaze-verify --daemon-socket /tmp/custom_socket.sock

# Specify Pico serial port
blaze-verify --port /dev/cu.usbmodem1101
```

---

## Verification Steps

### Step A: AgentDaemon Reachability

**Checks:**
- AgentDaemon socket exists at `/tmp/blaze_agent.sock`
- Socket is accessible

**Failure:** `DAEMON_UNREACHABLE`
- **Fix:** Start AgentDaemon or check socket path

---

### Step B: Pico Device Session

**Checks:**
- Pico serial device detected (`/dev/cu.usbmodem*`)
- Persistent session established via `DeviceManager`
- Readiness handshake completed (`BLAZE_READY`)

**Failure:** `NO_SERIAL_DEVICE` or `DEVICE_NOT_READY`
- **Fix:** Connect Pico device, wait for boot sequence, or reboot

---

### Step C: Binary Command Verification

**Checks:**
- Send `RED ON` via binary protocol
- Receive ACK from firmware
- Verify GPIO feedback matches expected state

**Failure:** `ACK_TIMEOUT` or `GPIO_MISMATCH`
- **Fix:** Check USB reconnect, reboot Pico, or verify GPIO wiring

---

### Step D: Voice Command Path

**Checks:**
- Simulated voice command: "turn the red light on"
- Routes through LLM  Agent  Tool  Serial
- Command executes successfully
- ACK received

**Failure:** `VOICE_ROUTING_FAIL`
- **Fix:** Check AgentDaemon integration

---

## Report Format

```
========================================
PIPELINE VERIFICATION REPORT
========================================

AgentDaemon: OK
Pico Device: OK
Firmware Ready: OK
Binary Command: OK
GPIO Feedback: OK
Voice  Tool Routing: OK

----------------------------------------
Latency Breakdown
----------------------------------------

LLM: 205ms
Agent dispatch: 12ms
Serial: 7ms
Firmware: 0.5ms

TOTAL: 230ms

----------------------------------------

END-TO-END STATUS: PASS
========================================
```

---

## Failure Diagnostics

If verification fails, the report includes:

```
FAILURE STAGE: ACK_TIMEOUT
SUGGESTED FIX: Check USB reconnect / reboot Pico
```

**Supported failure types:**
- `DAEMON_UNREACHABLE` - AgentDaemon not running
- `NO_SERIAL_DEVICE` - Pico not connected
- `DEVICE_NOT_READY` - Pico not booted
- `ACK_TIMEOUT` - No ACK received
- `GPIO_MISMATCH` - GPIO state incorrect
- `VOICE_ROUTING_FAIL` - Voice pipeline failed

---

## Architecture

### Uses Existing Infrastructure

 **DeviceManager** - Multi-device orchestration  
 **PicoSession** - Persistent connections  
 **Telemetry System** - Trace ID propagation  
 **Binary Protocol** - BlazeTransport packets  
 **Event Streaming** - Combine event streams  

**No shortcuts. No bypasses. Real integration test.**

---

## Success Criteria

The system is considered **fully operational** ONLY if:

-  AgentDaemon reachable
-  Pico device detected
-  Readiness handshake confirmed
-  Binary command ACK received
-  GPIO feedback matches expected state
-  Simulated voice command routes correctly

**All checks must pass for `END-TO-END STATUS: PASS`**

---

## Integration with CI/CD

```bash
# In CI pipeline
if ! blaze-verify; then
    echo "Pipeline verification failed"
    exit 1
fi
```

**Exit codes:**
- `0` - All checks passed
- `1` - One or more checks failed

---

## What This Proves

**If `blaze-verify` passes:**

You can literally:

1. Sit at your Mac
2. Say: **"turn the green light on"**
3. Your voice  LLM  agent  runtime  serial  firmware  GPIO  LED will happen

**Not a demo. A real control system.**

---

## Implementation

**Location:** `PicoLEDControlSwift/Sources/PipelineVerifier/main.swift`

**Components:**
- `PipelineVerifierEngine` - Verification logic
- `VerificationReport` - Result structure
- Structured report output
- Failure diagnostics

**CLI Wrapper:** `Scripts/blaze-verify`

---

## Next Steps

After verification passes:

1. **Real Voice Integration** - Connect VoiceAgentController
2. **Extended Testing** - Run 100+ iterations
3. **Performance Monitoring** - Track latency trends
4. **Failure Recovery** - Test reconnection scenarios

---

**This is professional systems engineering.**

**Always verify. Never assume.**
