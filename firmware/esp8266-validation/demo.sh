#!/usr/bin/env bash
# Blaze protocol on real hardware: one-command demo for the ESP8266 validation target.
#
#   ./demo.sh                 check the board, watch the LED blink, run the hardware checks
#   ./demo.sh --flash         also (re)flash the tested proto2 firmware first
#   ./demo.sh --full          also prove old (PROTOCOL=1) firmware is refused, then restore proto2
#   ./demo.sh --port /dev/cu.usbserial-XXXX
#
# Tools: uses $PIO / $ESPTOOL_PY if set, otherwise a local .venv (created on first run).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="$HERE/../../PicoLEDControlSwift"
FLASH=0; FULL=0; PORT="${BLAZE_HW_PORT:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --flash) FLASH=1 ;; --full) FULL=1 ;; --port) PORT="$2"; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac; shift
done

G=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
ok()   { printf "  ${G}✔${N} %-11s %s\n" "$1" "$2"; }
bad()  { printf "  ${R}✘${N} %-11s %s\n" "$1" "$2"; FAILED=1; }
step() { printf "\n${B}[%s]${N} %s\n" "$1" "$2"; }
FAILED=0; LOG="$(mktemp -d)"

# ---- tools -------------------------------------------------------------------------------
if [ -z "${PIO:-}" ] || [ -z "${ESPTOOL_PY:-}" ]; then
  if [ ! -x "$HERE/.venv/bin/pio" ]; then
    echo "${D}First run: installing PlatformIO + esptool into $HERE/.venv ...${N}"
    python3 -m venv "$HERE/.venv" && "$HERE/.venv/bin/pip" -q install platformio esptool >/dev/null || { echo "install failed"; exit 1; }
  fi
  PIO="${PIO:-$HERE/.venv/bin/pio}"; ESPTOOL_PY="${ESPTOOL_PY:-$HERE/.venv/bin/python -m esptool}"
fi
esptool() { $ESPTOOL_PY --port "$PORT" --baud 115200 "$@"; }

printf "\n${B}━━━ Blaze protocol · real-hardware demo (ESP8266 validation target) ━━━${N}\n"
printf "${D}Same portable C protocol code as the Pico firmware, talking to the real Swift host.${N}\n"

# ---- 1. board ----------------------------------------------------------------------------
step 1 "Board"
if [ -z "$PORT" ]; then PORT="$(ls /dev/cu.usbserial* /dev/cu.SLAB_USBtoUART* 2>/dev/null | head -1)"; fi
if [ -z "$PORT" ]; then bad "board" "no USB serial device found (check the cable / plug)"; exit 1; fi
CHIP=""
for attempt in 1 2 3; do   # the ESP8266 sometimes misses the first auto-reset into download mode
  esptool chip_id >"$LOG/chip.log" 2>&1
  CHIP="$(sed -n 's/^Chip is //p' "$LOG/chip.log" | head -1)"
  [ -n "$CHIP" ] && break
  sleep 1
done
if [ -n "$CHIP" ]; then
  ok "board" "$CHIP on $PORT"
else
  bad "board" "could not talk to the chip on $PORT (3 tries). esptool said:"
  grep -iE "error|fatal|busy|failed" "$LOG/chip.log" | head -3 | sed 's/^/     /'
  echo "     Try: unplug and replug the board, close any serial monitor using the port, run again."
  exit 1
fi

# ---- 2. firmware -------------------------------------------------------------------------
step 2 "Firmware"
( cd "$HERE" && "$PIO" run -e proto2 >"$LOG/build.log" 2>&1 ) || { bad "build" "see $LOG/build.log"; exit 1; }
BIN="$HERE/.pio/build/proto2/firmware.bin"
ok "built" "proto2  $(stat -f %z "$BIN") bytes  sha256 $(shasum -a 256 "$BIN" | cut -c1-12)"
if [ $FLASH = 1 ] || ! esptool verify_flash 0 "$BIN" >"$LOG/verify.log" 2>&1; then
  ( cd "$HERE" && "$PIO" run -e proto2 -t upload --upload-port "$PORT" >"$LOG/flash.log" 2>&1 ) \
    && grep -q "Hash of data verified" "$LOG/flash.log" && ok "flashed" "written to the chip, hash verified" \
    || { bad "flashed" "see $LOG/flash.log"; exit 1; }
else
  ok "on chip" "the board is already running exactly this build (flash digest matched)"
fi

# ---- 3. handshake ------------------------------------------------------------------------
step 3 "Handshake (what the board says when it boots)"
"${ESPTOOL_PY%% *}" - "$PORT" <<'PY' 2>/dev/null | sed 's/^/     /'
import serial, sys, time
s = serial.Serial(sys.argv[1], 115200, timeout=0.2)
buf = b''; end = time.time() + 2.5
while time.time() < end: buf += s.read(512)
s.write(b'DEVICE_INFO\n'); time.sleep(0.4); buf += s.read(2048); s.close()
keep = ('BOOT:MODEL', 'SESSION:', 'BLAZE_READY', 'PROTOCOL=')
print('\n'.join(l.strip() for l in buf.decode(errors='replace').splitlines() if l.strip().startswith(keep)))
PY

# ---- 4. live LED + hardware checks ---------------------------------------------------------
cd "$HOST" && swift build --build-tests >"$LOG/swift-build.log" 2>&1 || { bad "host build" "see $LOG/swift-build.log"; exit 1; }
step 4 "Wire trace: one command at every layer, the bytes sent, and the raw reply"
BLAZE_HW_PORT="$PORT" BLAZE_HW_DEMO=1 swift test --skip-build --filter "ESP8266HardwareTests/test00_AWireTrace" >"$LOG/wire.log" 2>&1
grep -h "^\[WIRE\]" "$LOG/wire.log" | sed 's/^\[WIRE\]/    /'
grep -q "test00_AWireTrace\]' passed" "$LOG/wire.log" && ok "wire" "encoded in Swift, decoded in C on the board, ACK carries the same trace" || bad "wire" "see $LOG/wire.log"

step 5 "Live: blink the blue LED through the host library (watch the board)"
BLAZE_HW_PORT="$PORT" BLAZE_HW_DEMO=1 swift test --skip-build --filter "ESP8266HardwareTests/test00_DemoBlink" >"$LOG/demo.log" 2>&1
grep -h "^\[DEMO\]" "$LOG/demo.log" | sed 's/^\[DEMO\] /     /'
grep -q "test00_DemoBlink\]' passed" "$LOG/demo.log" && ok "blink" "6 commands, 6 ACKs matched by trace ID" || bad "blink" "see $LOG/demo.log"

step 6 "Hardware checks (Swift host ↔ real board)"
BLAZE_HW_PORT="$PORT" swift test --skip-build --filter ESP8266HardwareTests >"$LOG/checks.log" 2>&1
label() { case "$1" in
  test01_Handshake) echo "protocol 2 handshake accepted" ;;
  test02_CommandDrivesLEDWithTraceCorrelation) echo "command → LED → ACK with same trace → state change" ;;
  test03_TwentyCommands) echo "20 commands in a row, every one acknowledged" ;;
  test04_Batch) echo "batch of 3 frames in one write, all acknowledged" ;;
  test05_MalformedInputExecutesNothing) echo "garbage / bad CRC / wrong version / bad value: nothing executed" ;;
  test06_Reconnect) echo "disconnect and reconnect, then a command works" ;;
  test07_Protocol1FirmwareRefused) echo "old PROTOCOL=1 firmware refused, 0 binary frames reached it" ;;
  *) echo "$1" ;; esac; }
while read -r name result; do
  [ "$result" = skipped ] && continue
  [ "$result" = passed ] && ok "pass" "$(label "$name")" || bad "FAIL" "$(label "$name")"
done < <(sed -En "s/.*ESP8266HardwareTests (test0[1-6][A-Za-z_0-9]*)\]' (passed|failed|skipped).*/\1 \2/p" "$LOG/checks.log")

# ---- optional: old firmware refused ---------------------------------------------------------
if [ $FULL = 1 ]; then
  step 7 "Old firmware (PROTOCOL=1) must be refused"
  ( cd "$HERE" && "$PIO" run -e proto1 -t upload --upload-port "$PORT" >"$LOG/p1.log" 2>&1 ) && ok "flashed" "proto1 (reports PROTOCOL=1)" || bad "flashed" "proto1: see $LOG/p1.log"
  BLAZE_HW_PORT="$PORT" BLAZE_HW_EXPECT_PROTOCOL=1 swift test --skip-build --filter ESP8266HardwareTests/test07 >"$LOG/p1test.log" 2>&1
  grep -h "refused as expected" "$LOG/p1test.log" | sed 's/^\[ESP8266\] /     /'
  grep -q "test07_Protocol1FirmwareRefused\]' passed" "$LOG/p1test.log" && ok "pass" "$(label test07_Protocol1FirmwareRefused)" || bad "FAIL" "$(label test07_Protocol1FirmwareRefused)"
  ( cd "$HERE" && "$PIO" run -e proto2 -t upload --upload-port "$PORT" >"$LOG/p2.log" 2>&1 ) && ok "restored" "proto2 flashed back" || bad "restored" "see $LOG/p2.log"
fi

# ---- verdict ---------------------------------------------------------------------------------
echo
if [ $FAILED = 0 ]; then
  printf "${G}${B}✅ WORKING: the portable Blaze protocol runs on real hardware and talks to the Swift host.${N}\n"
else
  printf "${R}${B}❌ NOT WORKING: see the ✘ lines above. Logs: $LOG${N}\n"
fi
printf "${D}Logs: $LOG${N}\n\n"
exit $FAILED
