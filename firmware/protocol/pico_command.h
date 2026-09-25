/*
 * pico_command.h
 * PicoCommandV1: the Mac -> Pico command message, serialized with BlazeBinary.
 *
 * Wire schema (BlazeBinary fields in order, no schema marker):
 *
 *   version   UInt8   must be 1
 *   traceID   UInt64  big-endian, echoed back in ACK TRACE:<id>
 *   command   UInt8   one of the PICO_CMD_* IDs below
 *   value     UInt8   meaning depends on the command
 *
 * Golden example: version 1, traceID 0x0123456789ABCDEF, command 0x03, value 0x5A
 *   01 01 23 45 67 89 AB CD EF 03 5A
 *
 * The version is an ordinary UInt8 field rather than BlazeBinary's 0xFE
 * schema marker because BlazeBinary writes version 1 as "no marker", which
 * the firmware could not tell apart from a missing or garbled version.
 *
 * Portable C99. No Pico SDK dependency.
 */

#ifndef PICO_COMMAND_H
#define PICO_COMMAND_H

#include <stddef.h>
#include <stdint.h>

#define PICO_COMMAND_VERSION 1
#define PICO_COMMAND_V1_SIZE 11

/* Command IDs */
#define PICO_CMD_RED 1
#define PICO_CMD_GREEN 2
#define PICO_CMD_YELLOW 3
#define PICO_CMD_BLUE 4
#define PICO_CMD_MULTI 5            /* all RGB channels, brightness 0-100 */
#define PICO_CMD_MULTI_RED 6        /* RGB red channel, brightness 0-100 */
#define PICO_CMD_MULTI_GREEN 7      /* RGB green channel, brightness 0-100 */
#define PICO_CMD_MULTI_BLUE 8       /* RGB blue channel, brightness 0-100 */
#define PICO_CMD_ALL 10             /* all LEDs; value is on/off and RGB brightness 0-100 */
#define PICO_CMD_QUERY_STATE 20     /* value must be 0 */
#define PICO_CMD_STATUS 21          /* value must be 0 */
#define PICO_CMD_ENTER_BOOTLOADER 30 /* value must be 1 (explicit arm) */
#define PICO_CMD_SERVO_SET 40       /* angle 0-180 */

typedef struct {
    uint8_t version;
    uint64_t trace_id;
    uint8_t command;
    uint8_t value;
} pico_command_t;

typedef enum {
    PICO_COMMAND_OK = 0,
    PICO_COMMAND_MALFORMED,           /* not a complete BlazeBinary PicoCommand */
    PICO_COMMAND_UNSUPPORTED_VERSION, /* version field is not 1; rest is not parsed */
    PICO_COMMAND_TRAILING_BYTES,      /* extra bytes after the value field */
    PICO_COMMAND_UNKNOWN_COMMAND,
    PICO_COMMAND_INVALID_VALUE,
    PICO_COMMAND_BUFFER_TOO_SMALL
} pico_command_result_t;

/*
 * Decode and fully validate. On any result other than OK, nothing may be
 * executed. `out` is still filled with whatever fields were decoded
 * (trace_id is valid for UNKNOWN_COMMAND, INVALID_VALUE, TRAILING_BYTES)
 * so errors can be reported against the right trace.
 */
pico_command_result_t pico_command_decode(const uint8_t *data, size_t length, pico_command_t *out);

/* Encode (does not validate). Writes exactly PICO_COMMAND_V1_SIZE bytes. */
pico_command_result_t pico_command_encode(const pico_command_t *cmd, uint8_t *buffer, size_t capacity,
                                          size_t *written);

/* Command/value validation only. */
pico_command_result_t pico_command_validate(uint8_t command, uint8_t value);

const char *pico_command_result_name(pico_command_result_t result);

#endif /* PICO_COMMAND_H */
