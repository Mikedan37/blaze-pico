import struct
import serial
import time

PORT = "/dev/cu.usbmodem1101"
BAUD = 115200


def build_packet(command: str):

    cmd_bytes = command.encode("ascii")

    # frame type = 0 (DATA)
    payload = b'\x00' + struct.pack(">I", 1) + cmd_bytes

    header = (
        bytes([1, 0]) +           # version, flags
        struct.pack(">I", 1) +    # connection id
        struct.pack(">I", 1) +    # packet number
        struct.pack(">I", 1) +    # stream id
        struct.pack(">H", len(payload))
    )

    # Add magic header "BLAZ" before packet
    magic = b'BLAZ'
    return magic + header + payload


def main():

    ser = serial.Serial(PORT, BAUD, timeout=1)
    try:
        time.sleep(2)

        print("READY")

        while True:

            cmd = input(">>> ").strip().upper()

            if cmd == "EXIT":
                break

            packet = build_packet(cmd)

            print("Sending:", cmd)
            ser.write(packet)
    finally:
        ser.close()


if __name__ == "__main__":
    main()
