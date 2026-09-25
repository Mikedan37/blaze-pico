/*
 * blaze_binary.c
 * BlazeBinary C: see blaze_binary.h. Swift BlazeBinary is authoritative.
 *
 * Copyright (c) 2025 Michael Danylchuk
 * MIT License
 */

#include "blaze_binary.h"

#define BLAZE_BINARY_SCHEMA_MARKER 0xFEu
#define BLAZE_BINARY_MAX_VARINT_BYTES 10u

void blaze_binary_reader_init(blaze_binary_reader_t *r, const uint8_t *data, size_t length) {
    r->data = data;
    r->length = (data == NULL) ? 0 : length;
    r->offset = 0;
}

void blaze_binary_writer_init(blaze_binary_writer_t *w, uint8_t *data, size_t capacity) {
    w->data = data;
    w->capacity = (data == NULL) ? 0 : capacity;
    w->offset = 0;
}

size_t blaze_binary_reader_remaining(const blaze_binary_reader_t *r) {
    return (r->offset <= r->length) ? r->length - r->offset : 0;
}

static size_t writer_space(const blaze_binary_writer_t *w) {
    return (w->offset <= w->capacity) ? w->capacity - w->offset : 0;
}

/* ---- fixed width, big-endian ---- */

static blaze_binary_result_t write_be(blaze_binary_writer_t *w, uint64_t value, unsigned width) {
    if (writer_space(w) < width) return BLAZE_BINARY_BUFFER_TOO_SMALL;
    for (unsigned i = 0; i < width; i++) {
        unsigned shift = 8u * (width - 1u - i);
        w->data[w->offset + i] = (uint8_t)((value >> shift) & 0xFFu);
    }
    w->offset += width;
    return BLAZE_BINARY_OK;
}

static blaze_binary_result_t read_be(blaze_binary_reader_t *r, uint64_t *out, unsigned width) {
    if (blaze_binary_reader_remaining(r) < width) return BLAZE_BINARY_EOF;
    uint64_t value = 0;
    for (unsigned i = 0; i < width; i++) {
        value = (value << 8) | r->data[r->offset + i];
    }
    r->offset += width;
    *out = value;
    return BLAZE_BINARY_OK;
}

blaze_binary_result_t blaze_binary_write_u8(blaze_binary_writer_t *w, uint8_t value) {
    return write_be(w, value, 1);
}

blaze_binary_result_t blaze_binary_read_u8(blaze_binary_reader_t *r, uint8_t *out) {
    uint64_t v;
    blaze_binary_result_t res = read_be(r, &v, 1);
    if (res == BLAZE_BINARY_OK) *out = (uint8_t)v;
    return res;
}

blaze_binary_result_t blaze_binary_write_u16(blaze_binary_writer_t *w, uint16_t value) {
    return write_be(w, value, 2);
}

blaze_binary_result_t blaze_binary_read_u16(blaze_binary_reader_t *r, uint16_t *out) {
    uint64_t v;
    blaze_binary_result_t res = read_be(r, &v, 2);
    if (res == BLAZE_BINARY_OK) *out = (uint16_t)v;
    return res;
}

blaze_binary_result_t blaze_binary_write_u32(blaze_binary_writer_t *w, uint32_t value) {
    return write_be(w, value, 4);
}

blaze_binary_result_t blaze_binary_read_u32(blaze_binary_reader_t *r, uint32_t *out) {
    uint64_t v;
    blaze_binary_result_t res = read_be(r, &v, 4);
    if (res == BLAZE_BINARY_OK) *out = (uint32_t)v;
    return res;
}

blaze_binary_result_t blaze_binary_write_u64(blaze_binary_writer_t *w, uint64_t value) {
    return write_be(w, value, 8);
}

blaze_binary_result_t blaze_binary_read_u64(blaze_binary_reader_t *r, uint64_t *out) {
    return read_be(r, out, 8);
}

/* ---- varint (unsigned LEB128) ---- */

blaze_binary_result_t blaze_binary_write_varint(blaze_binary_writer_t *w, uint64_t value) {
    uint8_t tmp[BLAZE_BINARY_MAX_VARINT_BYTES];
    size_t n = 0;
    do {
        uint8_t byte = (uint8_t)(value & 0x7Fu);
        value >>= 7;
        if (value != 0) byte |= 0x80u;
        tmp[n++] = byte;
    } while (value != 0);

    if (writer_space(w) < n) return BLAZE_BINARY_BUFFER_TOO_SMALL;
    for (size_t i = 0; i < n; i++) w->data[w->offset + i] = tmp[i];
    w->offset += n;
    return BLAZE_BINARY_OK;
}

/*
 * Accepts exactly the canonical encodings Swift's encoder produces.
 * Stricter than Swift's decoder in two documented cases (both are bytes no
 * Swift encoder can produce): overlong encodings such as 80 00 are INVALID,
 * and a 10th byte above 0x01 is OVERFLOW (Swift silently drops those bits).
 */
blaze_binary_result_t blaze_binary_read_varint(blaze_binary_reader_t *r, uint64_t *out) {
    uint64_t result = 0;
    size_t avail = blaze_binary_reader_remaining(r);

    for (unsigned i = 0; i < BLAZE_BINARY_MAX_VARINT_BYTES; i++) {
        if (i >= avail) return BLAZE_BINARY_EOF;
        uint8_t byte = r->data[r->offset + i];
        uint8_t bits = byte & 0x7Fu;

        if (i == BLAZE_BINARY_MAX_VARINT_BYTES - 1u) {
            /* 10th byte carries only bit 63 and must terminate. */
            if (byte & 0x80u) return BLAZE_BINARY_INVALID;
            if (bits > 1u) return BLAZE_BINARY_OVERFLOW;
        }
        result |= (uint64_t)bits << (7u * i);

        if ((byte & 0x80u) == 0) {
            if (i > 0 && byte == 0) return BLAZE_BINARY_INVALID; /* overlong */
            r->offset += i + 1u;
            *out = result;
            return BLAZE_BINARY_OK;
        }
    }
    return BLAZE_BINARY_INVALID; /* unreachable: 10th byte always returns */
}

/* ---- Int (zigzag varint) ---- */

blaze_binary_result_t blaze_binary_write_int(blaze_binary_writer_t *w, int64_t value) {
    /* (value << 1) ^ (value >> 63), computed in unsigned space: no signed overflow. */
    uint64_t u = (uint64_t)value;
    uint64_t sign = (value < 0) ? UINT64_MAX : 0u;
    return blaze_binary_write_varint(w, (u << 1) ^ sign);
}

blaze_binary_result_t blaze_binary_read_int(blaze_binary_reader_t *r, int64_t *out) {
    uint64_t zz;
    blaze_binary_result_t res = blaze_binary_read_varint(r, &zz);
    if (res != BLAZE_BINARY_OK) return res;
    uint64_t u = (zz >> 1) ^ (0u - (zz & 1u));
    /* Two's complement reinterpretation without implementation-defined conversion. */
    *out = (u <= (uint64_t)INT64_MAX) ? (int64_t)u : -(int64_t)(UINT64_MAX - u) - 1;
    return BLAZE_BINARY_OK;
}

/* ---- Bool ---- */

blaze_binary_result_t blaze_binary_write_bool(blaze_binary_writer_t *w, bool value) {
    return write_be(w, value ? 1u : 0u, 1);
}

blaze_binary_result_t blaze_binary_read_bool(blaze_binary_reader_t *r, bool *out) {
    if (blaze_binary_reader_remaining(r) < 1) return BLAZE_BINARY_EOF;
    uint8_t byte = r->data[r->offset];
    if (byte > 1u) return BLAZE_BINARY_INVALID;
    r->offset += 1;
    *out = (byte == 1u);
    return BLAZE_BINARY_OK;
}

/* ---- schema version marker ---- */

blaze_binary_result_t blaze_binary_write_schema_version(blaze_binary_writer_t *w, uint8_t version) {
    if (version == 1) return BLAZE_BINARY_OK;
    if (version < 2 || version > 127) return BLAZE_BINARY_UNSUPPORTED_VERSION;
    if (w->offset != 0) return BLAZE_BINARY_INVALID;
    if (writer_space(w) < 2) return BLAZE_BINARY_BUFFER_TOO_SMALL;
    w->data[0] = BLAZE_BINARY_SCHEMA_MARKER;
    w->data[1] = version;
    w->offset = 2;
    return BLAZE_BINARY_OK;
}

blaze_binary_result_t blaze_binary_read_schema_version(blaze_binary_reader_t *r, uint8_t *version) {
    if (r->offset != 0) return BLAZE_BINARY_INVALID;
    if (r->length > 2 && r->data[0] == BLAZE_BINARY_SCHEMA_MARKER &&
        (r->data[1] & 0x80u) == 0 && r->data[1] >= 2u) {
        *version = r->data[1];
        r->offset = 2;
    } else {
        *version = 1;
    }
    return BLAZE_BINARY_OK;
}
