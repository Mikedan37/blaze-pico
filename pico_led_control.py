#!/usr/bin/env python3
"""
Blaze Pico LED Control Tool
============================

Tool for agent daemon to control Pico LEDs via BlazeTransport protocol.

Usage:
    python3 pico_led_control.py RED ON
    python3 pico_led_control.py ALL OFF
    python3 pico_led_control.py GREEN ON BLUE ON

Or as a module:
    from pico_led_control import send_command
    send_command("RED ON")
"""

import serial
import sys
import time
import argparse

# Default port - can be overridden
DEFAULT_PORT = "/dev/cu.usbmodem1101"
DEFAULT_BAUD = 115200

def build_blaze_packet(command: str):
    """
    Encode a text command for the Pico.

    Text commands ("RED ON", "SERVO 90", "GPIO SET 2 1", ...) go over the
    firmware's text command path as a single line. Binary BLAZ frames only
    carry BlazeBinary PicoCommandV1 messages; see firmware/protocol/ and
    PicoLEDControlSwift/Sources/PicoLEDControlLib/PicoWire.swift.
    """
    return (command + "\n").encode("ascii")


def send_command(command: str, port: str = None, baud: int = DEFAULT_BAUD, timeout: float = 2.0):
    """
    Send a command to the Pico via BlazeTransport.
    
    Args:
        command: Command string (e.g., "RED ON", "ALL OFF")
        port: Serial port path (default: auto-detect or DEFAULT_PORT)
        baud: Baud rate (default: 115200)
        timeout: Serial timeout in seconds
    
    Returns:
        True if successful, False otherwise
    """
    if port is None:
        port = DEFAULT_PORT
    
    ser = None
    try:
        ser = serial.Serial(port, baud, timeout=timeout)
        time.sleep(0.1)  # Brief delay for serial to stabilize
        
        packet = build_blaze_packet(command.upper().strip())
        
        ser.write(packet)
        ser.flush()
        
        # Wait a bit for response
        time.sleep(0.1)
        
        return True
        
    except serial.SerialException as e:
        print(f"Serial error: {e}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return False
    finally:
        if ser is not None:
            ser.close()


def find_pico_port():
    """Try to find the Pico USB serial port."""
    import glob
    ports = glob.glob("/dev/cu.usbmodem*")
    if ports:
        return sorted(ports)[0]  # Return first found
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Control Blaze Pico LEDs via BlazeTransport protocol"
    )
    parser.add_argument(
        "commands",
        nargs="+",
        help="LED commands (e.g., 'RED ON', 'ALL OFF')"
    )
    parser.add_argument(
        "-p", "--port",
        default=None,
        help=f"Serial port (default: auto-detect or {DEFAULT_PORT})"
    )
    parser.add_argument(
        "-b", "--baud",
        type=int,
        default=DEFAULT_BAUD,
        help=f"Baud rate (default: {DEFAULT_BAUD})"
    )
    
    args = parser.parse_args()
    
    # Auto-detect port if not specified
    port = args.port
    if port is None:
        detected = find_pico_port()
        if detected:
            port = detected
            print(f"Auto-detected port: {port}", file=sys.stderr)
        else:
            port = DEFAULT_PORT
            print(f"Using default port: {port}", file=sys.stderr)
    
    # Process each command
    success_count = 0
    for cmd in args.commands:
        if send_command(cmd, port=port, baud=args.baud):
            print(f"✓ Sent: {cmd}")
            success_count += 1
            time.sleep(0.1)  # Small delay between commands
        else:
            print(f"✗ Failed: {cmd}", file=sys.stderr)
    
    return 0 if success_count == len(args.commands) else 1


if __name__ == "__main__":
    sys.exit(main())
