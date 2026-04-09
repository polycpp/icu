# icu-cmake - ICU 78

CMake build wrapper for [ICU4C](https://github.com/unicode-org/icu) (International Components for Unicode).

This branch builds **ICU 78** (defaults to release-78.3). To use a different
patch version, pass `-DICU_VERSION=78.1`. For other major versions, see the
[main branch](../../tree/master) for available version branches.

ICU upstream uses MSBuild on Windows and autoconf on POSIX. This project provides
a CMake-native build that produces `ICU::uc`, `ICU::i18n`, and `ICU::data` targets,
making ICU easy to integrate via `FetchContent` or `add_subdirectory`.

## Quick Start

### As a FetchContent dependency

```cmake
include(FetchContent)
FetchContent_Declare(icu
    GIT_REPOSITORY https://github.com/aspect-build/icu-cmake.git
    GIT_TAG icu/78)
FetchContent_MakeAvailable(icu)

target_link_libraries(myapp PRIVATE ICU::uc ICU::i18n)
```

### With a local ICU source checkout

```bash
cmake -B build -DICU_SOURCE_DIR=/path/to/icu/icu4c/source
cmake --build build --config Release
```

## CMake Targets

| Target | Alias | Library | Description |
|--------|-------|---------|-------------|
| `icuuc` | `ICU::uc` | icuuc | Unicode common (normalization, properties, converters) |
| `icui18n` | `ICU::i18n` | icuin | Internationalization (collation, formatting, regex) |
| `icudata` | `ICU::data` | icudt | Data library (archive by default, stub/prebuilt optional) |

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `ICU_VERSION` | `78.3` | ICU release version to fetch (e.g. `78.1`, `78.2`, `78.3`) |
| `ICU_SOURCE_DIR` | *(auto-fetch)* | Path to `icu4c/source`. If not set, ICU is fetched via git. |
| `ICU_BUILD_SHARED` | `OFF` | Build shared (DLL) instead of static libraries |
| `ICU_DATA_MODE` | `archive` | `archive` = full locale data, `stubdata` = minimal (no locale data), `prebuilt` = pre-built DLL |
| `ICU_DATA_ARCHIVE_DIR` | `${CMAKE_BINARY_DIR}/data` | Directory containing `icudt78l.dat` in archive mode |
| `ICU_DATA_AUTO_FETCH` | `ON` | Auto-download ICU data archive when archive mode is selected and data is missing |
| `ICU_DATA_DOWNLOAD_DIR` | `${CMAKE_BINARY_DIR}/_downloads` | Cache directory for downloaded ICU data archives |
| `ICU_DATA_ARCHIVE_URL` | *(empty)* | Optional override URL for ICU data archive zip |
| `ICU_BUILD_TESTS` | `OFF` | Build upstream ICU test suites (`cintltst`, `intltest`) |

## ICU Data

By default, ICU is built in **archive mode** with full locale data. If
`icudt78l.dat` is missing, CMake automatically downloads and extracts the
official ICU data archive into `ICU_DATA_ARCHIVE_DIR`.

If you explicitly select `stubdata`, ICU uses a minimal empty data package. This is
sufficient for:
- Unicode normalization (NFC, NFD, etc.)
- Unicode character properties
- Basic string operations
- Case mapping (simple)

For full locale-aware functionality (collation, date formatting, number formatting,
break iteration with dictionary data), use archive mode:

```bash
# Default (archive mode + auto fetch)
cmake -B build

# Explicit archive mode and data directory
cmake -B build -DICU_DATA_MODE=archive -DICU_DATA_ARCHIVE_DIR=./data

# Optional: disable auto fetch and provide data manually
./scripts/fetch-data.sh 78.3 ./data
cmake -B build -DICU_DATA_MODE=archive -DICU_DATA_AUTO_FETCH=OFF -DICU_DATA_ARCHIVE_DIR=./data

# Minimal stubdata mode (no locale data)
cmake -B build -DICU_DATA_MODE=stubdata
```

At runtime, set `ICU_DATA` environment variable to the directory containing the `.dat`
file, or use `u_setDataDirectory()` in code.

## Running Tests

To build and run the upstream ICU test suites (`cintltst` and `intltest`):

```bash
cmake -B build -DICU_BUILD_TESTS=ON -DICU_DATA_MODE=archive
cmake --build build
cd build && ctest --output-on-failure
```

## Supported Platforms

- Windows (MSVC 2019+)
- Linux (GCC 10+, Clang 12+)
- macOS (Clang 12+)

## Build Verification

| Platform | Compiler | Status |
|----------|----------|--------|
| Windows x64 | MSVC 19.50 (VS 2026) | Verified |
| Windows x64 | MSVC 19.40+ (VS 2022) | Supported |
| Linux x64 | GCC 10+ | Supported |
| Linux x64 | Clang 12+ | Supported |
| macOS | Apple Clang 12+ | Supported |

Verified on 2026-04-07 with CMake 4.2 and Visual Studio 2026.

## License

The CMake build scripts in this repository are MIT licensed.
ICU itself is licensed under the [Unicode License](https://www.unicode.org/copyright.html).
