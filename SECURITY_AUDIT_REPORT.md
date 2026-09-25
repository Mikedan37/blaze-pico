# Security and Correctness Audit Report: main.c
## BLAZE PICO LED Controller Firmware

**Audit Date:** February 21, 2025  
**File:** `/Users/mdanylchuk/pico/blaze-pico/main.c`  
**Scope:** Full file review for buffer overflows, integer issues, memory safety, protocol confusion, race conditions, edge cases, state machine, and GPIO safety

---

## Executive Summary

The audit identified **1 CRITICAL** and **3 HIGH** severity issues, along with several **MEDIUM** and **LOW** findings. The most critical vulnerability allows command injection when oversized binary payloads are rejected—the payload bytes are not discarded and are subsequently interpreted as text commands.

---

## 1. Buffer Overflow Vulnerabilities

### 1.1 ✅ log_append / log_buffer — NO VULNERABILITY
- **Lines:** 113–130
- **Analysis:** Uses `vsnprintf` with explicit `remaining` size; properly clamps `log_buffer_pos`. The `(remaining - 1)` handling for truncated output is correct. Flush threshold at 384 bytes (512 - 128) provides adequate headroom.

### 1.2 ✅ text_line in state machine — NO VULNERABILITY
- **Lines:** 664, 738, 761, 796
- **Analysis:** All writes use `text_pos < MAX_LINE - 1` (or `-2`, `-3` for multi-char rollback). Null termination before `exec()` is correctly applied.

### 1.3 ✅ payload / header — NO VULNERABILITY
- **Lines:** 832–836
- **Analysis:** `payload_len > MAX_PAYLOAD` check prevents overflow. Payload read loop correctly bounds `payload_pos < payload_len`.

### 1.4 ✅ ASCII protocol null-termination — NO VULNERABILITY
- **Lines:** 907–911
- **Analysis:** Correctly handles `payload_len < MAX_PAYLOAD` vs `payload_len == MAX_PAYLOAD` to avoid writing `payload[64]`.

---

## 2. Integer Overflow / Underflow

### 2.1 LOW — state_sequence wraparound
- **File/Line:** main.c:242
- **Severity:** LOW
- **Description:** `state_sequence++` is `uint64_t`; wraparound at 2^64 is theoretically possible.
- **Root cause:** No saturation or wraparound handling.
- **Suggested fix:** For production robustness, consider saturating at UINT64_MAX or documenting that 2^64 toggles is not a supported use case.

### 2.2 LOW — session_counter wraparound
- **File/Line:** main.c:482
- **Severity:** LOW
- **Description:** `session_counter++` can wrap after ~4 billion reconnects.
- **Root cause:** 32-bit counter with no overflow handling.
- **Suggested fix:** Document as acceptable or add wraparound handling if session UUID uniqueness is critical long-term.

### 2.3 ✅ Timestamps — NO VULNERABILITY
- **Analysis:** `to_ms_since_boot`, `time_us_64` are monotonic. `uint64_t` used consistently. Underflow in `time_since_last` and `uptime_ms` is prevented by boot-order and monotonicity.

---

## 3. Memory Safety

### 3.1 ✅ Uninitialized reads — NO VULNERABILITY
- **Analysis:** `text_line`, `header`, `payload` are filled before use. `led_state` is statically initialized. `log_buffer` is only read up to `log_buffer_pos`.

### 3.2 ✅ Use-after-free / dynamic allocation — N/A
- **Analysis:** No dynamic allocation; all buffers are static or stack-allocated.

### 3.3 ✅ Stack usage — NO VULNERABILITY
- **Analysis:** Fixed buffers (~220 bytes local) well within typical Pico stack (4KB).

---

## 4. Command Injection / Protocol Confusion

### 4.1 **CRITICAL — Oversized payload bytes interpreted as text commands**
- **File/Line:** main.c:830–839
- **Severity:** CRITICAL
- **Description:** When `payload_len > MAX_PAYLOAD`, the firmware rejects the packet and resets the parser to `MODE_TEXT`, but **does not consume/drain the payload bytes** from the input stream. Those bytes remain in the CDC buffer and are read in subsequent iterations, where they are parsed as text.
- **Root cause:** Parser resets without discarding the invalid payload; protocol mode switches from binary to text without draining the binary payload.
- **Attack scenario:**
  1. Attacker sends: `BLAZ` + 16-byte header (payload_len=200) + `RED ON\r\n` + padding
  2. Firmware rejects the packet due to oversized payload
  3. Parser resets to `MODE_TEXT`
  4. Bytes `R`, `E`, `D`, ` `, `O`, `N`, `\r`, `\n` are read as text
  5. `exec("RED ON")` is called — command injection despite “rejection”
- **Suggested fix:**
  ```c
  if (payload_len > MAX_PAYLOAD) {
      printf("ERROR: Payload too big: %d (max: %d)\n", payload_len, MAX_PAYLOAD);
      mode = MODE_BLAZE_DRAIN;  // New state: discard payload_len bytes
      bytes_to_drain = payload_len;
      // ... or add a drain loop that reads and discards bytes until bytes_to_drain == 0
  }
  ```
  Add a `MODE_BLAZE_DRAIN` state that reads and discards `payload_len` bytes before returning to `MODE_TEXT`.

### 4.2 HIGH — Batch command index mismatch (11-byte vs 12-byte ambiguity)
- **File/Line:** main.c:879–887, 1152–1163
- **Severity:** HIGH
- **Description:** For `payload_len == 12`, the packet is treated as a batch. `commandCount = payload[9]` (intended as count) is read. In a malformed or mis-sent 11-byte single-command packet with an extra byte, `payload[9]` could be interpreted as both count and (in effect) affect which bytes are used as cmd/value. The loop guard `(12 + i*2) <= payload_len` limits reads, but the semantics of `payload[9]` differ between single (commandID) and batch (count).
- **Root cause:** Overloaded use of `payload[9]` without a clear format discriminator between single (11-byte) and batch (12+ byte) packets.
- **Suggested fix:** Use an explicit frame type or length discriminator (e.g., extra byte, or strict rule: 11 bytes = single, 12+ = batch with `payload[9]` as count). Document the protocol unambiguously and validate that batch format is only used when `payload_len >= 12 + 2*commandCount`.

### 4.3 MEDIUM — ASCII payload with embedded null bytes
- **File/Line:** main.c:904–918
- **Severity:** MEDIUM
- **Description:** If the ASCII payload contains null bytes (e.g., `RED\x00ON`), `exec()` receives a string truncated at the first null. The command may be misinterpreted or rejected unexpectedly.
- **Root cause:** `strlen()` stops at the first null; protocol does not define handling of binary data in ASCII frame.
- **Suggested fix:** Either sanitize (reject payloads with nulls) or explicitly document that ASCII commands must not contain null bytes.

### 4.4 ✅ Format string — NO VULNERABILITY
- **Analysis:** All `printf`/`PROTOCOL_LOG` calls use fixed format strings; user input is passed only as `%s` arguments, so there is no format string vulnerability.

---

## 5. Race Conditions

### 5.1 ✅ USB CDC vs main loop — NO VULNERABILITY
- **Analysis:** Single-threaded design. `session_active`, `accept_commands` are only modified in the main loop. No concurrent access. USB is polled via `getchar_timeout_us` and `stdio_usb_connected()` in the same thread.

---

## 6. Edge Cases

### 6.1 MEDIUM — Heartbeat only on byte receipt
- **File/Line:** main.c:953–956, 1217–1248
- **Severity:** MEDIUM
- **Description:** Heartbeat is checked only after successfully reading a byte. When `c < 0` (timeout), the loop `continue`s and never reaches the heartbeat block. Idle devices (no input) never emit heartbeat.
- **Root cause:** Heartbeat check is placed after the “byte received” path; timeout path skips it.
- **Suggested fix:** Move the heartbeat check before the `if (c < 0) continue;` block, or add a separate check in the timeout path so it runs on a time-based schedule regardless of input.

### 6.2 MEDIUM — payload_len == 0 keeps parser in MODE_BLAZE
- **File/Line:** main.c:837–941
- **Severity:** MEDIUM
- **Description:** When `payload_len == 0`, the condition `payload_pos < payload_len` is false (0 < 0), so the parser hits the `else` block, resets to `MODE_TEXT`, and consumes no payload bytes. This is correct. However, each subsequent byte restarts header parsing; a stream of all-zero headers could cause repeated 16-byte “headers” with payload_len=0, potentially causing unnecessary resets.
- **Root cause:** Zero-length payload is handled but could be optimized or documented.
- **Suggested fix:** Consider explicitly documenting zero-length payload behavior; optional optimization to detect repeated junk and force resync.

### 6.3 LOW — Magic sequence bytes lost when buffer full
- **File/Line:** main.c:762–764, 797–799
- **Severity:** LOW
- **Description:** In `MODE_MAGIC_BL` or `MODE_MAGIC_BLA`, when `text_pos >= MAX_LINE - 2` (or `-3`), `text_pos` is reset to 0 and `B`/`BL`/`BLA` are not appended. Those bytes are effectively dropped.
- **Root cause:** Buffer-full handling prioritizes avoiding overflow over preserving content.
- **Suggested fix:** Document that long lines can truncate; alternatively, flush/process the line before rolling back to avoid silent data loss.

---

## 7. State Machine Issues

### 7.1 HIGH — Parser state not reset after oversized payload rejection
- **File/Line:** main.c:830–839
- **Severity:** HIGH (overlaps with 4.1)
- **Description:** After rejecting oversized payload, `header_pos`, `payload_pos`, `payload_len` are reset, but the input stream is not. The logical “frame” is not fully consumed, leaving the parser logically out of sync.
- **Root cause:** Missing drain phase for rejected payloads.
- **Suggested fix:** As in 4.1: add a drain state/loop to discard the rejected payload before returning to `MODE_TEXT`.

### 7.2 ✅ Mode transitions — generally correct
- **Analysis:** Transitions between `MODE_TEXT`, `MODE_MAGIC_*`, and `MODE_BLAZE` are consistent. Disconnect resets state. No obvious stuck states.

---

## 8. GPIO Safety

### 8.1 ✅ Conflicting GPIO states — NO VULNERABILITY
- **Analysis:** All LED pins are configured as OUTPUT only. No conflicting input/output or alternate functions. `gpio_put` is used consistently.

### 8.2 LOW — Documentation vs code mismatch
- **File/Line:** main.c:22–24 (comments) vs 163–165 (code)
- **Severity:** LOW
- **Description:** Comments describe “GPIO 24, 25, 26” for RGB multicolor, but code uses `MULTI_RED_PIN 18`, `MULTI_GREEN_PIN 19`, `MULTI_BLUE_PIN 20`.
- **Root cause:** Outdated or incorrect comments.
- **Suggested fix:** Update comments to match the actual pin definitions (18, 19, 20).

### 8.3 ✅ Hardware damage risk — LOW
- **Analysis:** LEDs driven with standard active-high logic. No obvious short-circuit or over-current risk from the firmware logic. Ensure hardware uses appropriate series resistors.

---

## Summary Table

| # | Severity   | Category       | Description                                                  |
|---|------------|----------------|--------------------------------------------------------------|
| 1 | CRITICAL   | Protocol       | Oversized payload bytes executed as text commands            |
| 2 | HIGH       | Protocol       | Batch vs single format ambiguity (payload[9])                |
| 3 | HIGH       | State machine  | No drain of rejected oversized payload                       |
| 4 | MEDIUM     | Protocol       | ASCII payload with embedded nulls                            |
| 5 | MEDIUM     | Edge case      | Heartbeat not emitted when idle                              |
| 6 | MEDIUM     | Edge case      | payload_len==0 behavior                                      |
| 7 | LOW        | Integer        | state_sequence / session_counter wraparound                  |
| 8 | LOW        | Edge case      | Magic bytes dropped when buffer full                         |
| 9 | LOW        | Documentation  | GPIO pin number mismatch in comments                         |

---

## Recommended Priority Fixes

1. **CRITICAL:** Add payload drain when rejecting oversized binary packets (see 4.1 / 7.1).
2. **HIGH:** Clarify and validate single vs batch binary format; ensure `payload[9]` interpretation is unambiguous.
3. **MEDIUM:** Fix heartbeat so it runs periodically even when no bytes are received.
4. **MEDIUM:** Define and enforce handling of null bytes in ASCII payloads.
5. **LOW:** Update GPIO comments and document counter wraparound behavior.
