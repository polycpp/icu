cmake_minimum_required(VERSION 3.20)
project(icu-cmake VERSION 79.0.1 LANGUAGES C CXX)

# ============================================================================
# ICU CMake Build Wrapper
# ============================================================================
#
# Builds ICU4C (common + i18n + data) as static libraries via CMake.
# The upstream ICU project uses MSBuild on Windows and autoconf on POSIX;
# this wrapper provides a CMake-native build for easy FetchContent integration.
#
# Usage (as FetchContent):
#   FetchContent_Declare(icu
#       GIT_REPOSITORY https://github.com/<org>/icu-cmake.git
#       GIT_TAG main)
#   FetchContent_MakeAvailable(icu)
#   target_link_libraries(myapp PRIVATE ICU::uc ICU::i18n ICU::data)
#
# Usage (standalone):
#   cmake -B build -DICU_SOURCE_DIR=E:/repo/icu/icu4c/source
#   cmake --build build --config Release
#
# Options:
#   ICU_SOURCE_DIR  — Path to icu4c/source (auto-fetched if not set)
#   ICU_BUILD_SHARED — Build shared libraries instead of static (default OFF)
#   ICU_DATA_MODE   — "stubdata" (default, minimal) or "archive" (full data)

option(ICU_BUILD_SHARED "Build ICU as shared libraries" OFF)
set(ICU_DATA_MODE "stubdata" CACHE STRING "Data mode: stubdata (minimal) or archive (full)")
set_property(CACHE ICU_DATA_MODE PROPERTY STRINGS stubdata archive)

# ── Fetch ICU source if not provided ────────────────────────────────────────

if(NOT ICU_SOURCE_DIR)
    include(FetchContent)
    FetchContent_Declare(icu_source
        GIT_REPOSITORY https://github.com/unicode-org/icu.git
        GIT_TAG        release-79-1
        GIT_SHALLOW    TRUE
        GIT_PROGRESS   TRUE
    )
    FetchContent_MakeAvailable(icu_source)
    set(ICU_SOURCE_DIR "${icu_source_SOURCE_DIR}/icu4c/source")
endif()

message(STATUS "ICU source: ${ICU_SOURCE_DIR}")

if(NOT EXISTS "${ICU_SOURCE_DIR}/common/unicode/utypes.h")
    message(FATAL_ERROR "ICU source not found at ${ICU_SOURCE_DIR}. "
        "Set ICU_SOURCE_DIR to <icu-repo>/icu4c/source")
endif()

# ── Version detection ───────────────────────────────────────────────────────

file(STRINGS "${ICU_SOURCE_DIR}/common/unicode/uvernum.h" _icu_version_line
     REGEX "^#define U_ICU_VERSION_MAJOR_NUM")
string(REGEX MATCH "[0-9]+" ICU_MAJOR_VERSION "${_icu_version_line}")
message(STATUS "ICU version: ${ICU_MAJOR_VERSION}")

# ── Common settings ─────────────────────────────────────────────────────────

set(ICU_COMMON_DIR "${ICU_SOURCE_DIR}/common")
set(ICU_I18N_DIR   "${ICU_SOURCE_DIR}/i18n")
set(ICU_STUB_DIR   "${ICU_SOURCE_DIR}/stubdata")
set(ICU_DATA_DIR   "${ICU_SOURCE_DIR}/data")

if(ICU_BUILD_SHARED)
    set(_icu_lib_type SHARED)
else()
    set(_icu_lib_type STATIC)
endif()

# Compiler settings shared by all ICU targets
function(icu_target_settings target)
    target_compile_features(${target} PUBLIC cxx_std_17)
    set_target_properties(${target} PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        C_STANDARD 11
    )

    # ICU compile definitions
    target_compile_definitions(${target} PRIVATE
        # Suppress deprecation warnings within ICU itself
        U_ATTRIBUTE_DEPRECATED=
    )

    if(NOT ICU_BUILD_SHARED)
        target_compile_definitions(${target} PUBLIC U_STATIC_IMPLEMENTATION)
    endif()

    if(WIN32)
        target_compile_definitions(${target} PRIVATE
            U_PLATFORM_USES_ONLY_WIN32_API=1
            WIN32
            _WIN32
            _CRT_SECURE_NO_DEPRECATE
            _CRT_NONSTDC_NO_DEPRECATE
        )
        # Suppress common ICU warnings on MSVC
        target_compile_options(${target} PRIVATE
            /wd4244 /wd4267 /wd4275 /wd4251 /wd4996
            /utf-8
        )
    else()
        # POSIX/Linux/macOS
        target_compile_options(${target} PRIVATE
            -Wno-deprecated-declarations
            -Wno-sign-compare
        )
    endif()
endfunction()

# ============================================================================
# Target: icudata (stub data library)
# ============================================================================
# The stub data library provides an empty data package. This is sufficient for
# ICU initialization. Full locale data can be loaded at runtime via ICU_DATA
# environment variable or u_setDataDirectory().

add_library(icudata ${_icu_lib_type} "${ICU_STUB_DIR}/stubdata.cpp")
icu_target_settings(icudata)

target_include_directories(icudata
    PUBLIC  "$<BUILD_INTERFACE:${ICU_COMMON_DIR}>"
    PRIVATE "${ICU_COMMON_DIR}"
)

if(ICU_BUILD_SHARED)
    target_compile_definitions(icudata PRIVATE U_DATA_IMPLEMENTATION)
    set_target_properties(icudata PROPERTIES
        OUTPUT_NAME "icudt${ICU_MAJOR_VERSION}"
    )
else()
    set_target_properties(icudata PROPERTIES
        OUTPUT_NAME "icudt"
    )
endif()

# ============================================================================
# Target: icuuc (common library)
# ============================================================================

file(GLOB ICU_COMMON_SOURCES "${ICU_COMMON_DIR}/*.cpp")

add_library(icuuc ${_icu_lib_type} ${ICU_COMMON_SOURCES})
icu_target_settings(icuuc)

target_include_directories(icuuc
    PUBLIC
        "$<BUILD_INTERFACE:${ICU_COMMON_DIR}>"
        "$<INSTALL_INTERFACE:include>"
    PRIVATE
        "${ICU_COMMON_DIR}"
)

target_compile_definitions(icuuc PRIVATE U_COMMON_IMPLEMENTATION)
target_link_libraries(icuuc PUBLIC icudata)

if(ICU_BUILD_SHARED)
    set_target_properties(icuuc PROPERTIES
        OUTPUT_NAME "icuuc${ICU_MAJOR_VERSION}"
    )
else()
    set_target_properties(icuuc PROPERTIES
        OUTPUT_NAME "icuuc"
    )
endif()

if(WIN32)
    target_link_libraries(icuuc PRIVATE advapi32)
endif()

if(CMAKE_DL_LIBS)
    target_link_libraries(icuuc PRIVATE ${CMAKE_DL_LIBS})
endif()

if(CMAKE_THREAD_LIBS_INIT OR Threads_FOUND)
    find_package(Threads)
    target_link_libraries(icuuc PRIVATE Threads::Threads)
endif()

# ============================================================================
# Target: icui18n (internationalization library)
# ============================================================================

file(GLOB ICU_I18N_SOURCES "${ICU_I18N_DIR}/*.cpp")

add_library(icui18n ${_icu_lib_type} ${ICU_I18N_SOURCES})
icu_target_settings(icui18n)

target_include_directories(icui18n
    PUBLIC
        "$<BUILD_INTERFACE:${ICU_I18N_DIR}>"
        "$<INSTALL_INTERFACE:include>"
    PRIVATE
        "${ICU_COMMON_DIR}"
        "${ICU_I18N_DIR}"
)

target_compile_definitions(icui18n PRIVATE U_I18N_IMPLEMENTATION)
target_link_libraries(icui18n PUBLIC icuuc)

if(ICU_BUILD_SHARED)
    set_target_properties(icui18n PROPERTIES
        OUTPUT_NAME "icuin${ICU_MAJOR_VERSION}"
    )
else()
    set_target_properties(icui18n PROPERTIES
        OUTPUT_NAME "icuin"
    )
endif()

# ============================================================================
# Aliases (match CMake FindICU convention: ICU::uc, ICU::i18n, ICU::data)
# ============================================================================

add_library(ICU::uc   ALIAS icuuc)
add_library(ICU::i18n ALIAS icui18n)
add_library(ICU::data ALIAS icudata)

# ============================================================================
# ICU Data Archive Support
# ============================================================================
# When ICU_DATA_MODE=archive, we set ICU_DATA_DIR compile definition to tell
# ICU where to find the full data archive at runtime. The archive must be
# downloaded separately (see scripts/fetch-data.sh).

if(ICU_DATA_MODE STREQUAL "archive")
    set(ICU_DATA_ARCHIVE_DIR "${CMAKE_CURRENT_BINARY_DIR}/data"
        CACHE PATH "Directory containing icudt${ICU_MAJOR_VERSION}l.dat")

    target_compile_definitions(icuuc PRIVATE
        "ICU_DATA_DIR=\"${ICU_DATA_ARCHIVE_DIR}/\""
    )

    message(STATUS "ICU data mode: archive (${ICU_DATA_ARCHIVE_DIR})")
else()
    message(STATUS "ICU data mode: stubdata (minimal, no locale data)")
endif()

# ============================================================================
# Summary
# ============================================================================

message(STATUS "ICU targets: icuuc (ICU::uc), icui18n (ICU::i18n), icudata (ICU::data)")
message(STATUS "ICU build type: ${_icu_lib_type}")
