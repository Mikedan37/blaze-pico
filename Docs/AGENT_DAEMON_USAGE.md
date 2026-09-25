# Agent Daemon Usage Guide - Preventing Stalls

## Quick Fix: Use `sendCommandWithCompletion()`

The easiest way to prevent agent stalling is to use the new `sendCommandWithCompletion()` helper function.

### Before (Causes Stalling) 

```swift
// DON'T DO THIS - causes 5-second timeout and stalls
try await session.sendCommand(commandID: .green, value: 1)
let state = try await session.queryState()  // Times out after 5 seconds!
// Agent never sends completion response  frontend stalls
```

### After (No Stalling) 

```swift
// DO THIS - uses automatic STATE_CHANGE events, short timeouts
let result = try await session.sendCommandWithCompletion(
    commandID: .green,
    value: 1,
    ackTimeoutMs: 500,      // Wait for ACK (confirms execution)
    stateTimeoutMs: 500     // Wait for STATE_CHANGE (automatic event)
)

if result.success {
    // Command executed successfully (ACK received)
    let state = result.state  // May be nil if timeout, but that's OK
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

## How It Works

1. **Sends command** to Pico
2. **Waits for ACK** (500ms timeout) - confirms command executed
3. **Waits for STATE_CHANGE event** (500ms timeout) - automatic event sent after every command
4. **Returns immediately** - doesn't throw on timeout, just returns `nil` for state

## Benefits

-  **No stalling** - Short timeouts (500ms each)
-  **Reliable** - Uses automatic STATE_CHANGE events (no query needed)
-  **Simple** - One function call handles everything
-  **Graceful** - Returns `nil` on timeout instead of throwing

## Alternative Approaches

If you need more control, see `docs/AGENT_STALLING_ISSUE.md` for other options:
- Option B: Listen for STATE_CHANGE events manually
- Option C: Use shorter timeout on `queryState()` and handle `nil` gracefully
- Option D: Don't query state after commands

## Critical Rule

**Always send completion response**, even if state query fails or times out:

```swift
//  CORRECT: Send response even if state is nil
if result.success {
    sendCompletionResponse(success: true, message: "Command executed", state: result.state)
} else {
    sendCompletionResponse(success: false, message: "Command failed")
}

//  WRONG: Don't wait for state query before sending response
// This causes frontend to stall
```

## Example: Full Command Handler

```swift
func handleVoiceCommand(_ command: String) async {
    // Parse command (e.g., "turn on green light"  .green, value: 1)
    let (commandID, value) = parseCommand(command)
    
    do {
        // Use the new helper function
        let result = try await session.sendCommandWithCompletion(
            commandID: commandID,
            value: value
        )
        
        if result.success {
            // Success - send completion response immediately
            await sendCompletionResponse(
                success: true,
                message: "\(command) completed successfully",
                state: result.state  // Include state if available
            )
        } else {
            // ACK timeout - command may not have executed
            await sendCompletionResponse(
                success: false,
                message: "\(command) failed - device did not respond"
            )
        }
    } catch {
        // Connection error - send error response
        await sendCompletionResponse(
            success: false,
            message: "\(command) failed - \(error.localizedDescription)"
        )
    }
}
```

## Testing

After updating your agent daemon:

1. Send voice command: "turn on green light"
2. Command should execute (LED turns on)
3. **Agent should respond immediately** (within ~500ms)
4. Frontend should show: "Green light turned on successfully"
5. User can continue chatting 

If it still stalls, check:
- Are you using `sendCommandWithCompletion()`?
- Are you sending completion response even if state is `nil`?
- Are you handling errors gracefully (not throwing on timeout)?
