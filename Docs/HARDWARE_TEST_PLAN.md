# Hardware Test Plan: BlazeBinary Command Path

Everything in the protocol stack is tested on the Mac. These checks need a real Pico 2 W running the new firmware, and none of them has been run yet.

## Setup

```bash
pico-build && pico-flash          # flash firmware from this branch
cd PicoLEDControlSwift && swift build -c release
pico-monitor                      # in a second terminal, to watch the Pico's output
```

## Checklist

| # | Check | How | Pass when |
|---|---|---|---|
| 1 | Firmware boots | Plug in, watch `pico-monitor` | `BOOT:*` lines appear |
| 2 | Ready handshake | Same | `SESSION:<id>` then `BLAZE_READY` |
| 3 | V1 command sent | `.build/release/PicoLEDControl RED ON` | Host log shows a 40 byte write |
| 4 | Pico decodes it | Build with `ENABLE_DEBUG_LOGS 1` | `PACKET RECEIVED TRACE:<id> SEQ:<n> CMD:1 VAL:1` with the host's trace ID |
| 5 | LED turns on | Look at the board | Red LED on |
| 6 | ACK has the right trace | `pico-monitor` | `ACK TRACE:<same id> cmdID=1 value=1` |
| 7 | STATE_CHANGE matches | Same | `STATE_CHANGE: ... R=1 ...` |
| 8 | Repeated commands | Run 20 on/off commands in a row | Every one gets an ACK, final state matches the last command |
| 9 | Batch | `DeviceManager.sendBatch` with 3 commands | 3 ACKs, all with the batch trace ID, LEDs match |
| 10 | Hot unplug | Unplug USB while the agent is running | Host reports disconnect, no crash |
| 11 | Reconnect | Plug back in | New `SESSION`, `BLAZE_READY`, host reconnects on its own |
| 12 | Reboot / session change | Send `BOOTLOADER`, reflash, or power cycle | Host sees a new session ID and fails any in-flight commands |
| 13 | Command after reconnect | `RED OFF` after 11 | ACK and LED off |
| 14 | Garbage does nothing | Send random bytes: `head -c 200 /dev/urandom > /dev/cu.usbmodem*` | No LED change, no `ACK`, only `ERROR: Rejected frame` lines if a `BLAZ` happened to appear |
| 15 | Wrong version does nothing | Send a frame whose PicoCommand version byte is 2 (Python snippet below) | `ERROR: Rejected frame: UNSUPPORTED_VERSION`, no LED change |
| 16 | Text commands still work | In `pico-monitor`, type `GREEN ON`, `SERVO 90`, `STATUS` | Same responses as before this change |
| 17 | Old firmware is refused | Flash firmware from `main` (protocol 1), run `.build/release/PicoLEDControl RED ON` | `Incompatible Pico firmware protocol (device reports protocol 1). Host requires protocol 2. Reflash the device firmware.` and the LED does not change |
| 18 | Servo timing (separate issue) | `SERVO 0`, `SERVO 180` | Servo reaches both ends without straining. Known risk: PWM math assumes 125 MHz, RP2350 defaults to 150 MHz |

### Sending a hand-made frame (checks 14 and 15)

```python
import serial, struct, zlib
def frame(version, trace, command, value, packet=1):
    cmd = struct.pack(">BQBB", version, trace, command, value)
    payload = struct.pack(">BI", 0, packet) + cmd
    covered = struct.pack(">BBIIIH", 1, 0, 1, packet, 1, len(payload)) + payload
    return b"BLAZ" + covered + struct.pack(">I", zlib.crc32(covered))

s = serial.Serial("/dev/cu.usbmodem1101", 115200, timeout=1)
s.write(frame(2, 7, 1, 1))   # version 2: must be rejected
print(s.read(300).decode(errors="ignore"))
s.write(frame(1, 7, 1, 1))   # version 1 RED ON: must execute
print(s.read(300).decode(errors="ignore"))
```

Replace the port with your own (`ls /dev/cu.usbmodem*`).
