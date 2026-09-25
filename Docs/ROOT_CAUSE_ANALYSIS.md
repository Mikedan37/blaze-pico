# Root Cause Analysis: VoiceAgentController Not Working

## Problem Statement
VoiceAgentController app is not working - commands are not executing on the Pico device.

## Investigation Summary

### ✅ What's Working
1. **Firmware**: Boot sequence working (`SESSION` → `STATE` → `BLAZE_READY`)
2. **Direct CLI**: Commands work via `PicoLEDControl` CLI tool
3. **Daemon**: Running and listening on `/tmp/blaze_agent.sock`
4. **DeviceManager**: Connected to Pico (`BLAZE_READY` received)
5. **Socket**: Accepting connections (tested with `nc`)

### ❌ What's NOT Working
1. **No command attempts in daemon logs**: Zero `planWork`, `handlePlanWork`, or `IntentRouter.route()` calls
2. **No socket connection attempts logged**: No client connections visible in logs

## Root Cause Hypothesis

**The issue is BEFORE the daemon receives commands.**

### Possible Failure Points

#### 1. VoiceAgentController Not Sending Commands
- **Symptom**: No logs of any kind in daemon
- **Check**: VoiceAgentController logs/console output
- **Likely**: Connection failure, error handling swallowing errors, or commands not being triggered

#### 2. AgentDaemonClient Connection Failure
- **Symptom**: Silent failure, no error propagation
- **Check**: VoiceAgentController error handling
- **Likely**: Socket connection timeout, permission issues, or connection retry exhaustion

#### 3. Request Encoding Failure
- **Symptom**: Commands sent but malformed
- **Check**: BlazeBinary encoding in AgentDaemonClient
- **Likely**: Protocol mismatch or encoding error

## Diagnostic Steps

### Step 1: Check VoiceAgentController Logs
```bash
# Check VoiceAgentController console/logs for:
# - Connection errors
# - "sendVoiceCommand" invocations
# - Socket connection failures
# - Timeout errors
```

### Step 2: Test Socket Connection from VoiceAgentController
```swift
// In VoiceAgentController, test connection:
let client = AgentDaemonClient(socketPath: "/tmp/blaze_agent.sock")
do {
    let response = try await client.planWork(
        workspacePath: "/Users/mdanylchuk",
        goal: "agent status"
    )
    print("Connection successful: \(response)")
} catch {
    print("Connection failed: \(error)")
}
```

### Step 3: Add Logging to DaemonServer
Check if `DaemonServer.swift` logs incoming connections:
- Look for `accept()` calls
- Check if connections are logged
- Verify request decoding happens

### Step 4: Check AgentDaemonClient Retry Logic
- Verify retry attempts are happening
- Check if errors are being swallowed
- Confirm connection timeout values

## Most Likely Root Cause

Based on evidence:
1. ✅ Daemon is running and listening
2. ✅ Socket accepts connections (tested)
3. ✅ DeviceManager is ready
4. ❌ **ZERO command attempts in logs**

**Most likely**: VoiceAgentController is failing to connect or send commands, and errors are being silently swallowed or not logged.

## Next Steps

1. **Check VoiceAgentController logs** - Look for connection errors
2. **Add verbose logging** to AgentDaemonClient connection logic
3. **Test connection** from VoiceAgentController directly
4. **Check error handling** - Ensure errors are propagated, not swallowed
5. **Verify socket permissions** - Ensure VoiceAgentController can access `/tmp/blaze_agent.sock`

## Files to Check

1. `/Users/mdanylchuk/Developer/ProjectBlaze/VoiceAgentController/VoiceAgentController/VoiceDaemonBridge.swift`
   - `sendVoiceCommand()` method
   - Error handling
   - Connection initialization

2. `/Users/mdanylchuk/Developer/ProjectBlaze/AgentDaemonClient/Sources/AgentDaemonClient/Client.swift`
   - `ensureConnected()` method
   - `planWork()` method
   - Error propagation

3. `/Users/mdanylchuk/Developer/ProjectBlaze/AgentDaemon/Sources/AgentDaemon/DaemonServer.swift`
   - Accept loop logging
   - Request handling
   - Error logging

## Quick Test

Run this to verify the full pipeline:
```bash
# Terminal 1: Monitor daemon logs
tail -f /tmp/agentdaemon.log | grep -E "planWork|handlePlanWork|IntentRouter|connection|accept"

# Terminal 2: Send test command from VoiceAgentController
# (Use the app UI to send "turn red light on")
```

If nothing appears in Terminal 1, the issue is in VoiceAgentController → AgentDaemonClient connection.
