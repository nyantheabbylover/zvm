# Installs zvm: downloads a prebuilt release by default.
# Pass -Build to build from source instead, that requires running this
# script from a local checkout of the repo (not the irm | iex one-liner,
# since there's no source tree to build in that case) and a zig compiler
# matching this project's pinned version already on PATH. Note: -Build only
# works from a local checkout (for example, .\install.ps1 -Build); it can't be
# passed through the piped irm | iex form.
param(
    [switch]$Build,
    [switch]$Force,
    [Alias("y")]
    [switch]$Yes,
    [switch]$AddToPath,
    [switch]$NoAddToPath
)

$ErrorActionPreference = "Stop"

if ($AddToPath -and $NoAddToPath) {
    throw "-AddToPath and -NoAddToPath cannot be used together."
}

$ReleaseBase = if ($env:ZVM_RELEASE_BASE) {
    $env:ZVM_RELEASE_BASE
} else {
    "https://git.xeondev.com/nyan/zvm/releases/download/latest"
}
$ReleaseApi = if ($env:ZVM_RELEASE_API) {
    $env:ZVM_RELEASE_API
} else {
    "https://git.xeondev.com/api/v1/repos/nyan/zvm/releases/latest"
}

function Get-InstalledZvmVersion {
    if (-not (Get-Command zvm -ErrorAction SilentlyContinue)) {
        return $null
    }

    $version = [string](& zvm version 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return $version.Trim()
}

function Write-PathSetupCommand {
    param([string]$BinDir)

    $escapedBinDir = $BinDir.Replace("'", "''")
    Write-Host "Run this PowerShell command to add zvm to your user PATH:"
    Write-Host "  `$zvmBin = '$escapedBinDir'; `$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User'); [Environment]::SetEnvironmentVariable('PATH', `"`$zvmBin;`$userPath`", 'User')"
}

function Get-ProcessesUsingFile {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    
    @(
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $processPath = $_.Path
                if ($processPath -and [System.IO.Path]::GetFullPath($processPath) -ieq $fullPath) {
                    $_
                }
            } catch {}
        }
    )
}

function Copy-InstalledBinary {
    param(
        [string]$Source,
        [string]$Destination
    )

    try {
        Copy-Item $Source -Destination $Destination -Force
        return
    } catch {
        $copyError = $_.Exception.Message
    }

    $processes = @(Get-ProcessesUsingFile $Destination)
    if ($processes.Count -eq 0) {
        throw "Could not replace $Destination. $copyError"
    }

    Write-Warning "Could not replace $Destination because it is in use by:"
    foreach ($process in $processes) {
        Write-Host "  $($process.ProcessName) (PID $($process.Id))"
    }

    $kill = $false
    if (-not $Yes -and [Environment]::UserInteractive) {
        $answer = Read-Host "Terminate these process(es) and retry? [y/N]"
        $kill = $answer -match '^[Yy]'
    }

    if (-not $kill) {
        throw "Could not replace $Destination. Close the process(es) above and retry the installation."
    }

    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not terminate $($process.ProcessName) (PID $($process.Id)): $($_.Exception.Message)"
        }
    }
    Start-Sleep -Milliseconds 250

    try {
        Copy-Item $Source -Destination $Destination -Force
    } catch {
        throw "Could not replace $Destination even after terminating the blocking process(es). $($_.Exception.Message)"
    }
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
    $zvmVersion = $null
    if ($zonContent -match '\.version\s*=\s*"([^"]+)"') {
        $zvmVersion = $Matches[1]
    }

    if (-not $Force -and $zvmVersion) {
        $installedVersion = Get-InstalledZvmVersion
        if ($installedVersion -eq $zvmVersion) {
            Write-Host "zvm $installedVersion is already installed."

            return
        }
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

    Copy-InstalledBinary (Join-Path $ScriptDir "zig-out\bin\zig.exe") (Join-Path $binDir "zig.exe")
    Copy-InstalledBinary (Join-Path $ScriptDir "zig-out\bin\zls.exe") (Join-Path $binDir "zls.exe")
    Copy-InstalledBinary (Join-Path $ScriptDir "zig-out\bin\zvm.exe") (Join-Path $binDir "zvm.exe")
} else {
    if (-not $Force) {
        $installedVersion = Get-InstalledZvmVersion
        if ($installedVersion) {
            try {
                $release = Invoke-RestMethod -Uri $ReleaseApi
                $remoteVersion = ([string]$release.tag_name).Trim()
                if ($remoteVersion.StartsWith("v")) {
                    $remoteVersion = $remoteVersion.Substring(1)
                }

                if ($remoteVersion -and $installedVersion -eq $remoteVersion) {
                    Write-Host "zvm $installedVersion is already installed."

                    return
                }
            } catch {
                Write-Warning "Could not check the latest zvm release, continuing with installation."
            }
        }
    }

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
        $zlsExe = Get-ChildItem -Path $extractPath -Recurse -Filter "zls.exe" | Select-Object -First 1
        $zvmExe = Get-ChildItem -Path $extractPath -Recurse -Filter "zvm.exe" | Select-Object -First 1
        if (-not $zigExe -or -not $zlsExe -or -not $zvmExe) {
            Write-Error "Release archive didn't contain zig.exe, zls.exe, and zvm.exe."

            exit 1
        }

        Copy-InstalledBinary $zigExe.FullName (Join-Path $binDir "zig.exe")
        Copy-InstalledBinary $zlsExe.FullName (Join-Path $binDir "zls.exe")
        Copy-InstalledBinary $zvmExe.FullName (Join-Path $binDir "zvm.exe")
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host "Installed zig + zls + zvm to $binDir"

$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
$pathEntries = @()
if ($userPath) { $pathEntries = $userPath -split ";" }
$pathAvailable = ($env:PATH -split ";") -contains $binDir
if (-not $pathAvailable) {
    $env:PATH = if ($env:PATH) { "$binDir;$env:PATH" } else { $binDir }
    $pathAvailable = $true
}
$pathConfigured = $false

if ($pathEntries -contains $binDir) {
    $pathConfigured = $true
    Write-Host "$binDir is already on your PATH."
} else {
    $answer = $null
    if ($AddToPath -or ($Yes -and -not $NoAddToPath)) {
        $answer = "y"
    } elseif ($NoAddToPath) {
        $answer = "n"
    } elseif ([Environment]::UserInteractive) {
        try {
            $answer = Read-Host "Add $binDir to your user PATH? [y/n]"
        } catch {
            $answer = $null
        }
    }

    if ($null -eq $answer) {
        Write-PathSetupCommand $binDir
    } elseif ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[Yy]') {
        $newPath = if ($userPath) { "$binDir;$userPath" } else { $binDir }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        $pathConfigured = $true
        Write-Host "Added. Open a new terminal to pick it up."
    } else {
        if ($NoAddToPath) {
            Write-Host "Skipped PATH setup (-NoAddToPath)."
        } else {
            Write-Host "Skipped."
        }
        Write-PathSetupCommand $binDir
    }
}

Write-Host ""
if ($pathAvailable) {
    Write-Host "Done. Try: zvm version"
} elseif ($pathConfigured) {
    Write-Host "Done. Open a new terminal and try: zvm version"
} else {
    Write-Host "Done. Once $binDir is on your PATH, try: zvm version"
}
