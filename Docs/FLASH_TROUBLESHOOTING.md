# Flash Troubleshooting

## Device in Bootloader Mode But Not Showing Up

### Check Bootloader Mode
1. **Hold BOOTSEL button**
2. **Press RESET button** (while holding BOOTSEL)
3. **Release BOOTSEL**
4. Device should appear as `/Volumes/RPI-RP2`

### If Volume Doesn't Appear

**Check 1: USB Connection**
```bash
# Check if USB device is detected
system_profiler SPUSBDataType | grep -i "raspberry\|pico"
```

**Check 2: Disk Utility**
```bash
# List all volumes
diskutil list

# Look for RPI-RP2 or similar
ls /Volumes/
```

**Check 3: Manual Mount**
```bash
# Try to find the disk
diskutil list | grep -i "disk"

# If found, try mounting manually
# (replace diskXsY with actual disk identifier)
```

### Alternative Flash Methods

**Method 1: Using picotool (if installed)**
```bash
picotool load -x build/blaze_pico.uf2
```

**Method 2: Direct copy when volume appears**
```bash
# Wait for volume to appear
while [ ! -d "/Volumes/RPI-RP2" ]; do sleep 1; done

# Copy firmware
cp build/blaze_pico.uf2 /Volumes/RPI-RP2/
sync
diskutil eject /Volumes/RPI-RP2
```

**Method 3: Using Finder**
1. Open Finder
2. Look for "RPI-RP2" drive
3. Drag `build/blaze_pico.uf2` to the drive
4. Wait for copy to complete
5. Eject drive

## After Flashing

1. **Wait 5-10 seconds** for device to reboot
2. **Check device appears**: `ls /dev/tty.usbmodem*`
3. **Verify boot output**: `screen /dev/tty.usbmodem2101 115200`
4. **Look for**: `BLAZE_READY` signal

## Expected Boot Sequence

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

## LED Boot Sequence

After flashing, you should see:
- **All 7 LEDs blink 5 times** (boot test)
- **LEDs turn off** (ready for commands)

If LEDs don't light up:
- Firmware may not have flashed correctly
- Check bootloader mode was successful
- Try re-flashing
