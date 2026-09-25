# Cold Boot Behavior Findings

## Summary

After extensive testing, we've determined that **RP2350 (Pico W2) firmware does not execute on cold boot** (unplug/replug power cycle), even with the simplest possible firmware.

## Test Results

###  What Works
- Firmware executes after flash (warm reset)
- Commands work via serial (firmware runs normally)
- GPIO works perfectly when firmware is running
- Scanner firmware works
- All LED commands work

###  What Doesn't Work
- Firmware does NOT execute on cold boot (unplug/replug)
- Even simplest firmware (onboard LED blink) doesn't run
- Boot LED test code never executes on cold boot

## Root Cause

**Bootloader Issue**: The RP2350 bootloader runs on cold boot (serial port appears), but **does not load the flashed UF2 file** on cold power-up.

### Evidence
1. Serial port `/dev/cu.usbmodem*` appears on cold boot  bootloader runs
2. No firmware response to commands immediately after cold boot  firmware not loaded
3. Even simplest firmware (5-line onboard LED blink) doesn't execute  not a firmware issue
4. flash_nuke.uf2 didn't fix it  bootloader behavior, not corrupted flash

## Workaround

**Firmware starts running after some delay or trigger** (possibly USB enumeration, serial connection, or timeout). Once running, everything works perfectly.

## Implications

- Boot LED test code will never execute on cold boot
- LEDs won't light immediately on plug-in
- System requires a "wake-up" trigger (serial connection, command, or delay)
- This appears to be RP2350 bootloader behavior, not a bug in our firmware

## Recommendation

Accept this behavior and rely on:
- Commands to control LEDs (which work perfectly)
- Optional: Add a "wake-up" command that triggers boot LED test
- Document that cold boot LEDs won't light automatically
