# Blaze-Pico Hardware SDK Reference

Technical documentation for the blaze-pico hardware control system: firmware protocol specification, Swift SDK API reference, and integration guide.

**Target audience:** Developers integrating RP2350-based hardware into macOS software via the `PicoLEDControlLib` Swift package.

**Platform:** macOS 14+ / Swift 5.9+ / Raspberry Pi Pico 2 (RP2350)

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Firmware Text Protocol Specification](#2-firmware-text-protocol-specification)
3. [Device Introspection and Capability Model](#3-device-introspection-and-capability-model)
4. [Swift SDK Structure](#4-swift-sdk-structure)
5. [Swift Hardware API Reference](#5-swift-hardware-api-reference)
6. [Practical Swift Usage Examples](#6-practical-swift-usage-examples)
7. [Error Handling Model](#7-error-handling-model)
8. [Safety and Hardware Guarantees](#8-safety-and-hardware-guarantees)
9. [Extending the System](#9-extending-the-system)
10. [Design Philosophy](#10-design-philosophy)

---

## 1. System Overview

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  macOS Host                                                             │
│                                                                         │
│  ┌──────────────┐    ┌─────────────────┐    ┌────────────────────────┐  │
│  │  Your Code   │───▶│  Hardware SDK    │───▶│  DeviceManager (actor) │  │
│  │              │    │  Hardware        │    │  Persistent session    │  │
│  │  board.pin(5)│    │  HardwareDevice  │    │  Keepalive ping        │  │
│  │  .setHigh()  │    │  HardwarePin     │    │  Auto-reconnect        │  │
│  └──────────────┘    └─────────────────┘    └──────────┬─────────────┘  │
│                                                        │                │
│                                              ┌─────────▼──────────┐     │
│                                              │  PicoSession       │     │
│                                              │  Binary + Text     │     │
│                                              │  ACK correlation    │     │
│                                              │  Event reader       │     │
│                                              └─────────┬──────────┘     │
│                                                        │                │
│                                              ┌─────────▼──────────┐     │
│                                              │  SerialPort        │     │
│                                              │  POSIX termios     │     │
│                                              │  115200 baud       │     │
│                                              │  Non-blocking I/O  │     │
│                                              └─────────┬──────────┘     │
└────────────────────────────────────────────────────────│────────────────┘
                                                        │
                                              USB CDC Serial
                                                        │
┌────────────────────────────────────────────────────────│────────────────┐
│  Raspberry Pi Pico 2 (RP2350)                         │                │
│                                              ┌────────▼───────────┐    │
│                                              │  Firmware (main.c) │    │
│                                              │  Dual-mode parser  │    │
│                                              │  Text + Binary     │    │
│                                              └────────┬───────────┘    │
│                                                       │                │
│  ┌────────────────────────────────────────────────────┘                │
│  │                                                                     │
│  ▼                                                                     │
│  GPIO 0–29    PWM slices 0–7    ADC channels 0–3 (GP26–29)            │
│                                                                         │
│  Reserved: GPIO 14–21 (LEDs + Servo)                                   │
│  Available: GPIO 0–13, 22–29                                           │
└─────────────────────────────────────────────────────────────────────────┘
```

### Transport Layer

Communication uses **USB CDC** (Communications Device Class) serial at **115200 baud**. The Pico 2 presents as a virtual serial port at `/dev/cu.usbmodem*` on macOS.

The firmware accepts two protocol modes on the same serial channel:

| Protocol | Trigger | Use case |
|----------|---------|----------|
| **Binary (BlazeTransport)** | `BLAZ` magic prefix | LED commands, servo, state queries — latency-critical, ACK-traced |
| **Text** | Any ASCII line terminated by `\n` or `\r` | GPIO, PWM, ADC — variable-argument, human-debuggable |

The text protocol is used by the Hardware SDK for generic pin operations. The binary protocol is used for built-in LED/servo commands where sub-millisecond latency matters.

### Command Execution Model

All commands are serialized through the `PicoSession` transport layer:

- **Single writer lock** prevents concurrent USB writes (USB CDC is not thread-safe).
- **One command at a time** — a new command cannot be sent until the previous one receives a response or times out.
- **Text commands** are serialized by an internal `DispatchQueue`. A pending response handler is registered *before* the write to prevent race conditions.
- **Response timeout** is 2000ms for text commands (configurable per call).

### Session Lifecycle

The `DeviceManager` actor maintains a persistent serial session for the process lifetime:

1. **Warm start** — on daemon startup, scans `/dev/cu.usbmodem*`, opens the first Pico port, waits for `BLAZE_READY` signal.
2. **Keepalive** — pings every 30 seconds to prevent USB sleep.
3. **Hard failure recovery** — on write/read failure, invalidates the session, scans for the device, and reconnects automatically.
4. **Background monitor** — polls `/dev/` every 2 seconds when disconnected; auto-connects on device appearance.
5. **Bootloader transition** — suppresses reconnect during intentional reboot for firmware flashing.

The session is never reopened per-command. Once established, all subsequent calls reuse the persistent session with zero connection overhead.

---

## 2. Firmware Text Protocol Specification

All text commands are sent as ASCII strings terminated by a newline (`\n`). Responses are ASCII strings terminated by `\n`. All communication is case-sensitive at the wire level (the Swift SDK uppercases before sending).

### GPIO SET

Set a GPIO pin to a digital high or low value. Automatically initializes the pin as an output if not already initialized.

**Syntax:**
```
GPIO SET <pin> <value>
```

| Parameter | Type | Range | Description |
|-----------|------|-------|-------------|
| `pin` | integer | 0–29 | GPIO pin number |
| `value` | integer | 0 or 1 | 0 = low, 1 = high |

**Success response:**
```
OK
```

**Error responses:**
```
ERROR: pin 5 out of range (0-29)
ERROR: pin 14 is reserved
ERROR: pin 5 has active PWM, stop PWM first
ERROR: usage: GPIO SET <pin> <0|1>
```

**Example:**
```
→  GPIO SET 5 1
←  OK

→  GPIO SET 14 1
←  ERROR: pin 14 is reserved

→  GPIO SET 9 1
←  ERROR: pin 9 has active PWM, stop PWM first
```

**Behavior:** The firmware calls `gpio_set_dir(pin, GPIO_OUT)` followed by `gpio_put(pin, value)`. If the pin was previously configured as an input, it is silently reconfigured as an output.

---

### GPIO GET

Read the current digital state of a GPIO pin. Initializes the pin if not already initialized.

**Syntax:**
```
GPIO GET <pin>
```

| Parameter | Type | Range | Description |
|-----------|------|-------|-------------|
| `pin` | integer | 0–29 | GPIO pin number |

**Success response:**
```
GPIO_READ: pin=<pin> value=<0|1>
```

**Error responses:**
```
ERROR: pin 30 out of range (0-29)
ERROR: pin 14 is reserved
ERROR: usage: GPIO GET <pin>
```

**Example:**
```
→  GPIO GET 5
←  GPIO_READ: pin=5 value=1

→  GPIO GET 26
←  GPIO_READ: pin=26 value=0
```

---

### GPIO MODE

Configure pin direction and pull resistor. Does not read or write the pin value.

**Syntax:**
```
GPIO MODE <pin> <mode>
```

| Parameter | Type | Values | Description |
|-----------|------|--------|-------------|
| `pin` | integer | 0–29 | GPIO pin number |
| `mode` | string | `OUT`, `IN`, `IN_PU`, `IN_PD` | Direction and pull configuration |

| Mode | Direction | Pull resistor |
|------|-----------|---------------|
| `OUT` | Output | Disabled |
| `IN` | Input | Disabled (floating) |
| `IN_PU` | Input | Pull-up enabled |
| `IN_PD` | Input | Pull-down enabled |

**Success response:**
```
OK
```

**Error responses:**
```
ERROR: pin 14 is reserved
ERROR: pin 5 has active PWM, stop PWM first
ERROR: unknown mode 'PULLUP' (use OUT|IN|IN_PU|IN_PD)
ERROR: usage: GPIO MODE <pin> <OUT|IN|IN_PU|IN_PD>
```

**Example:**
```
→  GPIO MODE 5 IN_PU
←  OK

→  GPIO MODE 5 PULLUP
←  ERROR: unknown mode 'PULLUP' (use OUT|IN|IN_PU|IN_PD)
```

---

### PWM SET

Enable PWM output on a GPIO pin with the specified frequency and duty cycle.

**Syntax:**
```
PWM SET <pin> <frequency> <duty>
```

| Parameter | Type | Range | Description |
|-----------|------|-------|-------------|
| `pin` | integer | 0–29 | GPIO pin number |
| `frequency` | integer | 1–62,500,000 | Frequency in Hz |
| `duty` | integer | 0–100 | Duty cycle percentage |

**Success response:**
```
OK
```

**Error responses:**
```
ERROR: pin 14 is reserved
ERROR: frequency 0 out of range (1-62500000 Hz)
ERROR: duty 150 out of range (0-100%)
ERROR: pin 5 shares PWM slice with active pin 4
ERROR: usage: PWM SET <pin> <freq_hz> <duty_percent>
```

**Example:**
```
→  PWM SET 5 1000 50
←  OK

→  PWM SET 4 2000 75
←  ERROR: pin 4 shares PWM slice with active pin 5
```

**Behavior:**

1. The firmware switches the pin function to `GPIO_FUNC_PWM`.
2. Calculates the clock divider and wrap value from the system clock (125 MHz) and requested frequency.
3. Sets the PWM level proportional to the duty cycle.
4. Enables the PWM slice.
5. Marks the pin in the `pwm_active_mask` bitmask.

**PWM slice constraint:** On the RP2350, each PWM slice controls two pins (pin N and pin N^1, i.e., pins 0/1, 2/3, 4/5, etc.). Reconfiguring a slice's divider and wrap affects both pins. The firmware rejects `PWM SET` if the sibling pin already has active PWM to prevent unintended frequency changes.

---

### PWM STOP

Disable PWM on a pin and revert it to standard GPIO mode.

**Syntax:**
```
PWM STOP <pin>
```

| Parameter | Type | Range | Description |
|-----------|------|-------|-------------|
| `pin` | integer | 0–29 | GPIO pin number |

**Success response:**
```
OK
```

**Error responses:**
```
ERROR: pin 14 is reserved
ERROR: pin 5 has no active PWM
ERROR: usage: PWM STOP <pin>
```

**Example:**
```
→  PWM STOP 5
←  OK
```

**Behavior:** Reverts the pin to GPIO via `gpio_init(pin)`, clears the `pwm_active_mask` bit. Only disables the PWM slice if the sibling pin is not also using PWM on the same slice.

---

### ADC READ

Read the raw analog value from an ADC-capable pin. The RP2350 has a 12-bit SAR ADC with four channels mapped to GPIO 26–29.

**Syntax:**
```
ADC READ <pin>
```

| Parameter | Type | Range | Description |
|-----------|------|-------|-------------|
| `pin` | integer | 26–29 | ADC-capable GPIO pin |

**Success response:**
```
ADC_READ: pin=<pin> value=<raw>
```

The `value` field is a 12-bit unsigned integer (0–4095). The default reference voltage is 3.3V, giving a resolution of approximately 0.8 mV per count.

**Error responses:**
```
ERROR: pin 5 not an ADC pin (use 26-29)
ERROR: pin 28 is reserved
ERROR: usage: ADC READ <pin>
```

**Example:**
```
→  ADC READ 26
←  ADC_READ: pin=26 value=2048

→  ADC READ 5
←  ERROR: pin 5 not an ADC pin (use 26-29)
```

**Behavior:** On first ADC read, the firmware calls `adc_init()` to initialize the ADC peripheral. Each subsequent read calls `adc_gpio_init(pin)` and `adc_select_input(pin - 26)` to select the channel, then `adc_read()` for a single sample.

---

### PING

Connection verification handshake.

**Syntax:**
```
PING
```

**Response:**
```
PONG
```

---

### STATUS

Health check probe. Returns device status including readiness, uptime, firmware version, and session identity.

**Syntax:**
```
STATUS
```

**Response:**
```
STATUS: ready=1 session=A3F2B1C0 uptime=123456 seq=42 fw=1.0 proto=1 model=pico2_w
```

---

### BOOT / BOOTLOADER

Reboot into USB mass storage bootloader for firmware flashing. The device does not return a response after the reboot message.

**Syntax:**
```
BOOT
```

**Response (before reboot):**
```
BOOT: Entering bootloader mode...
```

The USB serial connection will drop after this command.

---

### Unknown Commands

Any unrecognized command produces:

```
UNKNOWN: <original command text>
```

---

### Response Format Summary

All firmware responses are newline-terminated ASCII (`\n`). The response categories are:

| Prefix | Meaning |
|--------|---------|
| `OK` | Command succeeded (exact match, not prefix) |
| `GPIO_READ: pin=N value=V` | Digital read result |
| `ADC_READ: pin=N value=V` | Analog read result |
| `ERROR: <message>` | Command failed with reason |
| `UNKNOWN: <text>` | Unrecognized command |
| `PONG` | Ping response |
| `STATUS: ...` | Device status |
| `STATE: ...` | GPIO state snapshot |
| `STATE_CHANGE: ...` | State change event (binary protocol) |
| `ACK TRACE:...` | Command acknowledgment (binary protocol) |
| `HEARTBEAT: ...` | Periodic health pulse |

---

## 3. Device Introspection and Capability Model

### Pin Capability Map

The RP2350 has 30 GPIO pins (GP0–GP29). Each pin has hardware capabilities determined by the silicon and firmware configuration:

| Capability | Pins | Notes |
|------------|------|-------|
| **Digital I/O** | GP0–GP29 | All pins support digital read/write |
| **PWM** | GP0–GP29 | All pins have hardware PWM via 8 paired slices |
| **ADC** | GP26–GP29 | 4-channel 12-bit SAR ADC |
| **Reserved** | GP14–GP21 | Wired to LEDs (14–20) and servo (21) by the blaze-pico board |

### Reserved Pin Map

```
GPIO 14  →  Red LED (single color)
GPIO 15  →  Green LED (single color)
GPIO 16  →  Yellow LED (single color)
GPIO 17  →  Blue LED (single color)
GPIO 18  →  RGB LED — Red channel
GPIO 19  →  RGB LED — Green channel
GPIO 20  →  RGB LED — Blue channel
GPIO 21  →  Servo (PWM at 50 Hz)
```

Reserved pins are enforced at two levels:

1. **Firmware:** The `is_pin_reserved()` function checks a compile-time bitmask. Generic GPIO/PWM/ADC commands targeting reserved pins return `ERROR: pin N is reserved`.
2. **SDK:** The `HardwarePin.isReserved` property checks the same set client-side, allowing callers to filter before sending a command.

### SDK Capability Properties

The `HardwareDevice` class exposes filtered pin collections based on capabilities:

| Property | Returns | Filter logic |
|----------|---------|--------------|
| `device.pins` | All 30 pins (GP0–GP29) | No filter |
| `device.availablePins` | Non-reserved pins | `!pin.isReserved` |
| `device.adcPins` | ADC-capable pins (GP26–GP29) | `pin.supportsADC` |
| `device.pwmPins` | PWM-capable, non-reserved pins | `pin.supportsPWM` |

Each `HardwarePin` instance exposes individual capability flags:

| Property | Type | Description |
|----------|------|-------------|
| `pin.supportsPWM` | `Bool` | True if pin supports PWM and is not reserved |
| `pin.supportsADC` | `Bool` | True if pin is in the ADC range (GP26–GP29) |
| `pin.isReserved` | `Bool` | True if pin is in the reserved set (GP14–GP21) |
| `pin.isValid` | `Bool` | True if pin number is in range 0–29 |

### Why Introspection Matters

Without introspection, a caller must know the RP2350 pin map to avoid invalid commands. With introspection:

```swift
// Safe — capability check before action
if pin.supportsPWM {
    try await pin.pwm(frequency: 1000, duty: 50)
}

// Iterative — scan all ADC pins without hardcoding
for pin in board.adcPins {
    let v = try await pin.analog.readVoltage()
}
```

This is particularly valuable for LLM-driven planners that generate hardware commands from natural language. The planner can query capabilities at runtime instead of relying on hardcoded knowledge.

---

## 4. Swift SDK Structure

### Object Hierarchy

```
Hardware                          (namespace — device discovery)
  └── HardwareDevice              (a connected board)
        ├── pin(_ number: Int)    (factory — returns HardwarePin)
        ├── pins                  (all 30 GPIO pins)
        ├── availablePins         (non-reserved)
        ├── adcPins               (GP26–29)
        ├── pwmPins               (non-reserved PWM)
        ├── leds                  (LEDCluster — named LED access)
        ├── setServo(angle:)      (built-in servo)
        ├── queryState()          (device state snapshot)
        └── enterBootloader()     (firmware flash mode)

HardwarePin                       (a single GPIO pin)
  ├── setHigh() / setLow() / set(_:)   (digital output)
  ├── read()                            (digital input)
  ├── setMode(_:)                       (direction + pull)
  ├── pwm(frequency:duty:)              (PWM output)
  ├── stopPWM()                         (disable PWM)
  ├── analog                            (AnalogPin sub-interface)
  │     ├── read()                      (raw 12-bit value)
  │     └── readVoltage()               (voltage conversion)
  ├── supportsPWM                       (capability flag)
  ├── supportsADC                       (capability flag)
  ├── isReserved                        (reservation flag)
  └── isValid                           (range check)

LEDCluster                        (named access to built-in LEDs)
  ├── red / green / yellow / blue       (single-color LED objects)
  ├── multiRed / multiGreen / multiBlue (RGB LED channel objects)
  ├── allOff()                          (all LEDs off)
  └── allOn()                           (all LEDs on)

LEDCluster.LED                    (a single LED via binary protocol)
  ├── on()                              (turn on)
  ├── off()                             (turn off)
  └── isOn()                            (query state from cache)
```

### Type Summary

| Type | Kind | Sendable | Description |
|------|------|----------|-------------|
| `Hardware` | `enum` (namespace) | — | Static device discovery methods |
| `HardwareDevice` | `final class` | `@unchecked Sendable` | A connected Pico board |
| `HardwarePin` | `final class` | `@unchecked Sendable` | A single GPIO pin |
| `HardwarePin.PinMode` | `enum` | `Sendable` | Pin direction/pull configuration |
| `AnalogPin` | `struct` | `Sendable` | ADC read sub-interface |
| `LEDCluster` | `struct` | `Sendable` | Named LED access |
| `LEDCluster.LED` | `struct` | `Sendable` | Single LED via binary protocol |
| `HardwareError` | `enum` | — | Typed error cases |

### Relationship to Existing Types

The SDK is a facade over the existing transport layer. It does not replace `DeviceManager`, `PicoSession`, or `DeviceManagerCommandHelper` — it wraps them.

```
Hardware SDK (new)          Transport Layer (existing, unchanged)
─────────────────           ────────────────────────────────────
Hardware.first()        →   DeviceManager.shared.warmStart()
HardwareDevice          →   DeviceManager.shared.getSession()
HardwarePin.setHigh()   →   PicoSession.sendTextCommand("GPIO SET N 1")
HardwarePin.analog.read()→  PicoSession.sendTextCommand("ADC READ N")
board.leds.allOff()     →   DeviceManagerCommandHelper.sendCommand("ALL OFF")
```

---

## 5. Swift Hardware API Reference

### Hardware

Top-level namespace for device discovery. No instances — all methods are static.

---

#### `Hardware.first() async throws -> HardwareDevice`

Returns the first (primary) connected Pico device. Initializes the persistent serial session if not already open.

- **Returns:** `HardwareDevice` for the primary device.
- **Throws:** `HardwareError.noDeviceFound` if no Pico is connected. Other errors if the serial session cannot be established.
- **Async:** Yes — performs USB serial port scan and connection handshake.
- **Thread safety:** Safe to call from any context. Internally calls the `DeviceManager` actor.

---

#### `Hardware.devices() async throws -> [HardwareDevice]`

Discovers all connected Pico devices. Returns one `HardwareDevice` per detected `/dev/cu.usbmodem*` port.

- **Returns:** Array of `HardwareDevice`. May be empty if no devices are connected.
- **Throws:** If the serial session cannot be established.
- **Async:** Yes.

---

#### `Hardware.initialize() async throws`

Initializes the hardware subsystem without returning a device. Opens the persistent serial session and starts the keepalive ping. Call once at daemon startup.

- **Throws:** If no device is found or connection fails.
- **Async:** Yes.

---

### HardwareDevice

Represents a connected Pico board. Created by `Hardware.first()` or `Hardware.devices()`.

---

#### `device.pin(_ number: Int) -> HardwarePin`

Returns a `HardwarePin` for the given GPIO number. Pin objects are cached per device — calling `pin(5)` twice returns the same instance.

- **Parameter `number`:** GPIO pin number (0–29). Out-of-range numbers return a pin object that will throw `HardwareError.invalidPin` on any operation.
- **Returns:** `HardwarePin` — synchronous, no I/O.
- **Thread safety:** Thread-safe (internal lock on pin cache).

---

#### `device.pins -> [HardwarePin]`

All 30 GPIO pins (GP0–GP29). Computed on access.

---

#### `device.availablePins -> [HardwarePin]`

Non-reserved pins available for general-purpose I/O. Excludes GP14–GP21.

---

#### `device.adcPins -> [HardwarePin]`

Pins capable of analog-to-digital conversion (GP26–GP29).

---

#### `device.pwmPins -> [HardwarePin]`

Pins capable of general-purpose PWM output. Excludes reserved pins.

---

#### `device.leds -> LEDCluster`

Named access to the board's built-in LEDs. See `LEDCluster` below.

---

#### `device.setServo(angle: Int) async throws`

Set the built-in servo to an angle.

- **Parameter `angle`:** 0–180 degrees. Clamped to valid range.
- **Throws:** `HardwareError.timeout` if no ACK received.
- **Async:** Yes — sends binary servo command and waits for ACK.

---

#### `device.servoAngle() async throws -> Int?`

Returns the last known servo angle from the session event cache, or nil if no servo command has been sent.

---

#### `device.queryState() async throws -> [String: Bool]?`

Returns the current GPIO state of all built-in LEDs as a dictionary. Keys: `"R"`, `"G"`, `"Y"`, `"B"`, `"MR"`, `"MG"`, `"MB"`. Values: `true` = on, `false` = off.

Uses cached state from the event reader when available. Only sends a `QUERY_STATE` command if no cached state exists.

---

#### `device.sendCommand(_ command: String) async throws -> (success: Bool, state: [String: Bool]?)`

Send a raw text command via the binary protocol (e.g., `"RED ON"`, `"ALL OFF"`). Provided for backward compatibility and LLM text-mode integration.

---

#### `device.enterBootloader() async throws -> Bool`

Reboot the device into USB mass storage bootloader for firmware flashing. Returns true if ACK was received before disconnect. The serial connection will drop after this call.

---

#### `device.isReady -> Bool` (async property)

True if the device session is connected and ready for commands. Performs a lightweight session check (no I/O).

---

### HardwarePin

Represents a single GPIO pin on a device. Created by `HardwareDevice.pin(_:)`.

---

#### `pin.number -> Int`

The GPIO pin number (0–29).

---

#### `pin.setHigh() async throws`

Drive the pin to logic high (3.3V). Equivalent to `pin.set(true)`.

Sends `GPIO SET <pin> 1` to the firmware. Auto-configures the pin as an output.

- **Throws:** `HardwareError.invalidPin` if pin is out of range. `HardwareError.firmware` if the firmware rejects the command (reserved pin, active PWM). `HardwareError.timeout` if no response within 2 seconds.

---

#### `pin.setLow() async throws`

Drive the pin to logic low (0V). Equivalent to `pin.set(false)`.

Sends `GPIO SET <pin> 0` to the firmware.

- **Throws:** Same as `setHigh()`.

---

#### `pin.set(_ value: Bool) async throws`

Drive the pin to the specified digital value.

- **Parameter `value`:** `true` = high (3.3V), `false` = low (0V).
- **Throws:** Same as `setHigh()`.

---

#### `pin.read() async throws -> Bool`

Read the current digital state of the pin.

Sends `GPIO GET <pin>` and parses the `GPIO_READ:` response.

- **Returns:** `true` if pin is high, `false` if low.
- **Throws:** `HardwareError.invalidPin`, `HardwareError.firmware`, `HardwareError.timeout`, `HardwareError.malformedResponse`.

---

#### `pin.setMode(_ mode: PinMode) async throws`

Configure pin direction and pull resistor without reading or writing the pin value.

Sends `GPIO MODE <pin> <mode>` to the firmware.

- **Parameter `mode`:** One of `.output`, `.input`, `.inputPullUp`, `.inputPullDown`.
- **Throws:** `HardwareError.invalidPin`, `HardwareError.firmware`, `HardwareError.timeout`.

---

#### `pin.pwm(frequency: Int, duty: Int) async throws`

Start PWM output on this pin.

Sends `PWM SET <pin> <frequency> <duty>` to the firmware.

- **Parameter `frequency`:** Frequency in Hz. Valid range: 1–62,500,000.
- **Parameter `duty`:** Duty cycle percentage. Valid range: 0–100.
- **Throws:** `HardwareError.unsupportedCapability("PWM")` if `pin.supportsPWM` is false. `HardwareError.firmware` if firmware rejects (reserved pin, slice conflict). `HardwareError.timeout`.

---

#### `pin.stopPWM() async throws`

Disable PWM on this pin and revert to standard GPIO mode.

Sends `PWM STOP <pin>` to the firmware.

- **Throws:** `HardwareError.firmware` if no active PWM on this pin. `HardwareError.timeout`.

---

#### `pin.analog -> AnalogPin`

Returns the `AnalogPin` sub-interface for analog reads. This property is always available regardless of pin capabilities. Operations on `AnalogPin` throw `HardwareError.unsupportedCapability("ADC")` if the pin is not ADC-capable.

---

#### `pin.supportsPWM -> Bool`

True if this pin supports general-purpose PWM output. Returns `false` for reserved pins (GP14–GP21) even though they have hardware PWM capability, because the firmware rejects generic PWM commands on reserved pins.

---

#### `pin.supportsADC -> Bool`

True if this pin is ADC-capable (GP26–GP29).

---

#### `pin.isReserved -> Bool`

True if this pin is in the reserved set (GP14–GP21: LEDs and servo). Reserved pins can only be controlled via the binary LED/servo protocol, not via generic GPIO/PWM/ADC text commands.

---

#### `pin.isValid -> Bool`

True if the pin number is in the valid GPIO range (0–29).

---

### AnalogPin

ADC sub-interface accessed via `pin.analog`. Provides raw and voltage-converted analog reads.

---

#### `analogPin.read() async throws -> Int`

Read the raw 12-bit ADC value.

Sends `ADC READ <pin>` and parses the `ADC_READ:` response.

- **Returns:** Integer in the range 0–4095.
- **Throws:** `HardwareError.unsupportedCapability("ADC")` if the pin is not GP26–GP29. `HardwareError.firmware`, `HardwareError.timeout`, `HardwareError.malformedResponse`.

---

#### `analogPin.readVoltage(referenceVoltage: Double = 3.3) async throws -> Double`

Read the analog value converted to voltage.

- **Parameter `referenceVoltage`:** ADC reference voltage in volts. Default is 3.3V (the Pico 2 VREF).
- **Returns:** Voltage as a `Double`. Range: 0.0 to `referenceVoltage`.
- **Throws:** Same as `read()`.
- **Formula:** `voltage = (rawValue / 4095.0) * referenceVoltage`

---

### LEDCluster

Named access to the board's built-in LEDs. Accessed via `device.leds`.

LED pins are reserved — they cannot be controlled via generic GPIO text commands (`GPIO SET 14 1` returns `ERROR: pin 14 is reserved`). The `LEDCluster` routes all operations through the binary command protocol instead.

| Property | GPIO | Binary command | Description |
|----------|------|----------------|-------------|
| `leds.red` | GP14 | `RED ON/OFF` | Red single-color LED |
| `leds.green` | GP15 | `GREEN ON/OFF` | Green single-color LED |
| `leds.yellow` | GP16 | `YELLOW ON/OFF` | Yellow single-color LED |
| `leds.blue` | GP17 | `BLUE ON/OFF` | Blue single-color LED |
| `leds.multiRed` | GP18 | `MULTIRED ON/OFF` | RGB LED — red channel |
| `leds.multiGreen` | GP19 | `MULTIGREEN ON/OFF` | RGB LED — green channel |
| `leds.multiBlue` | GP20 | `MULTIBLUE ON/OFF` | RGB LED — blue channel |

Each LED property returns an `LED` struct with three methods:

#### `led.on() async throws`

Turn this LED on via the binary protocol.

#### `led.off() async throws`

Turn this LED off via the binary protocol.

#### `led.isOn() async throws -> Bool?`

Check the current state of this LED from the device state cache. Returns `nil` if state is unavailable.

#### `leds.allOff() async throws`

Turn all LEDs off via the binary protocol.

#### `leds.allOn() async throws`

Turn all LEDs on via the binary protocol.

---

### HardwarePin.PinMode

Enum representing pin direction and pull resistor configuration.

| Case | Wire value | Direction | Pull |
|------|------------|-----------|------|
| `.output` | `OUT` | Output | Disabled |
| `.input` | `IN` | Input | Disabled (floating) |
| `.inputPullUp` | `IN_PU` | Input | Pull-up (~50kΩ to 3.3V) |
| `.inputPullDown` | `IN_PD` | Input | Pull-down (~50kΩ to GND) |

---

## 6. Practical Swift Usage Examples

### Toggle a Digital Pin

```swift
let board = try await Hardware.first()

// Drive GP5 high
try await board.pin(5).setHigh()

// Wait 1 second
try await Task.sleep(nanoseconds: 1_000_000_000)

// Drive GP5 low
try await board.pin(5).setLow()
```

### Read a Digital Input with Pull-Up

```swift
let board = try await Hardware.first()
let button = board.pin(2)

// Configure as input with internal pull-up
try await button.setMode(.inputPullUp)

// Read the pin state (low = pressed for active-low button)
let pressed = try await button.read() == false
print("Button pressed: \(pressed)")
```

### Read Analog Sensor Voltage

```swift
let board = try await Hardware.first()

// Read raw 12-bit ADC value
let raw = try await board.pin(26).analog.read()
print("Raw ADC: \(raw)")  // 0–4095

// Read as voltage (3.3V reference)
let voltage = try await board.pin(26).analog.readVoltage()
print("Voltage: \(String(format: "%.3f", voltage))V")  // 0.000–3.300
```

### Generate a PWM Signal

```swift
let board = try await Hardware.first()

// 1 kHz PWM at 50% duty cycle on GP5
try await board.pin(5).pwm(frequency: 1000, duty: 50)

// Change to 25% duty cycle
try await board.pin(5).pwm(frequency: 1000, duty: 25)

// Stop PWM and revert to GPIO
try await board.pin(5).stopPWM()
```

### Scan All ADC Pins

```swift
let board = try await Hardware.first()

for pin in board.adcPins {
    let voltage = try await pin.analog.readVoltage()
    print("GP\(pin.number): \(String(format: "%.3f", voltage))V")
}
```

Output:
```
GP26: 1.652V
GP27: 0.003V
GP28: 3.298V
GP29: 1.100V
```

### Capability-Aware Safe PWM Assignment

```swift
let board = try await Hardware.first()

let targetPins = [3, 5, 14, 26]

for pinNumber in targetPins {
    let pin = board.pin(pinNumber)

    guard pin.isValid else {
        print("GP\(pinNumber): invalid pin number")
        continue
    }

    guard pin.supportsPWM else {
        if pin.isReserved {
            print("GP\(pinNumber): reserved (LED/servo) — skipping")
        } else {
            print("GP\(pinNumber): PWM not available")
        }
        continue
    }

    try await pin.pwm(frequency: 1000, duty: 50)
    print("GP\(pinNumber): PWM active at 1 kHz, 50%")
}
```

Output:
```
GP3: PWM active at 1 kHz, 50%
GP5: PWM active at 1 kHz, 50%
GP14: reserved (LED/servo) — skipping
GP26: PWM active at 1 kHz, 50%
```

### LED Control via Named Cluster

```swift
let board = try await Hardware.first()

// Named LED access — no magic numbers
try await board.leds.red.on()
try await board.leds.green.off()

// RGB LED
try await board.leds.multiRed.on()
try await board.leds.multiBlue.on()

// Check state
if let isOn = try await board.leds.red.isOn() {
    print("Red LED is \(isOn ? "on" : "off")")
}

// Bulk off
try await board.leds.allOff()
```

### Multi-Device (Future)

```swift
let boards = try await Hardware.devices()

for board in boards {
    print("Device: \(board.id)")
    try await board.pin(0).setHigh()
}
```

---

## 7. Error Handling Model

### Error Sources

Errors can originate at two levels:

1. **SDK-side** (before any I/O): Invalid pin numbers, unsupported capabilities.
2. **Firmware-side** (after command is sent): Reserved pin violations, PWM slice conflicts, malformed arguments.

### HardwareError Enum

All SDK errors are typed as `HardwareError`, which conforms to `Error` and `LocalizedError`.

| Case | When | Example message |
|------|------|-----------------|
| `.invalidPin(Int)` | Pin number outside 0–29 | `"Pin 35 is outside the valid GPIO range (0–29)"` |
| `.unsupportedCapability(String, pin: Int)` | Operation not supported by pin | `"Pin 5 does not support ADC"` |
| `.timeout(String, pin: Int)` | No firmware response within 2 seconds | `"Timeout waiting for GPIO SET response on pin 5"` |
| `.firmware(String, pin: Int)` | Firmware returned `ERROR:` | `"Firmware error on pin 14: ERROR: pin 14 is reserved"` |
| `.malformedResponse(String, pin: Int)` | Response could not be parsed | `"Malformed response for pin 5: GPIO_READ: garbage"` |
| `.noDeviceFound` | No Pico detected during discovery | `"No hardware device found"` |

### Error Handling Pattern

```swift
do {
    try await board.pin(5).pwm(frequency: 1000, duty: 50)
} catch let error as HardwareError {
    switch error {
    case .unsupportedCapability(let cap, let pin):
        print("Pin \(pin) doesn't support \(cap)")
    case .firmware(let msg, let pin):
        print("Firmware rejected pin \(pin): \(msg)")
    case .timeout(let op, let pin):
        print("\(op) timed out on pin \(pin)")
    default:
        print("Hardware error: \(error.localizedDescription)")
    }
}
```

### Firmware Error Responses

Firmware errors are returned as ASCII strings prefixed with `ERROR:`. The SDK converts these into `HardwareError.firmware` cases. Common firmware errors:

| Error message | Cause |
|---------------|-------|
| `ERROR: pin N out of range (0-29)` | Pin number outside valid GPIO range |
| `ERROR: pin N is reserved` | Pin is in the reserved set (GP14–GP21) |
| `ERROR: pin N has active PWM, stop PWM first` | GPIO SET/MODE on a pin with active PWM |
| `ERROR: pin N shares PWM slice with active pin M` | PWM slice conflict |
| `ERROR: pin N has no active PWM` | PWM STOP on a pin without active PWM |
| `ERROR: pin N not an ADC pin (use 26-29)` | ADC READ on a non-ADC pin |
| `ERROR: frequency N out of range (1-62500000 Hz)` | PWM frequency out of bounds |
| `ERROR: duty N out of range (0-100%)` | PWM duty cycle out of bounds |

### Timeout Behavior

If the firmware does not respond within 2000ms (default), the SDK throws `HardwareError.timeout`. This can happen if:

- The USB serial connection was lost mid-command.
- The firmware is busy or has crashed.
- A previous command's response was misrouted.

The `DeviceManager` will detect the connection loss via the event reader and trigger automatic reconnection in the background.

---

## 8. Safety and Hardware Guarantees

### Reserved Pin Protection

GPIO pins 14–21 are reserved by the blaze-pico board for LEDs and servo. Both the firmware and SDK enforce this:

- **Firmware:** `is_pin_reserved()` checks a compile-time bitmask before executing any generic GPIO/PWM/ADC command. Reserved pins return `ERROR: pin N is reserved`.
- **SDK:** `HardwarePin.isReserved` lets callers check before sending a command. `HardwarePin.supportsPWM` returns `false` for reserved pins.

Reserved pins can still be controlled via the binary LED protocol (`board.leds.red.on()`) and servo protocol (`board.setServo(angle: 90)`).

### PWM Slice Conflict Prevention

The RP2350 has 8 PWM slices, each controlling a pair of pins (N and N^1). Reconfiguring a slice's frequency and wrap value affects both pins. The firmware prevents conflicts:

- `PWM SET` on pin N is rejected if pin N^1 already has active PWM (different frequency would break the sibling).
- `PWM STOP` on pin N only disables the slice if the sibling is not also using it.

### GPIO Blocked While PWM Active

Attempting `GPIO SET` or `GPIO MODE` on a pin with active PWM is rejected by the firmware:

```
ERROR: pin 5 has active PWM, stop PWM first
```

This prevents accidentally overriding a PWM configuration. Call `pin.stopPWM()` first.

### Serialized Command Execution

All commands to a device are serialized through a single writer lock in `PicoSession`. This guarantees:

- No two commands can write to the USB serial port concurrently (USB CDC is not thread-safe).
- Response matching is unambiguous — each response corresponds to exactly one pending command.
- No protocol desync from interleaved writes.

### USB Disconnect Recovery

If the USB connection drops (cable unplugged, device reset, kernel USB stall):

1. The `PicoSession` event reader detects the failure (read error or heartbeat timeout).
2. The session is invalidated — all pending operations are failed.
3. `DeviceManager` clears the persistent session and starts scanning for the device.
4. On reconnection, `DeviceManager` queries the device state to resynchronize.
5. Subsequent SDK calls succeed transparently once the device is reconnected.

During disconnection, SDK calls throw errors immediately rather than blocking. The background monitor polls every 2 seconds until the device reappears.

---

## 9. Extending the System

### Adding a New Hardware Command

To add a new command to the system, three layers need changes.

**Example: Adding `I2C READ <address> <register>`**

#### Step 1: Firmware Command Handler (main.c)

Add a new text command parser in the `exec()` function:

```c
else if(!strncmp(cmd, "I2C ", 4)) {
    char *sub = cmd + 4;
    while(*sub == ' ') sub++;

    if(!strncmp(sub, "READ ", 5)) {
        int addr = -1, reg = -1;
        if(sscanf(sub + 5, "%d %d", &addr, &reg) == 2) {
            if(addr < 0 || addr > 127) {
                printf("ERROR: I2C address %d out of range (0-127)\n", addr);
            } else {
                uint8_t data;
                int result = i2c_read_register(addr, reg, &data);
                if(result < 0) {
                    printf("ERROR: I2C read failed (addr=%d reg=%d)\n", addr, reg);
                } else {
                    printf("I2C_READ: addr=%d reg=%d value=%d\n", addr, reg, data);
                }
            }
            fflush(stdout);
        } else {
            printf("ERROR: usage: I2C READ <address> <register>\n");
            fflush(stdout);
        }
    }
}
```

Link `hardware_i2c` in `CMakeLists.txt`:

```cmake
target_link_libraries(blaze_pico pico_stdlib hardware_pwm hardware_adc hardware_i2c)
```

#### Step 2: Swift SDK Wrapper (HardwareDevice.swift)

Add an I2C read method to `HardwareDevice`:

```swift
public func i2cRead(address: Int, register: Int) async throws -> Int {
    let session = try await manager.getSession()
    let cmd = "I2C READ \(address) \(register)"
    let response = try await session.sendTextCommand(
        cmd, responsePrefix: "I2C_READ:", timeoutMs: 2000
    )
    guard let resp = response else {
        throw HardwareError.timeout("I2C READ", pin: 0)
    }
    if resp.hasPrefix("ERROR:") {
        throw HardwareError.firmware(resp, pin: 0)
    }
    guard let range = resp.range(of: "value="),
          let val = Int(String(resp[range.upperBound...])
              .trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw HardwareError.malformedResponse(resp, pin: 0)
    }
    return val
}
```

#### Step 3: Usage

```swift
let board = try await Hardware.first()
let temperature = try await board.i2cRead(address: 0x48, register: 0x00)
print("Temperature register: \(temperature)")
```

### Adding a New Capability Flag

To expose a new capability (e.g., I2C support on specific pins):

1. Add a static set to `HardwarePin`:
   ```swift
   public static let i2cPins: Set<Int> = [4, 5]  // GP4=SDA, GP5=SCL
   ```
2. Add a capability property:
   ```swift
   public var supportsI2C: Bool { Self.i2cPins.contains(number) && !isReserved }
   ```
3. Add a filtered collection to `HardwareDevice`:
   ```swift
   public var i2cPins: [HardwarePin] { pins.filter { $0.supportsI2C } }
   ```

---

## 10. Design Philosophy

### Object-Oriented Hardware SDK

The SDK models hardware as objects — devices contain pins, pins have capabilities — rather than exposing flat procedural functions. This provides:

- **Discoverability** — IDE autocomplete shows all operations available on a pin.
- **Composability** — pins can be passed to functions, stored in collections, filtered by capability.
- **Readability** — `board.pin(5).setHigh()` communicates intent; `gpioSet(pin: 5, value: true)` communicates mechanism.

### Transport-Agnostic

The SDK is decoupled from the transport layer. `HardwarePin` operations produce text commands (`GPIO SET 5 1`) that are sent through whatever transport `PicoSession` provides. The same object model could work over:

- USB CDC serial (current)
- TCP/IP (networked Pico W)
- Bluetooth (Pico W BLE)
- Mock transport (unit testing)

The pin object does not know or care how the command reaches the firmware.

### Device-Introspectable

Every pin exposes its capabilities as queryable properties. This means:

- **LLM planners** can enumerate capabilities at runtime instead of relying on hardcoded knowledge.
- **UI generators** can build control panels automatically from the pin list.
- **Safety checks** happen before commands are sent, not after they fail.

### Safe by Default

Invalid operations are rejected at the earliest possible layer:

1. **SDK** rejects invalid pin numbers and unsupported capabilities before any I/O.
2. **Firmware** rejects reserved pins, PWM conflicts, and out-of-range parameters.
3. **Transport** serializes all writes to prevent protocol corruption.
4. **Session** recovers automatically from USB disconnects.

The firmware is the authority for hardware safety. The SDK enforces what it can statically (pin ranges, capability flags) but defers to firmware for dynamic constraints (PWM slice conflicts, active PWM on GPIO pins).

### Pin Caching

Pin objects are cached per device. Calling `board.pin(5)` returns the same `HardwarePin` instance every time, avoiding unnecessary closure allocations. Pins are lightweight — they hold a pin number and a session reference, no mutable state.

---

*Generated from blaze-pico firmware (main.c) and PicoLEDControlLib Swift package. Source of truth for command syntax is the firmware; source of truth for API surface is the Swift source.*
