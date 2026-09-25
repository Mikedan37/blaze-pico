# USB CDC Readiness Gate Fix

## Problem
Firmware was emitting `BLAZE_READY` before USB CDC connection was established, causing boot messages to be discarded.

## Solution
Added `stdio_usb_connected()` wait loop before emitting boot messages.

## Changes
- Replaced fixed 2-second delay with USB connection polling
- Waits for actual USB connection, not just time
- Added 200ms warmup delay after connection

## Flash Instructions
1. Put device in bootloader mode (hold BOOTSEL, press RESET)
2. Copy `build/blaze_pico.uf2` to `/Volumes/RP2350/`
3. Device will reboot automatically
4. Run benchmarks - should now receive BLAZE_READY immediately

## Expected Behavior
- Firmware waits for USB connection before printing
- Host receives SESSION, STATE, and BLAZE_READY reliably
- Commands execute immediately after connect
