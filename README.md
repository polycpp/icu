# icu-cmake — ICU 76

CMake build wrapper for [ICU4C](https://github.com/unicode-org/icu) (International Components for Unicode).

This branch builds **ICU 76** (defaults to release-76-1). To use a different
patch version, pass `-DICU_VERSION=76.1`. For other major versions, see the
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
    GIT_TAG icu/76)
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
| `icudata` | `ICU::data` | icudt | Data (stub by default, full archive optional) |

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `ICU_VERSION` | `76.1` | ICU release version to fetch (e.g. `76.1`) |
| `ICU_SOURCE_DIR` | *(auto-fetch)* | Path to `icu4c/source`. If not set, ICU is fetched via git. |
| `ICU_BUILD_SHARED` | `OFF` | Build shared (DLL) instead of static libraries |
| `ICU_DATA_MODE` | `stubdata` | `stubdata` = minimal (no locale data), `prebuilt` = pre-built DLL, `archive` = full data |
| `ICU_DATA_ARCHIVE_DIR` | `${CMAKE_BINARY_DIR}/data` | Where to find `icudt76l.dat` (archive mode) |
| `ICU_BUILD_TESTS` | `OFF` | Build upstream ICU test suites (`cintltst`, `intltest`) |

## ICU Data

By default, ICU is built with **stub data** — a minimal empty data package. This is
sufficient for:
- Unicode normalization (NFC, NFD, etc.)
- Unicode character properties
- Basic string operations
- Case mapping (simple)

For full locale-aware functionality (collation, date formatting, number formatting,
break iteration with dictionary data), you need the full data archive:

```bash
# Download the data archive
./scripts/fetch-data.sh 76.1 ./data

# Build with full data
cmake -B build -DICU_DATA_MODE=archive -DICU_DATA_ARCHIVE_DIR=./data
```

At runtime, set `ICU_DATA` environment variable to the directory containing the `.dat`
file, or use `u_setDataDirectory()` in code.

## Running Tests

To build and run the upstream ICU test suites (`cintltst` and `intltest`):

```bash
./scripts/fetch-data.sh 76.1 ./data
cmake -B build -DICU_BUILD_TESTS=ON -DICU_DATA_MODE=archive -DICU_DATA_ARCHIVE_DIR=./data
cmake --build build
cd build && ctest --output-on-failure
```

## Supported Platforms

- Windows (MSVC 2019+)
- Linux (GCC 10+, Clang 12+)
- macOS (Clang 12+)

## License

The CMake build scripts in this repository are MIT licensed.
ICU itself is licensed under the [Unicode License](https://www.unicode.org/copyright.html).
