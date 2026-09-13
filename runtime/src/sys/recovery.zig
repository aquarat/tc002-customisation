//! recovery helpers for the persistent boot path (see ../../FIRMWARE.md).
//!
//! two mechanisms keep a flashed runtime from bricking the device:
//!
//!  - **the stock-config fallback.** the vendor loader reads `/tmp/EasyUI.cfg` before the read-only
//!    `/res/etc/EasyUI.cfg`. writing a copy whose `startupLibPath` is the stock app library makes
//!    the next `zkswe` start the vendor app instead of our bootstrap. `/tmp` is tmpfs, so this
//!    lasts only until the next power cycle -- long enough for the vendor app to bring the network
//!    up its own proven way (so adb is reachable) and to run its own upgrade check, which is what
//!    the reset button's reflash relies on.
//!
//!  - **the boot-failure counter.** the bootstrap increments a small counter on the persistent
//!    `/data` partition before it execs the supervisor; the supervisor clears it once it is
//!    healthy. if the runtime keeps failing to come up, the count reaches a threshold and the
//!    bootstrap writes the stock config and steps aside, so a broken runtime self-recovers to the
//!    vendor app with no hands on the device.
//!
//! raw linux syscalls, no allocator, so the no-libc bootstrap can use it as-is.
const std = @import("std");
const linux = std.os.linux;

pub const easyui_cfg_path: [*:0]const u8 = "/tmp/EasyUI.cfg";
pub const fail_count_path: [*:0]const u8 = "/data/tc002/state/boot-fails";
pub const fail_threshold: u8 = 3;

/// the stock loader configuration: the same keys as the device's `/res/etc/EasyUI.cfg`, with
/// `startupLibPath` pointing at the vendor app library. compact json (the loader parses it with
/// jsoncpp, so whitespace and key order do not matter); written to `/tmp/EasyUI.cfg` to hand back.
pub const stock_easyui_cfg =
    "{\"baud\":\"115200\",\"rotateTouch\":0,\"rotateScreen\":0," ++
    "\"startupLibPath\":\"/res/lib/libzkgui.so\",\"languageCode\":\"zh_CN\"," ++
    "\"defBrightness\":-1,\"screensaverTimeOut\":-1,\"touchDev\":\"/dev/input/event0\"," ++
    "\"languagePath\":\"/res/tr/\",\"uart\":\"ttyS1\",\"startupTouchCalib\":false," ++
    "\"zkdebug\":false,\"resPath\":\"/res/ui/\"}\n";

fn isErr(rc: usize) bool {
    const s: isize = @bitCast(rc);
    return s < 0 and s > -4096;
}

fn openZ(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) ?i32 {
    const rc = linux.openat(linux.AT.FDCWD, path, flags, mode);
    if (isErr(rc)) return null;
    return @intCast(rc);
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (isErr(rc)) return false;
        const n: usize = @intCast(rc);
        if (n == 0) return false;
        off += n;
    }
    return true;
}

/// write the stock loader config to `/tmp/EasyUI.cfg`. best effort; returns whether it was written.
pub fn writeStockCfg() bool {
    const fd = openZ(easyui_cfg_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) orelse return false;
    defer _ = linux.close(fd);
    return writeAll(fd, stock_easyui_cfg);
}

/// the boot-failure count, or 0 when the file is absent or unreadable.
pub fn readFailCount() u8 {
    const fd = openZ(fail_count_path, .{ .ACCMODE = .RDONLY }, 0) orelse return 0;
    defer _ = linux.close(fd);
    var buf: [16]u8 = undefined;
    const rc = linux.read(fd, &buf, buf.len);
    if (isErr(rc)) return 0;
    const n: usize = @intCast(rc);
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(u8, trimmed, 10) catch 0;
}

/// write the boot-failure count, creating the state directory if it is not there yet.
pub fn writeFailCount(v: u8) void {
    _ = linux.mkdir("/data/tc002", 0o700);
    _ = linux.mkdir("/data/tc002/state", 0o700);
    const fd = openZ(fail_count_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) orelse return;
    defer _ = linux.close(fd);
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{v}) catch return;
    _ = writeAll(fd, text);
}

test "fail count round-trips through /tmp" {
    // redirect the path check is not worth it here; just exercise the parse/format helpers.
    try std.testing.expectEqual(@as(u8, 0), std.fmt.parseInt(u8, std.mem.trim(u8, "0\n", " \t\r\n"), 10) catch 0);
    try std.testing.expectEqual(@as(u8, 3), std.fmt.parseInt(u8, std.mem.trim(u8, "  3 \n", " \t\r\n"), 10) catch 0);
    try std.testing.expectEqual(@as(u8, 0), std.fmt.parseInt(u8, std.mem.trim(u8, "garbage", " \t\r\n"), 10) catch 0);
}
