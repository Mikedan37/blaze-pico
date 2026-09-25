# Quick Test to Debug ACK Issue

## The Problem

- RED ON works 
- GREEN ON, BLUE ON, YELLOW ON don't get ACK 

## Debug Test

### Step 1: Flash Updated Firmware

```bash
cd /Users/mdanylchuk/pico/blaze-pico/build
cp blaze_pico.uf2 /Volumes/RP2350/
```

### Step 2: Watch Serial Output

In terminal 1:
```bash
screen /dev/cu.usbmodem1101 115200
```

### Step 3: Send Commands

In terminal 2:
```bash
cd PicoLEDControlSwift

# Test RED (should work)
.build/release/PicoLEDControl --port /dev/cu.usbmodem1101 RED ON

# Test GREEN (watch serial output)
.build/release/PicoLEDControl --port /dev/cu.usbmodem1101 GREEN ON
```

### Step 4: Check Serial Output

**For RED ON, you should see:**
```
PACKET RECEIVED
DEBUG: payload_len=3, payload[0]=0, payload[1]=1
BINARY: cmdID=1 value=1
ACK:1:1
```

**For GREEN ON, check:**
- Does it say `payload_len=3`? (should be 3 for binary)
- Does it say `BINARY:` or `ASCII:`?
- Does it show `ACK:2:1`?

## What to Look For

**If you see `payload_len=5` or more:**
 Swift is sending ASCII format, not binary
 Check `sendBinaryCommand` is being called

**If you see `payload_len=3` but `ERROR:`:**
 Binary detection logic issue

**If you see `BINARY:` and `ACK:` but Swift doesn't read it:**
 ACK reading timing issue

## Expected Behavior

After flashing updated firmware with debug output:
- You'll see exactly what payload length is received
- You'll see if it's detected as BINARY or ASCII
- You'll see the ACK being sent

This will tell us exactly where the problem is.
