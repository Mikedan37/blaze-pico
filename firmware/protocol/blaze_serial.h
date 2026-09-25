/*
 * blaze_serial.h
 * USB CDC byte-stream parser: text command lines and BLAZ binary frames.
 *
 * Stream layout of a binary frame:
 *
 *   "BLAZ"                    4 bytes   serial resynchronization marker
 *   BlazeTransport header    16 bytes   version must be 1 (blaze_transport.h)
 *   DATA frame                          frameType 0, sequence u32 BE
 *   PicoCommandV1            11 bytes   BlazeBinary (pico_command.h)
 *   CRC-32                    4 bytes   big-endian, IEEE 802.3 (zlib crc32), over header + payload
 *
 * Anything else is a text line, ended by CR or LF.
 *
 * Safety rules:
 *   - A COMMAND event is emitted only after the CRC, the header, the DATA
 *     frame and the BlazeBinary payload have all been validated. The CRC is
 *     what stops a truncated frame merged with the next one, or a corrupted
 *     byte, from decoding as a different but well-formed command.
 *   - After any binary error the parser discards input until the next
 *     "BLAZ" marker. It never falls back to text mode on its own; the caller
 *     returns it to text mode with blaze_serial_idle() after a quiet period.
 *   - Bytes of a failed frame are rescanned, so a valid frame that started
 *     inside a truncated one is still found.
 *
 * Portable C99. No heap, no globals, no Pico SDK dependency.
 */

#ifndef BLAZE_SERIAL_H
#define BLAZE_SERIAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "blaze_transport.h"
#include "pico_command.h"

#define BLAZE_SERIAL_MAX_LINE 128
#define BLAZE_SERIAL_MAX_PAYLOAD 64
#define BLAZE_SERIAL_CRC_SIZE 4
#define BLAZE_SERIAL_FRAME_MAX (BLAZE_HEADER_SIZE + BLAZE_SERIAL_MAX_PAYLOAD + BLAZE_SERIAL_CRC_SIZE)

typedef enum {
    BLAZE_SERIAL_EVENT_TEXT_LINE,
    BLAZE_SERIAL_EVENT_COMMAND,
    BLAZE_SERIAL_EVENT_ERROR
} blaze_serial_event_kind_t;

typedef enum {
    BLAZE_SERIAL_ERROR_NONE = 0,
    BLAZE_SERIAL_ERROR_BAD_VERSION,       /* header version is not 1 */
    BLAZE_SERIAL_ERROR_EMPTY_PAYLOAD,     /* header payload length is 0 */
    BLAZE_SERIAL_ERROR_PAYLOAD_TOO_LARGE, /* header payload length > BLAZE_SERIAL_MAX_PAYLOAD */
    BLAZE_SERIAL_ERROR_BAD_CRC,           /* CRC-32 over header + payload does not match */
    BLAZE_SERIAL_ERROR_NOT_DATA_FRAME,    /* frame type is not DATA */
    BLAZE_SERIAL_ERROR_TRUNCATED_FRAME,   /* DATA frame shorter than type + sequence, or stream went idle mid-frame */
    BLAZE_SERIAL_ERROR_COMMAND            /* BlazeBinary payload rejected, see command_result */
} blaze_serial_error_t;

typedef struct {
    blaze_serial_event_kind_t kind;
    char *line;                          /* TEXT_LINE: NUL-terminated, valid during the callback */
    pico_command_t command;              /* COMMAND; for ERROR_COMMAND, the fields decoded so far */
    uint32_t sequence;                   /* DATA frame sequence (COMMAND and ERROR_COMMAND) */
    uint16_t payload_length;             /* header payload length, for errors */
    blaze_serial_error_t error;
    pico_command_result_t command_result;
} blaze_serial_event_t;

typedef void (*blaze_serial_handler_t)(const blaze_serial_event_t *event, void *context);

typedef enum {
    BLAZE_SERIAL_STATE_TEXT,
    BLAZE_SERIAL_STATE_HEADER,
    BLAZE_SERIAL_STATE_PAYLOAD,
    BLAZE_SERIAL_STATE_CRC,
    BLAZE_SERIAL_STATE_RESYNC
} blaze_serial_state_t;

typedef struct {
    blaze_serial_state_t state;
    uint8_t magic_matched;
    char line[BLAZE_SERIAL_MAX_LINE];
    size_t line_len;
    uint8_t frame[BLAZE_SERIAL_FRAME_MAX]; /* header + payload + CRC, magic excluded */
    size_t frame_len;
    uint16_t payload_len;
    uint8_t replay[BLAZE_SERIAL_FRAME_MAX];
    size_t replay_len;
    size_t replay_pos;
} blaze_serial_t;

void blaze_serial_init(blaze_serial_t *p);

/* Feed one byte. The handler may be called zero or more times. */
void blaze_serial_feed(blaze_serial_t *p, uint8_t byte, blaze_serial_handler_t handler, void *context);

/*
 * Call after the stream has been quiet for a while. A partial frame is
 * reported as TRUNCATED_FRAME, and RESYNC returns to text mode. A partial
 * text line is kept (a person may be typing slowly).
 */
void blaze_serial_idle(blaze_serial_t *p, blaze_serial_handler_t handler, void *context);

/* True while inside a binary frame or resynchronizing. */
bool blaze_serial_busy(const blaze_serial_t *p);

const char *blaze_serial_error_name(blaze_serial_error_t error);

/* CRC-32 (IEEE 802.3, reflected, init and xorout 0xFFFFFFFF). Check value: "123456789" -> 0xCBF43926. */
uint32_t blaze_serial_crc32(const uint8_t *data, size_t length);

#endif /* BLAZE_SERIAL_H */
