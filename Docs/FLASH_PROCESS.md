# Pico Flash Process - Working Method

## CRITICAL: ARM Toolchain Setup

**DO NOT USE HOMEBREW ARM TOOLCHAIN** - It lacks newlib and will fail!

The correct ARM toolchain is located at:
```
~/arm-toolchain/arm-gnu-toolchain-13.2.Rel1-darwin-arm64-arm-none-eabi/
```

This is configured in `~/.zshrc` but must be explicitly exported in build scripts.

## Build Process (Step 1)

```bash
cd /Users/mdanylchuk/pico/blaze-pico

# CRITICAL: Set PATH to use correct ARM toolchain
export PATH="$HOME/arm-toolchain/arm-gnu-toolchain-13.2.Rel1-darwin-arm64-arm-none-eabi/bin:$PATH"
export PICO_SDK_PATH=/Users/mdanylchuk/pico/pico-sdk

# Clean and build
rm -rf build
mkdir build
cd build
cmake ..
make -j4
```

**Expected output:** 
- `blaze_pico.uf2` in `build/` directory (~89 KB)
- Build should complete without errors

## Flash Process (Step 2)

**Put Pico in Bootloader Mode:**
1. Hold BOOTSEL button on Pico
2. Plug USB cable into Mac (keep holding BOOTSEL)
3. Release BOOTSEL after 1 second
4. Pico W2 (RP2350) should mount as `/Volumes/RP2350`
   - Note: Firmware is built for RP2040, but RP2350 bootloader accepts RP2040 UF2s (backward compatible)

**Copy UF2 file:**
```bash
cd /Users/mdanylchuk/pico/blaze-pico
cp build/blaze_pico.uf2 /Volumes/RP2350/
sync
```

The Pico will automatically reboot after copying the UF2 file.

## Monitor Serial Output (Step 3)

Wait 2-3 seconds for Pico to reboot, then:

```bash
screen /dev/cu.usbmodem* 115200
```

**To exit screen:**
- Press `Ctrl+A`
- Press `K`
- Press `Y` to confirm

## Expected Boot Sequence

After flashing, you should see:
```
BOOT:GPIO_INIT
BOOT:GPIO_TEST          ← LEDs flash 3 times here (all 7 LEDs)
BOOT:GPIO_OK
BOOT:USB_WAIT
BOOT:USB_OK
BOOT_TS:<timestamp>
READY_TS:<timestamp>
BLAZE_READY
STATE_CHANGE: R=0 G=0 Y=0 B=0 MR=0 MG=0 MB=0
```

Then every 2 seconds:
```
HEARTBEAT: UPTIME:<ms> READY:1 R=0 G=0 Y=0 B=0 MR=0 MG=0 MB=0
```

## Complete One-Liner (All Steps)

```bash
cd /Users/mdanylchuk/pico/blaze-pico && \
export PATH="$HOME/arm-toolchain/arm-gnu-toolchain-13.2.Rel1-darwin-arm64-arm-none-eabi/bin:$PATH" && \
export PICO_SDK_PATH=/Users/mdanylchuk/pico/pico-sdk && \
rm -rf build && mkdir build && cd build && cmake .. && make -j4 && \
cd .. && cp build/blaze_pico.uf2 /Volumes/RP2350/ && sync && \
echo " Flashed! Wait 3s then: screen /dev/cu.usbmodem* 115200"
```

## Using the Build Script

The `pico-cli/pico-build` script should work, but it checks for toolchain in `/tmp/arm-gnu-toolchain-*`. 
To make it work, ensure PATH is set before running:

```bash
export PATH="$HOME/arm-toolchain/arm-gnu-toolchain-13.2.Rel1-darwin-arm64-arm-none-eabi/bin:$PATH"
export PICO_SDK_PATH=/Users/mdanylchuk/pico/pico-sdk
./pico-cli/pico-build
```

## Troubleshooting

**Build fails with "cannot read spec file 'nosys.specs'":**
-  Wrong ARM toolchain in PATH (Homebrew version)
-  Solution: Use `~/arm-toolchain/arm-gnu-toolchain-13.2.Rel1-darwin-arm64-arm-none-eabi/bin`

**Build fails with "cannot find -lg" or "cannot find -lc":**
-  Missing newlib in toolchain
-  Solution: Use the official ARM toolchain from `~/arm-toolchain/`

**Pico not mounting as /Volumes/RP2350:**
- Make sure BOOTSEL is held BEFORE plugging in USB
- Try unplugging and repeating the process
- Check: `ls /Volumes/ | grep -i rp`

**No serial output after flash:**
- Wait 3-5 seconds after flash for reboot
- Check device: `ls /dev/cu.usbmodem*`
- Try: `./pico-cli/pico-monitor` instead of screen

## Key Points

1. **ARM Toolchain Location:** `~/arm-toolchain/arm-gnu-toolchain-13.2.Rel1-darwin-arm64-arm-none-eabi/`
2. **This toolchain includes newlib** (unlike Homebrew version)
3. **Always export PATH before building** - it's in `.zshrc` but not always loaded
4. **Build script location:** `pico-cli/pico-build` (but check PATH first)
5. **Flash method:** Simple `cp` to `/Volumes/RP2350/` works perfectly
6. **Monitor:** Use `screen /dev/cu.usbmodem* 115200`

## Current Firmware Features

 RGB multicolor LED support (GPIO 24, 25, 26)
- Command IDs: 6=MULTI_RED, 7=MULTI_GREEN, 8=MULTI_BLUE, 5=MULTI (all RGB)

 Enhanced feedback:
- Automatic STATE_CHANGE after every command
- Heartbeat includes full GPIO state every 2 seconds
- Error events for invalid commands, GPIO mismatches, not ready

 Boot LED flash sequence:
- All 7 LEDs flash 3 times on boot (150ms ON, 150ms OFF)

 All LED channels tracked:
- RED (GPIO 14), GREEN (GPIO 15), YELLOW (GPIO 16), BLUE (GPIO 17)
- MULTI_RED (GPIO 24), MULTI_GREEN (GPIO 25), MULTI_BLUE (GPIO 26)
