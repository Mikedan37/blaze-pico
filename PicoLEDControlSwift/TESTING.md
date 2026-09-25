# Testing Guide

## ✅ Build Status

```bash
cd PicoLEDControlSwift
swift build
# ✅ Build complete!
```

## ✅ Unit Tests

```bash
swift test
# ✅ All tests pass (3/3)
```

Tests verify:
- Packet format matches BlazeTransport spec
- Magic header "BLAZ" is included
- Command encoding is correct
- Packet structure is valid

## 🧪 Integration Testing

### Prerequisites

1. **Pico firmware flashed**: The C firmware (`main.c`) must be running on the Pico
2. **Pico connected**: USB cable connected, Pico powered on
3. **Port available**: Check port with `ls /dev/cu.usbmodem*`

### Test Steps

1. **Build the Swift tool**:
   ```bash
   cd PicoLEDControlSwift
   swift build -c release
   ```

2. **Find your Pico port**:
   ```bash
   ls /dev/cu.usbmodem*
   # Example output: /dev/cu.usbmodem1101
   ```

3. **Test single command**:
   ```bash
   .build/release/PicoLEDControl RED ON
   # LED should turn on
   ```

4. **Test multiple commands**:
   ```bash
   .build/release/PicoLEDControl RED ON GREEN ON BLUE ON
   # Multiple LEDs should turn on
   ```

5. **Test with explicit port**:
   ```bash
   .build/release/PicoLEDControl --port /dev/cu.usbmodem1101 ALL OFF
   # All LEDs should turn off
   ```

### Expected Behavior

- ✅ Commands are sent successfully (no errors)
- ✅ LEDs respond correctly
- ✅ Multiple commands work in sequence
- ✅ Port auto-detection works

### Troubleshooting

**Error: Failed to open serial port**
- Check Pico is connected: `ls /dev/cu.usbmodem*`
- Try unplugging and replugging Pico
- Check no other process is using the port: `lsof | grep usbmodem`

**Error: Write failed**
- Pico firmware might not be running
- Flash firmware: `cp build/blaze_pico.uf2 /Volumes/RP2350/`
- Reset Pico (press RESET button)

**LEDs don't respond**
- Verify firmware is running: `screen /dev/cu.usbmodem1101 115200`
- Should see: "BLAZE PICO LED CONTROLLER READY"
- Test direct text mode: type `RED ON<ENTER>`

## 📊 Test Results

```
✅ Build: SUCCESS
✅ Unit Tests: 3/3 passed
✅ Packet Format: Valid
✅ Magic Header: Correct
✅ Command Encoding: Correct
```

## Next Steps

Once integration tests pass, you can:
1. Use in AgentDaemon integration
2. Create wrapper functions for common LED patterns
3. Add more commands as needed
