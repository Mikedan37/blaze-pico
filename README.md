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

Commands travel as small binary frames instead of text or JSON:

```
"BLAZ"  | 16 byte header | payload (up to 64 bytes)
                           [0][trace ID, 8 bytes][command][value]
```

A single command such as "green on" is 31 bytes on the wire. Several commands can be batched into one frame: `[0][trace ID][count][cmd, val][cmd, val]...`

This is its own frame format, separate from the BlazeBinary encoding the voice app and AgentDaemon use between themselves.

**Why binary?**

The device side needs parsing to be simple, bounded, and deterministic, so the protocol uses compact fixed-layout frames. The point is predictable behavior on the microcontroller, not raw speed: round-trip time is dominated by USB timing and waiting for the acknowledgement, not by message size.

- **Simple, safe parsing on the microcontroller.** The firmware reads fixed byte offsets into a fixed 64 byte buffer. No JSON library, no heap allocation, no string handling, and nothing a malformed message can make grow.
- **Resync after garbage.** The `BLAZ` magic bytes mark where a frame starts, so the parser can find its place again after noise, and oversized frames are drained instead of being misread as commands.
- **Traceability for free.** The 8 byte trace ID rides inside every frame and comes back in the Pico's acknowledgement, so the host can match each reply to the exact command that caused it.
- **Batching.** Multiple commands fit in one frame and one USB write.
- **Smaller messages.** A binary command is about half the size of the JSON equivalent. Nice to have, but secondary over USB.

The firmware also accepts plain text commands (`RED ON`, `SERVO 90`, `STATUS`) so you can drive it by hand from a serial monitor.

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
cd PicoLEDControlSwift
swift test
```

Protocol and telemetry tests run anywhere. The chaos tests (command flood, hot unplug, rapid reconnects) need a Pico connected.

---

## Project Structure

```
blaze-pico/
├── main.c                 # Pico firmware
├── CMakeLists.txt         # Firmware build
├── PicoLEDControlSwift/   # Swift host library, CLI, metrics tool, tests
├── Benchmarks/            # Hardware benchmark suite and past results
├── pico-cli/              # Build / flash / monitor tools
├── firmware/              # Prebuilt .uf2 files and test firmware
├── Scripts/               # Test and flash scripts
└── Docs/                  # Design notes and debugging write-ups
```

Good places to start in `Docs/`: [SYSTEM_ARCHITECTURE.md](Docs/SYSTEM_ARCHITECTURE.md), [PICO_COMMAND_INTERFACE.md](Docs/PICO_COMMAND_INTERFACE.md), [USB_CDC_BOOT_PATTERN.md](Docs/USB_CDC_BOOT_PATTERN.md).

---

## Known Limitations

- Binary frames have no checksum. USB already checks for transmission errors, but a checksum would catch host-side bugs.
- PWM timing assumes a 125 MHz system clock. The RP2350 defaults to 150 MHz, so servo and PWM timing need verifying on the Pico 2.
- Some generic PWM pins share a hardware PWM unit with the servo and RGB LED.
- Manages one Pico at a time.
