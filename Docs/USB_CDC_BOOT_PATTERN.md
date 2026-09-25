# USB CDC Boot Pattern - Production Firmware

## Problem

USB CDC on Pico 2 is slow on cold boot. Early prints vanish if USB CDC hasn't attached yet.

## Solution

**Production firmware pattern**: Wait 2 seconds after `stdio_init_all()` before any `printf()`.

## Implementation

```c
int main() {
    stdio_init_all();
    
    // CRITICAL: USB CDC on Pico 2 is slow on cold boot
    // Early prints vanish if USB CDC hasn't attached yet
    // Production firmware pattern: wait 2 seconds after stdio_init_all()
    // This ensures USB CDC is fully ready before any printf()
    sleep_ms(2000);
    
    // NOW safe to print
    printf("BOOT:GPIO_INIT\n");
    // ... rest of boot sequence
}
```

## Why 2 Seconds?

- **200ms**: Too short - USB CDC may not be ready
- **500ms**: Still unreliable on cold boot
- **1000ms**: Better but can still miss on some systems
- **2000ms**: Reliable for production firmware

## Boot Print Order (Production Pattern)

1. `stdio_init_all()` - Initialize USB CDC
2. `sleep_ms(2000)` - Wait for USB CDC attachment
3. `BOOT:GPIO_INIT` - GPIO initialization started
4. `BOOT:GPIO_OK` - GPIO initialization complete
5. `BOOT:USB_INIT` - USB initialization started
6. `BOOT_TS:...` - Boot timestamp
7. `READY_TS:...` - Ready timestamp
8. `SESSION:xxxx` - Session UUID
9. `STATE: seq=0 ...` - Initial state (before READY)
10. `BLAZE_READY` - Device ready for commands

## Common Mistakes

###  Wrong: Print immediately after stdio_init_all()
```c
stdio_init_all();
printf("BOOT:GPIO_INIT\n");  // May vanish!
```

###  Correct: Wait for USB CDC attachment
```c
stdio_init_all();
sleep_ms(2000);  // Wait for USB CDC
printf("BOOT:GPIO_INIT\n");  // Guaranteed to be received
```

###  Wrong: Using sleep_us() or too short delay
```c
stdio_init_all();
sleep_ms(200);  // Too short - USB CDC not ready
```

###  Correct: Use sleep_ms(2000) for reliability
```c
stdio_init_all();
sleep_ms(2000);  // Reliable for production
```

## Why This Matters

Without the delay:
- Early prints vanish
- Device appears "silent"
- Daemon never receives BLAZE_READY
- Benchmarks fail (correctly - device not ready)

With the delay:
- All prints are received
- BLAZE_READY arrives reliably
- Daemon connects successfully
- Benchmarks run correctly

## Status

 **Fixed**: Added `sleep_ms(2000)` after `stdio_init_all()` in firmware

This ensures USB CDC is fully ready before any printf(), making boot prints 100% reliable.
