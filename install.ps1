# Installs zvm: downloads a prebuilt release by default.
# Pass -Build to build from source instead, that requires running this
# script from a local checkout of the repo (not the irm | iex one-liner,
# since there's no source tree to build in that case) and a zig compiler
# matching this project's pinned version already on PATH. Note: -Build only
# works when you run the script as a file (.\install.ps1 -Build); it can't be
# passed through the piped irm | iex form.
param(
    [switch]$Build
)

$ErrorActionPreference = "Stop"

$ReleaseBase = if ($env:ZVM_RELEASE_BASE) {
    $env:ZVM_RELEASE_BASE
} else {
    "https://git.xeondev.com/nyan/zvm/releases/download/latest"
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_IDENTIFIER -like "*ARM*") {
    "aarch64"
} else {
    "x86_64"
}
$target = "$arch-windows"

$zvmHome = if ($env:ZVM_HOME) { $env:ZVM_HOME } else { Join-Path $env:LOCALAPPDATA "zvm" }
$binDir = Join-Path $zvmHome "bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

if ($Build) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $zonPath = Join-Path $ScriptDir "build.zig.zon"
    if (-not (Test-Path $zonPath)) {
        Write-Error "-Build requires running this script from a checkout of the zvm repository."

        exit 1
    }

    $required = $null
    $zonContent = Get-Content $zonPath -Raw
    if ($zonContent -match 'minimum_zig_version\s*=\s*"([^"]+)"') {
        $required = $Matches[1]
    }

    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    if (-not $zigCmd) {
        Write-Error "zig is not installed, or not on PATH. This project needs zig $required. Get it from: https://ziglang.org/download/"

        exit 1
    }

    $have = (zig version).Trim()
    if ($required -and $have -ne $required) {
        Write-Error "Found zig $have on PATH, but this project needs exactly zig $required. Install it from: https://ziglang.org/download/"

        exit 1
    }

    Write-Host "Building zvm with zig $have..."
    Push-Location $ScriptDir
    try {
        zig build -Doptimize=ReleaseFast

        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } finally {
        Pop-Location
    }

    Copy-Item (Join-Path $ScriptDir "zig-out\bin\zig.exe") -Destination (Join-Path $binDir "zig.exe") -Force
    Copy-Item (Join-Path $ScriptDir "zig-out\bin\zvm.exe") -Destination (Join-Path $binDir "zvm.exe") -Force
} else {
    $url = "$ReleaseBase/zvm-$target.zip"

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zipPath = Join-Path $tmp "zvm.zip"
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $zipPath

        $extractPath = Join-Path $tmp "extracted"
        Expand-Archive -Path $zipPath -DestinationPath $extractPath

        $zigExe = Get-ChildItem -Path $extractPath -Recurse -Filter "zig.exe" | Select-Object -First 1
        $zvmExe = Get-ChildItem -Path $extractPath -Recurse -Filter "zvm.exe" | Select-Object -First 1
        if (-not $zigExe -or -not $zvmExe) {
            Write-Error "Release archive didn't contain both zig.exe and zvm.exe."

            exit 1
        }

        Copy-Item $zigExe.FullName -Destination (Join-Path $binDir "zig.exe") -Force
        Copy-Item $zvmExe.FullName -Destination (Join-Path $binDir "zvm.exe") -Force
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host "Installed zig + zvm to $binDir"

$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
$pathEntries = @()
if ($userPath) { $pathEntries = $userPath -split ";" }

if ($pathEntries -contains $binDir) {
    Write-Host "$binDir is already on your PATH."
} else {
    $answer = $null
    if ([Environment]::UserInteractive) {
        try {
            $answer = Read-Host "Add $binDir to your user PATH? [y/n]"
        } catch {
            $answer = $null
        }
    }

    if ($null -eq $answer) {
        Write-Host "Run this PowerShell command to add zvm to your user PATH:"
        Write-Host "  `$zvmBin = Join-Path `$env:LOCALAPPDATA 'zvm\bin'; `$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User'); [Environment]::SetEnvironmentVariable('PATH', `"`$zvmBin;`$userPath`", 'User')"
    } elseif ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[Yy]') {
        $newPath = if ($userPath) { "$binDir;$userPath" } else { $binDir }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Host "Added. Open a new terminal to pick it up."
    } else {
        Write-Host "Skipped. Run this PowerShell command to add zvm to your user PATH:"
        Write-Host "  `$zvmBin = Join-Path `$env:LOCALAPPDATA 'zvm\bin'; `$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User'); [Environment]::SetEnvironmentVariable('PATH', `"`$zvmBin;`$userPath`", 'User')"
    }
}

Write-Host ""
Write-Host "Done. Open a new terminal and try: zig version"
