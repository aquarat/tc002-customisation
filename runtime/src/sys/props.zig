//! a bounded invocation of the device's own /bin/setprop: fork, exec with an empty environment,
//! wait at most `timeout_ns`, kill on timeout. never reports success it did not observe.
//! `get` reads a property back through /bin/getprop for the boot-path recovery checks.
const std = @import("std");
const sys = @import("linux.zig");

pub const Error = error{ SpawnFailed, SetpropFailed, Timeout };

pub const setprop_path: [:0]const u8 = "/bin/setprop";
pub const getprop_path: [:0]const u8 = "/bin/getprop";

/// read a property via /bin/getprop; returns the trimmed value in `out`, or an empty slice on any
/// failure or unset property. best effort: it never errors, so callers treat "" as "not set".
pub fn get(name: [:0]const u8, out: []u8, timeout_ns: u64) []const u8 {
    const fds = sys.pipeNonblock() catch return out[0..0];
    const pid = sys.fork() catch {
        sys.close(fds[0]);
        sys.close(fds[1]);
        return out[0..0];
    };
    if (pid == 0) {
        sys.unblockAllSignals();
        sys.dup2(fds[1], 1) catch sys.exit(126);
        sys.close(fds[0]);
        sys.close(fds[1]);
        const argv = [_:null]?[*:0]const u8{ getprop_path.ptr, name.ptr };
        const envp = [_:null]?[*:0]const u8{};
        sys.execve(getprop_path.ptr, &argv, &envp) catch {};
        sys.exit(127);
    }
    sys.close(fds[1]);
    defer sys.close(fds[0]);
    var len: usize = 0;
    var child_done = false;
    const deadline = sys.monotonicNs() + timeout_ns;
    while (true) {
        var progressed = false;
        if (len < out.len) {
            if (sys.read(fds[0], out[len..])) |n| {
                if (n > 0) {
                    len += n;
                    progressed = true;
                } else if (child_done) break; // EOF and the child is gone
            } else |_| {}
        } else if (child_done) break;
        if (!child_done and (sys.waitNoHang(pid) catch null) != null) child_done = true;
        if (!progressed) {
            if (sys.monotonicNs() >= deadline) {
                sys.kill(pid, .KILL);
                _ = sys.waitNoHang(pid) catch null;
                break;
            }
            sys.nanosleep(5_000_000);
        }
    }
    return std.mem.trim(u8, out[0..len], " \t\r\n");
}

pub fn set(name: [:0]const u8, value: [:0]const u8, timeout_ns: u64) Error!void {
    const pid = sys.fork() catch return error.SpawnFailed;
    if (pid == 0) {
        sys.unblockAllSignals();
        const argv = [_:null]?[*:0]const u8{ setprop_path.ptr, name.ptr, value.ptr };
        const envp = [_:null]?[*:0]const u8{};
        sys.execve(setprop_path.ptr, &argv, &envp) catch {};
        sys.exit(127);
    }
    const deadline = sys.monotonicNs() + timeout_ns;
    while (true) {
        const status = sys.waitNoHang(pid) catch return error.SetpropFailed;
        if (status) |st| {
            const exited_normally = (st & 0x7f) == 0;
            const code = (st >> 8) & 0xff;
            return if (exited_normally and code == 0) {} else error.SetpropFailed;
        }
        if (sys.monotonicNs() >= deadline) {
            sys.kill(pid, .KILL);
            var tries: u32 = 0;
            while (tries < 100) : (tries += 1) {
                if ((sys.waitNoHang(pid) catch null) != null) break;
                sys.nanosleep(10_000_000);
            }
            return error.Timeout;
        }
        sys.nanosleep(10_000_000);
    }
}
