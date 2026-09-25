#!/usr/bin/env python3
"""Interactive Blaze console for the ESP8266 validation board.

Stays connected, so you can change things on the board while it runs. Every
binary command shows the bytes at each layer and the board's raw reply.

  ./console                      auto-detect the board
  ./console /dev/cu.usbserial-X  explicit port

The command list is read from firmware/protocol/pico_command.h, so a command
added there appears here automatically. On startup the encoder is checked
against firmware/tests/protocol/golden_frames.txt (the same bytes the Swift
host and the C firmware are tested against).
"""
import glob, os, random, re, struct, sys, threading, time, zlib

import serial

HERE = os.path.dirname(os.path.abspath(__file__))
HEADER = os.path.join(HERE, "..", "protocol", "pico_command.h")
GOLDEN = os.path.join(HERE, "..", "tests", "protocol", "golden_frames.txt")
DIM, GREEN, RED, BOLD, RESET = "\033[2m", "\033[32m", "\033[31m", "\033[1m", "\033[0m"

# ---- wire format (mirrors PicoWire.swift / blaze_serial.c) --------------------------------

def command_bytes(trace, command, value, version=1):
    """PicoCommandV1 in BlazeBinary: version u8, trace u64 BE, command u8, value u8."""
    return struct.pack(">BQBB", version, trace, command, value)

def frame(packet, trace, command, value, version=1):
    """"BLAZ" + BlazeTransport header + DATA frame [0][seq] + PicoCommandV1 + CRC-32."""
    body = struct.pack(">BI", 0, packet) + command_bytes(trace, command, value, version)
    covered = struct.pack(">BBIIIH", 1, 0, 1, packet, 1, len(body)) + body
    return b"BLAZ" + covered + struct.pack(">I", zlib.crc32(covered))

def load_commands():
    """PICO_CMD_<NAME> <id> from the firmware header -> {"name": id}."""
    text = open(HEADER).read()
    return {m.group(1).lower(): int(m.group(2))
            for m in re.finditer(r"#define PICO_CMD_([A-Z0-9_]+)\s+(\d+)", text)}

def self_check():
    ok = total = 0
    for line in open(GOLDEN):
        p = line.split()
        if not p or p[0] != "frame":
            continue
        total += 1
        ok += frame(int(p[1]), int(p[2], 16), int(p[3]), int(p[4])).hex() == p[6]
    return ok, total

# ---- console ----------------------------------------------------------------------------------

def hx(b):
    return " ".join(f"{x:02x}" for x in b)

def show_frame(f, name, command, value, trace):
    print(f"  {BOLD}command{RESET}      {name} (command {command}, value {value}, trace 0x{trace:016X} = {trace})")
    print(f"  {BOLD}BlazeBinary{RESET}  {hx(f[25:36])}   {DIM}version · trace(8) · command · value{RESET}")
    print(f"  {BOLD}frame sent{RESET}   {hx(f[:4])} | {hx(f[4:20])}")
    print(f"               {hx(f[20:25])} | {hx(f[25:36])} | {hx(f[36:])}")
    print(f"               {DIM}BLAZ sync | BlazeTransport header | DATA type+seq | PicoCommandV1 | CRC-32 = {len(f)} bytes{RESET}")

HELP = """commands:
  led on | led off          turn the blue LED on/off (protocol command 1)
  <name> <value>            send any protocol command by name, e.g.  servo_set 90   query_state 0
  send <id> <value>         send a raw command number (try an unknown one: send 99 1)
  status                    ask the board for its status line (text)
  text <line>               send a plain text line, e.g.  text PING
  corrupt                   send a frame with one flipped bit (the board must reject it)
  version2                  send a frame claiming PicoCommand version 2 (must be rejected)
  heartbeats on|off         show or hide the board's 2-second heartbeat
  list                      show the protocol commands (from pico_command.h)
  help | quit"""

def main():
    commands = load_commands()
    ok, total = self_check()
    tag = f"{GREEN}✔{RESET}" if ok == total else f"{RED}✘{RESET}"
    print(f"{tag} encoder matches the golden frames shared with Swift and C ({ok}/{total})")
    if ok != total:
        sys.exit(1)

    port = sys.argv[1] if len(sys.argv) > 1 else next(iter(sorted(glob.glob("/dev/cu.usbserial*"))), None)
    if not port:
        sys.exit("no USB serial device found (check the cable)")
    ser = serial.Serial(port, 115200, timeout=0.1)
    print(f"{GREEN}✔{RESET} connected to {port} {DIM}(opening the port reboots this board){RESET}")

    state = {"heartbeats": False, "packet": 0}
    ready = threading.Event()

    def reader():
        buf = b""
        while True:
            try:
                buf += ser.read(512)
            except (serial.SerialException, OSError):
                print(f"\n{RED}✘ board disconnected{RESET}")
                os._exit(1)
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode(errors="replace").strip()
                if not text or (text.startswith("HEARTBEAT") and not state["heartbeats"]):
                    continue
                if sum(c.isprintable() for c in text) < 0.9 * len(text):
                    print(f"  {DIM}received     (boot ROM output at 74880 baud, not protocol data; ignored){RESET}")
                    continue
                if text == "BLAZE_READY":
                    ready.set()
                color = RED if text.startswith(("ERROR", "UNKNOWN")) else GREEN if text.startswith(("ACK", "STATE_CHANGE")) else ""
                print(f"  {DIM}received{RESET}     {color}{text}{RESET}")
    threading.Thread(target=reader, daemon=True).start()

    if not ready.wait(4):
        print(f"{DIM}(no BLAZE_READY seen; continuing){RESET}")
    ser.write(b"DEVICE_INFO\n")
    time.sleep(0.5)
    print(f"\n{BOLD}Type 'help' for commands.{RESET}  The same checks the Swift host does run on the board for every frame.\n")

    def send_command(name, command, value, version=1, corrupt=False):
        state["packet"] += 1
        trace = random.getrandbits(40)
        f = bytearray(frame(state["packet"], trace, command, value, version))
        show_frame(f, name, command, value, trace)
        if corrupt:
            f[30] ^= 0x01
            print(f"  {RED}flipped one bit in byte 30 (CRC no longer matches){RESET}")
        ser.write(bytes(f))
        time.sleep(0.4)

    while True:
        try:
            line = input(f"{BOLD}blaze>{RESET} ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line:
            continue
        words = line.split()
        verb = words[0].lower()
        try:
            if verb in ("quit", "exit"):
                break
            elif verb == "help":
                print(HELP)
            elif verb == "list":
                for name, cid in sorted(commands.items(), key=lambda x: x[1]):
                    print(f"  {cid:>3}  {name}")
            elif verb == "led" and len(words) == 2 and words[1] in ("on", "off"):
                send_command(f"LED {words[1].upper()}", commands["red"], 1 if words[1] == "on" else 0)
            elif verb == "send" and len(words) == 3:
                send_command(f"raw {words[1]}", int(words[1]), int(words[2]))
            elif verb == "status":
                ser.write(b"STATUS\n"); time.sleep(0.4)
            elif verb == "text" and len(words) > 1:
                ser.write((line[5:] + "\n").encode()); time.sleep(0.4)
            elif verb == "corrupt":
                send_command("LED ON (corrupted)", commands["red"], 1, corrupt=True)
            elif verb == "version2":
                send_command("LED ON (version 2)", commands["red"], 1, version=2)
            elif verb == "heartbeats" and len(words) == 2:
                state["heartbeats"] = words[1] == "on"
            elif verb in commands and len(words) == 2:
                send_command(verb.upper(), commands[verb], int(words[1]))
            else:
                print("unknown command, type 'help'")
        except ValueError:
            print("values must be numbers, type 'help'")
    ser.close()

if __name__ == "__main__":
    main()
