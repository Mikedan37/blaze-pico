# Production State Authority Implementation - Complete

## Overview

This document describes the final 10% of production-ready state management: **monotonic sequence numbers**, **trace ID correlation**, and **proper reconnect recovery**. These features turn "works on my desk" into "doesn't embarrass me when it matters."

## Implementation Summary

### 1. Monotonic State Sequence Numbers

**Firmware (`main.c`):**
- Added `static uint64_t state_sequence = 0` counter
- Increments on every LED state mutation (in `set_led_state()`)
- Included in all `STATE_CHANGE:` and `STATE:` responses:
  - `STATE_CHANGE: trace=<traceID> seq=<sequence> R=... G=...`
  - `STATE: seq=<sequence> R=... G=...`

**Swift (`PicoSession.swift`):**
- Added `lastAppliedSequence: UInt64` tracking
- Seq-based deduplication: only apply updates where `seq > lastAppliedSequence`
- Ignores duplicate/out-of-order events automatically
- Updates `lastAppliedSequence` when parsing `STATE:` responses

**Benefits:**
- Deterministic deduplication (no hash computation needed)
- Prevents duplicate state updates from UI spam
- Handles out-of-order events gracefully
- Cheap (single counter comparison)

### 2. Trace ID Correlation

**Firmware (`main.c`):**
- `STATE_CHANGE` includes trace ID when command-driven:
  - `STATE_CHANGE: trace=<traceID> seq=<sequence> R=...`
- Boot sequence `STATE_CHANGE` has no trace ID (non-command-driven)

**Swift (`PicoSession.swift`):**
- `sendCommandWithCompletion()` captures `seqBeforeCommand`
- Waits for `STATE_CHANGE` with `seq > seqBeforeCommand`
- Trace ID correlation prevents unrelated state spam from interfering
- Makes command confirmation immune to periodic state pushes

**Benefits:**
- Command confirmation is traceable end-to-end
- Prevents unrelated state events from breaking command flow
- Enables debugging across firmware  daemon  UI

### 3. Reconnect Recovery (Hardware as Authority)

**DeviceManager (`DeviceManager.swift`):**
- On `warmStart()` success, automatically queries state:
  ```swift
  Task.detached {
      if let state = try await session.queryState(timeoutMs: 2000) {
          // State applied via STATUS event (with seq)
      }
  }
  ```
- Hardware is the authority: query device state on reconnect
- Do NOT replay last known UI state to device (prevents desync)

**Benefits:**
- State always matches hardware after reconnect
- No stale UI state after USB unplug/replug
- Recovery happens automatically without manual intervention

### 4. Timeout Adjustments

**Updated Timeouts:**
- ACK timeout: **500ms** (unchanged - fast confirmation)
- STATE_CHANGE timeout: **1500ms** (increased from 500ms)
  - Accounts for USB hiccups, daemon load, macOS scheduling
  - Still snappy but not brittle

**Rationale:**
- 500ms ACK: Fast failure detection for command execution
- 1500ms STATE_CHANGE: Allows for USB serial delays without false timeouts
- 5s watchdog: Separate from operation timeouts (zombie detection only)

## Architecture Flow

### Command Flow (with seq + trace):
```
1. sendCommandWithCompletion(traceID=123)
    Captures seqBeforeCommand=100
   
2. Firmware executes command
    Increments state_sequence to 101
    Emits: ACK TRACE:123 ...
    Emits: STATE_CHANGE: trace=123 seq=101 R=1 G=0 ...
   
3. Swift receives ACK
    Confirms command executed
   
4. Swift receives STATE_CHANGE
    Parses seq=101, trace=123
    Checks: 101 > 100  (our command's state)
    Applies state update
    Updates lastAppliedSequence = 101
```

### Reconnect Flow:
```
1. DeviceManager.warmStart() succeeds
    Session connected
   
2. Automatic QUERY_STATE sent (2s timeout)
    Firmware responds: STATE: seq=105 R=0 G=1 ...
   
3. Swift parses STATE response
    Extracts seq=105
    Updates lastAppliedSequence = 105
    Emits STATUS event with GPIO state
   
4. UI receives authoritative state
    Hardware state matches UI state
```

### Deduplication Flow:
```
1. Rapid commands cause multiple STATE_CHANGE events
    STATE_CHANGE: seq=101 ...
    STATE_CHANGE: seq=102 ...
    STATE_CHANGE: seq=103 ...
   
2. Swift processes each event
    seq=101: 101 > 100   Apply, lastAppliedSequence=101
    seq=102: 102 > 101   Apply, lastAppliedSequence=102
    seq=103: 103 > 102   Apply, lastAppliedSequence=103
   
3. Duplicate/out-of-order events ignored
    seq=101: 101 <= 103   Ignore (already applied)
    seq=100: 100 <= 103   Ignore (out-of-order)
```

## Production Protections

###  State Deduplication
- Monotonic sequence prevents duplicate updates
- No hash computation overhead
- Handles out-of-order events

###  Trace Correlation
- Command  ACK  STATE_CHANGE traceable end-to-end
- Prevents unrelated state spam from breaking command flow
- Enables debugging across layers

###  Reconnect Recovery
- Hardware is authority (query on reconnect)
- No stale UI state after disconnect
- Automatic recovery without manual intervention

###  Timeout Hardening
- ACK: 500ms (fast failure detection)
- STATE_CHANGE: 1500ms (USB hiccup tolerance)
- Watchdog: 5s (separate from operation timeouts)

## Testing Scenarios

### 1. Rapid Commands
- Send 10 commands in quick succession
- **Expected**: All STATE_CHANGE events applied in order
- **Protection**: Seq deduplication prevents duplicate updates

### 2. USB Reconnect
- Unplug device, wait 2s, replug
- **Expected**: State query on reconnect, UI matches hardware
- **Protection**: Hardware authority recovery

### 3. Duplicate Events
- Simulate duplicate STATE_CHANGE events (same seq)
- **Expected**: Only first event applied, duplicates ignored
- **Protection**: Seq-based deduplication

### 4. Out-of-Order Events
- Simulate STATE_CHANGE events with seq < lastAppliedSequence
- **Expected**: Out-of-order events ignored
- **Protection**: Monotonic sequence check

### 5. Command Timeout
- Send command, ACK received, STATE_CHANGE timeout
- **Expected**: Command succeeds (ACK confirmed), state may be nil
- **Protection**: Graceful degradation (ACK confirms execution)

## Files Modified

1. **`main.c`**:
   - Added `state_sequence` counter
   - Increments on LED state mutations
   - Includes `seq=` in STATE_CHANGE and STATE responses
   - Includes `trace=` in command-driven STATE_CHANGE

2. **`PicoSession.swift`**:
   - Added `lastAppliedSequence` tracking
   - Implemented `parseStateChangeHeader()` for seq/trace extraction
   - Updated `parseStateResponse()` to extract and update seq
   - Updated `sendCommandWithCompletion()` for trace correlation
   - Seq-based deduplication in STATE_CHANGE handler

3. **`DeviceManager.swift`**:
   - Added automatic QUERY_STATE on reconnect
   - Hardware authority recovery pattern

## Status:  Production Ready

The system now has:
-  Monotonic state sequence (deduplication)
-  Trace ID correlation (command tracking)
-  Reconnect recovery (hardware authority)
-  Timeout hardening (USB hiccup tolerance)
-  Persistent sessions (no port conflicts)
-  Command confirmation (ACK + STATE_CHANGE)
-  Heartbeat watchdog (zombie detection)

**This is the final 10% that turns "works on my desk" into "doesn't embarrass me when it matters."**
