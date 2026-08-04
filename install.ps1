#!/bin/sh
echo `# <#`

case "$0" in
  */*)
    script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
    installer="$script_dir/install.linux.sh"
    if [ -f "$installer" ]; then
      exec sh "$installer" "$@"
    fi
    ;;
esac

tmp="$(mktemp "${TMPDIR:-/tmp}/zvm-install.XXXXXX")" || exit 1
trap 'rm -f "$tmp"' EXIT HUP INT TERM
if ! curl -fsSL -o "$tmp" "https://git.xeondev.com/nyan/zvm/raw/branch/main/install.linux.sh"; then
  echo "error: failed to download the zvm installer" >&2
  exit 1
fi
sh "$tmp" "$@"
exit $?
#> > $null
$ErrorActionPreference = "Stop"
$installer = if ($PSScriptRoot) { Join-Path $PSScriptRoot "install.windows.ps1" } else { $null }
if ($installer -and (Test-Path -LiteralPath $installer -PathType Leaf)) {
    & $installer @args
    exit 0
}

$remoteInstaller = Invoke-RestMethod -Uri "https://git.xeondev.com/nyan/zvm/raw/branch/main/install.windows.ps1"
$installerScript = [ScriptBlock]::Create($remoteInstaller)
& $installerScript @args
