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
#   ICU_DATA_MODE   — "stubdata" (minimal), "prebuilt" (use pre-built DLL), or "archive" (full)

option(ICU_BUILD_SHARED "Build ICU as shared libraries" OFF)
set(ICU_DATA_MODE "stubdata" CACHE STRING
    "Data mode: stubdata (minimal), prebuilt (use pre-built data DLL), archive (full)")
set_property(CACHE ICU_DATA_MODE PROPERTY STRINGS stubdata prebuilt archive)

# For prebuilt mode: path to directory containing icudt<ver>.dll and icudt.lib
set(ICU_PREBUILT_DIR "" CACHE PATH
    "Path to pre-built ICU binaries (containing icudt*.dll + icudt.lib). Auto-detected from ICU repo.")

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
# Target: icudata
# ============================================================================
# Three modes:
#   stubdata — compile empty stub (minimal, no locale data)
#   prebuilt — use pre-built icudt.lib + icudt<ver>.dll from ICU release
#   archive  — load .dat file at runtime via ICU_DATA path

if(ICU_DATA_MODE STREQUAL "prebuilt")
    # ── Pre-built data DLL mode ─────────────────────────────────────────
    # Use the import library + DLL from an existing ICU build/release.
    # Auto-detect from ICU repo structure if ICU_PREBUILT_DIR not set.
    if(NOT ICU_PREBUILT_DIR)
        # Try <ICU_SOURCE_DIR>/../lib64 (standard ICU repo layout)
        get_filename_component(_icu_parent "${ICU_SOURCE_DIR}" DIRECTORY)
        if(EXISTS "${_icu_parent}/lib64/icudt.lib")
            set(ICU_PREBUILT_DIR "${_icu_parent}" CACHE PATH "" FORCE)
        elseif(EXISTS "${_icu_parent}/lib/icudt.lib")
            set(ICU_PREBUILT_DIR "${_icu_parent}" CACHE PATH "" FORCE)
        else()
            message(FATAL_ERROR "ICU_DATA_MODE=prebuilt but cannot find icudt.lib. "
                "Set ICU_PREBUILT_DIR to directory containing lib64/icudt.lib and bin64/icudt${ICU_MAJOR_VERSION}.dll")
        endif()
    endif()

    # Find the import lib and DLL
    find_library(_icu_data_implib NAMES icudt
        PATHS "${ICU_PREBUILT_DIR}/lib64" "${ICU_PREBUILT_DIR}/lib"
        NO_DEFAULT_PATH)
    find_file(_icu_data_dll NAMES "icudt${ICU_MAJOR_VERSION}.dll"
        PATHS "${ICU_PREBUILT_DIR}/bin64" "${ICU_PREBUILT_DIR}/bin"
        NO_DEFAULT_PATH)

    if(NOT _icu_data_implib)
        message(FATAL_ERROR "Cannot find icudt.lib in ${ICU_PREBUILT_DIR}/lib64")
    endif()

    message(STATUS "ICU data: pre-built ${_icu_data_implib}")
    if(_icu_data_dll)
        message(STATUS "ICU data DLL: ${_icu_data_dll}")
    endif()

    # Create imported target for the pre-built data library
    add_library(icudata SHARED IMPORTED GLOBAL)
    set_target_properties(icudata PROPERTIES
        IMPORTED_IMPLIB "${_icu_data_implib}"
        INTERFACE_INCLUDE_DIRECTORIES "${ICU_COMMON_DIR}"
    )
    if(_icu_data_dll)
        set_target_properties(icudata PROPERTIES
            IMPORTED_LOCATION "${_icu_data_dll}"
        )
    endif()

    # Copy DLL to output directory so tests can find it
    if(_icu_data_dll)
        # Create a custom target to copy the DLL at build time
        add_custom_target(icu_copy_data_dll ALL
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${_icu_data_dll}"
                "$<TARGET_FILE_DIR:icuuc>"
            COMMENT "Copying icudt${ICU_MAJOR_VERSION}.dll to output directory"
        )
    endif()

else()
    # ── Stubdata or archive mode ────────────────────────────────────────
    # Build data from source (stub = empty, archive = full at runtime)

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
elseif(ICU_DATA_MODE STREQUAL "prebuilt")
    message(STATUS "ICU data mode: prebuilt (${_icu_data_implib})")
else()
    message(STATUS "ICU data mode: stubdata (minimal, no locale data)")
endif()

# ============================================================================
# Summary
# ============================================================================

message(STATUS "ICU targets: icuuc (ICU::uc), icui18n (ICU::i18n), icudata (ICU::data)")
message(STATUS "ICU build type: ${_icu_lib_type}")
