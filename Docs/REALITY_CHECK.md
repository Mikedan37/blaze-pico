# Reality Check: What Actually Works

##  Fixed Issues

### 1. Packet Format (EXACT match)
-  Magic: "BLAZ" (4 bytes)
-  Header: 16 bytes (version, flags, connectionID, packetNumber, streamID, payloadLength)
-  Payload: frameType(0) + streamID(4) + command + null terminator
-  Matches firmware expectations exactly

### 2. Serial Buffering (CRITICAL FIX)
-  Added `tcdrain()` to force flush USB CDC buffer
-  Added 200ms wait after write
-  Prevents macOS from buffering packets

### 3. ACK Support
-  Firmware sends: `ACK:RED ON\n` after successful command
-  Swift tool reads ACK and confirms receipt
-  Shows ` (ACK received)` or ` (no ACK)` in output

### 4. Port Auto-Detection
-  Searches `/dev/cu.usbmodem*` (handles renumbering)
-  Works when macOS changes port numbers

### 5. Debug Output
-  Firmware prints: `PACKET RECEIVED` when packet arrives
-  Helps diagnose if packets are reaching Pico

##  Testing Checklist

### Step 1: Build Everything
```bash
# Build Swift tool
cd PicoLEDControlSwift
swift build -c release

# Build Pico firmware
cd ../build
cmake ..
make
cp blaze_pico.uf2 /Volumes/RP2350/
```

### Step 2: Test Direct Text Mode (Baseline)
```bash
screen /dev/cu.usbmodem1101 115200
# Type: RED ON<ENTER>
# Should see: CMD: RED ON
# LED should turn on
```

### Step 3: Test Swift Tool (The Real Test)
```bash
cd PicoLEDControlSwift
.build/release/PicoLEDControl RED ON
```

**Expected output:**
```
Using port: /dev/cu.usbmodem1101
Sending: RED ON  (ACK received)
 All commands sent and acknowledged
```

**If you see:**
- ` (no ACK)`  Packet format might be wrong, or Pico didn't receive it
- No output  Port detection failed, or Pico not connected
- Error opening port  Another process is using it

### Step 4: Verify Packet Reception
In another terminal, watch serial output:
```bash
screen /dev/cu.usbmodem1101 115200
```

When Swift tool runs, you should see:
```
PACKET RECEIVED
CMD: RED ON
ACK:RED ON
```

If you DON'T see `PACKET RECEIVED`:
- Swift tool isn't sending valid packets
- Check packet format matches exactly
- Verify "BLAZ" magic is included

##  Debugging

### Packet Format Verification

The Swift tool builds packets like this:

```swift
// 1. Magic header
var packet = Data("BLAZ".utf8)  // 4 bytes: B, L, A, Z

// 2. Header (16 bytes)
packet.append(1)  // version
packet.append(0)  // flags
packet.append(connectionID.bigEndianBytes)  // 4 bytes
packet.append(packetNumber.bigEndianBytes)  // 4 bytes
packet.append(streamID.bigEndianBytes)      // 4 bytes
packet.append(payloadLength.bigEndianBytes) // 2 bytes

// 3. Payload
packet.append(0x00)  // frameType = DATA
packet.append(streamID.bigEndianBytes)  // 4 bytes
packet.append(commandBytes)  // "RED ON"
packet.append(0x00)  // null terminator
```

### Common Failures

**"Payload too big"**
- Payload length in header doesn't match actual payload
- Check `payloadLength` calculation

**"Non-data frame ignored"**
- frameType is not 0
- Check payload[0] is 0x00

**No ACK received**
- Pico didn't receive packet
- Check serial port is correct
- Check no other process is using port
- Try unplugging/replugging Pico

**"Failed to open serial port"**
- Port doesn't exist: `ls /dev/cu.usbmodem*`
- Port in use: `lsof | grep usbmodem`
- Permissions: might need sudo (unlikely on macOS)

##  Success Criteria

 Swift tool builds without errors
 Pico firmware compiles and flashes
 Direct text mode works (`screen` + typing)
 Swift tool sends packet and receives ACK
 LED actually turns on/off

If ALL of these pass, you have a working hardware control runtime.

##  Next Level (When This Works)

1. **JSON Status Responses**: Pico sends structured status back
2. **Heartbeat Ping/Pong**: Keep connection alive
3. **Reconnect Logic**: Handle USB disconnects gracefully
4. **Multi-Command Batching**: Send multiple commands in one packet
5. **Error Reporting**: Pico reports GPIO errors back to Mac

Then you'll have a real distributed hardware control system.

Not just blinking lights.
