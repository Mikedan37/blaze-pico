#!/bin/bash

# Test script for boot LEDs and BOOT command

SERIAL_PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)

if [ -z "$SERIAL_PORT" ]; then
    echo "❌ Serial port not found. Please unplug and replug the Pico USB cable."
    exit 1
fi

echo "✅ Serial port found: $SERIAL_PORT"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST 1: Boot LED Test (check physical LEDs)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 INSTRUCTIONS:"
echo "   1. Watch the LEDs on your Pico"
echo "   2. They should turn ON immediately on boot"
echo "   3. They should stay ON for 5 seconds"
echo "   4. Then turn OFF automatically"
echo ""
echo "Reading boot messages..."
echo ""

python3 <<PYEOF
import serial
import time
import sys

port = "$SERIAL_PORT"
try:
    ser = serial.Serial(port, 115200, timeout=2)
    time.sleep(0.5)
    ser.reset_input_buffer()
    
    # Read for 5 seconds to catch boot messages
    start = time.time()
    messages = []
    boot_detected = False
    
    print("⏳ Reading serial output (5 seconds)...")
    while time.time() - start < 5:
        if ser.in_waiting:
            line = ser.readline().decode('utf-8', errors='ignore').strip()
            if line:
                messages.append(line)
                if 'BOOT' in line or 'LED' in line:
                    boot_detected = True
                    print(f"📨 {line}")
                elif 'BLAZE_READY' in line:
                    print(f"✅ {line}")
        time.sleep(0.1)
    
    print(f"\n📊 Total messages: {len(messages)}")
    
    if boot_detected:
        print("✅ Boot LED test messages detected!")
    else:
        print("⚠️  Boot LED messages may have been sent before USB ready")
        print("   (This is normal - check physical LEDs instead)")
    
    ser.close()
except Exception as e:
    print(f"❌ Error: {e}")
    sys.exit(1)
PYEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST 2: BOOT Command (triggers bootloader mode)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Press ENTER to send BOOT command (will reboot Pico into bootloader)..."
echo ""

python3 <<PYEOF
import serial
import time

port = "$SERIAL_PORT"
try:
    ser = serial.Serial(port, 115200, timeout=2)
    time.sleep(0.5)
    
    print("📤 Sending BOOT command...")
    ser.write(b"BOOT\n")
    ser.flush()
    time.sleep(0.5)
    
    # Try to read response
    if ser.in_waiting:
        response = ser.read(ser.in_waiting).decode('utf-8', errors='ignore')
        print(f"📥 Response: {response[:200]}")
    
    ser.close()
    print("✅ BOOT command sent!")
    print("")
    print("⏳ Waiting 3 seconds for bootloader mode...")
    time.sleep(3)
    
    import os
    mounts = []
    for vol in ['/Volumes/RP2350', '/Volumes/RPI-RP2']:
        if os.path.exists(vol):
            mounts.append(vol)
    
    if mounts:
        print(f"✅ Bootloader mode detected: {mounts[0]}")
        print("   Flash script can now flash without manual BOOTSEL!")
    else:
        print("⚠️  Bootloader mount not detected yet")
        print("   (May need a moment or physical replug)")
    
except Exception as e:
    print(f"❌ Error: {e}")
PYEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
