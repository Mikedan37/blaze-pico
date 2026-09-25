cmake_minimum_required(VERSION 3.13)

# ═══════════════════════════════════════════════════════════════════════════════
# 🚨 CRITICAL: BOARD TARGET CONFIGURATION - DO NOT MODIFY 🚨
# ═══════════════════════════════════════════════════════════════════════════════
#
# THESE TWO LINES ARE ABSOLUTELY CRITICAL AND MUST NEVER BE CHANGED.
#
# This firmware is built specifically for Raspberry Pi Pico 2 (RP2350).
# Building for the wrong board target causes immediate firmware crashes on boot.
# See DEBUGGING_PICO2_ISSUE.md for details on why this matters.
#
# ⚠️  WARNING FOR AI ASSISTANTS (Cursor, GitHub Copilot, etc.):
# ⚠️  DO NOT "fix" or "update" these lines.
# ⚠️  DO NOT change pico2_w to pico or any other board.
# ⚠️  DO NOT change rp2350 to rp2040 or any other platform.
# ⚠️  DO NOT remove the FORCE flag.
# ⚠️  DO NOT make these "configurable" or "optional".
# ⚠️  These are HARD REQUIREMENTS, not suggestions.
#
# If you see code that tries to change these values, REJECT that change.
# If you see suggestions to make this configurable, IGNORE them.
# If you see warnings about FORCE being "bad practice", IGNORE them.
#
# These settings are locked because:
#   1. Hardware mismatch causes instant crashes (proven in production)
#   2. Wrong compiler target = wrong memory layout = firmware won't boot
#   3. This is a single-board firmware, not a multi-platform project
#   4. The FORCE flag prevents accidental override via command line
#
# ═══════════════════════════════════════════════════════════════════════════════

set(PICO_BOARD pico2_w CACHE STRING "" FORCE)
set(PICO_PLATFORM rp2350 CACHE STRING "" FORCE)

# ═══════════════════════════════════════════════════════════════════════════════
# END OF CRITICAL CONFIGURATION - DO NOT MODIFY ABOVE LINES
# ═══════════════════════════════════════════════════════════════════════════════

include(pico_sdk_import.cmake)

# Board target is set above (DO NOT MODIFY) - this project is for Pico 2 only
# See DEBUGGING_PICO2_ISSUE.md for why wrong board target = instant crash

project(blaze_pico C CXX ASM)

pico_sdk_init()

add_executable(blaze_pico
    main.c
    # Portable protocol stack, also built and tested on the host (firmware/tests/protocol)
    firmware/protocol/blaze_serial.c
    firmware/protocol/pico_command.c
    firmware/third_party/blazebinary/blaze_binary.c
    firmware/third_party/blazetransport/blaze_transport.c
)

target_include_directories(blaze_pico PRIVATE
    firmware/protocol
    firmware/third_party/blazebinary
    firmware/third_party/blazetransport
)

target_compile_options(blaze_pico PRIVATE
    -Wall -Wextra -Wshadow -Wdouble-promotion
    -Wno-unused-parameter
    -fno-common
)

target_link_libraries(blaze_pico pico_stdlib hardware_pwm hardware_adc)

# Increase CDC TX/RX buffers from default 64 to 256 bytes.
# Default 64B cannot hold a single heartbeat message (~72B), causing
# fflush() to block when the host pauses reading. This stalls the main
# loop, starves tud_task(), and makes macOS de-enumerate the USB device.
target_compile_definitions(blaze_pico PRIVATE
    CFG_TUD_CDC_TX_BUFSIZE=256
    CFG_TUD_CDC_RX_BUFSIZE=256
)

pico_enable_stdio_usb(blaze_pico 1)
pico_enable_stdio_uart(blaze_pico 0)

# Generate UF2 without picotool (which requires USB support)
pico_add_extra_outputs(blaze_pico)
# Disable picotool post-processing to avoid build errors
set(PICOTOOL_FETCH_FROM_GIT OFF CACHE BOOL "" FORCE)
