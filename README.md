# icu-cmake

CMake build wrapper for [ICU4C](https://github.com/unicode-org/icu) (International Components for Unicode).

ICU upstream uses MSBuild on Windows and autoconf on POSIX. This project provides
a CMake-native build that produces `ICU::uc`, `ICU::i18n`, and `ICU::data` targets,
making ICU easy to integrate via `FetchContent` or `add_subdirectory`.

## Version Branches

Each ICU major version lives on its own branch. Pick the branch matching the
ICU version you need:

| Branch | ICU Version | Status |
|--------|-------------|--------|
| [`icu/78`](../../tree/icu/78) | ICU 78 (release-78.3) | **Latest** |

## Quick Start

```cmake
include(FetchContent)
FetchContent_Declare(icu
    GIT_REPOSITORY https://github.com/aspect-build/icu-cmake.git
    GIT_TAG icu/78)       # ← pick your ICU version branch
FetchContent_MakeAvailable(icu)

target_link_libraries(myapp PRIVATE ICU::uc ICU::i18n)
```

See the version branch README for full documentation, build options, and data
archive setup.

## Supported Platforms

- Windows (MSVC 2019+)
- Linux (GCC 10+, Clang 12+)
- macOS (Clang 12+)

## License

The CMake build scripts in this repository are MIT licensed.
ICU itself is licensed under the [Unicode License](https://www.unicode.org/copyright.html).
