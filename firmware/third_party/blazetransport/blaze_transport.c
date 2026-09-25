#include "blaze_transport.h"
#include <string.h>

// Read big-endian 32-bit integer
uint32_t blaze_read_uint32_be(const uint8_t* bytes) {
    return ((uint32_t)bytes[0] << 24) |
           ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) |
           (uint32_t)bytes[3];
}

// Read big-endian 16-bit integer
uint16_t blaze_read_uint16_be(const uint8_t* bytes) {
    return (uint16_t)(((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1]);
}

// Write big-endian 32-bit integer
void blaze_write_uint32_be(uint8_t* bytes, uint32_t value) {
    bytes[0] = (uint8_t)((value >> 24) & 0xFF);
    bytes[1] = (uint8_t)((value >> 16) & 0xFF);
    bytes[2] = (uint8_t)((value >> 8) & 0xFF);
    bytes[3] = (uint8_t)(value & 0xFF);
}

// Write big-endian 16-bit integer
void blaze_write_uint16_be(uint8_t* bytes, uint16_t value) {
    bytes[0] = (uint8_t)((value >> 8) & 0xFF);
    bytes[1] = (uint8_t)(value & 0xFF);
}

// Decode packet header
blaze_error_t blaze_decode_header(
    const uint8_t* buffer,
    size_t bufferSize,
    blaze_packet_header_t* header
) {
    if (bufferSize < BLAZE_HEADER_SIZE) {
        return BLAZE_ERROR_BUFFER_TOO_SMALL;
    }
    
    header->version = buffer[0];
    header->flags = buffer[1];
    header->connectionID = blaze_read_uint32_be(&buffer[2]);
    header->packetNumber = blaze_read_uint32_be(&buffer[6]);
    header->streamID = blaze_read_uint32_be(&buffer[10]);
    header->payloadLength = blaze_read_uint16_be(&buffer[14]);
    
    return BLAZE_OK;
}

// Encode packet header (vendored addition)
blaze_error_t blaze_encode_header(
    const blaze_packet_header_t* header,
    uint8_t* buffer,
    size_t bufferSize
) {
    if (bufferSize < BLAZE_HEADER_SIZE) {
        return BLAZE_ERROR_BUFFER_TOO_SMALL;
    }

    buffer[0] = header->version;
    buffer[1] = header->flags;
    blaze_write_uint32_be(&buffer[2], header->connectionID);
    blaze_write_uint32_be(&buffer[6], header->packetNumber);
    blaze_write_uint32_be(&buffer[10], header->streamID);
    blaze_write_uint16_be(&buffer[14], header->payloadLength);

    return BLAZE_OK;
}

// Decode ACK frame
blaze_error_t blaze_decode_ack_frame(
    const uint8_t* payload,
    size_t payloadSize,
    blaze_ack_frame_t* ackFrame
) {
    // Minimum size: frame type (1) + largest ACKed (4) + range count (1) = 6 bytes
    if (payloadSize < 6) {
        return BLAZE_ERROR_TRUNCATED;
    }
    
    // Skip frame type byte (already parsed)
    size_t offset = 1;
    
    // Read largest ACKed packet number
    ackFrame->largestAcked = blaze_read_uint32_be(&payload[offset]);
    offset += 4;
    
    // Read range count
    ackFrame->rangeCount = payload[offset];
    offset += 1;
    
    // rangeCount is a uint8_t, so it can never exceed BLAZE_MAX_ACK_RANGES (255).
    // (Vendored: the upstream check here was always false and failed -Werror=type-limits.)
    
    // Calculate required size
    size_t requiredSize = 6 + ((size_t)ackFrame->rangeCount * 8);
    if (payloadSize < requiredSize) {
        return BLAZE_ERROR_TRUNCATED;
    }
    
    // Read ACK ranges
    for (uint8_t i = 0; i < ackFrame->rangeCount; i++) {
        ackFrame->ranges[i].start = blaze_read_uint32_be(&payload[offset]);
        offset += 4;
        ackFrame->ranges[i].end = blaze_read_uint32_be(&payload[offset]);
        offset += 4;
        
        // Validate range
        if (ackFrame->ranges[i].start > ackFrame->ranges[i].end) {
            return BLAZE_ERROR_INVALID_ACK_FORMAT;
        }
    }
    
    return BLAZE_OK;
}

// Decode data frame
blaze_error_t blaze_decode_data_frame(
    const uint8_t* payload,
    size_t payloadSize,
    blaze_data_frame_t* dataFrame
) {
    // Minimum size: frame type (1) + sequence (4) = 5 bytes
    if (payloadSize < 5) {
        return BLAZE_ERROR_TRUNCATED;
    }
    
    // Skip frame type byte (already parsed)
    size_t offset = 1;
    
    // Read per-stream send sequence
    dataFrame->sequence = blaze_read_uint32_be(&payload[offset]);
    offset += 4;
    
    // Remaining bytes are data
    dataFrame->dataLength = payloadSize - offset;
    if (dataFrame->dataLength > 0) {
        dataFrame->data = &payload[offset];
    } else {
        dataFrame->data = NULL;
    }
    
    return BLAZE_OK;
}

// Decode handshake frame
blaze_error_t blaze_decode_handshake_frame(
    const uint8_t* payload,
    size_t payloadSize,
    blaze_handshake_frame_t* handshakeFrame
) {
    // Size: frame type (1) + public key (32) = 33 bytes
    if (payloadSize < 33) {
        return BLAZE_ERROR_TRUNCATED;
    }
    
    // Skip frame type byte (already parsed)
    memcpy(handshakeFrame->publicKey, &payload[1], 32);
    
    return BLAZE_OK;
}

// Decode frame (determines type and calls appropriate decoder)
blaze_error_t blaze_decode_frame(
    const uint8_t* payload,
    size_t payloadSize,
    blaze_frame_type_t* frameType,
    blaze_packet_t* packet
) {
    if (payloadSize < 1) {
        return BLAZE_ERROR_TRUNCATED;
    }
    
    *frameType = (blaze_frame_type_t)payload[0];
    packet->frameType = *frameType;
    
    switch (*frameType) {
        case BLAZE_FRAME_DATA:
            return blaze_decode_data_frame(payload, payloadSize, &packet->frame.data);
            
        case BLAZE_FRAME_ACK:
            return blaze_decode_ack_frame(payload, payloadSize, &packet->frame.ack);
            
        case BLAZE_FRAME_HANDSHAKE:
            return blaze_decode_handshake_frame(payload, payloadSize, &packet->frame.handshake);
            
        case BLAZE_FRAME_PING:
        case BLAZE_FRAME_PONG:
            // No additional data
            return BLAZE_OK;
            
        case BLAZE_FRAME_RESET:
            // Reset frame: frame type (1) + stream ID (4) = 5 bytes
            if (payloadSize < 5) {
                return BLAZE_ERROR_TRUNCATED;
            }
            packet->frame.data.sequence = blaze_read_uint32_be(&payload[1]);
            return BLAZE_OK;
            
        default:
            return BLAZE_ERROR_INVALID_FRAME_TYPE;
    }
}

// Main packet decoder function
blaze_error_t blaze_decode_packet(
    const uint8_t* buffer,
    size_t bufferSize,
    blaze_packet_t* packet
) {
    // Decode header
    blaze_error_t err = blaze_decode_header(buffer, bufferSize, &packet->header);
    if (err != BLAZE_OK) {
        return err;
    }
    
    // Validate payload length matches buffer
    size_t expectedSize = (size_t)BLAZE_HEADER_SIZE + packet->header.payloadLength;
    if (bufferSize < expectedSize) {
        return BLAZE_ERROR_TRUNCATED;
    }
    
    // Validate payload length
    if (packet->header.payloadLength > 0) {
        if (bufferSize < (size_t)BLAZE_HEADER_SIZE + packet->header.payloadLength) {
            return BLAZE_ERROR_INVALID_PAYLOAD_LENGTH;
        }
        
        // Decode frame
        const uint8_t* payload = &buffer[BLAZE_HEADER_SIZE];
        blaze_frame_type_t frameType;
        err = blaze_decode_frame(payload, packet->header.payloadLength, &frameType, packet);
        if (err != BLAZE_OK) {
            return err;
        }
    } else {
        // No payload
        packet->frameType = BLAZE_FRAME_PING;  // Default, but payload is empty
    }
    
    return BLAZE_OK;
}
