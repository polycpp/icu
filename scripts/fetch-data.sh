#!/usr/bin/env bash
# ============================================================================
# Fetch ICU data archive
# ============================================================================
# Downloads the full ICU data archive for a given version.
# The archive contains locale data, collation rules, timezone data, etc.
#
# Usage:
#   ./scripts/fetch-data.sh [version] [output-dir]
#
# Examples:
#   ./scripts/fetch-data.sh 78.3 ./data
#   ./scripts/fetch-data.sh            # defaults: version=78.3, output=./data
#
# The downloaded file will be: <output-dir>/icudt<major>l.dat
# ('l' suffix = little-endian, used on x86/x64/ARM)

set -euo pipefail

ICU_VERSION="${1:-74.2}"
OUTPUT_DIR="${2:-./data}"

# Extract major version (e.g. "78" from "78.3", or "77" from "77")
ICU_MAJOR="${ICU_VERSION%%[.-]*}"
FILENAME="icudt${ICU_MAJOR}l.dat"

# ICU data releases are published on GitHub releases.
# Tag/asset naming changed at version 78:
#   ≤77: tag=release-77-1   asset=icu4c-77_1-data-bin-l.zip
#   ≥78: tag=release-78.3   asset=icu4c-78.3-data-bin-l.zip
BASE_URL="https://github.com/unicode-org/icu/releases/download"

if [ "${ICU_MAJOR}" -ge 78 ] 2>/dev/null; then
    TAG="release-${ICU_VERSION}"
    DATA_URL="${BASE_URL}/${TAG}/icu4c-${ICU_VERSION}-data-bin-l.zip"
else
    TAG="release-${ICU_VERSION//./-}"
    ASSET_VER="${ICU_VERSION//./_}"
    # Default to X_1 if no minor version was given (e.g. "77" → "77_1")
    if [[ "${ASSET_VER}" != *_* ]]; then
        TAG="${TAG}-1"
        ASSET_VER="${ASSET_VER}_1"
    fi
    DATA_URL="${BASE_URL}/${TAG}/icu4c-${ASSET_VER}-data-bin-l.zip"
fi

mkdir -p "${OUTPUT_DIR}"

if [ -f "${OUTPUT_DIR}/${FILENAME}" ]; then
    echo "ICU data already exists: ${OUTPUT_DIR}/${FILENAME}"
    exit 0
fi

echo "Downloading ICU ${ICU_VERSION} data archive..."
echo "  URL: ${DATA_URL}"
echo "  Output: ${OUTPUT_DIR}/${FILENAME}"

TMPFILE=$(mktemp)
trap 'rm -f "${TMPFILE}"' EXIT

if command -v curl &>/dev/null; then
    curl -fSL "${DATA_URL}" -o "${TMPFILE}"
elif command -v wget &>/dev/null; then
    wget -q "${DATA_URL}" -O "${TMPFILE}"
else
    echo "Error: neither curl nor wget found" >&2
    exit 1
fi

# The download is a zip containing the .dat file
if command -v unzip &>/dev/null; then
    unzip -o "${TMPFILE}" -d "${OUTPUT_DIR}"
elif command -v python3 &>/dev/null; then
    python3 -c "
import zipfile, sys
with zipfile.ZipFile('${TMPFILE}') as z:
    z.extractall('${OUTPUT_DIR}')
"
else
    # Try just copying — some releases provide raw .dat
    cp "${TMPFILE}" "${OUTPUT_DIR}/${FILENAME}"
fi

if [ -f "${OUTPUT_DIR}/${FILENAME}" ]; then
    echo "Success: ${OUTPUT_DIR}/${FILENAME}"
    ls -lh "${OUTPUT_DIR}/${FILENAME}"
else
    echo "Warning: expected ${FILENAME} not found after extraction."
    echo "Contents of ${OUTPUT_DIR}:"
    ls -la "${OUTPUT_DIR}"
fi
