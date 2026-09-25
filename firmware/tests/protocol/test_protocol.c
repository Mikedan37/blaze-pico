/*
 * Host tests for the firmware protocol stack: exactly the C that runs on the Pico
 * (blaze_serial.c, pico_command.c, vendored BlazeTransport and BlazeBinary C).
 *
 * Usage: test_protocol <golden_frames.txt>
 */

#include "blaze_serial.h"
#include "pico_command.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, ...)                                        \
    do {                                                        \
        checks++;                                               \
        if (!(cond)) {                                          \
            failures++;                                         \
            fprintf(stderr, "FAIL %s:%d: ", __func__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                       \
            fprintf(stderr, "\n");                              \
        }                                                       \
    } while (0)

/* ---------- event collector ---------- */

#define MAX_EVENTS 4096

typedef struct {
    blaze_serial_event_kind_t kind;
    char line[BLAZE_SERIAL_MAX_LINE];
    pico_command_t command;
    uint32_t sequence;
    blaze_serial_error_t error;
    pico_command_result_t command_result;
} recorded_t;

typedef struct {
    recorded_t events[MAX_EVENTS];
    size_t count;
} log_t;

static void record(const blaze_serial_event_t *ev, void *context) {
    log_t *log = context;
    if (log->count >= MAX_EVENTS) return;
    recorded_t *r = &log->events[log->count++];
    memset(r, 0, sizeof *r);
    r->kind = ev->kind;
    if (ev->line) snprintf(r->line, sizeof r->line, "%s", ev->line);
    r->command = ev->command;
    r->sequence = ev->sequence;
    r->error = ev->error;
    r->command_result = ev->command_result;
}

static size_t count_kind(const log_t *log, blaze_serial_event_kind_t kind) {
    size_t n = 0;
    for (size_t i = 0; i < log->count; i++) n += (log->events[i].kind == kind);
    return n;
}

static const recorded_t *first_kind(const log_t *log, blaze_serial_event_kind_t kind) {
    for (size_t i = 0; i < log->count; i++)
        if (log->events[i].kind == kind) return &log->events[i];
    return NULL;
}

static void feed(blaze_serial_t *p, log_t *log, const uint8_t *bytes, size_t n) {
    for (size_t i = 0; i < n; i++) blaze_serial_feed(p, bytes[i], record, log);
}

static void feed_str(blaze_serial_t *p, log_t *log, const char *s) {
    feed(p, log, (const uint8_t *)s, strlen(s));
}

/* ---------- frame builder (C encode direction) ---------- */

/* Recompute the CRC of a frame in place (for tests that corrupt fields on purpose). */
static void reseal(uint8_t *frame, size_t len) {
    blaze_write_uint32_be(&frame[len - 4], blaze_serial_crc32(&frame[4], len - 8));
}

/* "BLAZ" + header(declared payload length) + payload bytes + CRC. */
static size_t build_raw(uint8_t *out, uint32_t packet_number, uint16_t declared_len, const uint8_t *payload,
                        size_t payload_len) {
    blaze_packet_header_t header = {1, 0, 1, packet_number, 1, declared_len};
    memcpy(out, "BLAZ", 4);
    blaze_encode_header(&header, &out[4], BLAZE_HEADER_SIZE);
    memcpy(&out[4 + BLAZE_HEADER_SIZE], payload, payload_len);
    size_t len = 4 + BLAZE_HEADER_SIZE + payload_len + 4;
    reseal(out, len);
    return len;
}

static size_t build_frame(uint8_t *out, uint32_t packet_number, uint64_t trace, uint8_t command, uint8_t value) {
    pico_command_t cmd = {PICO_COMMAND_VERSION, trace, command, value};
    uint8_t body[1 + 4 + PICO_COMMAND_V1_SIZE];
    size_t cmd_len = 0;
    body[0] = BLAZE_FRAME_DATA;
    blaze_write_uint32_be(&body[1], packet_number);
    pico_command_encode(&cmd, &body[5], PICO_COMMAND_V1_SIZE, &cmd_len);
    return build_raw(out, packet_number, (uint16_t)(5 + cmd_len), body, 5 + cmd_len);
}

static size_t parse_hex(const char *hex, uint8_t *out, size_t cap) {
    size_t n = strlen(hex) / 2;
    if (n > cap) n = cap;
    for (size_t i = 0; i < n; i++) {
        unsigned b;
        sscanf(hex + 2 * i, "%2x", &b);
        out[i] = (uint8_t)b;
    }
    return n;
}

static void print_hex(const char *label, const uint8_t *b, size_t n) {
    printf("  %-8s", label);
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
}

/* A valid frame used by the stream tests: servo to 90, trace 0x1122334455667788. */
static uint8_t VALID[64];
static size_t VALID_LEN;
#define VALID_TRACE 0x1122334455667788ULL

static bool is_valid_command(const recorded_t *r) {
    return r && r->kind == BLAZE_SERIAL_EVENT_COMMAND && r->command.trace_id == VALID_TRACE &&
           r->command.command == PICO_CMD_SERVO_SET && r->command.value == 90;
}

/* ---------- golden vectors ---------- */

static void test_golden(const char *path) {
    FILE *f = fopen(path, "r");
    CHECK(f != NULL, "open %s", path);
    if (!f) return;

    char line[512];
    int commands = 0, frames = 0;
    while (fgets(line, sizeof line, f)) {
        char kind[16];
        if (line[0] == '#' || line[0] == '\n' || sscanf(line, "%15s", kind) != 1) continue;

        if (strcmp(kind, "command") == 0) {
            unsigned version, command, value;
            char trace_hex[32], hex[128];
            sscanf(line, "%*s %u %31s %u %u %127s", &version, trace_hex, &command, &value, hex);
            uint64_t trace = strtoull(trace_hex, NULL, 16);
            uint8_t golden[32], buf[32];
            size_t glen = parse_hex(hex, golden, sizeof golden), len = 0;

            pico_command_t cmd = {(uint8_t)version, trace, (uint8_t)command, (uint8_t)value};
            CHECK(pico_command_encode(&cmd, buf, sizeof buf, &len) == PICO_COMMAND_OK && len == glen &&
                      memcmp(buf, golden, glen) == 0,
                  "C encode command %s", hex);

            pico_command_t out;
            pico_command_result_t res = pico_command_decode(golden, glen, &out);
            CHECK(out.version == version && out.trace_id == trace && out.command == command && out.value == value,
                  "C decode command %s (res %s)", hex, pico_command_result_name(res));
            commands++;
        } else if (strcmp(kind, "frame") == 0) {
            unsigned packet_number, command, value;
            char trace_hex[32], expect[32], hex[160];
            sscanf(line, "%*s %u %31s %u %u %31s %159s", &packet_number, trace_hex, &command, &value, expect, hex);
            uint64_t trace = strtoull(trace_hex, NULL, 16);
            uint8_t golden[80], buf[80];
            size_t glen = parse_hex(hex, golden, sizeof golden);

            /* C encode == golden (the reverse direction: Swift decodes these same bytes). */
            size_t len = build_frame(buf, packet_number, trace, (uint8_t)command, (uint8_t)value);
            CHECK(len == glen && memcmp(buf, golden, glen) == 0, "C build frame != golden %s", hex);

            /* golden (Swift-encoded) -> C stream decode */
            blaze_serial_t p;
            static log_t log;
            log.count = 0;
            blaze_serial_init(&p);
            feed(&p, &log, golden, glen);
            CHECK(log.count == 1, "frame %s: %zu events", hex, log.count);
            const recorded_t *r = &log.events[0];
            if (strcmp(expect, "OK") == 0) {
                CHECK(r->kind == BLAZE_SERIAL_EVENT_COMMAND && r->command.trace_id == trace &&
                          r->command.command == command && r->command.value == value && r->sequence == packet_number,
                      "frame %s: not decoded as expected command", hex);
            } else {
                CHECK(r->kind == BLAZE_SERIAL_EVENT_ERROR && r->error == BLAZE_SERIAL_ERROR_COMMAND &&
                          strcmp(pico_command_result_name(r->command_result), expect) == 0 &&
                          r->command.trace_id == trace,
                      "frame %s: want rejection %s", hex, expect);
            }

            if (frames == 0) {
                printf("Reference frame (C encode == golden == Swift encode):\n");
                print_hex("magic", golden, 4);
                print_hex("header", golden + 4, 16);
                print_hex("dataHdr", golden + 20, 5);
                print_hex("command", golden + 25, glen - 29);
                print_hex("crc32", golden + glen - 4, 4);
                printf("  decoded: version=%u trace=0x%016" PRIx64 " command=%u value=%u -> %s\n",
                       r->command.version, r->command.trace_id, r->command.command, r->command.value,
                       r->kind == BLAZE_SERIAL_EVENT_COMMAND ? "EXECUTE"
                                                             : pico_command_result_name(r->command_result));
            }
            frames++;
        }
    }
    fclose(f);
    CHECK(commands == 4 && frames == 3, "golden counts: %d commands %d frames", commands, frames);
}

/* ---------- stream robustness ---------- */

static blaze_serial_t P;
static log_t L;

static void reset(void) {
    blaze_serial_init(&P);
    L.count = 0;
}

static void test_one_frame(void) {
    reset();
    feed(&P, &L, VALID, VALID_LEN);
    CHECK(L.count == 1 && is_valid_command(&L.events[0]), "one frame");
}

/* Every possible split point: covers header split and payload split. */
static void test_every_split(void) {
    for (size_t k = 0; k < VALID_LEN; k++) {
        reset();
        feed(&P, &L, VALID, k);
        CHECK(L.count == 0, "split %zu: early event", k);
        feed(&P, &L, VALID + k, VALID_LEN - k);
        CHECK(L.count == 1 && is_valid_command(&L.events[0]), "split at %zu", k);
    }
}

static void test_two_frames_one_read(void) {
    uint8_t buf[128];
    memcpy(buf, VALID, VALID_LEN);
    memcpy(buf + VALID_LEN, VALID, VALID_LEN);
    reset();
    feed(&P, &L, buf, 2 * VALID_LEN);
    CHECK(L.count == 2 && is_valid_command(&L.events[0]) && is_valid_command(&L.events[1]), "two frames");
}

static void test_garbage_before_and_between(void) {
    const uint8_t junk[] = {0x00, 0xff, 0x13, 'B', 'L', 'X', 0x80, 'B', 'B', 'L', 'A'};
    reset();
    feed(&P, &L, junk, sizeof junk);
    feed(&P, &L, VALID, VALID_LEN);
    feed(&P, &L, junk, sizeof junk);
    feed(&P, &L, VALID, VALID_LEN);
    CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND) == 2, "garbage: commands %zu",
          count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND));
    CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_TEXT_LINE) == 0, "garbage produced a text line");
}

static void test_partial_magic_text(void) {
    reset();
    feed_str(&P, &L, "BLA");
    feed(&P, &L, VALID, VALID_LEN);
    CHECK(L.count == 1 && is_valid_command(&L.events[0]), "BLA prefix then frame");

    reset();
    feed_str(&P, &L, "BLUE ON\nBLA\nB\nRED ON\r\n");
    CHECK(L.count == 4 && strcmp(L.events[0].line, "BLUE ON") == 0 && strcmp(L.events[1].line, "BLA") == 0 &&
              strcmp(L.events[2].line, "B") == 0 && strcmp(L.events[3].line, "RED ON") == 0,
          "text lines with magic prefixes");
}

static void test_truncated_then_idle(void) {
    reset();
    feed(&P, &L, VALID, 20);
    blaze_serial_idle(&P, record, &L);
    CHECK(L.count == 1 && L.events[0].kind == BLAZE_SERIAL_EVENT_ERROR &&
              L.events[0].error == BLAZE_SERIAL_ERROR_TRUNCATED_FRAME,
          "truncated frame reported on idle");
    feed_str(&P, &L, "RED ON\n");
    CHECK(L.count == 2 && L.events[1].kind == BLAZE_SERIAL_EVENT_TEXT_LINE, "text works after idle");
}

static void test_truncated_then_valid(void) {
    /* Frame cut after 22 bytes, immediately followed by a valid frame: the
     * truncated frame swallows the start of the valid one, fails, and the
     * rescan finds the valid frame inside the swallowed bytes. */
    for (size_t cut = 5; cut < VALID_LEN; cut++) {
        reset();
        feed(&P, &L, VALID, cut);
        feed(&P, &L, VALID, VALID_LEN);
        blaze_serial_idle(&P, record, &L);
        CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND) == 1 && is_valid_command(first_kind(&L, BLAZE_SERIAL_EVENT_COMMAND)),
              "cut %zu: valid frame not recovered (commands %zu)", cut, count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND));
        CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_TEXT_LINE) == 0, "cut %zu: text leaked", cut);
    }
}

static void test_bad_payload_lengths(void) {
    uint8_t f[128];
    const uint8_t *payload = VALID + 4 + BLAZE_HEADER_SIZE; /* 16 valid payload bytes */

    /* Declared length 0. */
    reset();
    size_t n = build_raw(f, 3, 0, payload, 0);
    feed(&P, &L, f, n);
    CHECK(L.count >= 1 && L.events[0].error == BLAZE_SERIAL_ERROR_EMPTY_PAYLOAD, "empty payload");
    CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND) == 0, "empty payload executed");

    /* Payload one byte short, correctly sealed: PicoCommand truncated. */
    reset();
    n = build_raw(f, 3, 15, payload, 15);
    feed(&P, &L, f, n);
    feed(&P, &L, VALID, VALID_LEN);
    CHECK(L.events[0].kind == BLAZE_SERIAL_EVENT_ERROR && L.events[0].command_result == PICO_COMMAND_MALFORMED,
          "short payload -> MALFORMED");
    CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND) == 1, "valid frame after short one");

    /* Payload one byte long, correctly sealed: trailing byte. */
    uint8_t longer[17];
    memcpy(longer, payload, 16);
    longer[16] = 0;
    reset();
    n = build_raw(f, 3, 17, longer, 17);
    feed(&P, &L, f, n);
    CHECK(L.count == 1 && L.events[0].command_result == PICO_COMMAND_TRAILING_BYTES, "long payload -> TRAILING");

    /* DATA frame shorter than type + sequence. */
    reset();
    n = build_raw(f, 3, 3, payload, 3);
    feed(&P, &L, f, n);
    CHECK(L.count == 1 && L.events[0].error == BLAZE_SERIAL_ERROR_TRUNCATED_FRAME, "3-byte DATA frame");

    /* Declared length does not match what was sent: CRC catches it. */
    reset();
    memcpy(f, VALID, VALID_LEN);
    f[4 + 15] = (uint8_t)(f[4 + 15] - 1);
    feed(&P, &L, f, VALID_LEN);
    CHECK(L.events[0].error == BLAZE_SERIAL_ERROR_BAD_CRC && count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND) == 0,
          "length mismatch -> BAD_CRC");
}

static void test_crc(void) {
    CHECK(blaze_serial_crc32((const uint8_t *)"123456789", 9) == 0xCBF43926u, "CRC-32 check value");

    /* Every single-bit flip anywhere after the magic is rejected. */
    size_t accepted = 0;
    for (size_t i = 4; i < VALID_LEN; i++) {
        for (int bit = 0; bit < 8; bit++) {
            uint8_t f[64];
            memcpy(f, VALID, VALID_LEN);
            f[i] ^= (uint8_t)(1u << bit);
            reset();
            feed(&P, &L, f, VALID_LEN);
            blaze_serial_idle(&P, record, &L);
            accepted += count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND);
        }
    }
    CHECK(accepted == 0, "%zu single-bit corruptions were executed", accepted);
}

static void test_oversized_payload(void) {
    uint8_t f[512];
    memcpy(f, VALID, 20);
    f[4 + 14] = 0x01; /* 300 bytes */
    f[4 + 15] = 0x2c;
    size_t n = 20;
    /* 300 bytes of junk that would be a valid text command if it leaked. */
    for (int i = 0; i < 30; i++) {
        memcpy(f + n, "RED ON\n\x01\x02\x03", 10);
        n += 10;
    }
    reset();
    feed(&P, &L, f, n);
    feed(&P, &L, VALID, VALID_LEN);
    CHECK(L.events[0].error == BLAZE_SERIAL_ERROR_PAYLOAD_TOO_LARGE, "oversized reported");
    CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_TEXT_LINE) == 0, "oversized payload leaked into text parser");
    CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND) == 1, "valid frame after oversized");
}

static void test_invalid_contents(void) {
    uint8_t f[64];
    struct {
        size_t offset;
        uint8_t byte;
        blaze_serial_error_t error;
        pico_command_result_t result;
        const char *name;
    } cases[] = {
        {4, 9, BLAZE_SERIAL_ERROR_BAD_VERSION, PICO_COMMAND_OK, "header version 9"},
        {20, 1, BLAZE_SERIAL_ERROR_NOT_DATA_FRAME, PICO_COMMAND_OK, "ACK frame type"},
        {25, 2, BLAZE_SERIAL_ERROR_COMMAND, PICO_COMMAND_UNSUPPORTED_VERSION, "PicoCommand version 2"},
        {25, 0, BLAZE_SERIAL_ERROR_COMMAND, PICO_COMMAND_UNSUPPORTED_VERSION, "PicoCommand version 0"},
        {34, 99, BLAZE_SERIAL_ERROR_COMMAND, PICO_COMMAND_UNKNOWN_COMMAND, "unknown command 99"},
        {35, 181, BLAZE_SERIAL_ERROR_COMMAND, PICO_COMMAND_INVALID_VALUE, "servo 181"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        memcpy(f, VALID, VALID_LEN);
        f[cases[i].offset] = cases[i].byte;
        reseal(f, VALID_LEN); /* get past the CRC to exercise the check behind it */
        reset();
        feed(&P, &L, f, VALID_LEN);
        /* Corrupt frame followed by a valid one: must resync and accept it. */
        feed(&P, &L, VALID, VALID_LEN);
        CHECK(L.events[0].kind == BLAZE_SERIAL_EVENT_ERROR && L.events[0].error == cases[i].error &&
                  (cases[i].error != BLAZE_SERIAL_ERROR_COMMAND || L.events[0].command_result == cases[i].result),
              "%s: got error %s/%s", cases[i].name, blaze_serial_error_name(L.events[0].error),
              pico_command_result_name(L.events[0].command_result));
        CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_COMMAND) == 1 && is_valid_command(first_kind(&L, BLAZE_SERIAL_EVENT_COMMAND)),
              "%s: valid frame after corrupt one not accepted", cases[i].name);
    }
}

static void test_no_fallthrough_to_text(void) {
    uint8_t f[64];
    memcpy(f, VALID, VALID_LEN);
    f[34] = 99; /* unknown command */
    reseal(f, VALID_LEN);
    reset();
    feed(&P, &L, f, VALID_LEN);
    feed_str(&P, &L, "RED ON\nGREEN ON\r\n");
    CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_TEXT_LINE) == 0, "text accepted while resynchronizing");
    blaze_serial_idle(&P, record, &L);
    feed_str(&P, &L, "RED ON\n");
    CHECK(count_kind(&L, BLAZE_SERIAL_EVENT_TEXT_LINE) == 1, "text rejected after idle");
}

/* Deterministic fuzz: random bytes with valid frames mixed in. Every COMMAND
 * the parser emits must be one of the injected frames, bit for bit. */
static void test_fuzz(void) {
    uint32_t seed = 12345;
    size_t injected = 0;
    reset();
    for (int round = 0; round < 20000; round++) {
        seed = seed * 1103515245u + 12345u;
        uint32_t choice = (seed >> 16) % 8;
        if (choice == 0) {
            feed(&P, &L, VALID, VALID_LEN);
            injected++;
        } else if (choice == 2) {
            /* A truncated frame. */
            seed = seed * 1103515245u + 12345u;
            feed(&P, &L, VALID, 1 + (seed >> 16) % (VALID_LEN - 1));
        } else if (choice == 1) {
            /* A frame with one random byte corrupted. */
            uint8_t f[64];
            memcpy(f, VALID, VALID_LEN);
            seed = seed * 1103515245u + 12345u;
            f[4 + (seed >> 16) % (VALID_LEN - 4)] ^= (uint8_t)(1u + (seed >> 8) % 255u);
            feed(&P, &L, f, VALID_LEN);
        } else {
            seed = seed * 1103515245u + 12345u;
            uint8_t b = (uint8_t)(seed >> 16);
            blaze_serial_feed(&P, b, record, &L);
        }
        if (L.count > MAX_EVENTS - 64) {
            for (size_t i = 0; i < L.count; i++)
                if (L.events[i].kind == BLAZE_SERIAL_EVENT_COMMAND)
                    CHECK(is_valid_command(&L.events[i]), "fuzz: forged command %u/%u", L.events[i].command.command,
                          L.events[i].command.value);
            L.count = 0;
        }
    }
    for (size_t i = 0; i < L.count; i++)
        if (L.events[i].kind == BLAZE_SERIAL_EVENT_COMMAND) CHECK(is_valid_command(&L.events[i]), "fuzz: forged command");
    printf("Fuzz: %zu valid frames injected among ~%d random bytes and corrupted frames\n", injected, 20000);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <golden_frames.txt>\n", argv[0]);
        return 2;
    }
    VALID_LEN = build_frame(VALID, 3, VALID_TRACE, PICO_CMD_SERVO_SET, 90);

    test_golden(argv[1]);
    test_one_frame();
    test_every_split();
    test_two_frames_one_read();
    test_garbage_before_and_between();
    test_partial_magic_text();
    test_truncated_then_idle();
    test_truncated_then_valid();
    test_bad_payload_lengths();
    test_crc();
    test_oversized_payload();
    test_invalid_contents();
    test_no_fallthrough_to_text();
    test_fuzz();

    printf("Protocol tests: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
