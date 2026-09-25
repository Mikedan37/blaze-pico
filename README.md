# Blaze Pico

Firmware for a Raspberry Pi Pico 2 W plus a Swift runtime on the Mac that drives it over USB. It speaks a compact binary protocol, keeps a persistent connection, recovers from unplugs and reboots, and traces every command from the host to the pin.

It is the hardware layer for a voice agent: you say "turn on the red light", the agent decides what to do, and this project makes the LED actually turn on.

---

## How It Fits Together

```
Voice app -> AgentDaemon -> DeviceManager -> PicoSession -> USB serial -> Pico firmware -> GPIO / PWM / servo
            (separate repo)  |________________ this repo ________________________________|
```

- **Voice app and AgentDaemon** live in a separate project (ProjectBlaze). They turn speech into a command and hand it to this library. They talk to each other over a Unix socket using BlazeBinary encoding.
- **DeviceManager** finds the Pico, owns the connection, and reconnects when it drops.
- **PicoSession** does the boot handshake, sends commands, waits for acknowledgements, and tracks device state.
- **Pico firmware** (`main.c`) parses commands and drives LEDs, a servo, and generic GPIO, PWM, and ADC pins.

---

## The Protocol

Every Mac to Pico command is a BlazeBinary message, carried in a BlazeTransport packet, inside a small serial envelope. Each layer has one job:

| Layer | Job | Where |
|---|---|---|
| **BlazeBinary** | Serializes the command. Same bytes from Swift and from C. | Swift: BlazeBinary package. C: `firmware/third_party/blazebinary` |
| **BlazeTransport packet** | Packet metadata: 16 byte header plus a DATA frame with a sequence number | Swift: `PacketEncoder`. C: `firmware/third_party/blazetransport` |
| **BLAZ serial envelope** | Finds frame boundaries in the USB byte stream and checks integrity | `firmware/protocol/blaze_serial.c`, `PicoWire.swift` |
| **USB CDC** | Moves the bytes | |

One command on the wire (40 bytes), servo to 90 degrees:

```
42 4c 41 5a                                          "BLAZ"            serial envelope: sync marker
01 00 00000001 00000001 00000001 0010                BlazeTransport    version 1, flags, connection, packet 1, stream 1, payload length 16
00 00000001                                          DATA frame        frame type 0, sequence 1
01 0123456789abcdef 28 5a                            BlazeBinary       PicoCommandV1: version 1, trace ID, command 40 (servo), value 90
32571c33                                             CRC-32            serial envelope: integrity over header + payload
```

`PicoCommandV1` is four BlazeBinary fields in order: `version UInt8`, `traceID UInt64`, `command UInt8`, `value UInt8`. The version is checked first, so a future version is rejected instead of being misread. A batch of commands is sent as several frames in one USB write, all carrying the batch's trace ID.

BlazeBinary's own framing (`BlazeBinaryFrame`) is not used here: BlazeTransport and the serial envelope already frame the message, and nesting a third frame would only add bytes.

**Why BlazeBinary on a microcontroller?**

- **One serialization format across Swift and C.** The Mac and the Pico agree byte for byte, and golden byte tests in both languages prove it (`firmware/tests/protocol/golden_frames.txt`).
- **Bounded, deterministic parsing.** The C side reads fixed fields into fixed buffers. No heap allocation, no JSON library, no string parsing.
- **Portable.** The C codec has no Pico SDK dependency. The same code can decode the same messages on an ESP32 or STM32 over a different transport.
- **Explicit schema evolution.** The message version is the first field, and the firmware rejects versions it does not know.
- **Traceability.** The trace ID in every command comes back in the Pico's `ACK TRACE:<id>`, so the host can match each reply to the command that caused it.

Speed is not the reason. Round trip time is dominated by USB timing and waiting for the acknowledgement, not by message size.

**How the firmware handles bad input**

Nothing touches the hardware until the whole frame has been checked: CRC, header, DATA frame, BlazeBinary payload, message version, command ID, and value range. Anything that fails is rejected with an `ERROR:` line and nothing runs. After a bad frame the parser skips ahead to the next `BLAZ` marker and never treats binary bytes as a text command. If a truncated frame swallowed the start of the next one, the parser rescans the swallowed bytes and still finds it. The parser is plain C with no Pico SDK dependency, so all of this is tested on the Mac (`make -C firmware/tests/protocol test`), including a fuzz run.

The firmware also accepts plain text commands (`RED ON`, `SERVO 90`, `GPIO SET 2 1`, `STATUS`) so you can drive it by hand from a serial monitor. The voice app and AgentDaemon talk to each other in BlazeBinary as well, over a Unix socket.

---

## What It Does

**Firmware (C, Pico SDK)**
- LED control: red, green, yellow, blue, and an RGB LED with 0 to 100 brightness per channel
- Servo control: angle 0 to 180, center, sweep
- Generic pins: `GPIO SET/GET/MODE`, `PWM SET/STOP`, `ADC READ`, with reserved pins protected
- Boot handshake: announces `SESSION:<id>` and `BLAZE_READY` once USB is up
- Heartbeat every 2 seconds, and a numbered `STATE_CHANGE` after every change
- `BOOTLOADER` command to reboot into flash mode without pressing the button

**Host (Swift, macOS)**
- Persistent USB serial session with automatic reconnect
- Reboot detection: a new session ID resets sequencing and fails in-flight commands instead of leaving them hanging
- One command in flight at a time, duplicate and out-of-order state updates dropped
- Command batching over a short window
- Trace IDs, structured JSONL logs, os_log and signposts
- `BlazeMetrics`: reads the logs and reports p50, p95, p99 latency per stage

**Tooling**
- `pico-cli`: build, flash, watch and reflash on save, serial monitor

---

## Measuring Performance

Numbers depend on your board, cable, and Mac, so measure your own setup instead of trusting a README.

**1. Hardware benchmark** (needs a Pico connected and running this firmware):

```bash
cd Benchmarks
./run_benchmarks.sh
```

This measures, against the real device:
- Single command round trip: send, ACK from the Pico, then the `STATE_CHANGE` that confirms the pin changed
- Batch latency
- Sustained throughput and a burst stress test
- Host memory use

Results are saved to `Benchmarks/benchmark_results_<timestamp>.txt`.

**2. Live telemetry** from normal use:

```bash
cd PicoLEDControlSwift
.build/release/BlazeMetrics --minutes 60 --verbose
```

Every command is logged with its trace ID and timestamps at each stage, so `BlazeMetrics` can break latency down by stage and flag failures.

Note: `PicoLEDControl --full-pipeline` simulates the voice and LLM stages with fixed delays. Use it to check the wiring, not to measure performance.

---

## Quick Start

**Hardware:** Raspberry Pi Pico 2 W (RP2350). LEDs, RGB LED, and servo pin assignments are in `main.c`.

### Build and flash the firmware

```bash
# Install the CLI tools once
cd pico-cli && ./install-pico-cli.sh && cd ..

pico-build          # uses PICO_SDK_PATH, defaults to ~/pico-sdk
pico-flash          # copies the .uf2 to the Pico in BOOTSEL mode
pico-monitor        # watch serial output
```

### Build and run the host tools

```bash
cd PicoLEDControlSwift
swift build -c release

.build/release/PicoLEDControl RED ON
.build/release/PicoLEDControl --query-state
```

### Tests

```bash
# Host library: wire format golden bytes, telemetry, chaos tests
cd PicoLEDControlSwift && swift test

# Firmware protocol stack, built for the Mac: golden frames, stream robustness, fuzz
make -C firmware/tests/protocol test
```

Everything runs without hardware except the chaos tests (command flood, hot unplug, rapid reconnects), which skip unless a Pico is connected. The on-device checklist is in [Docs/HARDWARE_TEST_PLAN.md](Docs/HARDWARE_TEST_PLAN.md).

---

## Project Structure

```
blaze-pico/
├── main.c                 # Pico firmware
├── CMakeLists.txt         # Firmware build
├── PicoLEDControlSwift/   # Swift host library, CLI, metrics tool, tests
├── Benchmarks/            # Hardware benchmark suite and past results
├── pico-cli/              # Build / flash / monitor tools
├── firmware/
│   ├── protocol/          # Serial parser + PicoCommandV1 (portable C, runs on the Pico and in tests)
│   ├── third_party/       # Vendored BlazeBinary C and BlazeTransport C decoder
│   ├── tests/protocol/    # Host tests and golden frames for the protocol stack
│   └── bin/, tests/       # Prebuilt .uf2 files and test firmware
├── Scripts/               # Test and flash scripts
└── Docs/                  # Design notes and debugging write-ups
```

Good places to start in `Docs/`: [SYSTEM_ARCHITECTURE.md](Docs/SYSTEM_ARCHITECTURE.md), [PICO_COMMAND_INTERFACE.md](Docs/PICO_COMMAND_INTERFACE.md), [USB_CDC_BOOT_PATTERN.md](Docs/USB_CDC_BOOT_PATTERN.md).

---

## Known Limitations

- PWM timing assumes a 125 MHz system clock. The RP2350 defaults to 150 MHz, so servo and PWM timing need verifying on the Pico 2.
- Some generic PWM pins share a hardware PWM unit with the servo and RGB LED.
- Replies from the Pico (`ACK`, `STATE_CHANGE`, `HEARTBEAT`) are still text lines, not BlazeBinary.
- Manages one Pico at a time.
