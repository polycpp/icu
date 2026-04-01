# ============================================================================
# Fetch ICU data archive (Windows PowerShell)
# ============================================================================
# Downloads the full ICU data archive for a given version.
#
# Usage:
#   .\scripts\fetch-data.ps1 [-Version 79] [-OutputDir ./data]

param(
    [int]$Version = 79,
    [string]$OutputDir = "./data"
)

$filename = "icudt${Version}l.dat"
$tag = "release-${Version}-1"
$dataUrl = "https://github.com/unicode-org/icu/releases/download/$tag/icu4c-${Version}_1-data-bin-l.zip"

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
