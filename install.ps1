#!/bin/sh
echo `# <#`

zvm_installer_sourced=0
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  zvm_installer_sourced=1
fi

add_zvm_to_current_path() {
  if [ -n "${ZVM_HOME:-}" ]; then
    zvm_home="$ZVM_HOME"
  elif [ -n "${XDG_DATA_HOME:-}" ]; then
    zvm_home="$XDG_DATA_HOME/zvm"
  else
    zvm_home="$HOME/.local/share/zvm"
  fi

  zvm_bin="$zvm_home/bin"
  case ":$PATH:" in
    *":$zvm_bin:"*) ;;
    *) PATH="$zvm_bin:$PATH"; export PATH ;;
  esac
}

script_path="${BASH_SOURCE:-$0}"
case "$script_path" in
  */*)
    script_dir="$(CDPATH= cd "$(dirname "$script_path")" && pwd)"
    installer="$script_dir/install.linux.sh"
    if [ -f "$installer" ]; then
      if [ "$zvm_installer_sourced" = "1" ]; then
        if ZVM_INSTALLER_SOURCE_MODE=1 sh "$installer" "$@"; then
          add_zvm_to_current_path
          return 0
        else
          return $?
        fi
      fi
      exec sh "$installer" "$@"
    fi
    ;;
esac

if ! tmp="$(mktemp "${TMPDIR:-/tmp}/zvm-install.XXXXXX")"; then
  echo "error: failed to create a temporary file for the zvm installer" >&2
  if [ "$zvm_installer_sourced" = "1" ]; then
    return 1
  fi
  exit 1
fi
if [ "$zvm_installer_sourced" = "0" ]; then
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
fi
if ! curl -fsSL -o "$tmp" "https://git.xeondev.com/nyan/zvm/raw/branch/main/install.linux.sh"; then
  echo "error: failed to download the zvm installer" >&2
  rm -f "$tmp" || true
  if [ "$zvm_installer_sourced" = "1" ]; then
    return 1
  fi
  exit 1
fi
if [ "$zvm_installer_sourced" = "1" ]; then
  if ZVM_INSTALLER_SOURCE_MODE=1 sh "$tmp" "$@"; then
    rm -f "$tmp" || true
    add_zvm_to_current_path
    return 0
  else
    status=$?
    rm -f "$tmp" || true
    return "$status"
  fi
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
