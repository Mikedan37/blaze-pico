#ifndef BLAZE_TRANSPORT_H
#define BLAZE_TRANSPORT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// Protocol constants
#define BLAZE_HEADER_SIZE 16
#define BLAZE_VERSION 1
#define BLAZE_MAX_STREAMS 32
#define BLAZE_MAX_ACK_RANGES 255

// Frame types
typedef enum {
    BLAZE_FRAME_DATA      = 0,  // Application data frame
    BLAZE_FRAME_ACK       = 1,  // Acknowledgment frame
    BLAZE_FRAME_PING      = 2,  // Keep-alive ping
    BLAZE_FRAME_PONG      = 3,  // Keep-alive pong
    BLAZE_FRAME_RESET     = 4,  // Stream reset
    BLAZE_FRAME_HANDSHAKE = 5   // Cryptographic handshake
} blaze_frame_type_t;

// Packet header structure
typedef struct {
    uint8_t  version;        // Protocol version
    uint8_t  flags;          // Control flags
    uint32_t connectionID;   // Connection identifier
    uint32_t packetNumber;   // Packet sequence number
    uint32_t streamID;       // Stream identifier
    uint16_t payloadLength;  // Payload size in bytes
} blaze_packet_header_t;

// ACK range structure
typedef struct {
    uint32_t start;  // Start packet number (inclusive)
    uint32_t end;    // End packet number (inclusive)
} blaze_ack_range_t;

// ACK frame structure
typedef struct {
    uint32_t largestAcked;           // Largest acknowledged packet number
    uint8_t  rangeCount;             // Number of ACK ranges
    blaze_ack_range_t ranges[BLAZE_MAX_ACK_RANGES];  // ACK ranges
} blaze_ack_frame_t;

// Data frame structure: [frameType 0][sequence u32 BE][application data]
// Swift ConnectionManager.buildDataFramePayload writes a per-stream send
// sequence here (vendored fix: upstream called this field streamID).
typedef struct {
    uint32_t sequence;       // Per-stream application send sequence
    const uint8_t* data;     // Frame data (not null-terminated), points into the payload
    size_t   dataLength;     // Length of data
} blaze_data_frame_t;

// Handshake frame structure
typedef struct {
    uint8_t publicKey[32];  // X25519 public key (32 bytes)
} blaze_handshake_frame_t;

// Parsed packet structure
typedef struct {
    blaze_packet_header_t header;
    blaze_frame_type_t    frameType;
    
    union {
        blaze_data_frame_t      data;
        blaze_ack_frame_t       ack;
        blaze_handshake_frame_t handshake;
        // Ping/Pong/Reset have no additional data
    } frame;
} blaze_packet_t;

// Error codes
typedef enum {
    BLAZE_OK = 0,
    BLAZE_ERROR_BUFFER_TOO_SMALL,
    BLAZE_ERROR_TRUNCATED,
    BLAZE_ERROR_INVALID_PAYLOAD_LENGTH,
    BLAZE_ERROR_INVALID_FRAME_TYPE,
    BLAZE_ERROR_INVALID_ACK_FORMAT
} blaze_error_t;

// Function prototypes
blaze_error_t blaze_decode_packet(
    const uint8_t* buffer,
    size_t bufferSize,
    blaze_packet_t* packet
);

blaze_error_t blaze_decode_header(
    const uint8_t* buffer,
    size_t bufferSize,
    blaze_packet_header_t* header
);

blaze_error_t blaze_decode_frame(
    const uint8_t* payload,
    size_t payloadSize,
    blaze_frame_type_t* frameType,
    blaze_packet_t* packet
);

blaze_error_t blaze_decode_ack_frame(
    const uint8_t* payload,
    size_t payloadSize,
    blaze_ack_frame_t* ackFrame
);

blaze_error_t blaze_decode_data_frame(
    const uint8_t* payload,
    size_t payloadSize,
    blaze_data_frame_t* dataFrame
);

blaze_error_t blaze_decode_handshake_frame(
    const uint8_t* payload,
    size_t payloadSize,
    blaze_handshake_frame_t* handshakeFrame
);

// Encode a 16-byte header into `buffer` (vendored addition, mirrors Swift PacketParser.encode).
blaze_error_t blaze_encode_header(
    const blaze_packet_header_t* header,
    uint8_t* buffer,
    size_t bufferSize
);

// Utility functions
uint32_t blaze_read_uint32_be(const uint8_t* bytes);
uint16_t blaze_read_uint16_be(const uint8_t* bytes);
void blaze_write_uint32_be(uint8_t* bytes, uint32_t value);
void blaze_write_uint16_be(uint8_t* bytes, uint16_t value);

// Helper macros
#define BLAZE_MIN(a, b) ((a) < (b) ? (a) : (b))

#endif // BLAZE_TRANSPORT_H
