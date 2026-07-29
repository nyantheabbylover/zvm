//! Shared library for the `zig` shim and `zvm` CLI.

pub const app_version = @import("build_options").app_version;

pub const cached_fetch = @import("zvm/cached_fetch.zig");
pub const color = @import("zvm/color.zig");
pub const config = @import("zvm/config.zig");
pub const debug = @import("zvm/debug.zig");
pub const download = @import("zvm/download.zig");
pub const exec = @import("zvm/exec.zig");
pub const extract = @import("zvm/extract.zig");
pub const index = @import("zvm/index.zig");
pub const lock = @import("zvm/lock.zig");
pub const minisign = @import("zvm/minisign.zig");
pub const mirrors = @import("zvm/mirrors.zig");
pub const net = @import("zvm/net.zig");
pub const paths = @import("zvm/paths.zig");
pub const resolve = @import("zvm/resolve.zig");
pub const retry = @import("zvm/retry.zig");
pub const target = @import("zvm/target.zig");
pub const version = @import("zvm/version.zig");
pub const zon_scan = @import("zvm/zon_scan.zig");
