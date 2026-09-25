# Documentation Organization

This directory contains all project documentation, organized for open source contribution.

## Structure

All markdown files have been moved from the project root to this `docs/` directory to keep the root clean and organized.

## File Organization

Documentation is organized by topic:

- **Architecture & Design** - System architecture and design decisions
- **Firmware** - Firmware-specific documentation
- **Integration & Usage** - Integration guides and usage documentation
- **Performance & Benchmarks** - Performance analysis and benchmarks
- **Telemetry & Observability** - Telemetry system documentation
- **State Management** - State management patterns and implementation
- **Protocol & Communication** - Protocol specifications and communication details
- **Development & Debugging** - Development guides and debugging tips
- **Flash & Deployment** - Firmware flashing and deployment guides
- **Testing** - Testing documentation
- **Production & Operations** - Production deployment and operations
- **Migration & Updates** - Migration guides and update documentation

## Emoji Policy

**No emojis in documentation.** All emojis have been removed from markdown files to ensure:
- Better compatibility with all markdown renderers
- Professional appearance
- Easier text processing and searching
- Better accessibility

Use text markers instead:
- `[OK]` or `[SUCCESS]` instead of checkmarks
- `[ERROR]` or `[FAIL]` instead of X marks
- `[WARNING]` instead of warning symbols
- `[INFO]` instead of info symbols

## Contributing

When adding new documentation:
1. Place files in the appropriate topic area
2. Update `docs/README.md` with a link to your new document
3. Follow the emoji policy (no emojis)
4. Use clear, descriptive filenames (UPPER_SNAKE_CASE.md)

## References

When referencing other documentation files, use relative paths:
- `[Link Text](OTHER_FILE.md)` for files in the same directory
- `[Link Text](../README.md)` for files in parent directories
