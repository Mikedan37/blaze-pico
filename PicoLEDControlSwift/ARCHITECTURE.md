# Architecture Overview

## System Components

```
┌─────────────────────────────────────────────────────────┐
│                    macOS (Host)                         │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Swift Tool (PicoLEDControl)                     │  │
│  │  - Uses BlazeTransport library                   │  │
│  │  - Builds packets                                │  │
│  │  - Sends via serial port                         │  │
│  └──────────────────────────────────────────────────┘  │
│                        │                                │
│                        │ USB Serial                    │
│                        ▼                                │
└─────────────────────────────────────────────────────────┘
                        │
                        │ USB Cable
                        │
┌─────────────────────────────────────────────────────────┐
│              Raspberry Pi Pico                         │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │  C Firmware (main.c)                            │  │
│  │  - Receives BlazeTransport packets               │  │
│  │  - Parses commands                               │  │
│  │  - Controls GPIO pins (LEDs)                     │  │
│  └──────────────────────────────────────────────────┘  │
│                        │                                │
│                        ▼                                │
│              GPIO 14-18 (LEDs)                         │
└─────────────────────────────────────────────────────────┘
```

## What Runs Where

### macOS (Swift Tool)
- **Language**: Swift
- **Purpose**: Build BlazeTransport packets and send to Pico
- **Location**: `PicoLEDControlSwift/`
- **Dependencies**: BlazeTransport Swift library, ArgumentParser

### Raspberry Pi Pico (Firmware)
- **Language**: C (with Pico SDK)
- **Purpose**: Receive packets, parse commands, control LEDs
- **Location**: `main.c`
- **Dependencies**: Pico SDK (pico_stdlib)

## Communication Flow

1. **macOS**: User runs `swift run PicoLEDControl RED ON`
2. **macOS**: Swift tool builds BlazeTransport packet:
   - Magic: "BLAZ" (4 bytes)
   - Header: 16 bytes (version, flags, IDs, payload length)
   - Payload: frameType(0) + streamID(4) + "RED ON"
3. **macOS**: Sends packet via serial port (`/dev/cu.usbmodem1101`)
4. **Pico**: C firmware receives bytes via USB serial
5. **Pico**: Detects "BLAZ" magic, parses header, extracts command
6. **Pico**: Executes command: `gpio_put(RED_PIN, 1)`
7. **Pico**: LED turns on

## Why This Architecture?

- **Swift on macOS**: Leverages BlazeTransport library, type-safe, easy integration with AgentDaemon
- **C on Pico**: Required - Pico SDK is C/C++, minimal resource usage, real-time GPIO control
- **Serial Communication**: Simple, reliable, no network stack needed

## Testing

### Test Swift Tool (macOS)
```bash
cd PicoLEDControlSwift
swift test  # Unit tests for packet format
swift build # Build executable
```

### Test Pico Firmware
```bash
# Flash firmware to Pico
cd build && cmake .. && make
cp blaze_pico.uf2 /Volumes/RP2350/

# Test via serial
screen /dev/cu.usbmodem1101 115200
# Type: RED ON
```

### Integration Test
```bash
# On macOS, send command to Pico
swift run PicoLEDControl RED ON
# LED should turn on
```
