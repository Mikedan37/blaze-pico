# Contributing to Blaze Pico

Thank you for your interest in contributing to Blaze Pico!

## Project Structure

- `docs/` - All documentation files
- `scripts/` - Build and test scripts
- `PicoLEDControlSwift/` - Swift host library and CLI tools
- `main.c` - Pico firmware (C)
- `pico-cli/` - Developer CLI toolkit

## Development Setup

### Prerequisites

- macOS (for Swift development)
- Raspberry Pi Pico SDK (for firmware)
- Swift 5.9+ (for host code)
- picotool (for flashing)

### Building

```bash
# Build firmware
pico-build

# Build Swift tools
cd PicoLEDControlSwift
swift build -c release
```

### Testing

```bash
# Flash and test
./scripts/flash.sh
./scripts/test-leds.sh

# Run benchmarks
cd Benchmarks
./run_benchmarks.sh
```

## Code Style

- **Swift:** Follow Swift API Design Guidelines
- **C:** Follow Linux kernel style (for firmware)
- **Documentation:** Markdown files in `docs/` directory

## Documentation

- All documentation goes in `docs/`
- Update `docs/README.md` when adding new documentation
- No emojis in documentation (use text markers instead)

## Pull Requests

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Update documentation if needed
5. Test your changes
6. Submit a pull request

## Reporting Issues

Please include:
- System information (macOS version, Swift version)
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs or error messages

## License

See LICENSE file for details.
