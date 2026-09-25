# Blaze Pico LED Control

## Firmware Features

The firmware supports **two modes simultaneously**:

### 1. Direct Text Mode (for screen/terminal)
Just type commands directly:
```
screen /dev/cu.usbmodem1101 115200
RED ON
GREEN ON
ALL OFF
```

### 2. BlazeTransport Mode (for daemon integration)
Sends structured packets with "BLAZ" magic header.

## Available Commands

- `RED ON` / `RED OFF`
- `GREEN ON` / `GREEN OFF`
- `YELLOW ON` / `YELLOW OFF`
- `BLUE ON` / `BLUE OFF`
- `MULTI ON` / `MULTI OFF`
- `ALL ON` / `ALL OFF`

## Agent Daemon Integration

Use the `pico_led_control.py` tool:

```bash
# Single command
python3 pico_led_control.py RED ON

# Multiple commands
python3 pico_led_control.py RED ON GREEN ON BLUE ON

# Auto-detect port
python3 pico_led_control.py ALL OFF

# Specify port
python3 pico_led_control.py -p /dev/cu.usbmodem1103 RED ON
```

### Python API

```python
from pico_led_control import send_command

send_command("RED ON")
send_command("ALL OFF")
```

## Building & Flashing

```bash
rm -rf build
mkdir build
cd build
cmake ..
make -j4

# Hold BOOTSEL and plug in Pico
cp blaze_pico.uf2 /Volumes/RP2350/
```

## Troubleshooting

### USB Serial Issues
- Unplug Pico, wait 5 seconds, plug back in
- Check port: `ls /dev/cu.usbmodem*`
- Kill any Python processes holding the port: `pkill -f python`

### Commands Not Working
- Make sure you press ENTER after typing commands
- Check that firmware shows "BLAZE PICO LED CONTROLLER READY" on boot
- Try resetting Pico (press RESET button)
