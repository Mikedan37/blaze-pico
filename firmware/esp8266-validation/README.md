# ESP8266 validation board

**What this is:** a cheap ESP8266 board used as a second test target for the Blaze protocol. It is **not** a supported product board. It proves that the same C protocol code written for the Raspberry Pi Pico runs unchanged on a different CPU and talks byte-for-byte with the Swift host.

**What the board does:** it switches one pin, GPIO2, which drives the small **blue LED on the metal ESP-12 module** (next to the antenna). Everything around that one blink is the point: Swift encodes a command in BlazeBinary, the frame crosses USB with a CRC, and the board's C code checks it, decodes it, runs it, and answers with the same trace ID.

> **Why do commands say "RED"?** The protocol shares one command list between boards. Command 1 is the Pico's red LED. On this board, command 1 drives the blue LED, so the demo and console call it `LED ON` / `LED OFF`.

---

## 1. Run the demo (about 30 seconds)

Open a terminal in Cursor (**Ctrl+`**) and run:

```bash
cd ~/pico/blaze-pico-esp/firmware/esp8266-validation
./demo.sh
```

| Step | What you see |
|---|---|
| [1] Board | the chip and port it found |
| [2] Firmware | the build, and proof the chip runs exactly that build |
| [3] Handshake | the board's own boot lines: `SESSION`, `BLAZE_READY`, `PROTOCOL=2` |
| [4] Wire trace | one command at every layer: the command, its 11 BlazeBinary bytes, the full 40-byte frame, and the board's raw reply |
| [5] Live | the LED blinks 3 times, each with `ACK ✓` matched by trace ID |
| [6] Checks | 6 hardware checks, each ✔ or ✘ |
| verdict | `✅ WORKING` or `❌ NOT WORKING` |

Options:

```bash
./demo.sh --flash    # rebuild and flash the firmware first (good for a recording)
./demo.sh --full     # also flash old PROTOCOL=1 firmware, show the host refusing it, then restore
```

In Cursor you can also use **Terminal → Run Task → "Blaze demo: ESP8266"**.

## 2. Drive the board live (interactive console)

```bash
./console
```

It stays connected, so every command changes the board immediately and shows the bytes sent and the reply received:

```
blaze> led on          blue LED on
blaze> led off         blue LED off
blaze> status          uptime, frames accepted / rejected
blaze> list            every protocol command (read from firmware/protocol/pico_command.h)
blaze> servo_set 90    any command by name (this board replies "Unsupported")
blaze> send 99 1       a raw command number: rejected as UNKNOWN_COMMAND
blaze> corrupt         a frame with one flipped bit: rejected as BAD_CRC
blaze> version2        a frame claiming PicoCommand version 2: rejected
blaze> text PING       a plain text line
blaze> quit
```

On startup the console checks its own encoder against `firmware/tests/protocol/golden_frames.txt`, the same bytes the Swift host and the C firmware are tested against, and prints `✔ encoder matches the golden frames`.

## 3. Change what the board does

The only board-specific code is `src/main.cpp` (about 180 lines):

- `execute()`: what each command does. Command 1 sets GPIO2 here.
- `text_command()`: the plain text commands (`STATUS`, `PING`, `RED ON`, `RED OFF`, `DEVICE_INFO`).
- `LED_PIN`: the pin the LED is on (GPIO2). If your board's visible LED is elsewhere (many NodeMCU boards also have one on GPIO16), change it here.

After editing, flash and check in one step:

```bash
./demo.sh --flash
```

Do **not** edit `firmware/protocol/` or `firmware/third_party/` to change board behavior. That code is shared with the Pico and is what the demo proves unchanged.

## 4. Add a new command

Example: a `BLINK` command that blinks the LED *n* times.

1. **Give it an ID and a value range**, in the shared protocol files (these affect every board):
   - `firmware/protocol/pico_command.h`: add `#define PICO_CMD_BLINK 50   /* blink count 1-10 */` next to the others (around line 44).
   - `firmware/protocol/pico_command.c`: in `pico_command_validate()`, add
     `case PICO_CMD_BLINK: return (value >= 1 && value <= 10) ? PICO_COMMAND_OK : PICO_COMMAND_INVALID_VALUE;`
     Without this line the board **rejects** the command as `UNKNOWN_COMMAND`. That is deliberate: nothing unlisted can run.
2. **Make the board do it**: in `src/main.cpp` `execute()`, add a `case PICO_CMD_BLINK:` that blinks and then prints the `ACK TRACE:…` line (copy the `PICO_CMD_RED` case). For the Pico, the same goes in `execute_command()` in `main.c`.
3. **Let the Mac send it**: in `PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoLEDController.swift`, add `case blink = 50` to `enum CommandID` (around line 60).
4. **Test**:
   ```bash
   make -C ../tests/protocol test                  # C protocol tests (host)
   (cd ../../PicoLEDControlSwift && swift test)    # Swift host tests
   ./demo.sh --flash                               # flash and check the board
   ./console                                       # then:  blink 3
   ```

The console picks up the new command from `pico_command.h` automatically, so `blink 3` works as soon as the firmware is flashed.

**Limit to know:** a command carries one byte of value (0 to 255). A command that needs several values (for example PWM channel + frequency + duty) needs a bigger message format. That is a separate protocol change, not a new `case`.

## 5. Run the hardware tests directly

```bash
cd ../../PicoLEDControlSwift
BLAZE_HW_PORT=/dev/cu.usbserial-0001 swift test --filter ESP8266HardwareTests
```

These are skipped unless `BLAZE_HW_PORT` is set, so normal `swift test` and CI never need a board. More options (reset test, PROTOCOL=1 test) are at the top of `Tests/PicoLEDControlTests/ESP8266HardwareTests.swift`.

## Troubleshooting

| Problem | Fix |
|---|---|
| `no USB serial device found` | Unplug and replug. Use a cable that carries data. No buttons needed. |
| `could not talk to the chip … busy` | Something else has the port open (a Serial Monitor, another `./console`). Close it. |
| `could not talk to the chip` (timeout) | Unplug and replug, then run again. This board's connector can be loose. |
| LED doesn't light but checks pass | The firmware is switching GPIO2 (the board confirms each change with `R=1` / `R=0`). Look for the tiny blue LED on the metal module. If your board's LED is elsewhere, change `LED_PIN`. |
| Board resets when you connect | Normal for this board: opening the port reboots it. The host handles it. |

## Restore the board's original firmware

The original 4 MB flash was backed up and verified before anything was flashed:

```bash
.venv/bin/python -m esptool --port /dev/cu.usbserial-0001 write_flash 0 ~/pico/esp8266-backups/esp8266-40f5202d4ef1-20260925-083315.bin
```

## Files

| File | What it is |
|---|---|
| `demo.sh` | the one-command demo |
| `console` / `console.py` | the interactive console |
| `src/main.cpp` | the only ESP8266-specific code |
| `platformio.ini` | build settings; compiles the shared protocol C in place (no copies) |
| `FINDINGS.md` | host bugs this board found, and how they were fixed |

First run: `./demo.sh` installs PlatformIO and esptool into `.venv/` here (a few minutes, once).
