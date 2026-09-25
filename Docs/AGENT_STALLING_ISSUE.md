# Agent Stalling Issue - Root Cause & Fix

## Problem Summary

When sending voice commands like "turn on green light", the system stalls:
- Command executes successfully (LED turns on)
- But agent doesn't respond back to VoiceAgentController
- Frontend shows loading spinner indefinitely
- User can't continue chatting

## Root Cause

**Agent daemon is waiting for `queryState()` which times out after 5 seconds.**

### The Problem Flow

1. Voice command received: "turn on green light"
2. LLM processes  generates command: "GREEN ON"
3. Agent dispatches  sends command to Pico 
4. Firmware executes  LED turns on 
5. **Agent calls `queryState()` to verify state**
6. **`queryState()` times out (5 seconds)** because:
   - Parser was looking for old format ("M" key)
   - New firmware returns "MR", "MG", "MB" format
   - Validation fails  returns `nil`
   - Timeout occurs  agent stalls
7. **Agent never sends completion response**  frontend waits forever

### Why It Stalls

From logs:
```
 Timeout wrapper: timeout fired! Throwing error...
[DeviceState] Query failed: Failed to decode response: Invalid response from daemon
 withTimeout caught error: Request timed out after 5.0 seconds
```

The agent is waiting for a state query that never completes successfully.

## The Fix

### 1. Fixed STATE Parser (Already Done)

**File:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift`

-  Updated `parseStateResponse()` to handle MR, MG, MB format
-  Added STATE_CHANGE event parsing (more reliable)
-  Fixed `queryState()` validation to accept MR, MG, MB keys

### 2. Agent Daemon Changes Needed

**The agent daemon needs these fixes:**

####  Option A: Use `sendCommandWithCompletion()` (RECOMMENDED - EASIEST)

**NEW HELPER FUNCTION:** Use `sendCommandWithCompletion()` which handles everything automatically:

```swift
//  RECOMMENDED: Use the new helper function
let result = try await session.sendCommandWithCompletion(
    commandID: .green,
    value: 1,
    ackTimeoutMs: 500,
    stateTimeoutMs: 500
)

if result.success {
    // Command executed successfully (ACK received)
    let state = result.state  // May be nil if STATE_CHANGE timeout, but that's OK
    sendCompletionResponse(
        success: true,
        message: "Green light turned on successfully",
        state: state  // Optional - include if available
    )
} else {
    // ACK timeout - command may not have executed
    sendCompletionResponse(
        success: false,
        message: "Failed to turn on green light - device did not respond"
    )
}
```

**Benefits:**
-  Waits for ACK (confirms command executed)
-  Gets state from STATE_CHANGE event (automatic, no query needed)
-  Short timeouts (500ms each) - won't stall
-  Returns gracefully on timeout (doesn't throw)
-  One function call - simple to use

#### Option B: Use STATE_CHANGE Events Manually

If you need more control, listen for `STATE_CHANGE` events manually:

```swift
// DON'T DO THIS (causes timeout):
let state = try await session.queryState()  // Times out!

// DO THIS INSTEAD (non-blocking):
try await session.sendCommand(commandID: .green, value: 1)

// Wait for STATE_CHANGE event (sent automatically after every command)
// Listen to the event stream - no query needed
```

**Benefits:**
- No timeout risk
- More reliable (automatic)
- Faster (no extra query needed)
- State is always up-to-date

#### Option C: Shorter Timeout + Fallback

If queryState() is needed, use shorter timeout and handle failure gracefully:

```swift
do {
    let state = try await session.queryState(timeoutMs: 500)  // 500ms timeout instead of 5s
    // Use state
} catch {
    // Don't fail - command already executed successfully
    // Just log warning and continue
    print(" State query failed but command succeeded")
    // Send success response anyway
}
```

#### Option D: Don't Query After Commands

Since STATE_CHANGE events are sent automatically, don't query at all:

```swift
// After sending command:
try await session.sendCommand(commandID: .green, value: 1)

// DON'T query state - STATE_CHANGE event will arrive automatically
// Just wait for ACK (already handled)

// Send completion response immediately:
sendCompletionResponse(success: true, message: "Green light turned on")
```

### 3. Send Completion Response Always

**Critical:** Agent must send completion response even if state query fails:

```swift
// After command execution:
let commandSuccess = try await session.sendCommand(...)

if commandSuccess {
    // Command succeeded - send success response
    sendCompletionResponse(
        success: true,
        message: "Green light turned on successfully"
    )
} else {
    // Command failed - send error response
    sendCompletionResponse(
        success: false,
        message: "Failed to turn on green light"
    )
}

// DON'T wait for state query - it's optional verification only
```

## Expected Behavior After Fix

1. Voice command: "turn on green light"
2. Command executes  LED turns on
3. Agent receives ACK
4. **Agent sends completion response immediately** 
5. Frontend shows: "Green light turned on" 
6. User can continue chatting 

## Fixes Applied

###  Swift Library Fixes (Completed)

1. **Updated `parseStateResponse()`** in `PicoSession.swift`:
   -  Now correctly parses `MR`, `MG`, `MB` format
   -  Retains backward compatibility for `M` format
   -  Added `STATE_CHANGE` event parsing

2. **Fixed `queryState()`** in `PicoSession.swift`:
   -  Accepts `timeoutMs` parameter (defaults to 1000ms)
   -  Returns `nil` gracefully on timeout (doesn't throw)
   -  Updated validation to check for `MR`, `MG`, `MB` keys

3. **Updated `DeviceManager.syncAllDeviceStates()`**:
   -  Uses 1000ms timeout for `queryState()`
   -  Handles `nil` return gracefully

4. **NEW: Added `sendCommandWithCompletion()` helper**:
   -  Sends command and waits for ACK
   -  Automatically waits for STATE_CHANGE event
   -  Short timeouts (500ms each) - won't stall
   -  Returns `(success: Bool, state: [String: Bool]?)` tuple
   -  **RECOMMENDED** for agent daemon use

###  Agent Daemon Fixes (Still Needed)

The agent daemon (external project) needs to be updated to use one of these approaches:

1. **RECOMMENDED:** Use `sendCommandWithCompletion()` (easiest)
2. **OR:** Listen for STATE_CHANGE events manually
3. **OR:** Use shorter timeout on `queryState()` and handle `nil` gracefully
4. **OR:** Don't query state after commands (just send completion response)

**Critical:** Agent must send completion response even if state query fails or times out.

### 1. STATE Parser Fixed 

**File:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift`

-  Updated `parseStateResponse()` to handle MR, MG, MB format
-  Added STATE_CHANGE event parsing (more reliable)
-  Fixed `queryState()` validation to accept MR, MG, MB keys

### 2. Timeout Reduced 

**File:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift`

-  `queryState()` now has configurable timeout (default 1s instead of 5s)
-  Returns `nil` gracefully on timeout (doesn't throw errors)
-  Prevents agent from stalling if state query fails

**File:** `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManager.swift`

-  Uses shorter timeout (1s) for state queries
-  Handles timeout gracefully (non-critical)

### 3. STATE_CHANGE Events 

-  STATE_CHANGE events are now parsed automatically
-  These are sent after every command (more reliable than querying)
-  Agent can use these instead of calling queryState()

## Current State

-  STATE parser fixed (handles MR, MG, MB format)
-  STATE_CHANGE events parsed correctly
-  queryState() timeout reduced (1s default)
-  queryState() returns nil gracefully (doesn't throw)
-  Agent daemon still needs update (not in this repo)

## Next Steps

1. **Rebuild Swift daemon** with all fixes
2. **Update agent daemon** (separate project) to:
   - **Option A (Recommended):** Use STATE_CHANGE events instead of queryState()
     - STATE_CHANGE events arrive automatically after every command
     - No query needed - just listen to event stream
   - **Option B:** If queryState() is needed, handle nil return gracefully:
     ```swift
     let state = try await session.queryState(timeoutMs: 1000)
     // Don't wait - send completion response immediately
     sendCompletionResponse(success: true, message: "Green light turned on")
     // State query is optional verification only
     ```
3. **Test:** Voice commands should complete and show responses

## Related Files

- `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoSession.swift` - Fixed parser & timeout
- `PicoLEDControlSwift/Sources/PicoLEDControlLib/DeviceManager.swift` - Updated timeout handling
- Agent daemon (separate project) - Needs update to use STATE_CHANGE or handle timeouts

## Date Identified

February 19, 2025

## Date Fixed

February 19, 2025

## Status

 **FIXED** - Parser and timeout fixed. Agent daemon needs update to use fixes.
