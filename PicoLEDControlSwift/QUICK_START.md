# Quick Start

## What This Is

**macOS Swift tool** that runs on your Mac and sends commands to the **Raspberry Pi Pico** (which runs C firmware).

```
macOS (Swift) ──USB Serial──> Pico (C firmware) ──GPIO──> LEDs
```

## Build & Run

```bash
cd PicoLEDControlSwift

# Build
swift build -c release

# Run (auto-detects Pico port)
.build/release/PicoLEDControl RED ON

# Or specify port
.build/release/PicoLEDControl --port /dev/cu.usbmodem1101 ALL OFF
```

## Use in AgentDaemon

```swift
import Foundation

func controlPicoLED(_ command: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [
        "run",
        "--package-path", "/Users/mdanylchuk/pico/blaze-pico/PicoLEDControlSwift",
        "PicoLEDControl",
        command
    ]
    try process.run()
    process.waitUntilExit()
    
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "PicoLED", code: Int(process.terminationStatus))
    }
}

// Usage
try controlPicoLED("RED ON")
```

## Or Use Library Directly

```swift
import PicoLEDControlLib

let controller = PicoLEDController(portPath: "/dev/cu.usbmodem1101")
try controller.sendCommand("RED ON")
controller.close()
```

## Commands

- `RED ON` / `RED OFF`
- `GREEN ON` / `GREEN OFF`
- `YELLOW ON` / `YELLOW OFF`
- `BLUE ON` / `BLUE OFF`
- `MULTI ON` / `MULTI OFF`
- `ALL ON` / `ALL OFF`

## Architecture

- **macOS**: Swift tool builds BlazeTransport packets
- **Pico**: C firmware receives packets and controls GPIO
- **Communication**: USB serial port

See `ARCHITECTURE.md` for details.
