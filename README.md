# zvm

`zvm` is a small Zig version manager for Linux and Windows.

The main idea is simple: put zvm's `zig` shim on your PATH,
then keep typing `zig build` (or any other zig command) like normal.
When you're inside a project, it reads the project's `build.zig.zon`, 
finds the requested Zig version, downloads it if needed,
and runs the real compiler for you.

No `use` command before every project. No remembering which compiler you had installed last week.
Just `zig`.

It also includes a separate `zvm` command for the usual version-manager jobs:
installing versions ahead of time, listing them, choosing a default, and removing old ones.

## Why this exists

I liked the "look at `build.zig.zon` and get out of the way" workflow from
[anyzig](https://github.com/marler8997/anyzig).
I also wanted a proper cache, normal management commands, fallback mirrors,
and visible download progress.

So zvm is meant to be a fairly boring tool in the best way:
it should pick the right compiler and let you get back to your project.

## What it does

There are two executables:

- `zig` is the transparent shim. This is the one you put on your PATH and use day to day.
- `zvm` is the management CLI, not really required to be on PATH,
   but useful if you use it frequently.

When the shim needs to choose a version, it checks these in order:

1. A version written directly after `zig`, for example `zig 0.16.0 build`.
2. `minimum_zig_version` from the nearest `build.zig.zon`, 
   searching upward from the current directory.
3. Your configured default version.
4. The version you used most recently.

`minimum_zig_version` is treated as an exact version here.
That may sound a little strict, but it is the least surprising option for a compiler manager:
the project asks for a version, and zvm uses that version.

## Downloads and verification

zvm gets Zig's official community-mirror list, shuffles it,
and tries mirrors before falling back to ziglang.org.
If a mirror stops responding while zvm is waiting for response data,
it gives up after 5 seconds and moves on.

Downloads listed in Zig's official `index.json` are verified with their SHA-256 checksum.
For older development snapshots that are no longer listed there,
zvm tries the adjacent Minisign signature instead. If neither one is available,
an interactive install asks before continuing,
a non-interactive install refuses the unverified compiler.

This mostly comes up with IDEs. 
If an IDE starts `zig` for a project whose required compiler is
not installed and that compiler cannot be verified,
there is no terminal available for zvm to ask you the question,
so the IDE request fails. 
Open a terminal in that project and run `zig` once instead,
zvm will resolve and install the required version there (asking if needed).
After that, the IDE should find the cached compiler, restarting the IDE may be necessary.

There is also `zvm --no-verify install <version>` for situations where you
really need to bypass verification.

## Install

```sh
# Linux
curl -fsSL https://git.xeondev.com/nyan/zvm/raw/branch/main/install.ps1 | sh
```

```powershell
# Windows
irm https://git.xeondev.com/nyan/zvm/raw/branch/main/install.ps1 | iex
```

Both commands use the same cross-platform installer. It installs `zig` and
`zvm` into zvm's `bin` directory and offers to add that directory to your
PATH.

If you would rather build from a checkout:

```sh
# Linux
./install.ps1 --build
```

```powershell
# Windows
.\install.ps1 -Build
```

Building from source needs the exact Zig version pinned in `build.zig.zon`.

## Everyday usage

```sh
# In a project with minimum_zig_version in build.zig.zon
zig build

# Use a version for this one command only
zig 0.16.0 build-exe hello.zig

# Install something ahead of time
zvm install 0.15.0

# See what you have
zvm list

# See versions known by the official index
zvm list-remote

# See what `zig` would choose here, and why
zvm which

# Set or clear a fallback
zvm default 0.16.0
zvm default clear

# Clean up an old version
zvm remove 0.15.0
```

For extra diagnostics:

```sh
zvm --verbose install 0.16.0
```
```sh
# Linux
ZVM_DEBUG=1 zig build
```
```powershell
# Windows PowerShell
$env:ZVM_DEBUG=1; zig build; Remove-Item Env:ZVM_DEBUG
```

The shim does not accept `--verbose` itself because all of its arguments need
to be passed through untouched to the Zig compiler.

## Where it stores things

zvm uses `$ZVM_HOME` when it is set. Otherwise it uses:

- Windows: `%LOCALAPPDATA%\zvm`
- Linux: `$XDG_DATA_HOME/zvm`, or `~/.local/share/zvm`

Inside that directory you will find:

```text
versions/       installed Zig toolchains
cache/          downloaded index and mirror metadata + temporary files
config.json     default and most recently used versions
bin/            the zvm `zig` shim and `zvm` CLI
```

An installed version is only moved into `versions/` after extraction finishes,
so an interrupted download should not leave behind a version that looks valid
but is incomplete.

## Supported platforms

zvm supports Linux and Windows on x86_64 and aarch64.

macOS is intentionally not listed yet. It might be possible to make it work,
but shipping a platform I cannot properly test would be a bad deal for anyone
who tries it, but contributions are welcomed ^^.

## License

MIT. See [LICENSE](LICENSE).
