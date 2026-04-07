# icu-cmake

CMake build wrapper for [ICU4C](https://github.com/unicode-org/icu) (International Components for Unicode).

ICU upstream uses MSBuild on Windows and autoconf on POSIX. This project provides
a CMake-native build that produces `ICU::uc`, `ICU::i18n`, and `ICU::data` targets,
making ICU easy to integrate via `FetchContent` or `add_subdirectory`.

## Version Branches

Each ICU major version lives on its own branch. Pick the branch matching the
ICU version you need:

| Branch | ICU Version | MSVC Build | Status |
|--------|-------------|------------|--------|
| [`icu/78`](../../tree/icu/78) | ICU 78 (release-78.3) | Verified | **Latest** |
| [`icu/77`](../../tree/icu/77) | ICU 77 (release-77-1) | Verified | |
| [`icu/76`](../../tree/icu/76) | ICU 76 (release-76-1) | Verified | |
| [`icu/75`](../../tree/icu/75) | ICU 75 (release-75-1) | Verified | |
| [`icu/74`](../../tree/icu/74) | ICU 74 (release-74-2) | Verified | |
| [`icu/73`](../../tree/icu/73) | ICU 73 (release-73-2) | Verified | |
| [`icu/72`](../../tree/icu/72) | ICU 72 (release-72-1) | Verified | |
| [`icu/71`](../../tree/icu/71) | ICU 71 (release-71-1) | Verified | |
| [`icu/70`](../../tree/icu/70) | ICU 70 (release-70-1) | Verified | |

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

All branches verified with MSVC 19.50 (VS 2026) + CMake 4.2 on 2026-04-07.

## License

The CMake build scripts in this repository are MIT licensed.
ICU itself is licensed under the [Unicode License](https://www.unicode.org/copyright.html).
