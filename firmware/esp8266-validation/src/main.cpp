// ESP8266 protocol validation target. NOT a supported board.
//
// Only glue lives here: serial bytes in, text lines out, and the GPIO2 LED.
// Framing, CRC, resync, BlazeBinary decoding and command validation are the
// unchanged portable C files in firmware/protocol and firmware/third_party.
// Output lines use the exact formats of the Pico firmware (main.c), so the
// Swift host treats this board like a Pico with one LED.

#include <Arduino.h>

extern "C" {  // these headers have no C++ guards; the C sources are untouched
#include "blaze_serial.h"
#include "pico_command.h"
}

#ifndef BLAZE_PROTOCOL_VERSION
#define BLAZE_PROTOCOL_VERSION 2
#endif

#define FW_VERSION "esp8266-validation-0.1"
#define DEVICE_MODEL "BLAZE_ESP8266_VALIDATION"
#define LED_PIN 2             // blue LED on the ESP-12 module, lit when LOW
#define SERIAL_IDLE_MS 250    // same as the Pico firmware
#define HEARTBEAT_MS 2000

static blaze_serial_t parser;
static uint32_t session_id;
static uint32_t state_seq;
static bool red_on;
static uint32_t frames_ok;       // validated binary commands since boot
static uint32_t frames_rejected; // rejected binary frames since boot
static uint32_t last_byte_ms;
static uint32_t last_heartbeat_ms;

// The ESP8266 printf has no %llu, so 64-bit trace IDs are formatted by hand.
static const char *fmt_u64(uint64_t v, char *buf) {
    char tmp[21];
    int n = 0;
    do { tmp[n++] = (char)('0' + (v % 10)); v /= 10; } while (v);
    for (int i = 0; i < n; i++) buf[i] = tmp[n - 1 - i];
    buf[n] = '\0';
    return buf;
}

static void set_red(bool on) {
    if (on != red_on) state_seq++;
    red_on = on;
    digitalWrite(LED_PIN, on ? LOW : HIGH);
}

static void print_state(const char *prefix, uint64_t trace, bool with_trace) {
    char t[21];
    if (with_trace) {
        Serial.printf("%s trace=%s seq=%lu R=%d G=0 Y=0 B=0 MR=0 MG=0 MB=0 S=0\n", prefix, fmt_u64(trace, t),
                      (unsigned long)state_seq, red_on ? 1 : 0);
    } else {
        Serial.printf("%s seq=%lu R=%d G=0 Y=0 B=0 MR=0 MG=0 MB=0 S=0\n", prefix, (unsigned long)state_seq,
                      red_on ? 1 : 0);
    }
}

static void print_status() {
    Serial.printf("STATUS: ready=1 session=%08X uptime=%lu seq=%lu fw=%s proto=%d model=%s id=%08X "
                  "frames_ok=%lu frames_rejected=%lu\n",
                  session_id, (unsigned long)millis(), (unsigned long)state_seq, FW_VERSION,
                  BLAZE_PROTOCOL_VERSION, DEVICE_MODEL, ESP.getChipId(), (unsigned long)frames_ok,
                  (unsigned long)frames_rejected);
}

static void execute(uint64_t trace, uint8_t command, uint8_t value) {
    char t[21];
    switch (command) {
        case PICO_CMD_RED:
            set_red(value != 0);
            Serial.printf("ACK TRACE:%s cmdID=%d value=%d\n", fmt_u64(trace, t), command, value);
            print_state("STATE_CHANGE:", trace, true);
            break;
        case PICO_CMD_QUERY_STATE:
            print_state("STATE:", 0, false);
            break;
        case PICO_CMD_STATUS:
            print_status();
            break;
        default:
            // Valid PicoCommandV1, but this board has no such hardware.
            Serial.printf("ERROR: Unsupported on ESP8266 validation target cmdID=%d TRACE:%s\n", command,
                          fmt_u64(trace, t));
            break;
    }
}

static void text_command(char *line) {
    while (*line == ' ') line++;
    if (!strcmp(line, "DEVICE_INFO")) {
        Serial.printf("DEVICE_INFO_BEGIN\nMODEL=%s\nFW_VERSION=%s\nPROTOCOL=%d\nDEVICE_ID=%08X\n"
                      "MAX_CMD=%d\nGPIO_COUNT=1\nADC_PINS=0\nPWM_SLICES=0\nRESERVED=0\nDEVICE_INFO_END\n",
                      DEVICE_MODEL, FW_VERSION, BLAZE_PROTOCOL_VERSION, ESP.getChipId(), BLAZE_SERIAL_MAX_LINE);
    } else if (!strcmp(line, "PINMAP")) {
        Serial.print("PINMAP_BEGIN\nPINMAP_END\n");
    } else if (!strcmp(line, "STATUS")) {
        print_status();
    } else if (!strcmp(line, "PING")) {
        Serial.print("PONG\n");
    } else if (!strcmp(line, "RED ON")) {
        execute(0, PICO_CMD_RED, 1);
    } else if (!strcmp(line, "RED OFF")) {
        execute(0, PICO_CMD_RED, 0);
    } else {
        Serial.printf("UNKNOWN: %s\n", line);
    }
}

static void on_serial_event(const blaze_serial_event_t *ev, void *context) {
    (void)context;
    char t[21];
    switch (ev->kind) {
        case BLAZE_SERIAL_EVENT_TEXT_LINE:
            text_command(ev->line);
            break;
        case BLAZE_SERIAL_EVENT_COMMAND:
            frames_ok++;
            Serial.printf("PACKET RECEIVED TRACE:%s SEQ:%lu CMD:%d VAL:%d\n", fmt_u64(ev->command.trace_id, t),
                          (unsigned long)ev->sequence, ev->command.command, ev->command.value);
            execute(ev->command.trace_id, ev->command.command, ev->command.value);
            break;
        case BLAZE_SERIAL_EVENT_ERROR:
            frames_rejected++;
            if (ev->error == BLAZE_SERIAL_ERROR_COMMAND) {
                Serial.printf("ERROR: Rejected frame: %s TRACE:%s\n", pico_command_result_name(ev->command_result),
                              fmt_u64(ev->command.trace_id, t));
                Serial.printf("ERROR_EVENT: CODE:BAD_FRAME REASON:%s\n", pico_command_result_name(ev->command_result));
            } else {
                Serial.printf("ERROR: Rejected frame: %s (payload_len=%u)\n", blaze_serial_error_name(ev->error),
                              (unsigned)ev->payload_length);
                Serial.printf("ERROR_EVENT: CODE:BAD_FRAME REASON:%s\n", blaze_serial_error_name(ev->error));
            }
            break;
    }
}

void setup() {
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, HIGH);  // off
    Serial.begin(115200);
    delay(50);

    blaze_serial_init(&parser);
    session_id = ESP.random();  // hardware RNG: a new ID every boot

    Serial.print("\nBOOT:START\n");
    Serial.printf("BOOT:MODEL %s FW %s PROTOCOL %d\n", DEVICE_MODEL, FW_VERSION, BLAZE_PROTOCOL_VERSION);
    Serial.printf("SESSION:%08X\n", session_id);
    print_state("STATE:", 0, false);
    Serial.print("BLAZE_READY\n");
}

void loop() {
    uint32_t now = millis();

    while (Serial.available() > 0) {
        last_byte_ms = now;
        blaze_serial_feed(&parser, (uint8_t)Serial.read(), on_serial_event, nullptr);
    }

    if (blaze_serial_busy(&parser) && now - last_byte_ms > SERIAL_IDLE_MS) {
        blaze_serial_idle(&parser, on_serial_event, nullptr);
    }

    if (now - last_heartbeat_ms >= HEARTBEAT_MS) {
        last_heartbeat_ms = now;
        Serial.printf("HEARTBEAT: UPTIME:%lu READY:1 R=%d G=0 Y=0 B=0 MR=0 MG=0 MB=0 S=0\n", (unsigned long)now,
                      red_on ? 1 : 0);
    }

    yield();
}
