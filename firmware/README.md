# Firmware Directory

This directory contains firmware source code, test files, and compiled binaries.

## Structure

- `main.c` - Main firmware source (in project root)
- `tests/` - Test firmware files
- `bin/` - Compiled firmware binaries (.uf2 files)

## Test Files

Test firmware files in `tests/` are minimal test programs used during development:
- `test-*.c` - Various test programs
- `main_diagnostic.c` - Diagnostic firmware

## Binaries

Compiled firmware binaries in `bin/`:
- `blink.uf2` - Simple blink test
- `blink-pico2.uf2` - Blink test for Pico 2
- `flash_nuke.uf2` - Flash nuke utility

These are reference binaries. Production builds go to `build/` directory.

## Building

Firmware is built using CMake and the Pico SDK. See main `README.md` for build instructions.
