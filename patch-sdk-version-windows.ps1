# Make ANGLE's (Chromium-derived) build tree work with the Windows SDK that is
# actually installed on this machine, instead of the exact preview SDK Google
# pins for its own hermetic builds. Two things have to be patched:
#
# 1) The pinned SDK version in build/toolchain/win/setup_toolchain.py:
#
#        SDK_VERSION = '10.0.28000.0'
#
#    is passed straight to vcvarsall.bat with no env override, so if that
#    preview SDK isn't installed, `gn gen` fails with:
#
#        Path "...\include\10.0.28000.0\um" from environment variable
#        "include" does not exist. Make sure the necessary SDK is installed.
#
# 2) The hardcoded target OS version in build/config/win/BUILD.gn:
#
#        "NTDDI_VERSION=NTDDI_WIN11_BR",
#
#    NTDDI_WIN11_BR is a codename that only exists in sdkddkver.h of the very
#    newest (preview) SDK. On older SDKs it is undefined, so -DNTDDI_VERSION
#    expands to 0, the version guards collapse, and compilation dies with:
#
#        error: unknown type name 'FILE_INFO_BY_HANDLE_CLASS'   (fileapi.h)
#
#    We rewrite it to WDK_NTDDI_VERSION, a macro every sdkddkver.h defines as
#    that SDK's own NTDDI version, so it self-adjusts to whatever SDK we pick.
#
# GitHub's windows runners ship 10.0.26100.0 / 10.0.22621.0 but not preview
# SDKs, and 10.0.26100.0 is itself broken there (missing uuid.lib on
# windows-2022 -> link errors), so we pick the newest *usable* SDK and skip
# versions known to be broken.
# See https://github.com/actions/runner-images/issues/13310
#
# Must be run from the ANGLE checkout root (the directory containing build/).

$ErrorActionPreference = 'Stop'

$kitsRoot = 'C:\Program Files (x86)\Windows Kits\10'
$includeRoot = Join-Path $kitsRoot 'Include'
$libRoot = Join-Path $kitsRoot 'Lib'

# Versions known to be broken on GitHub runners despite looking installed.
$blockedVersions = @('10.0.26100.0')

if (-not (Test-Path $includeRoot)) {
    Write-Error "Windows SDK include root not found: $includeRoot"
    exit 1
}

# A version is "complete" only if the headers and the x64 import libraries we
# actually link against are present (uuid.lib is the one 26100 is missing).
function Test-SdkComplete($version) {
    $inc = Join-Path (Join-Path $includeRoot $version) 'um'
    $libX64 = Join-Path (Join-Path (Join-Path $libRoot $version) 'um') 'x64'
    return (Test-Path $inc) -and
           (Test-Path (Join-Path $libX64 'uuid.lib'))
}

$candidates = Get-ChildItem -Path $includeRoot -Directory |
    Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -ExpandProperty Name

Write-Host "Windows SDK versions found: $($candidates -join ', ')"

$sdk = $null
foreach ($version in $candidates) {
    if ($blockedVersions -contains $version) {
        Write-Host "Skipping $version (known-broken on CI runners)"
        continue
    }
    if (-not (Test-SdkComplete $version)) {
        Write-Host "Skipping $version (incomplete: missing headers or uuid.lib)"
        continue
    }
    $sdk = $version
    break
}

if (-not $sdk) {
    Write-Error "No usable Windows SDK found under $kitsRoot"
    exit 1
}

Write-Host "Selected Windows SDK version: $sdk"

# Replace $pattern (a regex) with $replacement in $path. Errors if the file is
# missing; warns (but does not fail) if the pattern isn't found, so this keeps
# working if ANGLE later renames/removes the line we're patching.
function Patch-File($path, $pattern, $replacement) {
    if (-not (Test-Path $path)) {
        Write-Error "Cannot find $path (run this from the ANGLE checkout root)"
        exit 1
    }
    $content = Get-Content -Raw $path
    if ($content -notmatch $pattern) {
        Write-Host "WARNING: pattern '$pattern' not found in $path; leaving it unchanged."
        return
    }
    $new = [regex]::Replace($content, $pattern, $replacement)
    # WriteAllText emits UTF-8 without a BOM, keeping the source file clean.
    [System.IO.File]::WriteAllText((Resolve-Path $path), $new)
    Write-Host "Patched $path -> $replacement"
}

# 1) Pin the SDK version to the one we selected.
Patch-File 'build\toolchain\win\setup_toolchain.py' "SDK_VERSION = '[0-9.]+'" "SDK_VERSION = '$sdk'"

# 2) Use the installed SDK's own NTDDI version instead of a preview-only codename.
Patch-File 'build\config\win\BUILD.gn' 'NTDDI_VERSION=NTDDI_[A-Za-z0-9_]+' 'NTDDI_VERSION=WDK_NTDDI_VERSION'
