import serial
import time

PORT = "/dev/cu.usbmodem1101"
BAUD = 115200


def build_packet(command: str):
    # Text commands go over the firmware's text path as one line.
    # Binary BLAZ frames only carry BlazeBinary PicoCommandV1 (see firmware/protocol/).
    return (command + "\n").encode("ascii")


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
