cmake_minimum_required(VERSION 3.20)
project(icu-cmake VERSION 78.3 LANGUAGES C CXX)

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
#       GIT_REPOSITORY https://github.com/aspect-build/icu-cmake.git
#       GIT_TAG icu/78)
#   FetchContent_MakeAvailable(icu)
#   target_link_libraries(myapp PRIVATE ICU::uc ICU::i18n ICU::data)
#
# Usage (standalone):
#   cmake -B build -DICU_SOURCE_DIR=E:/repo/icu/icu4c/source
#   cmake --build build --config Release
#
# Options:
#   ICU_VERSION     — ICU patch version to fetch (default "78.3")
#   ICU_SOURCE_DIR  — Path to icu4c/source (auto-fetched if not set)
#   ICU_BUILD_SHARED — Build shared libraries instead of static (default OFF)
#   ICU_DATA_MODE   — "stubdata" (minimal), "prebuilt" (data DLL), "archive" (download), "build" (from source)
#   ICU_BUILD_TESTS — Build ICU test suites: cintltst, intltest (default OFF)

set(ICU_VERSION "78.3" CACHE STRING
    "ICU release version to fetch (e.g. 78.1, 78.2, 78.3)")
option(ICU_BUILD_SHARED "Build ICU as shared libraries" OFF)
option(ICU_BUILD_TESTS "Build ICU test suites (cintltst, intltest)" OFF)
set(ICU_DATA_MODE "archive" CACHE STRING
    "Data mode: stubdata (minimal), prebuilt (data DLL), archive (download .dat), build (compile from source)")
set_property(CACHE ICU_DATA_MODE PROPERTY STRINGS stubdata prebuilt archive build)
option(ICU_DATA_AUTO_FETCH
    "Automatically download ICU data archive when ICU_DATA_MODE=archive and icudt*.dat is missing"
    ON)
set(ICU_DATA_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/_downloads" CACHE PATH
    "Directory used to cache downloaded ICU data archives")
set(ICU_DATA_ARCHIVE_URL "" CACHE STRING
    "Override URL for ICU data archive zip (advanced)")

# For prebuilt mode: path to directory containing icudt<ver>.dll and icudt.lib
set(ICU_PREBUILT_DIR "" CACHE PATH
    "Path to pre-built ICU binaries (containing icudt*.dll + icudt.lib). Auto-detected from ICU repo.")

# ── Fetch ICU source if not provided ────────────────────────────────────────

if(NOT ICU_SOURCE_DIR)
    include(FetchContent)
    FetchContent_Declare(icu_source
        GIT_REPOSITORY https://github.com/unicode-org/icu.git
        GIT_TAG        "release-${ICU_VERSION}"
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

function(icu_data_archive_url version major out_url out_zip_name)
    if(major GREATER_EQUAL 78)
        set(_tag "release-${version}")
        set(_zip "icu4c-${version}-data-bin-l.zip")
    else()
        string(REPLACE "." "-" _tag_ver "${version}")
        string(REPLACE "." "_" _asset_ver "${version}")
        if(NOT _asset_ver MATCHES "_")
            set(_tag_ver "${_tag_ver}-1")
            set(_asset_ver "${_asset_ver}_1")
        endif()
        set(_tag "release-${_tag_ver}")
        set(_zip "icu4c-${_asset_ver}-data-bin-l.zip")
    endif()

    set(_url "https://github.com/unicode-org/icu/releases/download/${_tag}/${_zip}")
    set(${out_url} "${_url}" PARENT_SCOPE)
    set(${out_zip_name} "${_zip}" PARENT_SCOPE)
endfunction()

# ── Common settings ─────────────────────────────────────────────────────────

set(ICU_COMMON_DIR "${ICU_SOURCE_DIR}/common")
set(ICU_I18N_DIR   "${ICU_SOURCE_DIR}/i18n")
set(ICU_IO_DIR     "${ICU_SOURCE_DIR}/io")
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
# Target: icuio (Unicode I/O library)
# ============================================================================

file(GLOB ICU_IO_SOURCES "${ICU_IO_DIR}/*.cpp")

add_library(icuio ${_icu_lib_type} ${ICU_IO_SOURCES})
icu_target_settings(icuio)

target_include_directories(icuio
    PUBLIC
        "$<BUILD_INTERFACE:${ICU_IO_DIR}>"
        "$<INSTALL_INTERFACE:include>"
    PRIVATE
        "${ICU_COMMON_DIR}"
        "${ICU_I18N_DIR}"
        "${ICU_IO_DIR}"
)

target_compile_definitions(icuio PRIVATE U_IO_IMPLEMENTATION)
target_link_libraries(icuio PUBLIC icui18n icuuc)

if(ICU_BUILD_SHARED)
    set_target_properties(icuio PROPERTIES
        OUTPUT_NAME "icuio${ICU_MAJOR_VERSION}"
    )
else()
    set_target_properties(icuio PROPERTIES
        OUTPUT_NAME "icuio"
    )
endif()

# ============================================================================
# Aliases (match CMake FindICU convention: ICU::uc, ICU::i18n, ICU::io, ICU::data)
# ============================================================================

add_library(ICU::uc   ALIAS icuuc)
add_library(ICU::i18n ALIAS icui18n)
add_library(ICU::io   ALIAS icuio)
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
    set(_icu_data_dat_file "${ICU_DATA_ARCHIVE_DIR}/icudt${ICU_MAJOR_VERSION}l.dat")

    if(NOT EXISTS "${_icu_data_dat_file}")
        if(ICU_DATA_AUTO_FETCH)
            if(ICU_DATA_ARCHIVE_URL)
                set(_icu_data_url "${ICU_DATA_ARCHIVE_URL}")
                get_filename_component(_icu_data_zip_name "${ICU_DATA_ARCHIVE_URL}" NAME)
            else()
                icu_data_archive_url("${ICU_VERSION}" "${ICU_MAJOR_VERSION}"
                    _icu_data_url _icu_data_zip_name)
            endif()

            if(NOT _icu_data_zip_name)
                message(FATAL_ERROR
                    "Could not determine ICU data archive filename for URL: ${_icu_data_url}")
            endif()

            file(MAKE_DIRECTORY "${ICU_DATA_ARCHIVE_DIR}")
            file(MAKE_DIRECTORY "${ICU_DATA_DOWNLOAD_DIR}")

            set(_icu_data_zip_file "${ICU_DATA_DOWNLOAD_DIR}/${_icu_data_zip_name}")

            if(NOT EXISTS "${_icu_data_zip_file}")
                message(STATUS "Downloading ICU data archive: ${_icu_data_url}")
                file(DOWNLOAD "${_icu_data_url}" "${_icu_data_zip_file}"
                    SHOW_PROGRESS
                    STATUS _icu_data_download_status)
                list(GET _icu_data_download_status 0 _icu_data_download_code)
                list(GET _icu_data_download_status 1 _icu_data_download_message)
                if(NOT _icu_data_download_code EQUAL 0)
                    file(REMOVE "${_icu_data_zip_file}")
                    message(FATAL_ERROR
                        "Failed to download ICU data archive (${_icu_data_download_code}): "
                        "${_icu_data_download_message}\nURL: ${_icu_data_url}")
                endif()
            else()
                message(STATUS "Using cached ICU data archive: ${_icu_data_zip_file}")
            endif()

            message(STATUS "Extracting ICU data archive to: ${ICU_DATA_ARCHIVE_DIR}")
            file(ARCHIVE_EXTRACT
                INPUT "${_icu_data_zip_file}"
                DESTINATION "${ICU_DATA_ARCHIVE_DIR}")
        else()
            message(FATAL_ERROR
                "ICU_DATA_MODE=archive requires ${_icu_data_dat_file}, but it was not found.\n"
                "Enable ICU_DATA_AUTO_FETCH=ON or download data manually with scripts/fetch-data.sh")
        endif()
    endif()

    if(NOT EXISTS "${_icu_data_dat_file}")
        message(FATAL_ERROR
            "Expected ICU data archive not found: ${_icu_data_dat_file}")
    endif()

    target_compile_definitions(icuuc PRIVATE
        "ICU_DATA_DIR=\"${ICU_DATA_ARCHIVE_DIR}/\""
    )

    message(STATUS "ICU data mode: archive (${_icu_data_dat_file})")
elseif(ICU_DATA_MODE STREQUAL "build")
    # ── Build from source mode ──────────────────────────────────────────
    # Compile locale data from ICU source files using the upstream Python
    # databuilder.  Requires Python 3 and builds all required ICU tools.
    # Produces icudt<ver>l.dat identical to the pre-built archive.
    find_package(Python3 REQUIRED COMPONENTS Interpreter)

    set(ICU_DATA_ARCHIVE_DIR "${CMAKE_CURRENT_BINARY_DIR}/data"
        CACHE PATH "Directory containing icudt${ICU_MAJOR_VERSION}l.dat")
    file(MAKE_DIRECTORY "${ICU_DATA_ARCHIVE_DIR}")

    target_compile_definitions(icuuc PRIVATE
        "ICU_DATA_DIR=\"${ICU_DATA_ARCHIVE_DIR}/\""
    )

    message(STATUS "ICU data mode: build (from source, output to ${ICU_DATA_ARCHIVE_DIR})")
elseif(ICU_DATA_MODE STREQUAL "prebuilt")
    message(STATUS "ICU data mode: prebuilt (${_icu_data_implib})")
else()
    message(STATUS "ICU data mode: stubdata (minimal, no locale data)")
endif()

# ============================================================================
# ICU Tools & Data Build (shared by tests and ICU_DATA_MODE=build)
# ============================================================================
# The toolutil library, ICU data tools, and helper functions are needed both
# for building test data (ICU_BUILD_TESTS) and for compiling locale data from
# source (ICU_DATA_MODE=build).

set(_icu_need_tools FALSE)
if(ICU_BUILD_TESTS)
    set(_icu_need_tools TRUE)
endif()
if(ICU_DATA_MODE STREQUAL "build")
    set(_icu_need_tools TRUE)
endif()

if(_icu_need_tools)
    set(ICU_TOOLS_DIR   "${ICU_SOURCE_DIR}/tools")

    # Helper: read source list from Makefile.in OBJECTS variable.
    # More reliable than file(GLOB) — Makefile.in is the source of truth
    # for which files to compile, and some .cpp files in the tree are not
    # meant to be compiled standalone.
    function(icu_read_sources_from_makefile makefile_path source_dir ext out_var)
        file(STRINGS "${makefile_path}" _lines)
        set(_in_objects FALSE)
        set(_objects_line "")
        foreach(_line ${_lines})
            if(_line MATCHES "^OBJECTS[ \t]*=")
                set(_in_objects TRUE)
            endif()
            if(_in_objects)
                string(APPEND _objects_line " ${_line}")
                if(NOT _line MATCHES "\\\\$")
                    set(_in_objects FALSE)
                endif()
            endif()
        endforeach()
        # Extract .o names and convert to source files
        string(REGEX MATCHALL "[a-zA-Z0-9_]+\\.o" _obj_files "${_objects_line}")
        set(_sources)
        foreach(_obj ${_obj_files})
            string(REPLACE ".o" "" _base "${_obj}")
            if(EXISTS "${source_dir}/${_base}.${ext}")
                list(APPEND _sources "${source_dir}/${_base}.${ext}")
            elseif(EXISTS "${source_dir}/${_base}.c")
                list(APPEND _sources "${source_dir}/${_base}.c")
            elseif(EXISTS "${source_dir}/${_base}.cpp")
                list(APPEND _sources "${source_dir}/${_base}.cpp")
            endif()
        endforeach()
        set(${out_var} ${_sources} PARENT_SCOPE)
    endfunction()

    # ── toolutil library ────────────────────────────────────────────────
    file(GLOB ICU_TOOLUTIL_SOURCES "${ICU_TOOLS_DIR}/toolutil/*.cpp")

    add_library(icutu STATIC ${ICU_TOOLUTIL_SOURCES})
    icu_target_settings(icutu)
    target_include_directories(icutu
        PUBLIC  "${ICU_TOOLS_DIR}/toolutil"
        PRIVATE "${ICU_COMMON_DIR}" "${ICU_I18N_DIR}"
    )
    target_compile_definitions(icutu PRIVATE U_TOOLUTIL_IMPLEMENTATION)
    target_link_libraries(icutu PUBLIC icui18n icuuc)

    # ── ctestfw library (test framework) ────────────────────────────────
    file(GLOB ICU_CTESTFW_SOURCES
        "${ICU_TOOLS_DIR}/ctestfw/*.c"
        "${ICU_TOOLS_DIR}/ctestfw/*.cpp"
    )

    add_library(icutest STATIC ${ICU_CTESTFW_SOURCES})
    icu_target_settings(icutest)
    target_include_directories(icutest
        PUBLIC  "${ICU_TOOLS_DIR}/ctestfw"
                "${ICU_TOOLS_DIR}/ctestfw/unicode"
        PRIVATE "${ICU_COMMON_DIR}" "${ICU_I18N_DIR}"
                "${ICU_TOOLS_DIR}/toolutil"
    )
    target_compile_definitions(icutest PRIVATE U_CTESTFW_IMPLEMENTATION)
    target_link_libraries(icutest PUBLIC icutu)

    # ════════════════════════════════════════════════════════════════════
    # ICU Data Tools
    # ════════════════════════════════════════════════════════════════════

    # Helper macro for tool executables
    macro(icu_add_tool name)
        icu_target_settings(${name})
        target_include_directories(${name} PRIVATE
            "${ICU_COMMON_DIR}" "${ICU_I18N_DIR}"
            "${ICU_TOOLS_DIR}/toolutil"
        )
        target_link_libraries(${name} PRIVATE icutu icui18n icuuc icudata)
        if(WIN32)
            target_link_libraries(${name} PRIVATE advapi32)
        endif()
    endmacro()

    # ── genrb (resource bundle compiler) ───────────────────────────────
    file(STRINGS "${ICU_TOOLS_DIR}/genrb/sources.txt" _genrb_basenames)
    set(_genrb_sources)
    foreach(_bn ${_genrb_basenames})
        list(APPEND _genrb_sources "${ICU_TOOLS_DIR}/genrb/${_bn}")
    endforeach()
    add_executable(genrb ${_genrb_sources})
    icu_add_tool(genrb)
    target_include_directories(genrb PRIVATE "${ICU_TOOLS_DIR}/genrb")

    # ── makeconv (charset converter compiler) ──────────────────────────
    add_executable(makeconv
        "${ICU_TOOLS_DIR}/makeconv/makeconv.cpp"
        "${ICU_TOOLS_DIR}/makeconv/genmbcs.cpp"
        "${ICU_TOOLS_DIR}/makeconv/gencnvex.c"
        "${ICU_TOOLS_DIR}/makeconv/ucnvstat.c"
    )
    icu_add_tool(makeconv)
    target_include_directories(makeconv PRIVATE "${ICU_TOOLS_DIR}/makeconv")

    # ── gensprep (string preparation data compiler) ────────────────────
    add_executable(gensprep
        "${ICU_TOOLS_DIR}/gensprep/gensprep.c"
        "${ICU_TOOLS_DIR}/gensprep/store.c"
    )
    icu_add_tool(gensprep)

    # ── gennorm2 (normalization data compiler) ─────────────────────────
    add_executable(gennorm2
        "${ICU_TOOLS_DIR}/gennorm2/gennorm2.cpp"
        "${ICU_TOOLS_DIR}/gennorm2/extradata.cpp"
        "${ICU_TOOLS_DIR}/gennorm2/n2builder.cpp"
        "${ICU_TOOLS_DIR}/gennorm2/norms.cpp"
    )
    icu_add_tool(gennorm2)
    target_include_directories(gennorm2 PRIVATE "${ICU_TOOLS_DIR}/gennorm2")

    # ── gencmn (common data archive packager) ────────────────────────
    add_executable(gencmn "${ICU_TOOLS_DIR}/gencmn/gencmn.c")
    icu_add_tool(gencmn)

    # ── genbrk (break iterator compiler) ──────────────────────────────
    add_executable(genbrk "${ICU_TOOLS_DIR}/genbrk/genbrk.cpp")
    icu_add_tool(genbrk)

    # ── gendict (dictionary generator) ─────────────────────────────────
    add_executable(gendict "${ICU_TOOLS_DIR}/gendict/gendict.cpp")
    icu_add_tool(gendict)

    # ── gencfu (confusables data compiler) ─────────────────────────────
    add_executable(gencfu "${ICU_TOOLS_DIR}/gencfu/gencfu.cpp")
    icu_add_tool(gencfu)

    # ── gencnval (converter alias compiler) ────────────────────────────
    add_executable(gencnval "${ICU_TOOLS_DIR}/gencnval/gencnval.c")
    icu_add_tool(gencnval)

    # ── icupkg (ICU data package tool) ─────────────────────────────────
    add_executable(icupkg "${ICU_TOOLS_DIR}/icupkg/icupkg.cpp")
    icu_add_tool(icupkg)

    # ── gentest (test data generator) ──────────────────────────────────
    add_executable(gentest
        "${ICU_TOOLS_DIR}/gentest/gentest.c"
        "${ICU_TOOLS_DIR}/gentest/genres32.c"
    )
    icu_add_tool(gentest)
    target_include_directories(gentest PRIVATE
        "${ICU_TOOLS_DIR}/ctestfw"
    )
    target_link_libraries(gentest PRIVATE icutest)

    # ════════════════════════════════════════════════════════════════════
    # ICU Data Build from Source (ICU_DATA_MODE=build)
    # ════════════════════════════════════════════════════════════════════
    # Uses the upstream Python databuilder to compile all locale data from
    # the ICU source .txt files, then packages with gencmn into .dat.

    if(ICU_DATA_MODE STREQUAL "build")
        # Stage tools in the layout the Python databuilder expects on Windows:
        #   {tool_dir}/{TOOL}/{tool_cfg}/{TOOL}.exe
        # Setting RUNTIME_OUTPUT_DIRECTORY + MSVC multi-config produces this.
        set(_icu_tool_staging "${CMAKE_CURRENT_BINARY_DIR}/tools")
        foreach(_tool IN ITEMS genrb makeconv genbrk gendict gencfu gencnval
                               gensprep gennorm2 icupkg gencmn)
            set_target_properties(${_tool} PROPERTIES
                RUNTIME_OUTPUT_DIRECTORY "${_icu_tool_staging}/${_tool}")
        endforeach()

        set(_data_out "${CMAKE_CURRENT_BINARY_DIR}/data_build/out")
        set(_data_tmp "${CMAKE_CURRENT_BINARY_DIR}/data_build/tmp")
        set(_icu_python_root "${ICU_SOURCE_DIR}/python")
        file(MAKE_DIRECTORY "${_data_out}")
        file(MAKE_DIRECTORY "${_data_tmp}")

        # Copy core Unicode data files from data/in/ to the output dir.
        # These are normally compiled into the ICU library (hardcoded) and
        # not included by the Python databuilder, but the tools need them
        # to initialize.  We also pass --include_uni_core_data so they end
        # up in the final icudata.lst.
        set(_icu_in_dir "${ICU_DATA_DIR}/in")
        file(GLOB _icu_core_data "${_icu_in_dir}/*.icu" "${_icu_in_dir}/*.nrm")
        set(_precopy_cmds)
        foreach(_f ${_icu_core_data})
            get_filename_component(_fname "${_f}" NAME)
            list(APPEND _precopy_cmds
                COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_f}" "${_data_out}/${_fname}")
        endforeach()

        # ICU's data loading looks for individual files in a subdirectory
        # named after the data package (e.g. icudt78l/).  The Python builder
        # places compiled files directly in out_dir.  Create a directory
        # junction (Windows) or symlink (POSIX) so that
        #   <out_dir>/icudt78l/<file>  resolves to  <out_dir>/<file>.
        set(_icu_pkg_link "${_data_out}/icudt${ICU_MAJOR_VERSION}l")

        add_custom_target(icu_build_data ALL
            # Step 1: copy core data files
            ${_precopy_cmds}
            # Step 2: create package subdirectory link (junction on Windows)
            COMMAND ${CMAKE_COMMAND} -E remove_directory "${_icu_pkg_link}"
            COMMAND ${CMAKE_COMMAND} -E create_symlink "${_data_out}" "${_icu_pkg_link}"
            # Step 3: run the Python databuilder
            COMMAND ${CMAKE_COMMAND} -E env
                "PYTHONPATH=${_icu_python_root}"
                "${Python3_EXECUTABLE}" -B -m icutools.databuilder
                --mode windows-exec
                --src_dir "${ICU_DATA_DIR}"
                --tool_dir "${_icu_tool_staging}"
                --tool_cfg "$<CONFIG>"
                --out_dir "${_data_out}"
                --tmp_dir "${_data_tmp}"
                --include_uni_core_data
                --verbose
            # Step 4: remove the junction before packaging (avoid recursion)
            COMMAND ${CMAKE_COMMAND} -E remove_directory "${_icu_pkg_link}"
            # Step 5: package all compiled data into icudt<ver>l.dat
            COMMAND $<TARGET_FILE:gencmn> -d "${ICU_DATA_ARCHIVE_DIR}"
                -n "icudt${ICU_MAJOR_VERSION}l"
                -s "${_data_out}" 0 "${_data_tmp}/icudata.lst"
            COMMENT "Building ICU locale data from source..."
            DEPENDS genrb makeconv genbrk gendict gencfu gencnval
                    gensprep gennorm2 icupkg gencmn
        )

        message(STATUS "ICU data build: Python databuilder -> gencmn -> icudt${ICU_MAJOR_VERSION}l.dat")
    endif()

endif() # _icu_need_tools

# ============================================================================
# ICU Test Suites (optional)
# ============================================================================
# Build the upstream ICU test executables: cintltst (C tests), intltest
# (C++ tests), and iotest (I/O tests).
#
# Usage:
#   cmake -B build -DICU_BUILD_TESTS=ON -DICU_DATA_MODE=archive
#   cmake --build build
#   cd build && ctest --output-on-failure

if(ICU_BUILD_TESTS)
    enable_testing()

    set(ICU_TEST_DIR    "${ICU_SOURCE_DIR}/test")

    # Test data output directories (inside build tree, not source tree)
    set(ICU_TESTDATA_SRC "${ICU_TEST_DIR}/testdata")
    set(ICU_TESTDATA_OUT "${CMAKE_CURRENT_BINARY_DIR}/test/testdata/out/testdata")
    set(ICU_TESTDATA_TMP "${CMAKE_CURRENT_BINARY_DIR}/test/testdata/out/tmp")
    file(MAKE_DIRECTORY "${ICU_TESTDATA_OUT}")
    file(MAKE_DIRECTORY "${ICU_TESTDATA_TMP}")

    # ════════════════════════════════════════════════════════════════════
    # Compile Test Data Resources
    # ════════════════════════════════════════════════════════════════════
    # Mirrors the upstream BUILDRULES.py / Makefile.in test data build.

    set(_testdata_outputs)

    # ── genrb: resource bundles (.txt → .res) ──────────────────────────
    set(_genrb_bundles
        calendar casing conversion format icuio idna_rules mc root
        sh_YU sh structLocale te_IN_REVISED te_IN te
        testaliases testempty testtypes
        Thai_graphclust_model4_heavy
        Thai_codepoints_exclusive_model5_heavy
        Burmese_graphclust_model5_heavy
    )
    foreach(_bn ${_genrb_bundles})
        set(_out "${ICU_TESTDATA_OUT}/${_bn}.res")
        add_custom_command(
            OUTPUT "${_out}"
            COMMAND genrb -q -i "${ICU_DATA_ARCHIVE_DIR}"
                -s "${ICU_TESTDATA_SRC}" -d "${ICU_TESTDATA_OUT}" "${_bn}.txt"
            DEPENDS genrb "${ICU_TESTDATA_SRC}/${_bn}.txt"
            COMMENT "genrb: ${_bn}.txt -> ${_bn}.res"
            VERBATIM
        )
        list(APPEND _testdata_outputs "${_out}")
    endforeach()

    # encoded.utf16be → encoded.res
    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/encoded.res"
        COMMAND genrb -s "${ICU_TESTDATA_SRC}" -eUTF-16BE
            -d "${ICU_TESTDATA_OUT}" encoded.utf16be
        DEPENDS genrb "${ICU_TESTDATA_SRC}/encoded.utf16be"
        COMMENT "genrb: encoded.utf16be -> encoded.res"
        VERBATIM
    )
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/encoded.res")

    # zoneinfo64.txt → zoneinfo64.res (to tmp dir)
    add_custom_command(
        OUTPUT "${ICU_TESTDATA_TMP}/zoneinfo64.res"
        COMMAND genrb -s "${ICU_TESTDATA_SRC}" -d "${ICU_TESTDATA_TMP}" zoneinfo64.txt
        DEPENDS genrb "${ICU_TESTDATA_SRC}/zoneinfo64.txt"
        COMMENT "genrb: zoneinfo64.txt -> zoneinfo64.res (tmp)"
        VERBATIM
    )
    list(APPEND _testdata_outputs "${ICU_TESTDATA_TMP}/zoneinfo64.res")

    # filtertest.txt → filtertest.res (with --filterDir)
    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/filtertest.res"
        COMMAND genrb -s "${ICU_TESTDATA_SRC}" -d "${ICU_TESTDATA_OUT}"
            -i "${ICU_TESTDATA_OUT}" --filterDir "${ICU_TESTDATA_SRC}/filters"
            filtertest.txt
        DEPENDS genrb "${ICU_TESTDATA_SRC}/filtertest.txt"
        COMMENT "genrb: filtertest.txt -> filtertest.res (filtered)"
        VERBATIM
    )
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/filtertest.res")

    # ── gensprep: string prep data (.txt → .spp) ──────────────────────
    set(_unidata_dir "${ICU_SOURCE_DIR}/data/unidata")

    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/nfscsi.spp"
        COMMAND gensprep -s "${ICU_TESTDATA_SRC}" -d "${ICU_TESTDATA_OUT}"
            -b nfscsi -u 3.2.0 nfs4_cs_prep_ci.txt
        DEPENDS gensprep "${ICU_TESTDATA_SRC}/nfs4_cs_prep_ci.txt"
        COMMENT "gensprep: nfscsi.spp" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/nfscsi.spp")

    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/nfscss.spp"
        COMMAND gensprep -s "${ICU_TESTDATA_SRC}" -d "${ICU_TESTDATA_OUT}"
            -b nfscss -u 3.2.0 nfs4_cs_prep_cs.txt
        DEPENDS gensprep "${ICU_TESTDATA_SRC}/nfs4_cs_prep_cs.txt"
        COMMENT "gensprep: nfscss.spp" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/nfscss.spp")

    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/nfscis.spp"
        COMMAND gensprep -s "${ICU_TESTDATA_SRC}" -d "${ICU_TESTDATA_OUT}"
            -b nfscis -u 3.2.0 -k -n "${_unidata_dir}" nfs4_cis_prep.txt
        DEPENDS gensprep "${ICU_TESTDATA_SRC}/nfs4_cis_prep.txt"
        COMMENT "gensprep: nfscis.spp" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/nfscis.spp")

    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/nfsmxs.spp"
        COMMAND gensprep -s "${ICU_TESTDATA_SRC}" -d "${ICU_TESTDATA_OUT}"
            -b nfsmxs -u 3.2.0 -k -n "${_unidata_dir}" nfs4_mixed_prep_s.txt
        DEPENDS gensprep "${ICU_TESTDATA_SRC}/nfs4_mixed_prep_s.txt"
        COMMENT "gensprep: nfsmxs.spp" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/nfsmxs.spp")

    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/nfsmxp.spp"
        COMMAND gensprep -s "${ICU_TESTDATA_SRC}" -d "${ICU_TESTDATA_OUT}"
            -b nfsmxp -u 3.2.0 -k -n "${_unidata_dir}" nfs4_mixed_prep_p.txt
        DEPENDS gensprep "${ICU_TESTDATA_SRC}/nfs4_mixed_prep_p.txt"
        COMMENT "gensprep: nfsmxp.spp" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/nfsmxp.spp")

    # ── makeconv: conversion tables (.ucm → .cnv) ─────────────────────
    set(_conv_tables test1 test1bmp test2 test3 test4 test4x test5 ibm9027)
    foreach(_bn ${_conv_tables})
        set(_out "${ICU_TESTDATA_OUT}/${_bn}.cnv")
        add_custom_command(
            OUTPUT "${_out}"
            COMMAND makeconv --small -d "${ICU_TESTDATA_OUT}"
                "${ICU_TESTDATA_SRC}/${_bn}.ucm"
            DEPENDS makeconv "${ICU_TESTDATA_SRC}/${_bn}.ucm"
            COMMENT "makeconv: ${_bn}.ucm -> ${_bn}.cnv"
            VERBATIM
        )
        list(APPEND _testdata_outputs "${_out}")
    endforeach()

    # ── gennorm2: normalization data ───────────────────────────────────
    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/testnorm.nrm"
        COMMAND gennorm2 -s "${ICU_TESTDATA_SRC}" testnorm.txt
            -o "${ICU_TESTDATA_OUT}/testnorm.nrm"
        DEPENDS gennorm2 "${ICU_TESTDATA_SRC}/testnorm.txt"
        COMMENT "gennorm2: testnorm.nrm" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/testnorm.nrm")

    # ── gentest: generated test data ───────────────────────────────────
    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/test.icu"
        COMMAND gentest -d "${ICU_TESTDATA_OUT}"
        DEPENDS gentest
        COMMENT "gentest: test.icu" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/test.icu")

    # gentest -r generates testtable32.txt, then genrb compiles it
    add_custom_command(
        OUTPUT "${ICU_TESTDATA_TMP}/testtable32.txt"
        COMMAND gentest -r -d "${ICU_TESTDATA_TMP}"
        DEPENDS gentest
        COMMENT "gentest: testtable32.txt (tmp)" VERBATIM)

    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/testtable32.res"
        COMMAND genrb -s "${ICU_TESTDATA_TMP}" -d "${ICU_TESTDATA_OUT}" testtable32.txt
        DEPENDS genrb "${ICU_TESTDATA_TMP}/testtable32.txt"
        COMMENT "genrb: testtable32.txt -> testtable32.res" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/testtable32.res")

    # ── copy: pre-built and derived files ──────────────────────────────
    add_custom_command(
        OUTPUT "${ICU_TESTDATA_TMP}/nam.typ"
        COMMAND ${CMAKE_COMMAND} -E copy
            "${ICU_TESTDATA_OUT}/te.res" "${ICU_TESTDATA_TMP}/nam.typ"
        DEPENDS "${ICU_TESTDATA_OUT}/te.res"
        COMMENT "copy: te.res -> nam.typ (tmp)" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_TMP}/nam.typ")

    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/old_l_testtypes.res"
        COMMAND ${CMAKE_COMMAND} -E copy
            "${ICU_TESTDATA_SRC}/old_l_testtypes.res"
            "${ICU_TESTDATA_OUT}/old_l_testtypes.res"
        DEPENDS "${ICU_TESTDATA_SRC}/old_l_testtypes.res"
        COMMENT "copy: old_l_testtypes.res" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/old_l_testtypes.res")

    add_custom_command(
        OUTPUT "${ICU_TESTDATA_OUT}/old_e_testtypes.res"
        COMMAND ${CMAKE_COMMAND} -E copy
            "${ICU_TESTDATA_SRC}/old_e_testtypes.res"
            "${ICU_TESTDATA_OUT}/old_e_testtypes.res"
        DEPENDS "${ICU_TESTDATA_SRC}/old_e_testtypes.res"
        COMMENT "copy: old_e_testtypes.res" VERBATIM)
    list(APPEND _testdata_outputs "${ICU_TESTDATA_OUT}/old_e_testtypes.res")

    # ── Package test data into testdata.dat ────────────────────────────
    # Generate a list file of all test data entries for gencmn, then
    # package them into testdata.dat (the "testdata" ICU data package).
    set(_testdata_lst "${ICU_TESTDATA_TMP}/testdata.lst")
    set(_testdata_dat "${CMAKE_CURRENT_BINARY_DIR}/test/testdata/out/testdata.dat")

    # Collect basenames of all OUT files (not TMP) for the package
    set(_pkg_files)
    foreach(_f ${_testdata_outputs})
        # Only include files in the OUT dir (not TMP)
        string(FIND "${_f}" "${ICU_TESTDATA_OUT}/" _is_out)
        if(_is_out EQUAL 0)
            get_filename_component(_basename "${_f}" NAME)
            list(APPEND _pkg_files "${_basename}")
        endif()
    endforeach()
    # Also include TMP files that belong in the package
    list(APPEND _pkg_files "nam.typ" "zoneinfo64.res")

    # Write the list file at configure time (list is static)
    list(JOIN _pkg_files "\n" _pkg_files_content)
    file(WRITE "${_testdata_lst}" "${_pkg_files_content}\n")

    # gencmn packages individual files into testdata.dat
    # -s: source dir for the files listed  -d: output dir  -n: package name
    # We need to give gencmn a source dir. Since files are split across OUT
    # and TMP, we copy TMP package files to OUT first.
    add_custom_command(
        OUTPUT "${_testdata_dat}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ICU_TESTDATA_TMP}/nam.typ" "${ICU_TESTDATA_OUT}/nam.typ"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ICU_TESTDATA_TMP}/zoneinfo64.res" "${ICU_TESTDATA_OUT}/zoneinfo64.res"
        COMMAND gencmn -d "${CMAKE_CURRENT_BINARY_DIR}/test/testdata/out"
            -n testdata -s "${ICU_TESTDATA_OUT}" 0 "${_testdata_lst}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_BINARY_DIR}/test/testdata/out/testdata.dat"
            "${ICU_DATA_ARCHIVE_DIR}/testdata.dat"
        DEPENDS gencmn ${_testdata_outputs}
        COMMENT "gencmn: packaging testdata.dat"
        VERBATIM
    )

    # ── Aggregate target ───────────────────────────────────────────────
    add_custom_target(icu_testdata ALL DEPENDS ${_testdata_outputs} "${_testdata_dat}")
    # When building locale data from source, test data compilation needs
    # the locale .dat to exist first (genrb uses -i ${ICU_DATA_ARCHIVE_DIR}).
    if(TARGET icu_build_data)
        add_dependencies(icu_testdata icu_build_data)
    endif()

    # ════════════════════════════════════════════════════════════════════
    # Test Executables
    # ════════════════════════════════════════════════════════════════════

    # U_TOPBUILDDIR tells tests where to find compiled test data
    set(_icu_topbuilddir "${CMAKE_CURRENT_BINARY_DIR}/")

    # ── cintltst (C API tests) ──────────────────────────────────────────
    icu_read_sources_from_makefile(
        "${ICU_TEST_DIR}/cintltst/Makefile.in"
        "${ICU_TEST_DIR}/cintltst" "c" ICU_CINTLTST_SOURCES)

    add_executable(cintltst ${ICU_CINTLTST_SOURCES})
    icu_target_settings(cintltst)
    target_include_directories(cintltst PRIVATE
        "${ICU_TEST_DIR}/cintltst"
        "${ICU_COMMON_DIR}" "${ICU_I18N_DIR}"
        "${ICU_TOOLS_DIR}/toolutil" "${ICU_TOOLS_DIR}/ctestfw"
    )
    target_compile_definitions(cintltst PRIVATE
        "U_TOPSRCDIR=\"${ICU_SOURCE_DIR}/\""
        "U_TOPBUILDDIR=\"${_icu_topbuilddir}\""
    )
    target_link_libraries(cintltst PRIVATE icutest icutu icui18n icuuc icudata)
    add_dependencies(cintltst icu_testdata)
    find_package(Threads)
    if(Threads_FOUND)
        target_link_libraries(cintltst PRIVATE Threads::Threads)
    endif()
    if(UNIX)
        target_link_libraries(cintltst PRIVATE m)
    endif()

    add_test(NAME cintltst COMMAND cintltst)
    set_tests_properties(cintltst PROPERTIES
        ENVIRONMENT "ICU_DATA=${ICU_DATA_ARCHIVE_DIR}"
    )

    # ── intltest (C++ API tests) ────────────────────────────────────────
    icu_read_sources_from_makefile(
        "${ICU_TEST_DIR}/intltest/Makefile.in"
        "${ICU_TEST_DIR}/intltest" "cpp" ICU_INTLTEST_SOURCES)

    add_executable(intltest ${ICU_INTLTEST_SOURCES})
    icu_target_settings(intltest)
    target_include_directories(intltest PRIVATE
        "${ICU_TEST_DIR}/intltest"
        "${ICU_COMMON_DIR}" "${ICU_I18N_DIR}" "${ICU_IO_DIR}"
        "${ICU_TOOLS_DIR}/toolutil" "${ICU_TOOLS_DIR}/ctestfw"
    )
    target_compile_definitions(intltest PRIVATE
        UNISTR_FROM_CHAR_EXPLICIT=
        UNISTR_FROM_STRING_EXPLICIT=
        "U_TOPSRCDIR=\"${ICU_SOURCE_DIR}/\""
        "U_TOPBUILDDIR=\"${_icu_topbuilddir}\""
    )
    target_link_libraries(intltest PRIVATE icutest icutu icui18n icuuc icudata)
    add_dependencies(intltest icu_testdata)
    if(Threads_FOUND)
        target_link_libraries(intltest PRIVATE Threads::Threads)
    endif()
    if(UNIX)
        target_link_libraries(intltest PRIVATE m)
    endif()

    add_test(NAME intltest COMMAND intltest)
    set_tests_properties(intltest PROPERTIES
        ENVIRONMENT "ICU_DATA=${ICU_DATA_ARCHIVE_DIR}"
    )

    # ── iotest (Unicode I/O tests) ─────────────────────────────────────
    icu_read_sources_from_makefile(
        "${ICU_TEST_DIR}/iotest/Makefile.in"
        "${ICU_TEST_DIR}/iotest" "cpp" ICU_IOTEST_SOURCES)

    add_executable(iotest ${ICU_IOTEST_SOURCES})
    icu_target_settings(iotest)
    target_include_directories(iotest PRIVATE
        "${ICU_TEST_DIR}/iotest"
        "${ICU_COMMON_DIR}" "${ICU_I18N_DIR}" "${ICU_IO_DIR}"
        "${ICU_TOOLS_DIR}/toolutil" "${ICU_TOOLS_DIR}/ctestfw"
    )
    target_compile_definitions(iotest PRIVATE
        UNISTR_FROM_CHAR_EXPLICIT=
        UNISTR_FROM_STRING_EXPLICIT=
        "U_TOPBUILDDIR=\"${_icu_topbuilddir}\""
    )
    target_link_libraries(iotest PRIVATE icutest icutu icuio icui18n icuuc icudata)
    add_dependencies(iotest icu_testdata)
    if(Threads_FOUND)
        target_link_libraries(iotest PRIVATE Threads::Threads)
    endif()
    if(UNIX)
        target_link_libraries(iotest PRIVATE m)
    endif()

    add_test(NAME iotest COMMAND iotest)
    set_tests_properties(iotest PROPERTIES
        ENVIRONMENT "ICU_DATA=${ICU_DATA_ARCHIVE_DIR}"
    )

    message(STATUS "ICU tests: cintltst, intltest, iotest (with compiled test data)")
    message(STATUS "ICU test data: ${ICU_TESTDATA_OUT}")
endif()

# ============================================================================
# Summary
# ============================================================================

message(STATUS "ICU targets: icuuc (ICU::uc), icui18n (ICU::i18n), icuio (ICU::io), icudata (ICU::data)")
message(STATUS "ICU build type: ${_icu_lib_type}")
