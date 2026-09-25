# ESP8266 validation: host findings

Observed on real hardware (ESP8266EX via CP2102, `/dev/cu.usbserial-0001`) on 2026-09-25. Both were **fixed in commit `ef7385e`** ("Scope session identity and state ordering to device sessions") and re-verified on this board, including the physical-reset test. Both are in the Swift host's session tracking (`PicoSession.swift`). Neither involves the portable C protocol code or the firmware.

## 1. STATE_CHANGE with seq=0 is dropped after a reset

**Observed** (test05, first run):

```
STATUS: ready=1 session=D8E3863D uptime=163 ...          <- opening the port reset the board
STATE_CHANGE: trace=13841079002911362678 seq=0 R=0 ...
STATE_CHANGE ignored (duplicate/out-of-order): seq=0 <= lastSeq=0
```

The board's state sequence counter starts at 0 after every boot and only increases when state actually changes. A command that changes nothing ("RED OFF" while already off) reports `seq=0`. The host's duplicate filter requires `seq > lastSeq`, and `lastSeq` is 0 on a fresh `connect()`, so the update is dropped and `lastKnownGPIOState` stays nil. The Pico firmware counts the same way, so this is not ESP8266-specific.

**To investigate:** whether the filter should accept the first STATE_CHANGE of a session, and whether sequence numbers are meant to be scoped per device session.

## 2. The first session change after connect() is not detected

**Observed** (test08, board reset with RST while connected):

```
connect(): board in session 02EFE7A7 (reset on port open), commands enabled
<RST pressed>
First session detected: F43E9693          <- should have been "Session changed: 02EFE7A7 -> F43E9693"
```

`connect()` reads the boot lines (including `SESSION:<id>`) in `waitForReady()` but never stores the ID. The event reader's `handleSessionChange()` only compares against an ID it has seen itself, so the first reboot after a connect looks like a first sighting. Consequences:

- sequence tracking is not reset for the new session (related to finding 1);
- pending commands from the old session are not failed;
- **the protocol is not re-checked**, so a device that rebooted into incompatible firmware would keep receiving binary commands until the next reconnect.

The pseudo-terminal tests missed this because they emitted a first `SESSION` line after `connect()` before testing the change.

**To investigate:** have `connect()` record the session ID it sees during the handshake; add a test that resets the device without a prior `SESSION` line.

## Also observed (not bugs in this code)

- **Opening the port resets this board** (NodeMCU auto-reset wiring on DTR/RTS). Every `connect()` starts a new device session. The host handles it.
- **The STATUS probe often needs 2 or 3 attempts:** it reads one chunk and matches `STATUS:` in it, but the device's `PACKET RECEIVED` line, or a line split across reads, can come first. It always recovered.
- **USB dropped once** (`readFailed(errno: 6)`, ENXIO) right after RST was pressed, then re-enumerated. This matches the intermittent connector seen while first detecting the board.
