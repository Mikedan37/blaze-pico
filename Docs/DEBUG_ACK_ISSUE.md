# Debugging ACK Issue

## Problem

-  RED ON works (ACK received, LED turns on)
-  GREEN ON, BLUE ON, YELLOW ON fail (no ACK, LEDs don't turn on)

## Possible Causes

1. **ACK reading timing** - ACK sent but not read in time
2. **Binary protocol detection** - Commands not recognized as binary
3. **Port state** - Port getting closed/reopened incorrectly
4. **Buffer issues** - ACK buffer getting full

## Debug Steps

### Step 1: Watch Serial Output

In one terminal:
```bash
screen /dev/cu.usbmodem1101 115200
```

In another terminal, run commands:
```bash
cd PicoLEDControlSwift
.build/release/PicoLEDControl --port /dev/cu.usbmodem1101 GREEN ON
```

**Watch for in screen:**
- `PACKET RECEIVED` - Packet arrived
- `BINARY: cmdID=2 value=1` - Binary protocol detected
- `ACK:2:1` - ACK sent

**If you see:**
- `PACKET RECEIVED` but no `BINARY:`  Protocol detection issue
- `BINARY:` but no `ACK:`  Command execution issue
- `ACK:` but Swift doesn't read it  ACK reading issue

### Step 2: Test Individual Commands

```bash
# Test each separately
.build/release/PicoLEDControl RED ON    # Should work
.build/release/PicoLEDControl GREEN ON  # Check if this works
.build/release/PicoLEDControl BLUE ON  # Check if this works
```

### Step 3: Check Binary Protocol

The firmware checks:
- `payload_len >= 3` (binary is 3 bytes: [0, cmdID, value])
- `payload_len <= 5` (to distinguish from ASCII which is 5+ bytes)
- `payload[1] >= 1 && payload[1] <= 255` (valid commandID)

If payload is exactly 3 bytes with valid commandID  Binary protocol
If payload is 5+ bytes  ASCII protocol

## Quick Fix Test

Try sending binary command directly:

```bash
# This should send binary [0, 2, 1] for GREEN ON
# Check serial output to see if it's detected as binary
```

## Expected Serial Output

For `GREEN ON`:
```
PACKET RECEIVED
BINARY: cmdID=2 value=1
ACK:2:1
```

If you see `ASCII:` instead of `BINARY:`  Payload format is wrong
