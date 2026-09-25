# USB Enumeration Failure Diagnosis

## Current Status
-  Firmware code is correct (USB enabled, proper initialization)
-  Firmware flashes successfully (UF2 copied to bootloader)
-  Serial port `/dev/cu.usbmodem*` does NOT appear after cold boot
-  No USB CDC device detected by macOS

## Root Cause Analysis

### Issue #1: Firmware May Not Execute on Cold Boot
According to `docs/COLD_BOOT_FINDINGS.md`, RP2350 firmware does not execute on cold boot (unplug/replug). This is a bootloader behavior, not a firmware bug.

**Evidence:**
- Even minimal blink firmware (no USB) doesn't work on cold boot
- Serial port never appears = firmware never starts
- Bootloader accepts UF2 files but doesn't load them on cold power-up

### Issue #2: USB CDC Not Enumerating
Even if firmware executes, USB CDC may not enumerate properly.

**Possible causes:**
1. USB stack initialization timing issue
2. RP2350 USB enumeration quirks
3. macOS USB driver issues
4. Firmware crashes before USB init completes

## Fixes Applied

1.  Removed duplicate GPIO initialization
2.  Reduced USB delay from 1000ms to 250ms
3.  Ensured `stdio_init_all()` is called first and only once
4.  Proper initialization order

## Next Steps

### Option A: Accept Cold Boot Limitation
- Document that firmware requires warm reset (after flash)
- Commands work perfectly once firmware is running
- Boot LED test won't work on cold boot

### Option B: Investigate Bootloader
- Check RP2350 bootloader version
- Try bootloader update if available
- May require Raspberry Pi Foundation fix

### Option C: Workaround
- Add watchdog timer to trigger firmware start
- Use external trigger (button press, serial connection)
- Accept that cold boot doesn't work

## Critical Test Needed

**Minimal blink test result:**
- Flash minimal blink firmware (GPIO 14, no USB)
- Unplug and replug
- Does GPIO 14 blink? YES or NO

This will definitively prove if firmware executes at all on cold boot.
