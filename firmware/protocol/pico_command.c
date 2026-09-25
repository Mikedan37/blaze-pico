/*
 * pico_command.c
 * See pico_command.h.
 */

#include "pico_command.h"

#include "blaze_binary.h"

pico_command_result_t pico_command_validate(uint8_t command, uint8_t value) {
    switch (command) {
        case PICO_CMD_RED:
        case PICO_CMD_GREEN:
        case PICO_CMD_YELLOW:
        case PICO_CMD_BLUE:
            return value <= 1 ? PICO_COMMAND_OK : PICO_COMMAND_INVALID_VALUE;
        case PICO_CMD_MULTI:
        case PICO_CMD_MULTI_RED:
        case PICO_CMD_MULTI_GREEN:
        case PICO_CMD_MULTI_BLUE:
        case PICO_CMD_ALL:
            return value <= 100 ? PICO_COMMAND_OK : PICO_COMMAND_INVALID_VALUE;
        case PICO_CMD_QUERY_STATE:
        case PICO_CMD_STATUS:
            return value == 0 ? PICO_COMMAND_OK : PICO_COMMAND_INVALID_VALUE;
        case PICO_CMD_ENTER_BOOTLOADER:
            return value == 1 ? PICO_COMMAND_OK : PICO_COMMAND_INVALID_VALUE;
        case PICO_CMD_SERVO_SET:
            return value <= 180 ? PICO_COMMAND_OK : PICO_COMMAND_INVALID_VALUE;
        default:
            return PICO_COMMAND_UNKNOWN_COMMAND;
    }
}

pico_command_result_t pico_command_decode(const uint8_t *data, size_t length, pico_command_t *out) {
    blaze_binary_reader_t r;
    blaze_binary_reader_init(&r, data, length);

    out->version = 0;
    out->trace_id = 0;
    out->command = 0;
    out->value = 0;

    /* Version first: an unknown version must not be interpreted as V1. */
    if (blaze_binary_read_u8(&r, &out->version) != BLAZE_BINARY_OK) return PICO_COMMAND_MALFORMED;
    if (out->version != PICO_COMMAND_VERSION) return PICO_COMMAND_UNSUPPORTED_VERSION;

    if (blaze_binary_read_u64(&r, &out->trace_id) != BLAZE_BINARY_OK) return PICO_COMMAND_MALFORMED;
    if (blaze_binary_read_u8(&r, &out->command) != BLAZE_BINARY_OK) return PICO_COMMAND_MALFORMED;
    if (blaze_binary_read_u8(&r, &out->value) != BLAZE_BINARY_OK) return PICO_COMMAND_MALFORMED;
    if (blaze_binary_reader_remaining(&r) != 0) return PICO_COMMAND_TRAILING_BYTES;

    return pico_command_validate(out->command, out->value);
}

pico_command_result_t pico_command_encode(const pico_command_t *cmd, uint8_t *buffer, size_t capacity,
                                          size_t *written) {
    blaze_binary_writer_t w;
    blaze_binary_writer_init(&w, buffer, capacity);
    *written = 0;
    if (capacity < PICO_COMMAND_V1_SIZE) return PICO_COMMAND_BUFFER_TOO_SMALL;

    /* Capacity checked above, so these cannot fail. */
    (void)blaze_binary_write_u8(&w, cmd->version);
    (void)blaze_binary_write_u64(&w, cmd->trace_id);
    (void)blaze_binary_write_u8(&w, cmd->command);
    (void)blaze_binary_write_u8(&w, cmd->value);
    *written = w.offset;
    return PICO_COMMAND_OK;
}

const char *pico_command_result_name(pico_command_result_t result) {
    switch (result) {
        case PICO_COMMAND_OK: return "OK";
        case PICO_COMMAND_MALFORMED: return "MALFORMED";
        case PICO_COMMAND_UNSUPPORTED_VERSION: return "UNSUPPORTED_VERSION";
        case PICO_COMMAND_TRAILING_BYTES: return "TRAILING_BYTES";
        case PICO_COMMAND_UNKNOWN_COMMAND: return "UNKNOWN_COMMAND";
        case PICO_COMMAND_INVALID_VALUE: return "INVALID_VALUE";
        case PICO_COMMAND_BUFFER_TOO_SMALL: return "BUFFER_TOO_SMALL";
    }
    return "UNKNOWN";
}
