# ============================================================================
# Fetch ICU data archive (Windows PowerShell)
# ============================================================================
# Downloads the full ICU data archive for a given version.
#
# Usage:
#   .\scripts\fetch-data.ps1 [-Version 78.3] [-OutputDir ./data]

param(
    [string]$Version = "78.3",
    [string]$OutputDir = "./data"
)

$major = ($Version -split '[.\-]')[0]
$filename = "icudt${major}l.dat"

# Tag/asset naming changed at version 78:
#   <=77: tag=release-77-1   asset=icu4c-77_1-data-bin-l.zip
#   >=78: tag=release-78.3   asset=icu4c-78.3-data-bin-l.zip
if ([int]$major -ge 78) {
    $tag = "release-${Version}"
    $dataUrl = "https://github.com/unicode-org/icu/releases/download/$tag/icu4c-${Version}-data-bin-l.zip"
} else {
    $tagVer = $Version -replace '\.', '-'
    $assetVer = $Version -replace '\.', '_'
    if ($assetVer -notmatch '_') {
        $tagVer = "${tagVer}-1"
        $assetVer = "${assetVer}_1"
    }
    $tag = "release-${tagVer}"
    $dataUrl = "https://github.com/unicode-org/icu/releases/download/$tag/icu4c-${assetVer}-data-bin-l.zip"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$datPath = Join-Path $OutputDir $filename
if (Test-Path $datPath) {
    Write-Host "ICU data already exists: $datPath"
    exit 0
}

Write-Host "Downloading ICU $Version data archive..."
Write-Host "  URL: $dataUrl"
Write-Host "  Output: $datPath"

$tmpFile = [System.IO.Path]::GetTempFileName() + ".zip"

try {
    Invoke-WebRequest -Uri $dataUrl -OutFile $tmpFile -UseBasicParsing
    Expand-Archive -Path $tmpFile -DestinationPath $OutputDir -Force
} catch {
    Write-Error "Download failed: $_"
    exit 1
} finally {
    Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
}

if (Test-Path $datPath) {
    Write-Host "Success: $datPath"
    Get-Item $datPath | Format-Table Name, Length
} else {
    Write-Warning "Expected $filename not found after extraction."
    Get-ChildItem $OutputDir
}
