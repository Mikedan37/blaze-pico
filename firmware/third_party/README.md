# Vendored C libraries

Copied into this repo so the firmware builds without the ProjectBlaze repos. Keep them in sync with their sources and re-run `make -C firmware/tests/protocol test` after updating.

## blazebinary/

- Source: BlazeBinary `c/include/blaze_binary.h` and `c/src/blaze_binary.c`
- Version: [BlazeBinary v2.0.0](https://github.com/Mikedan37/BlazeBinary/releases/tag/v2.0.0) (`dfa47fa`); the C files are unchanged since `e3b14f5`
- Changes: none (byte-identical copy)
- Wire compatibility with Swift BlazeBinary is proven in the BlazeBinary repo by `Fixtures/golden/primitives.txt`.

## blazetransport/

- Source: BlazeTransport `c_decoder/blaze_transport.h` and `c_decoder/blaze_transport.c`
- Version: uncommitted working copy (the `c_decoder/` directory is not yet tracked in the BlazeTransport repo). SHA-256 of the copied originals:
  - `blaze_transport.c` `80875ebeb267f14d600920587cedd74fc647d0ff526de5de471fb4fe5f0e6a45`
  - `blaze_transport.h` `b0e2816cca7f60d0501ed6f82648b17baa333a3896c9ba2c5907a518108d682b`
- Changes made here (candidates to upstream):
  1. `blaze_data_frame_t.streamID` renamed to `sequence`. Swift `ConnectionManager.buildDataFramePayload` writes a per-stream send sequence in those 4 bytes, not a stream ID. The packet header's `streamID` is unchanged.
  2. `blaze_data_frame_t.data` is `const uint8_t *` (it points into the caller's const buffer; the old cast dropped `const`).
  3. Added `blaze_encode_header()`, the C mirror of Swift `PacketParser.encode`, used for the C-encode direction of the golden tests.
  4. Explicit casts so the file builds with `-Wconversion -Werror`, removal of an always-false `uint8_t > 255` check, and `size_t` arithmetic for a signed/unsigned comparison. No behavior change.
