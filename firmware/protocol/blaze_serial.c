/*
 * blaze_serial.c
 * See blaze_serial.h.
 */

#include "blaze_serial.h"

#include <string.h>

static const uint8_t MAGIC[4] = {'B', 'L', 'A', 'Z'};

void blaze_serial_init(blaze_serial_t *p) {
    memset(p, 0, sizeof *p);
    p->state = BLAZE_SERIAL_STATE_TEXT;
}

bool blaze_serial_busy(const blaze_serial_t *p) {
    return p->state != BLAZE_SERIAL_STATE_TEXT;
}

static void emit(blaze_serial_event_t *ev, blaze_serial_handler_t handler, void *context) {
    if (handler) handler(ev, context);
}

static void text_char(blaze_serial_t *p, uint8_t byte, blaze_serial_handler_t handler, void *context) {
    if (byte == '\n' || byte == '\r') {
        if (p->line_len > 0) {
            p->line[p->line_len] = '\0';
            blaze_serial_event_t ev = {0};
            ev.kind = BLAZE_SERIAL_EVENT_TEXT_LINE;
            ev.line = p->line;
            emit(&ev, handler, context);
            p->line_len = 0;
        }
    } else if (byte >= 32 && byte <= 126 && p->line_len < BLAZE_SERIAL_MAX_LINE - 1) {
        p->line[p->line_len++] = (char)byte;
    }
}

/*
 * Advance the "BLAZ" matcher. Returns true when the full marker was seen.
 * In text mode, bytes that turn out not to be the marker are passed on as
 * text; in resync mode they are dropped.
 */
static bool match_magic(blaze_serial_t *p, uint8_t byte, bool as_text, blaze_serial_handler_t handler,
                        void *context) {
    if (byte == MAGIC[p->magic_matched]) {
        p->magic_matched++;
        if (p->magic_matched == sizeof MAGIC) {
            p->magic_matched = 0;
            return true;
        }
        return false;
    }

    if (as_text) {
        for (uint8_t i = 0; i < p->magic_matched; i++) text_char(p, MAGIC[i], handler, context);
    }
    p->magic_matched = 0;
    if (byte == MAGIC[0]) {
        p->magic_matched = 1;
    } else if (as_text) {
        text_char(p, byte, handler, context);
    }
    return false;
}

static void start_frame(blaze_serial_t *p) {
    p->state = BLAZE_SERIAL_STATE_HEADER;
    p->frame_len = 0;
    p->payload_len = 0;
    p->line_len = 0; /* text before the marker is discarded */
}

/*
 * Report an error, then rescan the failed frame's bytes (plus any replay
 * input not yet consumed) in resync mode so a frame that began inside
 * them is still found. The failed frame's own marker is not replayed, so
 * every replay is shorter than the one before it.
 */
static void fail(blaze_serial_t *p, blaze_serial_event_t *ev, blaze_serial_handler_t handler, void *context) {
    ev->kind = BLAZE_SERIAL_EVENT_ERROR;
    emit(ev, handler, context);

    uint8_t pending[BLAZE_SERIAL_FRAME_MAX];
    size_t n = 0;
    for (size_t i = 0; i < p->frame_len && n < sizeof pending; i++) pending[n++] = p->frame[i];
    for (size_t i = p->replay_pos; i < p->replay_len && n < sizeof pending; i++) pending[n++] = p->replay[i];
    memcpy(p->replay, pending, n);
    p->replay_len = n;
    p->replay_pos = 0;

    p->state = BLAZE_SERIAL_STATE_RESYNC;
    p->magic_matched = 0;
    p->frame_len = 0;
    p->payload_len = 0;
}

static void finish_header(blaze_serial_t *p, blaze_serial_handler_t handler, void *context) {
    blaze_packet_header_t header;
    blaze_serial_event_t ev = {0};
    (void)blaze_decode_header(p->frame, p->frame_len, &header);
    ev.payload_length = header.payloadLength;

    if (header.version != BLAZE_VERSION) {
        ev.error = BLAZE_SERIAL_ERROR_BAD_VERSION;
    } else if (header.payloadLength == 0) {
        ev.error = BLAZE_SERIAL_ERROR_EMPTY_PAYLOAD;
    } else if (header.payloadLength > BLAZE_SERIAL_MAX_PAYLOAD) {
        ev.error = BLAZE_SERIAL_ERROR_PAYLOAD_TOO_LARGE;
    } else {
        p->payload_len = header.payloadLength;
        p->state = BLAZE_SERIAL_STATE_PAYLOAD;
        return;
    }
    fail(p, &ev, handler, context);
}

uint32_t blaze_serial_crc32(const uint8_t *data, size_t length) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < length; i++) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return crc ^ 0xFFFFFFFFu;
}

static void finish_payload(blaze_serial_t *p, blaze_serial_handler_t handler, void *context) {
    const uint8_t *payload = &p->frame[BLAZE_HEADER_SIZE];
    size_t covered = (size_t)BLAZE_HEADER_SIZE + p->payload_len;
    blaze_serial_event_t ev = {0};
    ev.payload_length = p->payload_len;

    if (blaze_read_uint32_be(&p->frame[covered]) != blaze_serial_crc32(p->frame, covered)) {
        ev.error = BLAZE_SERIAL_ERROR_BAD_CRC;
        fail(p, &ev, handler, context);
        return;
    }

    if (payload[0] != BLAZE_FRAME_DATA) {
        ev.error = BLAZE_SERIAL_ERROR_NOT_DATA_FRAME;
        fail(p, &ev, handler, context);
        return;
    }

    blaze_data_frame_t data;
    if (blaze_decode_data_frame(payload, p->payload_len, &data) != BLAZE_OK) {
        ev.error = BLAZE_SERIAL_ERROR_TRUNCATED_FRAME;
        fail(p, &ev, handler, context);
        return;
    }
    ev.sequence = data.sequence;

    ev.command_result = pico_command_decode(data.data, data.dataLength, &ev.command);
    if (ev.command_result != PICO_COMMAND_OK) {
        ev.error = BLAZE_SERIAL_ERROR_COMMAND;
        fail(p, &ev, handler, context);
        return;
    }

    p->state = BLAZE_SERIAL_STATE_TEXT;
    p->frame_len = 0;
    p->payload_len = 0;
    ev.kind = BLAZE_SERIAL_EVENT_COMMAND;
    emit(&ev, handler, context);
}

static void process(blaze_serial_t *p, uint8_t byte, blaze_serial_handler_t handler, void *context) {
    switch (p->state) {
        case BLAZE_SERIAL_STATE_TEXT:
            if (match_magic(p, byte, true, handler, context)) start_frame(p);
            break;

        case BLAZE_SERIAL_STATE_RESYNC:
            if (match_magic(p, byte, false, handler, context)) start_frame(p);
            break;

        case BLAZE_SERIAL_STATE_HEADER:
            p->frame[p->frame_len++] = byte;
            if (p->frame_len == BLAZE_HEADER_SIZE) finish_header(p, handler, context);
            break;

        case BLAZE_SERIAL_STATE_PAYLOAD:
            p->frame[p->frame_len++] = byte;
            if (p->frame_len == (size_t)BLAZE_HEADER_SIZE + p->payload_len) p->state = BLAZE_SERIAL_STATE_CRC;
            break;

        case BLAZE_SERIAL_STATE_CRC:
            p->frame[p->frame_len++] = byte;
            if (p->frame_len == (size_t)BLAZE_HEADER_SIZE + p->payload_len + BLAZE_SERIAL_CRC_SIZE)
                finish_payload(p, handler, context);
            break;
    }
}

void blaze_serial_feed(blaze_serial_t *p, uint8_t byte, blaze_serial_handler_t handler, void *context) {
    process(p, byte, handler, context);
    while (p->replay_pos < p->replay_len) {
        uint8_t b = p->replay[p->replay_pos++];
        process(p, b, handler, context);
    }
    p->replay_len = 0;
    p->replay_pos = 0;
}

void blaze_serial_idle(blaze_serial_t *p, blaze_serial_handler_t handler, void *context) {
    /* Each pass rescans a strictly shorter buffer, so this terminates. */
    while (p->state == BLAZE_SERIAL_STATE_HEADER || p->state == BLAZE_SERIAL_STATE_PAYLOAD ||
           p->state == BLAZE_SERIAL_STATE_CRC) {
        blaze_serial_event_t ev = {0};
        ev.error = BLAZE_SERIAL_ERROR_TRUNCATED_FRAME;
        ev.payload_length = p->payload_len;
        fail(p, &ev, handler, context);
        while (p->replay_pos < p->replay_len) {
            uint8_t b = p->replay[p->replay_pos++];
            process(p, b, handler, context);
        }
        p->replay_len = 0;
        p->replay_pos = 0;
    }
    if (p->state != BLAZE_SERIAL_STATE_TEXT) {
        p->state = BLAZE_SERIAL_STATE_TEXT;
        p->magic_matched = 0;
        p->frame_len = 0;
        p->payload_len = 0;
        p->line_len = 0;
    }
}

const char *blaze_serial_error_name(blaze_serial_error_t error) {
    switch (error) {
        case BLAZE_SERIAL_ERROR_NONE: return "NONE";
        case BLAZE_SERIAL_ERROR_BAD_VERSION: return "BAD_VERSION";
        case BLAZE_SERIAL_ERROR_EMPTY_PAYLOAD: return "EMPTY_PAYLOAD";
        case BLAZE_SERIAL_ERROR_PAYLOAD_TOO_LARGE: return "PAYLOAD_TOO_LARGE";
        case BLAZE_SERIAL_ERROR_BAD_CRC: return "BAD_CRC";
        case BLAZE_SERIAL_ERROR_NOT_DATA_FRAME: return "NOT_DATA_FRAME";
        case BLAZE_SERIAL_ERROR_TRUNCATED_FRAME: return "TRUNCATED_FRAME";
        case BLAZE_SERIAL_ERROR_COMMAND: return "COMMAND";
    }
    return "UNKNOWN";
}
