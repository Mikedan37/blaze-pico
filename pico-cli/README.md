# Pico CLI Toolkit

Professional developer CLI tools for Raspberry Pi Pico W2 firmware development.

## Installation

```bash
cd pico-cli
./install-pico-cli.sh
```

This installs all commands to `/usr/local/bin` and makes them available globally.

## Commands

### `pico-build`

Builds the firmware from source.

```bash
pico-build
```

**What it does:**
- Cleans old build directory
- Runs `cmake ..`
- Runs `make -j4`
- Verifies UF2 file was created

**Output:**
```
✓ BUILD SUCCESS
  UF2 file: /path/to/build/blaze_pico.uf2
  Size: 123 KB
```

---

### `pico-wait`

Waits for Pico to be mounted in BOOTSEL mode.

```bash
pico-wait
```

**What it does:**
- Continuously checks `/Volumes` for `RP2350` or `RPI-RP2`
- Waits up to 60 seconds
- Exits when Pico is detected

**When to use:**
- After manually putting Pico into BOOTSEL mode
- Before flashing firmware

**Output:**
```
✓ PICO DETECTED
  Mount point: /Volumes/RP2350
```

---

### `pico-flash`

Flashes firmware to Pico.

```bash
pico-flash
```

**What it does:**
- Locates newest UF2 file in `build/` directory
- Waits for Pico mount (calls `pico-wait` internally)
- Copies UF2 file to mount point
- Runs `sync` to ensure write completes
- Verifies file was copied

**Output:**
```
✓ FLASH COMPLETE
  Firmware flashed to: /Volumes/RP2350
  Pico will reboot automatically
```

---

### `pico-monitor`

Opens serial monitor for Pico.

```bash
pico-monitor
```

**What it does:**
- Auto-detects serial device (`/dev/cu.usbmodem*`)
- Chooses newest device if multiple found
- Launches `screen` at 115200 baud

**To exit screen:**
- Press `CTRL+A`, then `K`, then `Y`

**Output:**
```
Serial device: /dev/cu.usbmodem1101
Opening serial monitor...
```

---

### `pico-all`

Complete workflow: build → flash → monitor.

```bash
pico-all
```

**What it does:**
1. Builds firmware (`pico-build`)
2. Prompts you to hold BOOTSEL
3. Waits for Pico mount (`pico-wait`)
4. Flashes firmware (`pico-flash`)
5. Waits 3 seconds for reboot
6. Opens serial monitor (`pico-monitor`)

**This replaces your entire manual workflow.**

**Output:**
```
[1/4] Building firmware...
✓ BUILD SUCCESS

[2/4] Waiting for Pico in BOOTSEL mode...
⚠ HOLD BOOTSEL NOW
✓ PICO DETECTED

[3/4] Flashing firmware...
✓ FLASH COMPLETE

[4/4] Waiting for reboot...
Opening serial monitor...
```

## Usage Examples

### Quick Development Cycle

```bash
# Make changes to main.c
# Then run:
pico-all

# This will:
# - Build firmware
# - Wait for you to hold BOOTSEL
# - Flash automatically
# - Open serial monitor
```

### Manual Workflow

```bash
# Build only
pico-build

# Later, flash when ready
pico-wait  # Hold BOOTSEL now
pico-flash

# Open monitor separately
pico-monitor
```

### Just Monitor

```bash
# If Pico is already running
pico-monitor
```

## Error Handling

All commands:
- ✅ Never crash if Pico is not connected
- ✅ Provide helpful error messages
- ✅ Exit with proper error codes
- ✅ Handle edge cases (multiple ports, different mount names)

## Requirements

- **macOS** (uses `/Volumes` mount detection)
- **cmake** (for building firmware)
- **make** (for building firmware)
- **screen** (for serial monitoring)
  - Install: `brew install screen`

## Troubleshooting

### "NO UF2 FOUND"
- Run `pico-build` first to build firmware

### "NO SERIAL DEVICE FOUND"
- Make sure Pico is connected via USB
- Make sure Pico is NOT in BOOTSEL mode
- Check: `ls /dev/cu.usbmodem*`

### "NO PICO DETECTED"
- Make sure to hold BOOTSEL button
- Plug in USB while holding BOOTSEL
- Keep holding for 1-2 seconds
- Check: `ls /Volumes/`

### "SCREEN NOT FOUND"
- Install screen: `brew install screen`

## Project Structure

```
pico-cli/
├── pico-build          # Build firmware
├── pico-wait           # Wait for BOOTSEL mount
├── pico-flash          # Flash firmware
├── pico-monitor        # Serial monitor
├── pico-all            # Complete workflow
├── install-pico-cli.sh # Installation script
└── README.md           # This file
```

## Notes

- All scripts are bash/zsh compatible
- Scripts use colored output for better visibility
- Scripts include defensive error handling
- Scripts never crash if devices are missing
- Scripts handle multiple serial ports gracefully

## Advanced Usage

### Custom Build Directory

Scripts assume project structure:
```
blaze-pico/
├── main.c
├── CMakeLists.txt
├── build/          (created by pico-build)
└── pico-cli/       (this directory)
```

If your structure differs, modify the `PROJECT_ROOT` variable in each script.

### Multiple Picos

If you have multiple Picos connected:
- `pico-wait` will detect the first one that mounts
- `pico-monitor` will use the newest serial device
- You can manually specify device: `screen /dev/cu.usbmodem1101 115200`

## Integration with Other Tools

These CLI tools can be integrated into:
- **CI/CD pipelines** (build and flash automatically)
- **File watchers** (auto-rebuild on save)
- **IDE extensions** (one-click flash)
- **VoiceAgentController** (hardware control UI)
