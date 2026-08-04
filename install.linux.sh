#!/bin/sh
# Installs zvm: downloads a prebuilt release by default.
# Pass --build to build from source instead, that requires running this
# script from a local checkout of the repo (not the curl | sh one-liner,
# since there's no source tree to build in that case) and a zig compiler
# matching this project's pinned version already on PATH.
set -eu

build_from_source=0
force=0
yes=0
path_mode="auto"
for arg in "$@"; do
  case "$arg" in
    --build) build_from_source=1 ;;
    --force) force=1 ;;
    -y | --yes) yes=1 ;;
    --add-to-path)
      if [ "$path_mode" = "no" ]; then
        echo "error: --add-to-path and --no-add-to-path cannot be used together" >&2
        exit 1
      fi
      path_mode="yes"
      ;;
    --no-add-to-path)
      if [ "$path_mode" = "yes" ]; then
        echo "error: --add-to-path and --no-add-to-path cannot be used together" >&2
        exit 1
      fi
      path_mode="no"
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

RELEASE_BASE="${ZVM_RELEASE_BASE:-https://git.xeondev.com/nyan/zvm/releases/download/latest}"
RELEASE_API="${ZVM_RELEASE_API:-https://git.xeondev.com/api/v1/repos/nyan/zvm/releases/latest}"

os="linux"
arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64) arch="x86_64" ;;
  aarch64 | arm64) arch="aarch64" ;;
  *)
    echo "error: unsupported architecture: $arch" >&2
    exit 1
    ;;
esac
target="$arch-$os"

if [ -n "${ZVM_HOME:-}" ]; then
  zvm_home="$ZVM_HOME"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
  zvm_home="$XDG_DATA_HOME/zvm"
else
  zvm_home="$HOME/.local/share/zvm"
fi
bin_dir="$zvm_home/bin"
mkdir -p "$bin_dir"

find_processes_using() {
  target="$1"
  for proc_dir in /proc/[0-9]*; do
    [ -r "$proc_dir/exe" ] || continue
    process_path="$(readlink "$proc_dir/exe" 2>/dev/null || true)"
    if [ "$process_path" = "$target" ]; then
      printf '%s\n' "${proc_dir##*/}"
    fi
  done
}

copy_installed_binary() {
  source="$1"
  destination="$2"

  pids="$(find_processes_using "$destination")"
  if [ -n "$pids" ]; then
    echo "warning: $destination is in use by:" >&2
    for pid in $pids; do
      process_name="$(cat "/proc/$pid/comm" 2>/dev/null || printf '%s' 'unknown')"
      echo "  $process_name (PID $pid)" >&2
    done

    reply="n"
    interactive_terminal=0
    if [ "$yes" = "0" ] && [ -t 1 ] && [ -r /dev/tty ]; then
      printf 'Terminate these process(es) and retry? [y/N] ' >/dev/tty
      if read -r reply </dev/tty; then
        interactive_terminal=1
      fi
    fi

    case "$reply" in
      [Yy]*)
        for pid in $pids; do
          kill -KILL "$pid" 2>/dev/null || true
        done
        sleep 0.25
        ;;
      *)
        if [ "$interactive_terminal" = "1" ]; then
          echo "Skipped. Close the process(es) above and retry the installation." >&2
        else
          echo "No interactive terminal was available. Close the process(es) above and retry the installation." >&2
        fi
        return 1
        ;;
    esac
  fi

  if cp "$source" "$destination" 2>/dev/null; then
    return 0
  fi

  echo "error: could not replace $destination." >&2
  echo "Close programs using it and retry the installation." >&2
  return 1
}

if [ "$build_from_source" = "1" ]; then
  SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
  zon_path="$SCRIPT_DIR/build.zig.zon"
  if [ ! -f "$zon_path" ]; then
    echo "error: --build requires running this script from a checkout of the zvm repository." >&2
    echo "(piping it straight from curl only gets you the script, not the source tree)" >&2
    exit 1
  fi

  required="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$zon_path")"
  zvm_version="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$zon_path")"

  if [ "$force" = "0" ] && command -v zvm >/dev/null 2>&1; then
    if installed_version="$(zvm version 2>/dev/null)" && [ "$installed_version" = "$zvm_version" ]; then
      echo "zvm $installed_version is already installed"
      exit 0
    fi
  fi

  if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig is not installed, or not on PATH." >&2
    echo "This project needs zig $required: https://ziglang.org/download/" >&2
    exit 1
  fi

  have="$(zig version)"
  if [ -n "$required" ] && [ "$have" != "$required" ]; then
    echo "error: found zig $have on PATH, but this project needs exactly zig $required." >&2
    echo "Install it from: https://ziglang.org/download/" >&2
    exit 1
  fi

  echo "Building zvm with zig $have..."
  (cd "$SCRIPT_DIR" && zig build -Doptimize=ReleaseFast)

  copy_installed_binary "$SCRIPT_DIR/zig-out/bin/zig" "$bin_dir/zig"
  copy_installed_binary "$SCRIPT_DIR/zig-out/bin/zvm" "$bin_dir/zvm"
else
  if [ "$force" = "0" ] && command -v zvm >/dev/null 2>&1; then
    if release_json="$(curl -fsSL "$RELEASE_API" 2>/dev/null)"; then
      remote_tag="$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
      remote_version="${remote_tag#v}"
      if installed_version="$(zvm version 2>/dev/null)" && [ -n "$remote_version" ] && [ "$installed_version" = "$remote_version" ]; then
        echo "zvm $installed_version is already installed"
        exit 0
      fi
    else
      echo "warning: could not check the latest zvm release, continuing with installation" >&2
    fi
  fi

  url="$RELEASE_BASE/zvm-$target.tar.xz"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "Downloading $url"
  curl -fsSL -o "$tmp/zvm.tar.xz" "$url"

  mkdir -p "$tmp/extracted"
  tar -xf "$tmp/zvm.tar.xz" -C "$tmp/extracted"

  zig_bin="$(find "$tmp/extracted" -type f -name 'zig' | head -n 1)"
  zvm_bin="$(find "$tmp/extracted" -type f -name 'zvm' | head -n 1)"
  if [ -z "$zig_bin" ] || [ -z "$zvm_bin" ]; then
    echo "error: release archive didn't contain both 'zig' and 'zvm' binaries." >&2
    exit 1
  fi

  copy_installed_binary "$zig_bin" "$bin_dir/zig"
  copy_installed_binary "$zvm_bin" "$bin_dir/zvm"
fi

chmod +x "$bin_dir/zig" "$bin_dir/zvm"

echo "Installed zig + zvm to $bin_dir"

path_available=0
case ":$PATH:" in
  *":$bin_dir:"*) path_available=1 ;;
esac
if [ "$path_available" = "0" ]; then
  PATH="$bin_dir:$PATH"
  export PATH
fi
path_configured=0

print_path_command() {
  quoted_bin_dir="$(printf '%s' "$bin_dir" | sed "s/'/'\\\\''/g")"
  printf '  export PATH='"'%s'"':"$PATH"\n' "$quoted_bin_dir"
}

if [ "$path_available" = "1" ]; then
  path_configured=1
  echo "$bin_dir is already on your PATH."
else
  profile=""
  supported_shell=1

  case "${SHELL:-}" in
    */zsh) profile="$HOME/.zshrc" ;;
    */bash) profile="$HOME/.bashrc" ;;
    */fish) profile="$HOME/.config/fish/config.fish" ;;
    *) supported_shell=0 ;;
  esac

  if [ "$supported_shell" = "0" ]; then
    if [ "$path_mode" = "yes" ]; then
      echo "error: --add-to-path requires bash, zsh, or fish so zvm can choose a profile file." >&2
      echo "Add this to your shell configuration manually:" >&2
      print_path_command >&2
      exit 1
    fi

    if [ "$path_mode" = "no" ]; then
      echo "Skipped PATH setup (--no-add-to-path)."
      print_path_command
    else
      if [ -n "${SHELL:-}" ]; then
        shell_name="${SHELL##*/}"
        echo "Your shell ($shell_name) is not supported for automatic PATH setup."
      else
        echo "Your shell could not be identified, so PATH was not changed."
      fi
      echo "For a POSIX-compatible shell, add this to its configuration manually:"
      print_path_command
    fi
  else
    reply="n"
    interactive_terminal=0
    if [ "$path_mode" = "yes" ] || { [ "$path_mode" = "auto" ] && [ "$yes" = "1" ]; }; then
      reply="Y"
    elif [ "$path_mode" = "no" ]; then
      reply="n"
    elif [ -t 1 ] && printf '\nAdd %s to PATH in %s? [Y/n] ' "$bin_dir" "$profile" >/dev/tty && read -r reply </dev/tty; then
      reply="${reply:-Y}"
      interactive_terminal=1
    fi

    case "$reply" in
      [Yy]*)
      mkdir -p "$(dirname "$profile")"
      if [ "${profile##*fish}" != "$profile" ]; then
        escaped_bin_dir="$(printf '%s' "$bin_dir" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g')"
        printf '\nfish_add_path "%s"\n' "$escaped_bin_dir" >>"$profile"
      else
        quoted_bin_dir="$(printf '%s' "$bin_dir" | sed "s/'/'\\\\''/g")"
        printf '\nexport PATH='"'%s'"':"$PATH"\n' "$quoted_bin_dir" >>"$profile"
      fi
      path_configured=1
      echo "Added to $profile. Restart your shell to pick it up."
      ;;
      *)
      if [ "$path_mode" = "no" ]; then
        echo "Skipped PATH setup (--no-add-to-path)."
      elif [ "$interactive_terminal" = "1" ]; then
        echo "Skipped. Add this to your shell config manually:"
      else
        echo "No interactive terminal was available, so PATH was not changed."
        echo "Add this to your shell config manually:"
      fi
      print_path_command
      ;;
    esac
  fi
fi

echo
if [ "$path_available" = "1" ] || [ "${ZVM_INSTALLER_SOURCE_MODE:-}" = "1" ]; then
  echo "Done. Try: zvm version"
elif [ "$path_configured" = "1" ]; then
  echo "Done. Restart your shell and try: zvm version"
else
  echo "Done. Once $bin_dir is on your PATH, try: zvm version"
fi
