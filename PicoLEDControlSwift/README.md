# Pico LED Control (Swift)

**macOS Swift tool** for controlling Blaze Pico LEDs using the BlazeTransport protocol.

## Architecture

- **macOS (this tool)**: Swift executable that runs on your Mac
- **Pico (firmware)**: C firmware (`main.c`) that runs on the Raspberry Pi Pico
- **Communication**: Serial port (USB) between Mac and Pico

The Swift tool builds BlazeTransport packets and sends them to the Pico's C firmware via serial port.

## Features

- ✅ Uses BlazeTransport Swift library to build packets
- ✅ Sends via serial port (macOS IOKit)
- ✅ Auto-detects Pico USB serial port
- ✅ Command-line interface
- ✅ Testable with unit tests

## Building

```bash
cd PicoLEDControlSwift
swift build -c release
```

## Usage

### Basic Usage

```bash
# Auto-detect port and send command
swift run PicoLEDControl RED ON

# Specify port
swift run PicoLEDControl --port /dev/cu.usbmodem1103 RED ON

# Multiple commands
swift run PicoLEDControl RED ON GREEN ON BLUE ON

# Custom baud rate
swift run PicoLEDControl --baud 115200 ALL OFF
```

### After Building

```bash
.build/release/PicoLEDControl RED ON
.build/release/PicoLEDControl --port /dev/cu.usbmodem1101 ALL OFF
```

## Testing

```bash
swift test
```

Tests verify:
- Packet format matches BlazeTransport spec
- Command encoding is correct
- Magic header "BLAZ" is included
- Packet structure is valid

## Integration with AgentDaemon

This tool can be called from AgentDaemon Swift code:

```swift
import Foundation

func controlPicoLED(_ command: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [
        "run",
        "--package-path", "/path/to/PicoLEDControlSwift",
        "PicoLEDControl",
        command
    ]
    try process.run()
    process.waitUntilExit()
    
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "PicoLED", code: Int(process.terminationStatus))
    }
}
```

Or use the library directly:

```swift
import PicoLEDControl

let controller = PicoLEDController(portPath: "/dev/cu.usbmodem1101")
try controller.sendCommand("RED ON")
controller.close()
```

## Protocol Details

The tool sends BlazeTransport packets with:
- Magic header: "BLAZ" (4 bytes) - custom for Pico serial
- BlazeTransport header: 16 bytes (version, flags, connectionID, packetNumber, streamID, payloadLength)
- Payload: frameType(0) + streamID(4) + ASCII command

See `INTEGRATION_VERIFICATION.md` for complete protocol specification.
