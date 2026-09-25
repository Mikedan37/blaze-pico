# Flash Status

## Current Status

**Firmware**:  Built successfully (80K)
**Device**:  Not detected

## To Flash Firmware

### Option 1: Bootloader Mode (Recommended)
1. **Connect Pico via USB**
2. **Hold BOOTSEL button**
3. **Press RESET button** (while holding BOOTSEL)
4. **Release BOOTSEL**
5. Device should appear as `/Volumes/RPI-RP2`
6. Run: `cp build/blaze_pico.uf2 /Volumes/RPI-RP2/ && sync && diskutil eject /Volumes/RPI-RP2`

### Option 2: Using picotool (if installed)
```bash
picotool load -x build/blaze_pico.uf2
```

## After Flashing

1. **Wait 5-10 seconds** for device to reboot
2. **Check device appears**: `ls /dev/tty.usbmodem*`
3. **Test serial output**: `screen /dev/tty.usbmodem2101 115200`
4. **Look for**: `BLAZE_READY` signal
5. **Run benchmarks**: `cd Benchmarks && ./run_benchmarks.sh`

## What Changed in Firmware

 **Added 2-second delay** after `stdio_init_all()` for USB CDC reliability
 **Boot print order**: SESSION  STATE  BLAZE_READY
 **Session UUID** generation for reboot detection
 **Sequence numbers** in all state responses

## Expected Boot Output

```
BOOT:GPIO_INIT
BOOT:GPIO_OK
BOOT:USB_INIT
BOOT_TS:...
READY_TS:...
SESSION:xxxx
STATE: seq=0 R=0 G=0 Y=0 B=0 MR=0 MG=0 MB=0
BLAZE_READY
```

Once device is connected and flashed, the benchmark suite will run successfully.
