/*
    ============================================
    BLAZE PICO LED CONTROLLER - PRODUCTION VERSION
    ============================================

    Supports BOTH:
    1. Binary command protocol (agent-friendly)
    2. Direct text commands (debugging)

    Binary Protocol:
        Payload: [frameType(1), traceID(8), commandID(1), value(1)] = 11 bytes total
        Command IDs: 1=RED, 2=GREEN, 3=YELLOW, 4=BLUE, 5=MULTI (all RGB), 6=MULTI_RED, 7=MULTI_GREEN, 8=MULTI_BLUE, 10=ALL, 20=QUERY_STATE, 21=STATUS, 30=BOOTLOADER, 40=SERVO_SET
        Values: 0=OFF, 1=ON (for LEDs); 2-100=PWM brightness % (for MULTI_RED/GREEN/BLUE); 0-180 (for SERVO_SET angle)
        Trace ID: 64-bit identifier for end-to-end tracing

    Text Protocol (backward compatible):
        RED ON, GREEN OFF, ALL ON, SERVO 90, MULTI_RED 50 (brightness %), etc.

    Generic Hardware Text Protocol:
        GPIO SET <pin> <0|1>              - Set pin high/low
        GPIO GET <pin>                    - Read pin → GPIO_READ: pin=N value=V
        GPIO MODE <pin> <OUT|IN|IN_PU|IN_PD> - Set pin direction/pull
        PWM SET <pin> <freq_hz> <duty%>   - Enable PWM on pin
        PWM STOP <pin>                    - Disable PWM on pin
        ADC READ <pin>                    - Read ADC → ADC_READ: pin=N value=V

    Introspection Protocol:
        DEVICE_INFO                       - Device info → DEVICE_INFO_BEGIN...DEVICE_INFO_END
        PINMAP                            - Pin capabilities → PINMAP_BEGIN...PINMAP_END

    GPIO mapping:
        Red        -> GPIO 14
        Green      -> GPIO 15
        Yellow     -> GPIO 16
        Blue       -> GPIO 17
        Multicolor RGB -> GPIO 18 (Red), GPIO 19 (Green), GPIO 20 (Blue)
        Servo      -> GPIO 21 (PWM, 50Hz)
        Feedback   -> GPIO readback (via gpio_get)

    ═══════════════════════════════════════════════════════════════════════════════
    🚨 CRITICAL USB SESSION LIFECYCLE INVARIANT 🚨
    ═══════════════════════════════════════════════════════════════════════════════
    
    On every USB session start (boot or reconnect), messages MUST be emitted in
    this EXACT order:
    
        1. SESSION:<uuid>
        2. STATE: seq=... R=... G=... Y=... B=... MR=... MG=... MB=... S=...
        3. BLAZE_READY
    
    ⚠️  NEVER change this order. ⚠️
    
    Host session correlation logic depends on this sequence. Breaking this
    invariant will cause:
        - Host session tracking failures
        - Stale state correlation
        - Ghost ACK problems
        - Sequence number desynchronization
    
    This is epoch-based identity: each reconnect = new epoch = new session UUID.
    The SESSION message establishes the epoch, STATE provides initial state,
    and BLAZE_READY gates command execution.
    
    ═══════════════════════════════════════════════════════════════════════════════
    ⚠️  KNOWN USB CDC BEHAVIORAL QUIRKS (NOT ARCHITECTURAL FLAWS) ⚠️
    ═══════════════════════════════════════════════════════════════════════════════
    
    USB CDC is a chaos goblin. These are transport-layer realities, not design bugs:
    
    1. Host may miss first packet after port open (especially after sleep/wake)
       → Host MUST tolerate missing first outbound command after READY
       → Our SESSION→STATE→READY sequence mitigates this
    
    2. CDC TX can stall for 200-400ms under system load
       → Normal latency: ~80ms ACK, ~160ms total
       → Occasional spikes: 400ms+ (USB scheduling garbage)
       → Host timeout logic must account for this
    
    3. Rapid unplug/replug can reuse same tty path
       → Session UUID protects against this (epoch identity)
       → This is exactly why epoch-based identity matters
    
    4. USB disconnect mid-write may succeed locally but fail on device
       → CDC buffers exist on both ends
       → ACK/STATE_CHANGE confirmation model mitigates this
    
    These are USB CDC realities, not firmware bugs. The architecture handles them.
    
    ═══════════════════════════════════════════════════════════════════════════════
*/

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include "pico/stdlib.h"
#include "pico/bootrom.h"  // For reset_usb_boot()
#include "hardware/resets.h"  // For reset handling
#include "hardware/gpio.h"  // For direct GPIO access
#include "tusb.h"  // For tud_cdc_write_available() back-pressure check
#include "hardware/pwm.h"  // For servo motor PWM control
#include "hardware/adc.h"  // For ADC reads on GP26-GP29
#include "pico/unique_id.h"  // For hardware-burned unique board ID
#include "blaze_serial.h"    // USB stream parser: text lines + BLAZ frames (portable, host-tested)
#include "pico_command.h"    // PicoCommandV1 (BlazeBinary) command IDs and validation

// Device identity (reported via CMD_STATUS and DEVICE_INFO)
#define FW_VERSION       "1.4.0"
#define PROTOCOL_VERSION 1
#define DEVICE_MODEL     "BLAZE_PICO"

// Hardware-unique device ID (from RP2350 OTP, stable across reboots/reflashes)
static char device_id_str[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];

// Structured logging support (optional via compile flag)
#ifndef ENABLE_USB_LIFECYCLE_LOGS
#define ENABLE_USB_LIFECYCLE_LOGS 1  // Enable by default, set to 0 to disable
#endif

#ifndef ENABLE_DEBUG_LOGS
#define ENABLE_DEBUG_LOGS 0  // Disable verbose debug logs by default (expensive on USB CDC)
#endif

#ifndef ENABLE_TELEMETRY_LOGS
#define ENABLE_TELEMETRY_LOGS 1  // Enable telemetry (GPIO_SET_START, etc.) by default
#endif

// Batched logging: accumulate messages, flush periodically
// CRITICAL: USB CDC fflush() is expensive - batch messages when possible
static char log_buffer[512];
static int log_buffer_pos = 0;

static void log_flush(void) {
    if (log_buffer_pos > 0) {
        printf("%.*s", log_buffer_pos, log_buffer);
        log_buffer_pos = 0;
        fflush(stdout);
    }
}

static void log_append(const char *fmt, ...) {
    if (log_buffer_pos >= (int)(sizeof(log_buffer)) - 128) {
        log_flush();  // Flush if buffer getting full
    }
    int remaining = (int)(sizeof(log_buffer)) - log_buffer_pos;
    if (remaining <= 0) {
        log_flush();
        remaining = (int)(sizeof(log_buffer));
    }
    va_list args;
    va_start(args, fmt);
    int written = vsnprintf(log_buffer + log_buffer_pos, remaining, fmt, args);
    va_end(args);
    // vsnprintf returns what *would* have been written; clamp to actual space used
    if (written > 0) {
        log_buffer_pos += (written < remaining) ? written : (remaining - 1);
    }
}

#if ENABLE_USB_LIFECYCLE_LOGS
#define USB_LOG(fmt, ...) do { log_append("[USB] " fmt "\n", ##__VA_ARGS__); log_flush(); } while(0)
#define BOOT_LOG(fmt, ...) do { log_append("[BOOT] " fmt "\n", ##__VA_ARGS__); log_flush(); } while(0)
#define SESSION_LOG(fmt, ...) do { log_append("[SESSION] " fmt "\n", ##__VA_ARGS__); log_flush(); } while(0)
#define READY_LOG(fmt, ...) do { log_append("[READY] " fmt "\n", ##__VA_ARGS__); log_flush(); } while(0)
#else
#define USB_LOG(fmt, ...) ((void)0)
#define BOOT_LOG(fmt, ...) ((void)0)
#define SESSION_LOG(fmt, ...) ((void)0)
#define READY_LOG(fmt, ...) ((void)0)
#endif

#if ENABLE_DEBUG_LOGS
#define DEBUG_LOG(fmt, ...) do { log_append(fmt "\n", ##__VA_ARGS__); } while(0)
#else
#define DEBUG_LOG(fmt, ...) ((void)0)
#endif

#if ENABLE_TELEMETRY_LOGS
#define TELEMETRY_LOG(fmt, ...) do { log_append(fmt "\n", ##__VA_ARGS__); } while(0)
#else
#define TELEMETRY_LOG(fmt, ...) ((void)0)
#endif

// Critical protocol messages always flush immediately (SESSION, STATE, BLAZE_READY, ACK)
#define PROTOCOL_LOG(fmt, ...) do { printf(fmt "\n", ##__VA_ARGS__); fflush(stdout); } while(0)

// LED pin mapping: GP14-GP20 (matches physical wiring)
#define RED_PIN 14
#define GREEN_PIN 15
#define YELLOW_PIN 16
#define BLUE_PIN 17
#define MULTI_RED_PIN 18    // RGB multicolor LED - Red channel (GP18, physical pin 24)
#define MULTI_GREEN_PIN 19   // RGB multicolor LED - Green channel (GP19, physical pin 25)
#define MULTI_BLUE_PIN 20    // RGB multicolor LED - Blue channel (GP20, physical pin 26)
// NOTE: FEEDBACK_PIN was GPIO 19, conflicting with MULTI_GREEN_PIN.
// Feedback/loopback is handled via gpio_get() readback instead of a dedicated pin.
// If a dedicated feedback pin is needed, assign an unused GPIO (e.g., GPIO 21).
// #define FEEDBACK_PIN 21

#define MAX_LINE BLAZE_SERIAL_MAX_LINE

// Command IDs (binary protocol). Defined once in protocol/pico_command.h.
#define CMD_RED PICO_CMD_RED
#define CMD_GREEN PICO_CMD_GREEN
#define CMD_YELLOW PICO_CMD_YELLOW
#define CMD_BLUE PICO_CMD_BLUE
#define CMD_MULTI PICO_CMD_MULTI
#define CMD_MULTI_RED PICO_CMD_MULTI_RED
#define CMD_MULTI_GREEN PICO_CMD_MULTI_GREEN
#define CMD_MULTI_BLUE PICO_CMD_MULTI_BLUE
#define CMD_ALL PICO_CMD_ALL
#define CMD_QUERY_STATE PICO_CMD_QUERY_STATE
#define CMD_STATUS PICO_CMD_STATUS
#define CMD_ENTER_BOOTLOADER PICO_CMD_ENTER_BOOTLOADER
#define CMD_SERVO_SET PICO_CMD_SERVO_SET

// A partial binary frame or a resync is abandoned after this much silence,
// and the parser returns to text mode. Frames arrive in one USB write, so a
// gap this long mid-frame means the frame was truncated.
#define SERIAL_IDLE_MS 250

// Servo pin and PWM configuration
#define SERVO_PIN 21
#define SERVO_MIN_PULSE 700      // 0 degrees  (safe range, avoids end-stop grinding)
#define SERVO_MAX_PULSE 2300     // 180 degrees (safe range)

// LED state tracking
// [0]=RED, [1]=GREEN, [2]=YELLOW, [3]=BLUE, [4]=MULTI_RED, [5]=MULTI_GREEN, [6]=MULTI_BLUE
static bool led_state[7] = {false, false, false, false, false, false, false};

// Multi-LED brightness (0=off, 100=full on). Indices: [0]=MULTI_RED, [1]=MULTI_GREEN, [2]=MULTI_BLUE
static uint8_t multi_led_brightness[3] = {0, 0, 0};

// LED pin mapping (static global - avoid recreating in functions)
// Standard LEDs: [0-3] = RED, GREEN, YELLOW, BLUE
// RGB Multicolor: [4-6] = MULTI_RED, MULTI_GREEN, MULTI_BLUE
static const int led_pins[7] = {
    RED_PIN, GREEN_PIN, YELLOW_PIN, BLUE_PIN,
    MULTI_RED_PIN, MULTI_GREEN_PIN, MULTI_BLUE_PIN
};

// Track whether PWM slice 9 (pins 18/19) has been initialized for LED dimming
static bool multi_pwm_slice9_init = false;

// Servo state tracking
static uint16_t servo_angle = 90;  // Default center position

// ---------- Generic GPIO runtime configuration ----------
// Configurable reserved pin set: pins managed by dedicated subsystems (LEDs, servo).
// Generic GPIO/PWM/ADC commands targeting these pins are rejected.
// Adjust this array when changing physical wiring.
#ifndef RESERVED_PIN_COUNT
#define RESERVED_PIN_COUNT 8
#endif
static const uint8_t reserved_pins[RESERVED_PIN_COUNT] = {
    14, 15, 16, 17,   // LED pins (RED, GREEN, YELLOW, BLUE)
    18, 19, 20,        // Multicolor RGB LED pins
    21                 // Servo PWM pin
};

// Bitmask tracking which generic GPIO pins have been initialized (avoids redundant gpio_init)
static uint32_t gpio_initialized_mask = 0;
// Bitmask tracking which pins have active PWM (for cleanup / conflict detection)
static uint32_t pwm_active_mask = 0;
// Whether the ADC peripheral has been initialized
static bool adc_initialized = false;

static bool is_pin_reserved(int pin) {
    for (int i = 0; i < RESERVED_PIN_COUNT; i++) {
        if (reserved_pins[i] == pin) return true;
    }
    return false;
}

static bool is_valid_gpio_pin(int pin) {
    return pin >= 0 && pin <= 29;
}

static bool is_valid_adc_pin(int pin) {
    return pin >= 26 && pin <= 29;
}

static void ensure_gpio_initialized(int pin) {
    if (!(gpio_initialized_mask & (1u << pin))) {
        gpio_init(pin);
        gpio_initialized_mask |= (1u << pin);
    }
}

// Boot state tracking
static bool accept_commands = false;
static uint64_t boot_timestamp_ms = 0;
static uint64_t ready_timestamp_ms = 0;

// State sequence number (monotonic counter for deduplication)
// Increments on every state mutation (LED change)
// Resets to 0 on firmware reboot
static uint64_t state_sequence = 0;

// Session UUID (generated on boot/reconnect, identifies this firmware session)
// Used by host to detect device reboots and reset sequence tracking
// MUST change on every reconnect to ensure host detects session restart
// Epoch-based identity: each reconnect = new epoch = new UUID
static uint32_t session_uuid = 0;
static bool session_active = false;
static uint32_t session_counter = 0;  // Monotonic counter for collision avoidance
static uint64_t last_session_start_ms = 0;  // Timestamp of last session start (reconnect spam protection)

// ---------- LED setup ----------

void setup_led(int pin){
    gpio_init(pin);
    gpio_disable_pulls(pin);  // CRITICAL: Disable pulls on cold boot
    gpio_set_dir(pin, GPIO_OUT);
    gpio_put(pin, 0);  // Start with LEDs OFF (active-HIGH: LOW = OFF)
}

// ---------- Update LED state and GPIO ----------

void set_led_state(int index, bool state) {
    if(index < 0 || index >= 7) return;
    
    // Only increment sequence if state actually changes
    if(led_state[index] != state) {
        state_sequence++;
    }
    
    led_state[index] = state;
    
    // CRITICAL: LEDs are active-HIGH (GPIO → resistor → LED → GND)
    // GPIO HIGH = LED ON, GPIO LOW = LED OFF
    gpio_put(led_pins[index], state ? 1 : 0);  // active-HIGH: state=true means GPIO=1 (LED ON)
}

// ---------- Multi-LED PWM brightness control ----------
// value=0: off, value=1: full on (gpio, no PWM), value=2-100: PWM brightness %
// Uses same PWM parameters as servo (clkdiv=125, wrap=19999, 50 Hz) because
// MULTI_BLUE (pin 20) shares PWM slice 10 with SERVO (pin 21).

void set_multi_led_brightness(int channel, uint8_t value) {
    if (channel < 0 || channel > 2) return;

    int led_index = channel + 4;
    int pin = led_pins[led_index];
    uint8_t brightness = value;
    if (value == 1) brightness = 100;
    if (brightness > 100) brightness = 100;

    if (multi_led_brightness[channel] == brightness) return;

    multi_led_brightness[channel] = brightness;
    state_sequence++;

    if (brightness == 0) {
        gpio_set_function(pin, GPIO_FUNC_SIO);
        gpio_init(pin);
        gpio_set_dir(pin, GPIO_OUT);
        gpio_put(pin, 0);
        led_state[led_index] = false;
    } else if (brightness == 100) {
        gpio_set_function(pin, GPIO_FUNC_SIO);
        gpio_init(pin);
        gpio_set_dir(pin, GPIO_OUT);
        gpio_put(pin, 1);
        led_state[led_index] = true;
    } else {
        uint slice = pwm_gpio_to_slice_num(pin);
        gpio_set_function(pin, GPIO_FUNC_PWM);
        if (slice != pwm_gpio_to_slice_num(SERVO_PIN)) {
            if (!multi_pwm_slice9_init) {
                pwm_set_clkdiv(slice, 125.0f);
                pwm_set_wrap(slice, 19999);
                pwm_set_enabled(slice, true);
                multi_pwm_slice9_init = true;
            }
        }
        uint16_t level = (uint16_t)((uint32_t)brightness * 200);
        pwm_set_gpio_level(pin, level);
        led_state[led_index] = true;
    }
}

// ---------- Servo setup and control ----------

void setup_servo(int pin) {
    gpio_set_function(pin, GPIO_FUNC_PWM);
    uint slice = pwm_gpio_to_slice_num(pin);
    // 125 MHz / 125 = 1 MHz clock → 1 us per tick
    // wrap = 19999 → 20000 ticks = 20 ms period = 50 Hz
    pwm_set_clkdiv(slice, 125.0f);
    pwm_set_wrap(slice, 19999);
    // Set initial position to center (90 degrees)
    uint16_t pulse = SERVO_MIN_PULSE +
        (uint16_t)((uint32_t)(SERVO_MAX_PULSE - SERVO_MIN_PULSE) * servo_angle / 180);
    pwm_set_gpio_level(pin, pulse);
    pwm_set_enabled(slice, true);
}

void set_servo_angle(uint16_t new_angle) {
    if (new_angle > 180) new_angle = 180;
    if (new_angle == servo_angle) return;  // JITTER PREVENTION: only update PWM on change
    servo_angle = new_angle;
    state_sequence++;
    uint16_t pulse = SERVO_MIN_PULSE +
        (uint16_t)((uint32_t)(SERVO_MAX_PULSE - SERVO_MIN_PULSE) * servo_angle / 180);
    pwm_set_gpio_level(SERVO_PIN, pulse);
}

// ---------- Command execution helpers (split responsibilities) ----------

// Execute command logic (pure execution, no logging)
static void execute_command(uint8_t commandID, uint8_t value) {
    bool state = (value != 0);
    
    switch(commandID) {
        case CMD_RED:
            set_led_state(0, state);
            break;
            
        case CMD_GREEN:
            set_led_state(1, state);
            break;
            
        case CMD_YELLOW:
            set_led_state(2, state);
            break;
            
        case CMD_BLUE:
            set_led_state(3, state);
            break;
            
        case CMD_MULTI:
            set_multi_led_brightness(0, value);
            set_multi_led_brightness(1, value);
            set_multi_led_brightness(2, value);
            break;
            
        case CMD_MULTI_RED:
            set_multi_led_brightness(0, value);
            break;
            
        case CMD_MULTI_GREEN:
            set_multi_led_brightness(1, value);
            break;
            
        case CMD_MULTI_BLUE:
            set_multi_led_brightness(2, value);
            break;
            
        case CMD_ALL:
            for(int i = 0; i < 4; i++) {
                set_led_state(i, state);
            }
            set_multi_led_brightness(0, value);
            set_multi_led_brightness(1, value);
            set_multi_led_brightness(2, value);
            if (!state) {
                gpio_put(RED_PIN, 0);
                gpio_put(GREEN_PIN, 0);
                gpio_put(YELLOW_PIN, 0);
                gpio_put(BLUE_PIN, 0);
            }
            break;
            
        case CMD_SERVO_SET:
            set_servo_angle((uint16_t)value);
            break;
            
        default:
            // Unknown command - handled by caller
            break;
    }
}

// Emit ACK message (protocol-critical, always flushed)
static void emit_ack(uint64_t traceID, uint8_t commandID, uint8_t value) {
    PROTOCOL_LOG("ACK TRACE:%llu cmdID=%d value=%d", traceID, commandID, value);
}

// Emit STATE_CHANGE message (protocol-critical, always flushed)
// MR/MG/MB report brightness (0-100) instead of 0/1. Backward compatible: non-zero = on.
static void emit_state_change(uint64_t traceID) {
    PROTOCOL_LOG("STATE_CHANGE: trace=%llu seq=%llu R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d S=%d",
                 traceID,
                 state_sequence,
                 led_state[0] ? 1 : 0,
                 led_state[1] ? 1 : 0,
                 led_state[2] ? 1 : 0,
                 led_state[3] ? 1 : 0,
                 multi_led_brightness[0],
                 multi_led_brightness[1],
                 multi_led_brightness[2],
                 servo_angle);
}

// Validate GPIO state (for debugging/telemetry)
static bool validate_gpio_state(uint8_t commandID) {
    int pin_index = -1;
    bool gpio_feedback = false;
    
    switch(commandID) {
        case CMD_RED: pin_index = 0; break;
        case CMD_GREEN: pin_index = 1; break;
        case CMD_YELLOW: pin_index = 2; break;
        case CMD_BLUE: pin_index = 3; break;
        case CMD_MULTI:
            // For MULTI (all RGB channels), check if any RGB channel is on
            if(gpio_get(MULTI_RED_PIN) || gpio_get(MULTI_GREEN_PIN) || gpio_get(MULTI_BLUE_PIN)) {
                gpio_feedback = true;
            }
            break;
        case CMD_MULTI_RED: pin_index = 4; break;
        case CMD_MULTI_GREEN: pin_index = 5; break;
        case CMD_MULTI_BLUE: pin_index = 6; break;
        case CMD_ALL:
            // For ALL command, check if any LED is on
            for(int i = 0; i < 7; i++) {
                if(gpio_get(led_pins[i])) {
                    gpio_feedback = true;
                    break;
                }
            }
            break;
        default: break;
    }
    
    if(pin_index >= 0 && pin_index < 7) {
        gpio_feedback = gpio_get(led_pins[pin_index]);
    }
    
    return gpio_feedback;
}

// ---------- Binary command execution with telemetry ----------

void exec_binary_with_trace(uint64_t traceID, uint8_t commandID, uint8_t value) {
    TELEMETRY_LOG("GPIO_SET_START TRACE:%llu CMD:%d", traceID, commandID);
    
    // Capture execution start time (microseconds for precision)
    uint64_t start_us = time_us_64();
    
    // DEBUG: Log GPIO state BEFORE setting (only if debug enabled)
    DEBUG_LOG("BEFORE_SET: R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d",
              gpio_get(RED_PIN) ? 1 : 0,
              gpio_get(GREEN_PIN) ? 1 : 0,
              gpio_get(YELLOW_PIN) ? 1 : 0,
              gpio_get(BLUE_PIN) ? 1 : 0,
              gpio_get(MULTI_RED_PIN) ? 1 : 0,
              gpio_get(MULTI_GREEN_PIN) ? 1 : 0,
              gpio_get(MULTI_BLUE_PIN) ? 1 : 0);
    
    // Handle QUERY_STATE separately (doesn't mutate state)
    if (commandID == CMD_QUERY_STATE) {
        PROTOCOL_LOG("STATE: seq=%llu R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d S=%d",
                     state_sequence,
                     led_state[0] ? 1 : 0,
                     led_state[1] ? 1 : 0,
                     led_state[2] ? 1 : 0,
                     led_state[3] ? 1 : 0,
                     multi_led_brightness[0],
                     multi_led_brightness[1],
                     multi_led_brightness[2],
                     servo_angle);
        log_flush();
        return;
    }
    
    // Handle CMD_STATUS: pull-based health probe (complements push-based BLAZE_READY)
    // Returns ready flag, session identity, uptime, and state sequence — enough for
    // the host to determine liveness, detect reboots, and confirm readiness.
    if (commandID == CMD_STATUS) {
        uint64_t uptime_ms = to_ms_since_boot(get_absolute_time()) - boot_timestamp_ms;
        PROTOCOL_LOG("STATUS: ready=%d session=%08X uptime=%llu seq=%llu fw=%s proto=%d model=%s id=%s",
                     accept_commands ? 1 : 0,
                     session_uuid,
                     uptime_ms,
                     state_sequence,
                     FW_VERSION,
                     PROTOCOL_VERSION,
                     DEVICE_MODEL,
                     device_id_str);
        log_flush();
        return;
    }
    
    // Handle ENTER_BOOTLOADER: ACK first, then reboot into USB bootloader
    if (commandID == CMD_ENTER_BOOTLOADER) {
        emit_ack(traceID, commandID, value);
        PROTOCOL_LOG("[BOOTLOADER] Entering USB bootloader via binary command");
        log_flush();
        fflush(stdout);
        // Extra flush cycles + longer delay to ensure ACK reaches host before CDC teardown
        stdio_flush();
        sleep_ms(50);
        fflush(stdout);
        stdio_flush();
        sleep_ms(200);
        reset_usb_boot(0, 0);
        // Never returns
    }
    
    // Execute command (pure execution logic)
    // Unknown commandIDs are rejected
    if (commandID != CMD_RED && commandID != CMD_GREEN && commandID != CMD_YELLOW &&
        commandID != CMD_BLUE && commandID != CMD_MULTI && commandID != CMD_MULTI_RED &&
        commandID != CMD_MULTI_GREEN && commandID != CMD_MULTI_BLUE && commandID != CMD_ALL &&
        commandID != CMD_SERVO_SET) {
        PROTOCOL_LOG("ERROR: Unknown commandID %d TRACE:%llu", commandID, traceID);
        PROTOCOL_LOG("ERROR_EVENT: CODE:INVALID_CMD CMD:%d TRACE:%llu", commandID, traceID);
        log_flush();
        return;
    }
    
    execute_command(commandID, value);
    
    // Capture execution end time
    uint64_t end_us = time_us_64();
    uint64_t exec_us = end_us - start_us;
    
    TELEMETRY_LOG("GPIO_SET_DONE TRACE:%llu", traceID);
    
    // Validate GPIO state (for telemetry/debugging)
    bool gpio_feedback = validate_gpio_state(commandID);
    
    TELEMETRY_LOG("GPIO_READBACK TRACE:%llu GPIO:%d", traceID, gpio_feedback ? 1 : 0);
    
    // ERROR DETECTION: If GPIO feedback doesn't match expected state, report error
    // Skip servo (PWM output can't be validated via gpio_get)
    bool expected_state = (value != 0);
    if(gpio_feedback != expected_state && commandID != CMD_QUERY_STATE && commandID != CMD_ALL && commandID != CMD_SERVO_SET) {
        PROTOCOL_LOG("ERROR_EVENT: CODE:GPIO_MISMATCH CMD:%d EXPECTED:%d ACTUAL:%d TRACE:%llu",
                     commandID, expected_state ? 1 : 0, gpio_feedback ? 1 : 0, traceID);
    }
    
    // DEBUG: Log GPIO state AFTER setting (only if debug enabled)
    DEBUG_LOG("AFTER_SET: R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d",
              gpio_get(RED_PIN) ? 1 : 0,
              gpio_get(GREEN_PIN) ? 1 : 0,
              gpio_get(YELLOW_PIN) ? 1 : 0,
              gpio_get(BLUE_PIN) ? 1 : 0,
              gpio_get(MULTI_RED_PIN) ? 1 : 0,
              gpio_get(MULTI_GREEN_PIN) ? 1 : 0,
              gpio_get(MULTI_BLUE_PIN) ? 1 : 0);
    
    // Structured telemetry log
    TELEMETRY_LOG("TRACE:%llu CMD:%d VAL:%d EXEC_US:%llu GPIO:%d",
                  traceID, commandID, value, exec_us, gpio_feedback ? 1 : 0);
    
    // Emit ACK (protocol-critical, always flushed)
    emit_ack(traceID, commandID, value);
    
    // Emit STATE_CHANGE (protocol-critical, always flushed)
    emit_state_change(traceID);
    
    // Flush any remaining buffered logs
    log_flush();
}

// Legacy binary execution (backward compatibility)
void exec_binary(uint8_t commandID, uint8_t value) {
    exec_binary_with_trace(0, commandID, value);
}

// ---------- Text command execution (backward compatibility) ----------

void exec(char *cmd){
    if(!cmd) return;
    
    // Trim leading whitespace
    while(*cmd == ' ' || *cmd == '\t') cmd++;
    
    size_t len = strlen(cmd);
    if(len == 0) return;
    
    // Trim trailing whitespace
    char *end = cmd + len - 1;
    while(end > cmd && (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n')) {
        *end = '\0';
        end--;
    }

    if(strlen(cmd) == 0) return;

    DEBUG_LOG("CMD: %s", cmd);

    if(!strcmp(cmd,"RED ON")) {
        exec_binary(CMD_RED, 1);
    }
    else if(!strcmp(cmd,"RED OFF")) {
        exec_binary(CMD_RED, 0);
    }
    else if(!strcmp(cmd,"GREEN ON")) {
        exec_binary(CMD_GREEN, 1);
    }
    else if(!strcmp(cmd,"GREEN OFF")) {
        exec_binary(CMD_GREEN, 0);
    }
    else if(!strcmp(cmd,"YELLOW ON")) {
        exec_binary(CMD_YELLOW, 1);
    }
    else if(!strcmp(cmd,"YELLOW OFF")) {
        exec_binary(CMD_YELLOW, 0);
    }
    else if(!strcmp(cmd,"BLUE ON")) {
        exec_binary(CMD_BLUE, 1);
    }
    else if(!strcmp(cmd,"BLUE OFF")) {
        exec_binary(CMD_BLUE, 0);
    }
    else if(!strcmp(cmd,"MULTI ON")) {
        exec_binary(CMD_MULTI, 1);
    }
    else if(!strcmp(cmd,"MULTI OFF")) {
        exec_binary(CMD_MULTI, 0);
    }
    else if(!strncmp(cmd,"MULTI ",6) && cmd[6] >= '0' && cmd[6] <= '9') {
        int b = atoi(cmd + 6);
        if (b >= 0 && b <= 100) exec_binary(CMD_MULTI, (uint8_t)b);
        else { printf("ERROR: brightness 0-100\n"); fflush(stdout); }
    }
    else if(!strcmp(cmd,"MULTI_RED ON") || !strcmp(cmd,"MULTIRED ON")) {
        exec_binary(CMD_MULTI_RED, 1);
    }
    else if(!strcmp(cmd,"MULTI_RED OFF") || !strcmp(cmd,"MULTIRED OFF")) {
        exec_binary(CMD_MULTI_RED, 0);
    }
    else if((!strncmp(cmd,"MULTI_RED ",10) || !strncmp(cmd,"MULTIRED ",9))) {
        const char *arg = cmd + (cmd[5] == '_' ? 10 : 9);
        int b = atoi(arg);
        if (b >= 0 && b <= 100) exec_binary(CMD_MULTI_RED, (uint8_t)b);
        else { printf("ERROR: brightness 0-100\n"); fflush(stdout); }
    }
    else if(!strcmp(cmd,"MULTI_GREEN ON") || !strcmp(cmd,"MULTIGREEN ON")) {
        exec_binary(CMD_MULTI_GREEN, 1);
    }
    else if(!strcmp(cmd,"MULTI_GREEN OFF") || !strcmp(cmd,"MULTIGREEN OFF")) {
        exec_binary(CMD_MULTI_GREEN, 0);
    }
    else if((!strncmp(cmd,"MULTI_GREEN ",12) || !strncmp(cmd,"MULTIGREEN ",11))) {
        const char *arg = cmd + (cmd[5] == '_' ? 12 : 11);
        int b = atoi(arg);
        if (b >= 0 && b <= 100) exec_binary(CMD_MULTI_GREEN, (uint8_t)b);
        else { printf("ERROR: brightness 0-100\n"); fflush(stdout); }
    }
    else if(!strcmp(cmd,"MULTI_BLUE ON") || !strcmp(cmd,"MULTIBLUE ON")) {
        exec_binary(CMD_MULTI_BLUE, 1);
    }
    else if(!strcmp(cmd,"MULTI_BLUE OFF") || !strcmp(cmd,"MULTIBLUE OFF")) {
        exec_binary(CMD_MULTI_BLUE, 0);
    }
    else if((!strncmp(cmd,"MULTI_BLUE ",11) || !strncmp(cmd,"MULTIBLUE ",10))) {
        const char *arg = cmd + (cmd[5] == '_' ? 11 : 10);
        int b = atoi(arg);
        if (b >= 0 && b <= 100) exec_binary(CMD_MULTI_BLUE, (uint8_t)b);
        else { printf("ERROR: brightness 0-100\n"); fflush(stdout); }
    }
    else if(!strcmp(cmd,"ALL ON")) {
        exec_binary(CMD_ALL, 1);
    }
    else if(!strcmp(cmd,"ALL OFF")) {
        exec_binary(CMD_ALL, 0);
    }
    else if(!strncmp(cmd,"SERVO ",6)) {
        char *arg = cmd + 6;
        while(*arg == ' ') arg++;
        if(!strcmp(arg,"CENTER")) {
            set_servo_angle(90);
            printf("ACK TRACE:0 cmdID=%d value=%d\n", CMD_SERVO_SET, 90);
            printf("STATE_CHANGE: trace=0 seq=%llu R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d S=%d\n",
                   state_sequence,
                   led_state[0]?1:0, led_state[1]?1:0, led_state[2]?1:0, led_state[3]?1:0,
                   multi_led_brightness[0], multi_led_brightness[1], multi_led_brightness[2], servo_angle);
            fflush(stdout);
        } else if(!strcmp(arg,"SWEEP")) {
            for(uint16_t a = 0; a <= 180; a += 5) {
                set_servo_angle(a);
                sleep_ms(20);
            }
            for(int a = 180; a >= 0; a -= 5) {
                set_servo_angle((uint16_t)a);
                sleep_ms(20);
            }
            printf("ACK TRACE:0 cmdID=%d value=%d\n", CMD_SERVO_SET, servo_angle);
            printf("STATE_CHANGE: trace=0 seq=%llu R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d S=%d\n",
                   state_sequence,
                   led_state[0]?1:0, led_state[1]?1:0, led_state[2]?1:0, led_state[3]?1:0,
                   multi_led_brightness[0], multi_led_brightness[1], multi_led_brightness[2], servo_angle);
            fflush(stdout);
        } else {
            int angle = -1;
            if(sscanf(arg, "%d", &angle) != 1) {
                printf("ERROR: Invalid servo angle (not a number)\n"); fflush(stdout);
            } else if(angle >= 0 && angle <= 180) {
                set_servo_angle((uint16_t)angle);
                printf("ACK TRACE:0 cmdID=%d value=%d\n", CMD_SERVO_SET, angle);
                printf("STATE_CHANGE: trace=0 seq=%llu R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d S=%d\n",
                       state_sequence,
                       led_state[0]?1:0, led_state[1]?1:0, led_state[2]?1:0, led_state[3]?1:0,
                       multi_led_brightness[0], multi_led_brightness[1], multi_led_brightness[2], servo_angle);
                fflush(stdout);
            } else {
                printf("ERROR: Invalid servo angle: %d (0-180)\n", angle);
                fflush(stdout);
            }
        }
    }
    // ---------- Generic GPIO commands ----------
    else if(!strncmp(cmd,"GPIO ",5)) {
        char *sub = cmd + 5;
        while(*sub == ' ') sub++;

        if(!strncmp(sub,"SET ",4)) {
            // GPIO SET <pin> <0|1>
            int pin = -1, val = -1;
            if(sscanf(sub + 4, "%d %d", &pin, &val) == 2) {
                if(!is_valid_gpio_pin(pin)) {
                    printf("ERROR: pin %d out of range (0-29)\n", pin); fflush(stdout);
                } else if(is_pin_reserved(pin)) {
                    printf("ERROR: pin %d is reserved\n", pin); fflush(stdout);
                } else if(pwm_active_mask & (1u << pin)) {
                    printf("ERROR: pin %d has active PWM, stop PWM first\n", pin); fflush(stdout);
                } else {
                    ensure_gpio_initialized(pin);
                    gpio_set_dir(pin, GPIO_OUT);
                    gpio_put(pin, val ? 1 : 0);
                    printf("OK\n"); fflush(stdout);
                }
            } else {
                printf("ERROR: usage: GPIO SET <pin> <0|1>\n"); fflush(stdout);
            }
        }
        else if(!strncmp(sub,"GET ",4)) {
            // GPIO GET <pin>
            int pin = -1;
            if(sscanf(sub + 4, "%d", &pin) == 1) {
                if(!is_valid_gpio_pin(pin)) {
                    printf("ERROR: pin %d out of range (0-29)\n", pin); fflush(stdout);
                } else if(is_pin_reserved(pin)) {
                    printf("ERROR: pin %d is reserved\n", pin); fflush(stdout);
                } else {
                    ensure_gpio_initialized(pin);
                    int val = gpio_get(pin) ? 1 : 0;
                    printf("GPIO_READ: pin=%d value=%d\n", pin, val); fflush(stdout);
                }
            } else {
                printf("ERROR: usage: GPIO GET <pin>\n"); fflush(stdout);
            }
        }
        else if(!strncmp(sub,"MODE ",5)) {
            // GPIO MODE <pin> <OUT|IN|IN_PU|IN_PD>
            int pin = -1;
            char mode_str[16] = {0};
            if(sscanf(sub + 5, "%d %15s", &pin, mode_str) == 2) {
                if(!is_valid_gpio_pin(pin)) {
                    printf("ERROR: pin %d out of range (0-29)\n", pin); fflush(stdout);
                } else if(is_pin_reserved(pin)) {
                    printf("ERROR: pin %d is reserved\n", pin); fflush(stdout);
                } else if(pwm_active_mask & (1u << pin)) {
                    printf("ERROR: pin %d has active PWM, stop PWM first\n", pin); fflush(stdout);
                } else {
                    ensure_gpio_initialized(pin);
                    if(!strcmp(mode_str,"OUT")) {
                        gpio_set_dir(pin, GPIO_OUT);
                        gpio_disable_pulls(pin);
                        printf("OK\n"); fflush(stdout);
                    } else if(!strcmp(mode_str,"IN")) {
                        gpio_set_dir(pin, GPIO_IN);
                        gpio_disable_pulls(pin);
                        printf("OK\n"); fflush(stdout);
                    } else if(!strcmp(mode_str,"IN_PU")) {
                        gpio_set_dir(pin, GPIO_IN);
                        gpio_pull_up(pin);
                        printf("OK\n"); fflush(stdout);
                    } else if(!strcmp(mode_str,"IN_PD")) {
                        gpio_set_dir(pin, GPIO_IN);
                        gpio_pull_down(pin);
                        printf("OK\n"); fflush(stdout);
                    } else {
                        printf("ERROR: unknown mode '%s' (use OUT|IN|IN_PU|IN_PD)\n", mode_str); fflush(stdout);
                    }
                }
            } else {
                printf("ERROR: usage: GPIO MODE <pin> <OUT|IN|IN_PU|IN_PD>\n"); fflush(stdout);
            }
        }
        else {
            printf("ERROR: unknown GPIO subcommand (use SET|GET|MODE)\n"); fflush(stdout);
        }
    }
    // ---------- Generic PWM commands ----------
    else if(!strncmp(cmd,"PWM ",4)) {
        char *sub = cmd + 4;
        while(*sub == ' ') sub++;

        if(!strncmp(sub,"SET ",4)) {
            // PWM SET <pin> <freq_hz> <duty_percent>
            int pin = -1, freq = -1, duty = -1;
            if(sscanf(sub + 4, "%d %d %d", &pin, &freq, &duty) == 3) {
                if(!is_valid_gpio_pin(pin)) {
                    printf("ERROR: pin %d out of range (0-29)\n", pin); fflush(stdout);
                } else if(is_pin_reserved(pin)) {
                    printf("ERROR: pin %d is reserved\n", pin); fflush(stdout);
                } else if(freq < 1 || freq > 62500000) {
                    printf("ERROR: frequency %d out of range (1-62500000 Hz)\n", freq); fflush(stdout);
                } else if(duty < 0 || duty > 100) {
                    printf("ERROR: duty %d out of range (0-100%%)\n", duty); fflush(stdout);
                } else {
                    uint slice = pwm_gpio_to_slice_num(pin);
                    // Slice conflict: each slice drives two pins (pin & pin^1).
                    // Reconfiguring divider/wrap affects both. Reject if sibling is active.
                    uint8_t sibling = pin ^ 1;
                    if((pwm_active_mask & (1u << sibling)) && is_valid_gpio_pin(sibling)) {
                        printf("ERROR: pin %d shares PWM slice with active pin %d\n", pin, sibling); fflush(stdout);
                    } else {
                        gpio_set_function(pin, GPIO_FUNC_PWM);
                        uint32_t sys_clk = 125000000;
                        float divider = (float)sys_clk / ((float)freq * 65536.0f);
                        if(divider < 1.0f) divider = 1.0f;
                        if(divider > 255.0f) divider = 255.0f;
                        uint32_t wrap32 = (uint32_t)((float)sys_clk / (divider * (float)freq) - 1.0f);
                        if(wrap32 < 1) wrap32 = 1;
                        if(wrap32 > 65535) wrap32 = 65535;
                        uint16_t wrap = (uint16_t)wrap32;
                        pwm_set_clkdiv(slice, divider);
                        pwm_set_wrap(slice, wrap);
                        uint16_t level = (uint16_t)((uint32_t)wrap * duty / 100);
                        pwm_set_gpio_level(pin, level);
                        pwm_set_enabled(slice, true);
                        pwm_active_mask |= (1u << pin);
                        gpio_initialized_mask |= (1u << pin);
                        printf("OK\n"); fflush(stdout);
                    }
                }
            } else {
                printf("ERROR: usage: PWM SET <pin> <freq_hz> <duty_percent>\n"); fflush(stdout);
            }
        }
        else if(!strncmp(sub,"STOP ",5)) {
            // PWM STOP <pin>
            int pin = -1;
            if(sscanf(sub + 5, "%d", &pin) == 1) {
                if(!is_valid_gpio_pin(pin)) {
                    printf("ERROR: pin %d out of range (0-29)\n", pin); fflush(stdout);
                } else if(is_pin_reserved(pin)) {
                    printf("ERROR: pin %d is reserved\n", pin); fflush(stdout);
                } else if(!(pwm_active_mask & (1u << pin))) {
                    printf("ERROR: pin %d has no active PWM\n", pin); fflush(stdout);
                } else {
                    uint slice = pwm_gpio_to_slice_num(pin);
                    // Only disable the slice if the sibling pin is NOT also using PWM
                    uint8_t sibling = pin ^ 1;
                    bool sibling_active = (pwm_active_mask & (1u << sibling)) != 0;
                    if(!sibling_active) {
                        pwm_set_enabled(slice, false);
                    }
                    // Revert this pin to GPIO regardless
                    gpio_init(pin);
                    pwm_active_mask &= ~(1u << pin);
                    printf("OK\n"); fflush(stdout);
                }
            } else {
                printf("ERROR: usage: PWM STOP <pin>\n"); fflush(stdout);
            }
        }
        else {
            printf("ERROR: unknown PWM subcommand (use SET|STOP)\n"); fflush(stdout);
        }
    }
    // ---------- ADC read command ----------
    else if(!strncmp(cmd,"ADC ",4)) {
        char *sub = cmd + 4;
        while(*sub == ' ') sub++;

        if(!strncmp(sub,"READ ",5)) {
            // ADC READ <pin>
            int pin = -1;
            if(sscanf(sub + 5, "%d", &pin) == 1) {
                if(!is_valid_adc_pin(pin)) {
                    printf("ERROR: pin %d not an ADC pin (use 26-29)\n", pin); fflush(stdout);
                } else if(is_pin_reserved(pin)) {
                    printf("ERROR: pin %d is reserved\n", pin); fflush(stdout);
                } else {
                    if(!adc_initialized) {
                        adc_init();
                        adc_initialized = true;
                    }
                    adc_gpio_init(pin);
                    adc_select_input(pin - 26);
                    uint16_t raw = adc_read();
                    printf("ADC_READ: pin=%d value=%d\n", pin, raw); fflush(stdout);
                }
            } else {
                printf("ERROR: usage: ADC READ <pin>\n"); fflush(stdout);
            }
        }
        else {
            printf("ERROR: unknown ADC subcommand (use READ)\n"); fflush(stdout);
        }
    }
    else if(!strcmp(cmd,"BOOT") || !strcmp(cmd,"BOOTLOADER")) {
        // BOOT command: Reboot into bootloader mode for flashing
        printf("BOOT: Entering bootloader mode...\n");
        fflush(stdout);
        sleep_ms(100);  // Give time for message to send
        reset_usb_boot(0, 0);  // Reboot into USB bootloader
        // Never returns
    }
    else if(!strcmp(cmd,"STATUS")) {
        exec_binary(CMD_STATUS, 0);
    }
    else if(!strcmp(cmd,"PING")) {
        printf("PONG\n");
        fflush(stdout);
    }
    else if(!strcmp(cmd,"DEVICE_INFO")) {
        printf("DEVICE_INFO_BEGIN\n");
        printf("MODEL=%s\n", DEVICE_MODEL);
        printf("FW_VERSION=%s\n", FW_VERSION);
        printf("PROTOCOL=%d\n", PROTOCOL_VERSION);
        printf("DEVICE_ID=%s\n", device_id_str);
        printf("MAX_CMD=%d\n", MAX_LINE);
        printf("GPIO_COUNT=30\n");
        printf("ADC_PINS=4\n");
        printf("PWM_SLICES=8\n");
        printf("RESERVED_COUNT=%d\n", RESERVED_PIN_COUNT);
        printf("DEVICE_INFO_END\n");
        fflush(stdout);
    }
    else if(!strcmp(cmd,"PINMAP")) {
        printf("PINMAP_BEGIN\n");
        for(uint8_t pin = 0; pin < 30; pin++) {
            printf("PIN %d", pin);
            if(is_pin_reserved(pin)) {
                printf(" RESERVED");
            } else {
                printf(" GPIO");
                printf(" PWM");
                if(is_valid_adc_pin(pin)) {
                    printf(" ADC");
                }
                // Runtime state
                if(pwm_active_mask & (1u << pin)) {
                    printf(" ACTIVE_PWM");
                } else if(gpio_initialized_mask & (1u << pin)) {
                    bool is_output = gpio_get_dir(pin);
                    if(is_output) {
                        printf(" OUTPUT %s", gpio_get(pin) ? "HIGH" : "LOW");
                    } else {
                        printf(" INPUT");
                    }
                }
            }
            printf("\n");
        }
        printf("PINMAP_END\n");
        fflush(stdout);
    }
    else{
        printf("UNKNOWN: %s\n", cmd);
        fflush(stdout);
    }
}

// ---------- USB stream events ----------

// Called by blaze_serial for every complete text line, fully validated binary
// command, or rejected frame. A COMMAND event is only produced after the CRC,
// BlazeTransport header, DATA frame and BlazeBinary PicoCommandV1 all
// validated, so nothing below runs on partial or malformed input.
static void on_serial_event(const blaze_serial_event_t *ev, void *context) {
    (void)context;
    switch (ev->kind) {
        case BLAZE_SERIAL_EVENT_TEXT_LINE:
            if (!accept_commands) {
                PROTOCOL_LOG("ERROR:NOT_READY Device still booting");
                return;
            }
            exec(ev->line);
            break;

        case BLAZE_SERIAL_EVENT_COMMAND:
            DEBUG_LOG("PACKET RECEIVED TRACE:%llu SEQ:%lu CMD:%d VAL:%d", ev->command.trace_id,
                      (unsigned long)ev->sequence, ev->command.command, ev->command.value);
            if (!accept_commands) {
                PROTOCOL_LOG("ERROR:NOT_READY Device still booting TRACE:%llu", ev->command.trace_id);
                PROTOCOL_LOG("ERROR_EVENT: CODE:NOT_READY MSG:Device still booting TRACE:%llu", ev->command.trace_id);
                return;
            }
            exec_binary_with_trace(ev->command.trace_id, ev->command.command, ev->command.value);
            break;

        case BLAZE_SERIAL_EVENT_ERROR:
            if (ev->error == BLAZE_SERIAL_ERROR_COMMAND && ev->command_result == PICO_COMMAND_UNKNOWN_COMMAND) {
                // Same lines the firmware has always sent for an unknown command.
                PROTOCOL_LOG("ERROR: Unknown commandID %d TRACE:%llu", ev->command.command, ev->command.trace_id);
                PROTOCOL_LOG("ERROR_EVENT: CODE:INVALID_CMD CMD:%d TRACE:%llu", ev->command.command,
                             ev->command.trace_id);
            } else if (ev->error == BLAZE_SERIAL_ERROR_COMMAND && ev->command_result == PICO_COMMAND_INVALID_VALUE) {
                PROTOCOL_LOG("ERROR: Invalid value %d for commandID %d TRACE:%llu", ev->command.value,
                             ev->command.command, ev->command.trace_id);
                PROTOCOL_LOG("ERROR_EVENT: CODE:INVALID_VALUE CMD:%d VAL:%d TRACE:%llu", ev->command.command,
                             ev->command.value, ev->command.trace_id);
            } else if (ev->error == BLAZE_SERIAL_ERROR_COMMAND) {
                PROTOCOL_LOG("ERROR: Rejected frame: %s", pico_command_result_name(ev->command_result));
                PROTOCOL_LOG("ERROR_EVENT: CODE:BAD_FRAME REASON:%s", pico_command_result_name(ev->command_result));
            } else {
                PROTOCOL_LOG("ERROR: Rejected frame: %s (payload_len=%u)", blaze_serial_error_name(ev->error),
                             (unsigned)ev->payload_length);
                PROTOCOL_LOG("ERROR_EVENT: CODE:BAD_FRAME REASON:%s", blaze_serial_error_name(ev->error));
            }
            break;
    }
}

// ---------- USB Session Lifecycle Management ----------

/**
 * Wait for USB CDC connection
 * Event-driven: polls stdio_usb_connected() until connection established
 * No fixed delays - waits for actual connection event
 */
static void wait_for_usb_connection(void) {
    BOOT_LOG("Waiting for USB CDC");
    while (!stdio_usb_connected()) {
        sleep_ms(50);  // Poll every 50ms
    }
    USB_LOG("Connected");
}

/**
 * Generate a new session UUID
 * 
 * Uses timestamp + monotonic counter to ensure uniqueness even on rapid reconnects.
 * This prevents collision risk if two reconnects happen within the same microsecond.
 * 
 * Pattern: timestamp (high bits) + counter (low bits)
 * This ensures epoch-based identity: each reconnect = new epoch = guaranteed unique UUID
 */
static void generate_session_uuid(void) {
    uint64_t now_us = time_us_64();
    uint32_t timestamp_component = (uint32_t)((now_us / 1000) & 0xFFFFF000);  // High 20 bits of ms
    uint32_t counter_component = (session_counter++ & 0xFFF);  // Low 12 bits from counter
    
    session_uuid = timestamp_component | counter_component;
    
    // Ensure non-zero UUID
    if (session_uuid == 0) {
        session_uuid = 1;
    }
}

/**
 * Start USB session lifecycle
 * Called on initial boot and after every reconnect
 * 
 * Lifecycle sequence:
 * 1. Wait for USB CDC connection
 * 2. Wait 200ms for CDC stability
 * 3. Generate new session UUID
 * 4. Reset sequence counters (if reconnect)
 * 5. Emit SESSION message
 * 6. Emit STATE message
 * 7. Emit BLAZE_READY
 * 
 * Device is authoritative - always speaks first
 * 
 * ⚠️ CRITICAL INVARIANT: Message order MUST be:
 *    SESSION → STATE → BLAZE_READY
 * 
 * Never change this order. Host correlation logic depends on it.
 * Breaking this invariant will cause host session tracking to fail.
 * 
 * Reconnect spam protection: Minimum 300ms between session starts
 * Prevents rapid reconnect loops if CDC resets during host port open
 */
static void start_usb_session(bool is_reconnect) {
    // Step 1: Wait for USB CDC connection
    wait_for_usb_connection();
    
    // Reconnect spam protection: Enforce minimum session lifetime
    // Prevents rapid reconnect loops if CDC resets during host port open
    if (is_reconnect && last_session_start_ms > 0) {
        uint64_t now_ms = to_ms_since_boot(get_absolute_time());
        uint64_t time_since_last = now_ms - last_session_start_ms;
        if (time_since_last < 300) {
            // Too soon - wait for minimum session lifetime
            sleep_ms(300 - time_since_last);
        }
    }
    
    // Step 2: Wait for CDC stability (200ms warmup)
    sleep_ms(200);
    
    // Record session start time for reconnect spam protection
    last_session_start_ms = to_ms_since_boot(get_absolute_time());
    
    // Step 3: Generate new session UUID (always new on reconnect)
    generate_session_uuid();
    SESSION_LOG("Created %08X", session_uuid);
    
    // Step 4: Reset sequence on reconnect (preserve on initial boot)
    if (is_reconnect) {
        state_sequence = 0;
        SESSION_LOG("Sequence reset on reconnect");
    }
    
    // Step 5: Capture timestamps
    if (!is_reconnect) {
        boot_timestamp_ms = to_ms_since_boot(get_absolute_time());
    }
    ready_timestamp_ms = to_ms_since_boot(get_absolute_time());
    
    // Step 6: Emit SESSION message (device speaks first)
    // CRITICAL: Protocol messages always flushed immediately
    PROTOCOL_LOG("SESSION:%08X", session_uuid);
    
    // Step 7: Emit STATE message (before READY)
    PROTOCOL_LOG("STATE: seq=%llu R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d S=%d",
                 state_sequence,
                 led_state[0] ? 1 : 0,
                 led_state[1] ? 1 : 0,
                 led_state[2] ? 1 : 0,
                 led_state[3] ? 1 : 0,
                 multi_led_brightness[0],
                 multi_led_brightness[1],
                 multi_led_brightness[2],
                 servo_angle);
    
    // Step 8: Emit BLAZE_READY (last boot message)
    // NOTE: PROTOCOL_LOG flushes immediately to USB CDC TX buffer.
    // Pico SDK USB CDC handles TX completion asynchronously.
    // If paranoid verification needed: unplug immediately after READY,
    // reconnect, verify host receives clean SESSION start.
    // In practice, 200ms CDC stability wait + immediate flush is sufficient.
    PROTOCOL_LOG("BLAZE_READY");
    READY_LOG("Device ready");
    
    // Mark session as active and ready for commands
    // CRITICAL: Flags set AFTER READY emission + flush
    // This ensures READY announcement precedes execution authority
    // Pattern: emit_ready_signal() THEN set_internal_accept_flag()
    session_active = true;
    accept_commands = true;
}

/**
 * Handle USB disconnection
 * Invalidates session and stops accepting commands
 */
static void handle_usb_disconnect(void) {
    if (session_active) {
        USB_LOG("Disconnected");
        SESSION_LOG("Invalidated");
        session_active = false;
        accept_commands = false;
    }
}

// ---------- main ----------

int main(){
    // ========================================
    // CRITICAL: stdio_init_all() MUST BE FIRST AND ONLY ONCE
    // ========================================
    // USB CDC requires SDK initialization - this MUST be first!
    stdio_init_all();
    
    // Load hardware-burned unique board ID (RP2350 OTP)
    pico_get_unique_board_id_string(device_id_str, sizeof(device_id_str));
    
    // ========================================
    // GPIO SETUP (SDK ONLY - NO DIRECT REGISTER ACCESS)
    // ========================================
    // GPIO initialization happens BEFORE USB session
    // This ensures hardware is ready before we start the session lifecycle
    setup_led(RED_PIN);
    setup_led(GREEN_PIN);
    setup_led(YELLOW_PIN);
    setup_led(BLUE_PIN);
    setup_led(MULTI_RED_PIN);
    setup_led(MULTI_GREEN_PIN);
    setup_led(MULTI_BLUE_PIN);
    
    // Servo PWM setup (GP21, 50 Hz, default center)
    setup_servo(SERVO_PIN);
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // 🚨 CRITICAL: BOOT LED BLINK SEQUENCE - DO NOT MODIFY 🚨
    // ═══════════════════════════════════════════════════════════════════════════════
    //
    // THIS CODE BLINKS ALL LEDs ON BOOT FOR DEBUGGING AND VISUAL CONFIRMATION.
    // IT IS ABSOLUTELY CRITICAL FOR STARTUP DIAGNOSTICS AND MUST NOT BE CHANGED.
    //
    // ⚠️  WARNING FOR AI ASSISTANTS (Cursor, GitHub Copilot, etc.):
    // ⚠️  DO NOT remove this boot LED blink sequence.
    // ⚠️  DO NOT change the blink cycles or timing.
    // ⚠️  DO NOT "optimize" or "clean up" this code.
    // ⚠️  DO NOT move this code elsewhere.
    // ⚠️  DO NOT make it "configurable" or "optional".
    //
    // Why this is critical:
    //   1. Visual confirmation that firmware booted successfully
    //   2. Verifies GPIO initialization worked correctly
    //   3. Helps diagnose boot failures (no blink = firmware crashed)
    //   4. Provides immediate feedback before serial/USB is ready
    //   5. Standard diagnostic pattern for embedded systems
    //
    // This runs BEFORE any commands are accepted, so it's the first thing
    // users see when the board powers on. Removing it makes debugging much harder.
    //
    // If you see suggestions to remove, modify, or make this optional, REJECT them.
    // This is a HARD REQUIREMENT for production firmware diagnostics.
    //
    // ═══════════════════════════════════════════════════════════════════════════════
    
    const int pins[7] = {RED_PIN, GREEN_PIN, YELLOW_PIN, BLUE_PIN, 
                         MULTI_RED_PIN, MULTI_GREEN_PIN, MULTI_BLUE_PIN};
    
    // Blink LEDs: 5 cycles of ON/OFF, ~500ms each = ~5 seconds total
    // DO NOT change these values - timing is important for visual confirmation
    const int blink_cycles = 5;
    const int blink_delay_ms = 500;
    
    // Blink all LEDs to indicate successful boot and GPIO initialization
    for (int cycle = 0; cycle < blink_cycles; cycle++) {
        // Turn ALL LEDs ON
        for (int i = 0; i < 7; i++) {
            gpio_put(pins[i], 1);
        }
        sleep_ms(blink_delay_ms);
        
        // Turn ALL LEDs OFF
        for (int i = 0; i < 7; i++) {
            gpio_put(pins[i], 0);
        }
        sleep_ms(blink_delay_ms);
    }
    
    // Ensure LEDs are OFF after boot test (critical for clean state)
    // Explicitly turn off all LEDs to guarantee clean state
    for (int i = 0; i < 7; i++) {
        gpio_put(pins[i], 0);
        led_state[i] = false;  // Initialize state tracking (LEDs are OFF after boot test)
    }
    
    // Double-check: ensure all LEDs are definitely OFF
    // This ensures internal state matches physical GPIO state
    for (int i = 0; i < 7; i++) {
        gpio_put(pins[i], 0);
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // END OF CRITICAL BOOT LED BLINK SEQUENCE - DO NOT MODIFY ABOVE CODE
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // NOTE: Dedicated feedback pin removed (was GPIO 19, conflicting with MULTI_GREEN_PIN).
    // GPIO readback via gpio_get() in validate_gpio_state() provides feedback instead.
    
    // ========================================
    // INITIAL USB SESSION STARTUP
    // ========================================
    // Emit boot messages for backward compatibility (before session start)
    // These are informational only - critical lifecycle messages come from start_usb_session()
    printf("BOOT:GPIO_INIT\n");
    printf("BOOT:GPIO_OK\n");
    printf("BOOT:USB_INIT\n");
    fflush(stdout);
    
    // Start first USB session (not a reconnect)
    // This will wait for USB connection, generate UUID, and emit SESSION/STATE/BLAZE_READY
    start_usb_session(false);
    
    // Emit timestamps after session is established
    printf("BOOT_TS:%llu\n", boot_timestamp_ms);
    printf("READY_TS:%llu\n", ready_timestamp_ms);
    fflush(stdout);
    
    // Emit STATE_CHANGE with trace=0 for format consistency with emit_state_change()
    PROTOCOL_LOG("STATE_CHANGE: trace=0 seq=%llu R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d S=%d",
                 state_sequence,
                 led_state[0] ? 1 : 0,
                 led_state[1] ? 1 : 0,
                 led_state[2] ? 1 : 0,
                 led_state[3] ? 1 : 0,
                 multi_led_brightness[0],
                 multi_led_brightness[1],
                 multi_led_brightness[2],
                 servo_angle);

    DEBUG_LOG("");
    DEBUG_LOG("========================================");
    DEBUG_LOG("BLAZE PICO LED CONTROLLER READY");
    DEBUG_LOG("========================================");
    DEBUG_LOG("Mode: Binary + Text (backward compatible)");
    DEBUG_LOG("Type commands like: RED ON<ENTER>");
    DEBUG_LOG("========================================");
    log_flush();
    
    // Boot LED test is complete - protocol loop starts now

    // USB stream parser (protocol/blaze_serial.c): text lines and BLAZ frames
    static blaze_serial_t serial_parser;
    blaze_serial_init(&serial_parser);
    uint64_t last_byte_ms = 0;

    // ========================================
    // MAIN PROTOCOL LOOP WITH USB LIFECYCLE MANAGEMENT
    // ========================================
    // This loop handles:
    // 1. USB connection monitoring
    // 2. Automatic reconnection on disconnect
    // 3. Command processing
    // 4. Heartbeat telemetry
    
    while(true){
        // ========================================
        // USB DISCONNECTION DETECTION & RECONNECT HANDLING
        // ========================================
        // Check USB connection status dynamically
        // If disconnected, handle disconnect and wait for reconnect
        if (!stdio_usb_connected()) {
            handle_usb_disconnect();
            
            // Reset parser state to prevent stale partial packets from corrupting next session
            blaze_serial_init(&serial_parser);
            
            // Wait for reconnection (event-driven, no fixed delays)
            wait_for_usb_connection();
            
            // Restart session on reconnect (new UUID, reset sequence)
            // start_usb_session() already emits SESSION, STATE, and BLAZE_READY
            start_usb_session(true);
            
            // Emit reconnect notification for backward compatibility
            printf("BOOT:USB_RECONNECT\n");
            fflush(stdout);
            
            // Continue to command processing loop
        }
        
        // ========================================
        // COMMAND PROCESSING (only when connected)
        // ========================================
        // CRITICAL: Only process commands when session is active and USB connected
        // This ensures zero commands execute before READY
        if (!session_active || !accept_commands || !stdio_usb_connected()) {
            sleep_ms(50);
            continue;
        }
        
        uint64_t now_ms = to_ms_since_boot(get_absolute_time());
        
        // CRITICAL: Yield CPU time to USB stack (but don't block)
        sleep_us(50);
        
        int c = getchar_timeout_us(1000); // 1ms timeout (reduced from 10ms for faster command detection)
        
        if(c < 0) {
            if (!stdio_usb_connected()) {
                continue;
            }
            // Abandon a partial frame / resync after a quiet period and return to text mode
            if(blaze_serial_busy(&serial_parser) && (now_ms - last_byte_ms > SERIAL_IDLE_MS)) {
                blaze_serial_idle(&serial_parser, on_serial_event, NULL);
            }
            goto check_heartbeat;
        }
        
        last_byte_ms = now_ms;
        blaze_serial_feed(&serial_parser, (uint8_t)c, on_serial_event, NULL);
        
check_heartbeat:;
        // Heartbeat telemetry (every 2 seconds)
        static uint64_t last_heartbeat_ms = 0;
        
        if(now_ms - last_heartbeat_ms >= 2000) {
            last_heartbeat_ms = now_ms;
            
            // CDC back-pressure guard: skip heartbeat output if host
            // isn't draining the TX buffer. Prevents fflush() from
            // blocking the main loop and starving the USB stack, which
            // causes macOS to de-enumerate the device.
            if(!stdio_usb_connected()) {
                continue;
            }
            uint32_t tx_avail = tud_cdc_write_available();
            if(tx_avail < 80) {
                // TX buffer congested — host not reading fast enough.
                // Skip this heartbeat to avoid blocking in fflush().
                continue;
            }
            
            uint64_t uptime_ms = now_ms - boot_timestamp_ms;
            
            printf("HEARTBEAT: UPTIME:%llu READY:%d R=%d G=%d Y=%d B=%d MR=%d MG=%d MB=%d S=%d\n", 
                   uptime_ms, 
                   accept_commands ? 1 : 0,
                   led_state[0] ? 1 : 0,
                   led_state[1] ? 1 : 0,
                   led_state[2] ? 1 : 0,
                   led_state[3] ? 1 : 0,
                   multi_led_brightness[0],
                   multi_led_brightness[1],
                   multi_led_brightness[2],
                   servo_angle);
            fflush(stdout);
            
            for(int i = 0; i < 7; i++) {
                bool actual = gpio_get(led_pins[i]);
                if(actual != led_state[i]) {
                    if(tud_cdc_write_available() >= 80) {
                        static const char *led_names[] = {"R","G","Y","B","MR","MG","MB"};
                        printf("GPIO_MISMATCH: %s expected=%d actual=%d\n",
                               led_names[i], led_state[i] ? 1 : 0, actual ? 1 : 0);
                        fflush(stdout);
                    }
                    break;
                }
            }
        }
    }
}
