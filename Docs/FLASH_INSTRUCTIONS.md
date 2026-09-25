# Flash and Test Instructions

## Quick Flash

```bash
./flash_and_test.sh
```

## Manual Flash Steps

### 1. Put Device in Bootloader Mode
- Hold **BOOTSEL** button
- Press **RESET** button (while holding BOOTSEL)
- Release **BOOTSEL**
- Device should appear as `/Volumes/RPI-RP2`

### 2. Build Firmware
```bash
mkdir -p build
cd build
cmake ..
make -j4
```

### 3. Flash Firmware
```bash
cp build/blaze_pico.uf2 /Volumes/RPI-RP2/
sync
diskutil eject /Volumes/RP2-RP2
```

### 4. Wait for Reboot
Device will automatically reboot after flash (5-10 seconds)

### 5. Test Connection
```bash
screen /dev/tty.usbmodem2101 115200
```

You should see:
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

### 6. Run Benchmarks
```bash
cd Benchmarks
./run_benchmarks.sh
```

## Troubleshooting

**Device not detected:**
- Check USB cable
- Try different USB port
- Check `ls /dev/tty.usbmodem*`

**Bootloader mode not working:**
- Ensure BOOTSEL button works
- Try holding BOOTSEL longer
- Check `/Volumes/RPI-RP2` appears

**No serial output:**
- Wait 2-3 seconds after reboot (USB CDC needs time)
- Check baud rate is 115200
- Try unplugging/replugging USB

**BLAZE_READY not received:**
- Firmware may need the 2-second delay (already added)
- Check serial output with `screen`
- Verify firmware flashed correctly
