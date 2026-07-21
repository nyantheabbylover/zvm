#!/usr/bin/env bash
# Installs zvm: downloads a prebuilt release by default.
# Pass --build to build from source instead, that requires running this
# script from a local checkout of the repo (not the curl | bash one-liner,
# since there's no source tree to build in that case) and a zig compiler
# matching this project's pinned version already on PATH.
set -euo pipefail

build_from_source=0
for arg in "$@"; do
  case "$arg" in
    --build) build_from_source=1 ;;
    *)
      echo "error: unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

RELEASE_BASE="${ZVM_RELEASE_BASE:-https://git.xeondev.com/nyan/zvm/releases/download/latest}"

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

if [ "$build_from_source" = "1" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  zon_path="$SCRIPT_DIR/build.zig.zon"
  if [ ! -f "$zon_path" ]; then
    echo "error: --build requires running this script from a checkout of the zvm repository." >&2
    echo "(piping it straight from curl only gets you the script, not the source tree)" >&2
    exit 1
  fi

  required="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$zon_path")"

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

  cp "$SCRIPT_DIR/zig-out/bin/zig" "$bin_dir/zig"
  cp "$SCRIPT_DIR/zig-out/bin/zvm" "$bin_dir/zvm"
else
  url="$RELEASE_BASE/zvm-$target.tar.xz"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "Downloading $url"
  curl -fsSL -o "$tmp/zvm.tar.xz" "$url"

  mkdir -p "$tmp/extracted"
  tar -xf "$tmp/zvm.tar.xz" -C "$tmp/extracted"

  zig_bin="$(find "$tmp/extracted" -type f -name 'zig' | head -1)"
  zvm_bin="$(find "$tmp/extracted" -type f -name 'zvm' | head -1)"
  if [ -z "$zig_bin" ] || [ -z "$zvm_bin" ]; then
    echo "error: release archive didn't contain both 'zig' and 'zvm' binaries." >&2
    exit 1
  fi

  cp "$zig_bin" "$bin_dir/zig"
  cp "$zvm_bin" "$bin_dir/zvm"
fi

chmod +x "$bin_dir/zig" "$bin_dir/zvm"

echo "Installed zig + zvm to $bin_dir"

case ":$PATH:" in
  *":$bin_dir:"*)
    echo "$bin_dir is already on your PATH."
    ;;
  *)
    profile="$HOME/.profile"
    case "${SHELL:-}" in
      */zsh) profile="$HOME/.zshrc" ;;
      */bash) profile="$HOME/.bashrc" ;;
      */fish) profile="$HOME/.config/fish/config.fish" ;;
    esac

    reply="n"
    if [ -t 0 ]; then
      echo
      read -r -p "Add $bin_dir to PATH in $profile? [Y/n] " reply
      reply="${reply:-Y}"
    fi

    if [[ "$reply" =~ ^[Yy] ]]; then
      if [[ "$profile" == *fish* ]]; then
        printf '\nfish_add_path %q\n' "$bin_dir" >>"$profile"
      else
        printf '\nexport PATH=%q:"$PATH"\n' "$bin_dir" >>"$profile"
      fi
      echo "Added to $profile. Restart your shell (or run: source $profile) to pick it up."
    else
      echo "Skipped. Add this to your shell config manually:"
      printf '  export PATH=%q:"$PATH"\n' "$bin_dir"
    fi
    ;;
esac

echo
echo "Done. Once $bin_dir is on your PATH, try: zig version"
