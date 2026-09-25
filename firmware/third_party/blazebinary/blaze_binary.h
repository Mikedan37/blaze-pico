/*
 * blaze_binary.h
 * BlazeBinary C: wire-compatible C implementation of a BlazeBinary subset.
 *
 * The Swift implementation (Sources/BlazeBinary) is authoritative. Every
 * function here produces and accepts exactly the bytes the Swift
 * BlazeBinaryEncoder / BlazeBinaryDecoder do, proven by the shared golden
 * vectors in Fixtures/golden/primitives.txt.
 *
 * Design rules:
 *   - no heap allocation, no global state, caller-owned buffers
 *   - every write checks capacity before touching the buffer
 *   - every read checks remaining bytes before touching the buffer
 *   - on error, the reader/writer offset is left unchanged
 *   - portable C99, no platform headers beyond <stdint.h>/<stddef.h>/<stdbool.h>
 *
 * Copyright (c) 2025 Michael Danylchuk
 * MIT License
 */

#ifndef BLAZE_BINARY_H
#define BLAZE_BINARY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    BLAZE_BINARY_OK = 0,
    BLAZE_BINARY_EOF,                 /* input ended before the value was complete */
    BLAZE_BINARY_INVALID,             /* bytes are not a valid encoding (bad bool, overlong varint) */
    BLAZE_BINARY_OVERFLOW,            /* varint does not fit in 64 bits */
    BLAZE_BINARY_BUFFER_TOO_SMALL,    /* writer capacity exhausted */
    BLAZE_BINARY_UNSUPPORTED_VERSION  /* schema version outside 2...127 */
} blaze_binary_result_t;

typedef struct {
    const uint8_t *data;
    size_t length;
    size_t offset;
} blaze_binary_reader_t;

typedef struct {
    uint8_t *data;
    size_t capacity;
    size_t offset;
} blaze_binary_writer_t;

void blaze_binary_reader_init(blaze_binary_reader_t *r, const uint8_t *data, size_t length);
void blaze_binary_writer_init(blaze_binary_writer_t *w, uint8_t *data, size_t capacity);

/* Bytes not yet read. */
size_t blaze_binary_reader_remaining(const blaze_binary_reader_t *r);

/* UInt8: exactly one byte. */
blaze_binary_result_t blaze_binary_write_u8(blaze_binary_writer_t *w, uint8_t value);
blaze_binary_result_t blaze_binary_read_u8(blaze_binary_reader_t *r, uint8_t *out);

/* UInt16/32/64: fixed width, big-endian. */
blaze_binary_result_t blaze_binary_write_u16(blaze_binary_writer_t *w, uint16_t value);
blaze_binary_result_t blaze_binary_read_u16(blaze_binary_reader_t *r, uint16_t *out);
blaze_binary_result_t blaze_binary_write_u32(blaze_binary_writer_t *w, uint32_t value);
blaze_binary_result_t blaze_binary_read_u32(blaze_binary_reader_t *r, uint32_t *out);
blaze_binary_result_t blaze_binary_write_u64(blaze_binary_writer_t *w, uint64_t value);
blaze_binary_result_t blaze_binary_read_u64(blaze_binary_reader_t *r, uint64_t *out);

/* Swift Int: zigzag, then unsigned LEB128 varint (1 to 10 bytes). */
blaze_binary_result_t blaze_binary_write_int(blaze_binary_writer_t *w, int64_t value);
blaze_binary_result_t blaze_binary_read_int(blaze_binary_reader_t *r, int64_t *out);

/* Unsigned LEB128 varint, as used for lengths and counts. */
blaze_binary_result_t blaze_binary_write_varint(blaze_binary_writer_t *w, uint64_t value);
blaze_binary_result_t blaze_binary_read_varint(blaze_binary_reader_t *r, uint64_t *out);

/* Bool: 0x00 or 0x01. Any other byte is INVALID. */
blaze_binary_result_t blaze_binary_write_bool(blaze_binary_writer_t *w, bool value);
blaze_binary_result_t blaze_binary_read_bool(blaze_binary_reader_t *r, bool *out);

/*
 * Schema version marker: 0xFE followed by one byte, version 2...127.
 * Version 1 is the default and is written as no marker at all.
 *
 * write: must be called on an empty writer. Version 1 writes nothing.
 * read:  applies the same detection rule as Swift BlazeBinaryDecoder.init:
 *        if the whole record is longer than 2 bytes, byte 0 is 0xFE and
 *        byte 1 is 2...127, the marker is consumed and *version is set;
 *        otherwise nothing is consumed and *version is 1.
 *        Must be called at offset 0.
 */
blaze_binary_result_t blaze_binary_write_schema_version(blaze_binary_writer_t *w, uint8_t version);
blaze_binary_result_t blaze_binary_read_schema_version(blaze_binary_reader_t *r, uint8_t *version);

#ifdef __cplusplus
}
#endif

#endif /* BLAZE_BINARY_H */
