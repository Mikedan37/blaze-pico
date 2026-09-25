# Blaze Pico Integration Verification

## Protocol Overview

The Pico firmware uses a **custom dual-mode protocol** that extends BlazeTransport:

1. **Direct Text Mode**: For screen/terminal use
   - Just type commands: `RED ON<ENTER>`
   - Processed line-by-line

2. **BlazeTransport Mode**: For daemon integration
   - Uses "BLAZ" magic header (4 bytes) to distinguish from text
   - Followed by standard BlazeTransport packet format

## Packet Format

### BlazeTransport Packet (with "BLAZ" magic)

```
[BLAZ] + [16-byte header] + [payload]
```

### Header Format (16 bytes, big-endian)
```
byte 0:   version (UInt8) = 1
byte 1:   flags (UInt8) = 0
bytes 2-5:   connectionID (UInt32, big-endian)
bytes 6-9:   packetNumber (UInt32, big-endian)
bytes 10-13: streamID (UInt32, big-endian)
bytes 14-15: payloadLength (UInt16, big-endian)
```

### Payload Format (for DATA frames)
```
byte 0:   frameType (UInt8) = 0 (DATA)
bytes 1-4: streamID (UInt32, big-endian) - redundant with header
bytes 5+:  ASCII command string (e.g., "RED ON")
```

## Component Verification

###  Firmware (`main.c`)
- **Status**: CORRECT
- Supports both direct text and BlazeTransport modes
- Uses state machine to detect "BLAZ" magic
- Parses 16-byte header correctly
- Extracts command from payload[5+]
- Yields CPU time to USB stack (prevents starvation)

###  Python Tool (`pico_led_control.py`)
- **Status**: CORRECT
- Builds packets with "BLAZ" magic + header + payload
- Header format matches BlazeTransport spec
- Payload format: frameType(0) + streamID(4) + command
- Auto-detects Pico port
- Can be used as CLI tool or Python module

###  Original Script (`send_led.py`)
- **Status**: CORRECT (after fix)
- Now includes "BLAZ" magic header
- Packet format matches firmware expectations

###  AgentDaemon Integration
- **Status**: NEEDS INTEGRATION TOOL
- AgentDaemon has IntentRouter for LED commands
- But no direct serial/Pico communication yet
- **Solution**: Use `pico_led_control.py` as bridge

## Integration Points

### For AgentDaemon

The AgentDaemon can control Pico LEDs by:

1. **Option A**: Call Python tool as subprocess
   ```swift
   let process = Process()
   process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
   process.arguments = ["/path/to/pico_led_control.py", "RED", "ON"]
   try process.run()
   ```

2. **Option B**: Import Python tool as module
   ```python
   # In AgentDaemon Swift  Python bridge
   from pico_led_control import send_command
   send_command("RED ON")
   ```

3. **Option C**: Direct Swift implementation
   - Use BlazeTransport Swift library
   - Build packets matching the format
   - Send via serial port

## Command Reference

### Available Commands
- `RED ON` / `RED OFF`
- `GREEN ON` / `GREEN OFF`
- `YELLOW ON` / `YELLOW OFF`
- `BLUE ON` / `BLUE OFF`
- `MULTI ON` / `MULTI OFF`
- `ALL ON` / `ALL OFF`

### GPIO Mapping
- Red  GPIO 14
- Green  GPIO 15
- Yellow  GPIO 16
- Blue  GPIO 17
- Multicolor  GPIO 18

## Testing Checklist

- [x] Firmware compiles and flashes
- [x] Direct text mode works (screen)
- [x] BlazeTransport mode works (Python tool)
- [ ] AgentDaemon integration tested
- [ ] Multiple commands in sequence
- [ ] Error handling (invalid commands, port issues)

## Notes

- The "BLAZ" magic is a **custom addition** for Pico, not part of standard BlazeTransport
- This allows the firmware to distinguish between text commands and binary packets
- Standard BlazeTransport (UDP) doesn't need this, but serial does
- The firmware correctly handles both modes simultaneously
