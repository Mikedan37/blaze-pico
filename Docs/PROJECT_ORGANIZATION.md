# Project Organization

This document describes the project structure and organization for open source contribution.

## Directory Structure

```
blaze-pico/
├── README.md                    # Main project readme
├── CONTRIBUTING.md              # Contribution guidelines
├── .gitignore                   # Git ignore rules
├── main.c                       # Main firmware source
├── pico_sdk_import.cmake        # Pico SDK CMake import (required for build)
│
├── docs/                        # All documentation (60+ files)
│   ├── README.md                # Documentation index
│   ├── SYSTEM_ARCHITECTURE.md   # System architecture
│   ├── COMPLETE_PIPELINE_AUDIT.md
│   └── ... (58 more docs)
│
├── scripts/                     # Build and test scripts (25 files)
│   ├── flash.sh                 # Flash firmware
│   ├── test-leds.sh             # Test LEDs
│   ├── start-agentdaemon.sh     # Start AgentDaemon
│   └── ... (22 more scripts)
│
├── firmware/                    # Firmware files
│   ├── bin/                     # Compiled firmware binaries
│   │   ├── blink.uf2
│   │   ├── blink-pico2.uf2
│   │   └── flash_nuke.uf2
│   ├── tests/                   # Test firmware files
│   │   ├── test-*.c            # Various test programs
│   │   └── main_diagnostic.c   # Diagnostic firmware
│   └── README.md                # Firmware directory docs
│
├── artifacts/                    # Backup files and artifacts
│   ├── CMakeLists.txt.backup    # Backup files
│   └── README.md                # Artifacts directory docs
│
├── PicoLEDControlSwift/         # Swift host library
├── pico-cli/                    # Developer CLI toolkit
├── Benchmarks/                   # Benchmark results
└── build*/                      # Build directories (gitignored)
```

## File Organization Rules

### Documentation
- **Location:** `docs/` directory
- **Format:** Markdown (.md)
- **Naming:** UPPER_SNAKE_CASE.md
- **Emojis:** None (removed for compatibility)
- **Index:** See `docs/README.md`

### Scripts
- **Location:** `scripts/` directory
- **Format:** Shell scripts (.sh)
- **Naming:** kebab-case.sh
- **References:** Use `./scripts/` prefix in documentation

### Firmware
- **Main source:** `main.c` (root directory)
- **Test files:** `firmware/tests/`
- **Binaries:** `firmware/bin/` (reference binaries)
- **Build output:** `build/` (gitignored)

### Artifacts
- **Location:** `artifacts/` directory
- **Contents:** Backup files, temporary artifacts
- **Note:** Not needed for building or running

## Build Outputs

Build outputs go to `build/` directories and are gitignored:
- `build/blaze_pico.uf2` - Compiled firmware
- `build/` - CMake build directory
- `build-*/` - Alternative build directories

Reference binaries in `firmware/bin/` are kept for reference but are not build outputs.

## CMake Files

- `pico_sdk_import.cmake` - Required for CMake builds (stays in root)
- `CMakeLists.txt` - Main CMake file (if exists, stays in root)

## Git Ignore Rules

The `.gitignore` file excludes:
- Build artifacts (`build*/`, `*.uf2` in build dirs)
- Backup files (`*.backup`, `*.bak`)
- IDE files (`.vscode/`, `.idea/`)
- macOS files (`.DS_Store`)
- Swift build artifacts (`.build/`, `.swiftpm/`)

## Contributing

When adding files:
1. **Documentation** → `docs/` directory
2. **Scripts** → `scripts/` directory
3. **Test firmware** → `firmware/tests/`
4. **Main firmware** → Root directory (`main.c`)
5. **Backup files** → `artifacts/` or delete them

Update `docs/README.md` when adding new documentation.
