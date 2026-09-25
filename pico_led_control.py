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

import struct
import serial
import sys
import time
import argparse

# Default port - can be overridden
DEFAULT_PORT = "/dev/cu.usbmodem1101"
DEFAULT_BAUD = 115200

def build_blaze_packet(command: str):
    """
    Build a BlazeTransport packet for the given command.
    
    Packet format:
        Magic: "BLAZ" (4 bytes)
        Header: 16 bytes
            bytes 0-1: version(1), flags(1)
            bytes 2-5: connection_id (big-endian uint32)
            bytes 6-9: packet_number (big-endian uint32)
            bytes 10-13: stream_id (big-endian uint32)
            bytes 14-15: payload_length (big-endian uint16)
        Payload:
            byte 0: frameType (0 = DATA)
            bytes 1-4: streamID (big-endian uint32)
            bytes 5+: ASCII command string
    """
    cmd_bytes = command.encode("ascii")
    
    # Payload: frameType(1) + streamID(4) + command
    payload = b'\x00' + struct.pack(">I", 1) + cmd_bytes
    
    # Header: version(1) + flags(1) + connection_id(4) + packet_num(4) + stream_id(4) + payload_len(2)
    header = (
        bytes([1, 0]) +           # version, flags
        struct.pack(">I", 1) +    # connection id
        struct.pack(">I", 1) +    # packet number
        struct.pack(">I", 1) +    # stream id
        struct.pack(">H", len(payload))  # payload length
    )
    
    # Magic header
    magic = b'BLAZ'
    
    return magic + header + payload


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
