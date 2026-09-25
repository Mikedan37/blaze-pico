# GPIO Pin Verification

## Current GPIO Mapping

- **Red:** GPIO 14
- **Green:** GPIO 15  
- **Yellow:** GPIO 16
- **Blue:** GPIO 17
- **Multi:** GPIO 18

## Issue

Commands are being sent correctly:
-  YELLOW ON  commandID 3  GPIO 16
-  MULTI ON  commandID 5  GPIO 18
-  ACK received
-  GPIO feedback = 1 (pin is HIGH)

**But LEDs don't light up**  Hardware wiring issue

## Troubleshooting Steps

### 1. Check Physical Wiring

Verify GPIO pins 16 and 18 are connected:
- GPIO 16  Yellow LED anode  Resistor  GND
- GPIO 18  Multi LED anode  Resistor  GND

### 2. Test GPIO Pins Directly

You can test if the pins work by checking voltage with a multimeter or connecting a known-good LED.

### 3. Verify LED Hardware

- Check if Yellow and Multi LEDs are functional (swap with Red/Green LEDs)
- Check resistor values (should be ~220Ω-1kΩ)
- Verify LED polarity (anode to GPIO, cathode to GND)

### 4. Firmware Verification

The firmware code is correct:
```c
case CMD_YELLOW:
    set_led_state(2, state);  // GPIO 16
    break;
    
case CMD_MULTI:
    set_led_state(4, state);  // GPIO 18
    break;
```

GPIO feedback confirms pins are being set HIGH, so firmware is working.

## Quick Test

Run this to see all GPIO states:
```bash
.build/release/PicoLEDControl ALL ON
# Check which LEDs light up
```

If only Red, Green, Blue light up  Yellow and Multi LEDs are not wired or LEDs are dead.
