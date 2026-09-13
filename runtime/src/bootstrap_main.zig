//! libtc002-bootstrap.so: the shared object the vendor loader dlopens as its "startup library".
//! it has no libc. its constructor execs the supervisor at the path fixed at build time, passing
//! `--from-bootstrap`, the loader's environment, and (for a flashed image, when `bin_dir` is set)
//! the directories that hold the binaries and the network bring-up scripts.
//!
//! before exec it consults the boot-failure counter on the persistent partition (see
//! sys/recovery.zig): if the runtime has failed to come up cleanly too many times, it writes the
//! stock loader config to /tmp and steps aside so the vendor app boots instead, and the device
//! self-recovers with no intervention. otherwise it arms the counter for this attempt; the
//! supervisor clears it once it is healthy. it never sets the anti-brick property; if the exec
//! fails it writes one line to stderr and exits, so an absent supervisor is never mistaken for a
//! running one.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const recovery = @import("sys/recovery.zig");

const supervisor_path: [:0]const u8 = build_options.supervisor_path ++ "";
const bin_dir: [:0]const u8 = build_options.bin_dir ++ "";
const failure_message = "tc002-bootstrap: exec of supervisor failed\n";

const Envp = [*:null]?[*:0]const u8;

// the host process's environment: glibc/uclibc/musl export `environ`; macos needs _NSGetEnviron.
const linux_environ = if (builtin.os.tag == .linux) @extern(?*Envp, .{ .name = "environ", .linkage = .weak }) else null;
extern "c" fn _NSGetEnviron() *Envp;

fn environment() Envp {
    const empty: [0:null]?[*:0]const u8 = .{};
    if (builtin.os.tag == .linux) {
        if (linux_environ) |p| return p.*;
        return &empty;
    }
    if (builtin.os.tag == .macos) return _NSGetEnviron().*;
    return &empty;
}

fn bootstrap() callconv(.c) void {
    if (builtin.os.tag == .linux) {
        // self-heal: if the runtime keeps failing to come up, hand back to the stock app
        const fails = recovery.readFailCount();
        if (fails >= recovery.fail_threshold) {
            _ = recovery.writeStockCfg();
            std.os.linux.exit_group(0); // the loader restarts and reads the stock /tmp/EasyUI.cfg
        }
        recovery.writeFailCount(fails + 1); // the supervisor clears this once it is healthy
        // on a flashed image (bin_dir set) tell the supervisor where its binaries and the network
        // bring-up scripts are; bin_dir.len is comptime, so only one argv is compiled in.
        if (bin_dir.len > 0) {
            const argv = [_:null]?[*:0]const u8{ supervisor_path.ptr, "--from-bootstrap", "--bin-dir", bin_dir.ptr, "--netup-dir", bin_dir.ptr };
            _ = std.os.linux.execve(supervisor_path.ptr, &argv, environment());
        } else {
            const argv = [_:null]?[*:0]const u8{ supervisor_path.ptr, "--from-bootstrap" };
            _ = std.os.linux.execve(supervisor_path.ptr, &argv, environment());
        }
        _ = std.os.linux.write(2, failure_message.ptr, failure_message.len);
        std.os.linux.exit_group(1);
    } else {
        const argv = [_:null]?[*:0]const u8{ supervisor_path.ptr, "--from-bootstrap" };
        _ = std.c.execve(supervisor_path.ptr, @ptrCast(&argv), @ptrCast(environment()));
        _ = std.c.write(2, failure_message.ptr, failure_message.len);
        std.c._exit(1);
    }
}

export const init_array linksection(if (builtin.os.tag == .macos) "__DATA,__mod_init_func" else ".init_array") = [_]*const fn () callconv(.c) void{&bootstrap};
