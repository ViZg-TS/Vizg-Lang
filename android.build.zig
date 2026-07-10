// android.build.zig - Android cross-compilation helpers for Zig projects.
//
// Import from your build.zig:
//   const android = @import("android.build");

const std = @import("std");

pub const Arch = enum {
    aarch64, // ARM 64-bit -- most common on modern devices
    armv7l,  // ARM 32-bit (hard-float) -- older but still used
    x86_64,  // x86_64 -- useful for emulators

    fn triple(self: Arch) []const u8 {
        return switch (self) {
            .aarch64 => "aarch64-linux-android",
            .armv7l => "armv7-linux-androideabi",
            .x86_64 => "x86_64-linux-android",
        };
    }

    fn defaultApi(self: Arch) u32 {
        return switch (self) {
            .aarch64 => 21,
            .armv7l => 24,
            .x86_64 => 24,
        };
    }

    fn cpuArch(self: Arch) std.Target.Cpu.Arch {
        return switch (self) {
            .aarch64 => .aarch64,
            .armv7l => .arm,
            .x86_64 => .x86_64,
        };
    }

    fn abi(self: Arch) std.Target.Abi {
        return switch (self) {
            .aarch64 => .android,
            .armv7l => .androideabi,
            .x86_64 => .gnu, // x86 Android uses gnu abi
        };
    }

    fn sysrootArch(self: Arch) []const u8 {
        return switch (self) {
            .aarch64 => "/aarch64-linux-android/",
            .armv7l => "/arm-linux-androideabi/",
            .x86_64 => "/x86_64-linux-android/",
        };
    }

    fn apiName(self: Arch) []const u8 {
        return switch (self) {
            .aarch64 => "aarch64-linux-android",
            .armv7l => "arm-linux-androideabi",
            .x86_64 => "x86_64-linux-android",
        };
    }
};

pub fn findNdk(allocator: std.mem.Allocator, b: *std.Build) ![]const u8 {
    if (try allocator.getEnvVarOwned("ANDROID_NDK_HOME")) |ndk| return ndk;
    if (try allocator.getEnvVarOwned("NDK_ROOT")) |ndk| return ndk;
    if (try allocator.getEnvVarOwned("NDK_PATH")) |ndk| return ndk;

    const home = try allocator.getEnvVarOwned("ANDROID_HOME") catch null orelse
        try allocator.getEnvVarOwned("ANDROID_SDK_ROOT") catch null;
    if (home) |h| {
        defer allocator.free(h);

        var best: ?[]const u8 = null;

        const dir_path = try std.mem.concat(allocator, u8, &[_][]const u8{ h, "/ndk/" });
        defer allocator.free(dir_path);

        var ndk_dir = b.graph.os.fs().openDir(dir_path[0..], .{}) catch {
            return error.NdkNotFound;
        };
        defer ndk_dir.close();

        while (true) {
            const entry = ndk_dir.readDir() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (!entry.kind.isDir()) continue;
            best = entry.name;
        }

        if (best) |name| {
            const path = try std.mem.concat(allocator, u8, &[_][]const u8{ h, "/", name });
            return path;
        }
    }

    return error.NdkNotFound;
}

pub fn configureAndroidTarget(
    b: *std.Build,
    compile_step: *std.Build.Step.Compile,
    arch: Arch,
    api_level: u32,
) !void {
    // Resolve target triple. NDK/LLVM toolchain is auto-discovered via ANDROID_NDK_HOME env var.
    // Do NOT set link_libc — Android uses bionic (auto-discovered); -lc forces glibc lookup and fails.
    compile_step.root_module.resolved_target = b.resolveTargetQuery(.{
        .cpu_arch = arch.cpuArch(),
        .os_tag   = .linux,
        .abi      = arch.abi(),
    });

    std.log.info(
        "[android.build] configured Android target:\n" ++
            "  arch     = {s}\n" ++
            "  api      = {d}\n",
        .{ @tagName(arch), api_level },
    );
}

pub fn addAndroidExe(
    b: *std.Build,
    name: []const u8,
    src_path: std.Build.LazyPath,
    arch: Arch,
) !*std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch.cpuArch(),
        .os_tag   = .linux,
        .abi      = arch.abi(),
    });

    const opts = std.Build.ExecutableOptions{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = src_path,
            .target         = target,
        }),
    };

    const exe = b.addExecutable(opts);

    try configureAndroidTarget(b, exe, arch, 24);

    return exe;
}

pub fn isAndroid(b: *std.Build) bool {
    const opts = b.standardTargetOptions(.{});
    return std.mem.eql(u8, @tagName(opts.os), "android");
}

pub fn androidPageAllocator(allocator: std.mem.Allocator) std.mem.Allocator {
    return allocator.page_allocator();
}

pub fn addAndroidStep(b: *std.Build, name: []const u8) *std.Build.Step {
    const step = b.step(name, "Build for Android");
    return step;
}
