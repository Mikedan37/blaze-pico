# End-to-End System Verification

##  What We're Testing

Complete pipeline:
```
Voice  AgentDaemon  Swift Tool  USB Serial  Pico Firmware  GPIO  LEDs
```

##  Pre-Flight Checklist

### 1. Firmware Status
```bash
cd /Users/mdanylchuk/pico/blaze-pico

# Check if firmware exists
ls -la build/blaze_pico.uf2

# If missing or old, rebuild:
rm -rf build
mkdir build
cd build
cmake ..
make -j4
```

### 2. Flash Firmware (if needed)
```bash
# Hold BOOTSEL button on Pico
# Plug in USB cable
# Release BOOTSEL

# Copy firmware
cp build/blaze_pico.uf2 /Volumes/RP2350/

# Wait for auto-reboot (Pico will disconnect/reconnect)
```

### 3. Swift Tool Status
```bash
cd PicoLEDControlSwift
swift build -c release

# Should see: "Build complete!"
```

### 4. Verify Pico Connection
```bash
# Check port exists
ls /dev/cu.usbmodem*

# Should see something like: /dev/cu.usbmodem1101
```

##  Test Sequence

### Test 1: Direct Text Mode (Baseline)
**Purpose**: Verify firmware is running and LEDs work

```bash
# Open serial terminal
screen /dev/cu.usbmodem1101 115200

# You should see:
# ========================================
# BLAZE PICO LED CONTROLLER READY
# ========================================
# Mode: Direct text + BlazeTransport
# Type commands like: RED ON<ENTER>
# ========================================

# Type: RED ON
# Press ENTER

# Expected:
# CMD: RED ON
# (LED should turn on)

# Type: ALL OFF
# Press ENTER

# Exit screen: Ctrl+A, K, Y
```

** Success Criteria**: LEDs respond to direct text commands

---

### Test 2: Swift Tool - Single Command
**Purpose**: Verify Swift  Pico communication works

```bash
cd /Users/mdanylchuk/pico/blaze-pico/PicoLEDControlSwift

# Run Swift tool
.build/release/PicoLEDControl RED ON
```

**Expected Output**:
```
Using port: /dev/cu.usbmodem1101
Sending: RED ON  (ACK received)
 All commands sent and acknowledged
```

** Success Criteria**: 
- Tool finds port automatically
- Command sent successfully
- ACK received from Pico
- LED turns on

**If you see ` (no ACK)`**:
- Open another terminal: `screen /dev/cu.usbmodem1101 115200`
- Run Swift tool again
- Watch for: `PACKET RECEIVED` message
- If you see it  ACK reading might have timing issue (non-critical)
- If you don't  Packet format issue (critical)

---

### Test 3: Swift Tool - Multiple Commands
**Purpose**: Verify command sequencing works

```bash
.build/release/PicoLEDControl RED ON GREEN ON BLUE ON
```

**Expected Output**:
```
Using port: /dev/cu.usbmodem1101
Sending: RED ON  (ACK received)
Sending: GREEN ON  (ACK received)
Sending: BLUE ON  (ACK received)
 All commands sent and acknowledged
```

** Success Criteria**: All LEDs turn on sequentially

---

### Test 4: Swift Tool - Explicit Port
**Purpose**: Verify port specification works

```bash
# Find your port
ls /dev/cu.usbmodem*

# Use explicit port
.build/release/PicoLEDControl --port /dev/cu.usbmodem1101 ALL OFF
```

**Expected Output**:
```
Sending: ALL OFF  (ACK received)
 All commands sent and acknowledged
```

** Success Criteria**: All LEDs turn off

---

### Test 5: Automated Test Script
**Purpose**: Run all tests automatically

```bash
cd /Users/mdanylchuk/pico/blaze-pico
./test_swift_tool.sh
```

**Expected Output**:
```
 Reality Check: Swift  Pico LED Control
==========================================
1⃣ Checking for Pico...
 Found Pico at: /dev/cu.usbmodem1101
2⃣ Building Swift tool...
 Swift tool built successfully
3⃣ Testing single command (RED ON)...
 Command sent and ACK received
4⃣ Testing multiple commands...
 Multiple commands sent successfully
5⃣ Testing ALL OFF...
 All LEDs should be off now
==========================================
 Reality check complete!
```

---

##  Debugging Guide

### Problem: "No Pico found"
**Solution**:
- Check USB cable is connected
- Try unplugging/replugging Pico
- Check: `ls /dev/cu.usbmodem*`
- If nothing appears  Pico might be in BOOTSEL mode

### Problem: "Failed to open serial port"
**Solution**:
- Check if another process is using it: `lsof | grep usbmodem`
- Kill any screen sessions: `pkill screen`
- Kill Python scripts: `pkill -f python`
- Try unplugging/replugging Pico

### Problem: " (no ACK)"
**Solution**:
- Open serial monitor: `screen /dev/cu.usbmodem1101 115200`
- Run Swift tool again
- Watch for `PACKET RECEIVED` message
- If you see it  ACK timing issue (non-critical, command still works)
- If you don't  Check packet format

### Problem: LEDs don't respond
**Solution**:
1. Test direct text mode first (Test 1)
2. If direct text works but Swift doesn't  Packet format issue
3. If direct text doesn't work  Firmware or wiring issue

### Problem: "Payload too big"
**Solution**:
- Check payload length calculation in Swift tool
- Verify command isn't too long
- Check firmware MAX_PAYLOAD size

---

##  Success Matrix

| Test | Status | Notes |
|------|--------|-------|
| Direct Text Mode |  | Baseline - must work |
| Swift Single Command |  | Core functionality |
| Swift Multiple Commands |  | Sequencing test |
| Explicit Port |  | Port handling |
| Automated Script |  | Full integration |

**All tests passing = System is production-ready**

---

##  Next Steps (After Verification)

Once all tests pass:

1. **Add Tool Schema to AgentDaemon**
   - Define `LightControl(color, state)` tool
   - Wire into tool registry
   - LLM outputs structured intent, not raw strings

2. **Add Status Feedback**
   - Pico sends JSON status: `{"status":"ok","led":"red","state":"on"}`
   - AgentDaemon confirms execution
   - Prevents silent failures

3. **Add Error Handling**
   - Pico reports GPIO errors
   - Swift tool handles serial errors
   - AgentDaemon handles tool failures

4. **Add Multi-Device Support**
   - Use stream IDs for device channels
   - Generic device bus protocol
   - Scale beyond LEDs

---

##  Final Verification

Run this complete sequence:

```bash
# 1. Flash firmware (if needed)
cd /Users/mdanylchuk/pico/blaze-pico/build
cp blaze_pico.uf2 /Volumes/RP2350/

# 2. Wait for reboot, then test
cd ../PicoLEDControlSwift
.build/release/PicoLEDControl RED ON GREEN ON BLUE ON ALL OFF

# 3. Verify LEDs responded
# If yes  System works!
# If no  Check wiring/firmware
```

**If LEDs respond correctly, you have a working hardware control runtime.**

Not a demo. Not a toy. A real system.
