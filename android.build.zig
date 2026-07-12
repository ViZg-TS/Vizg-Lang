// Android cross-compilation helpers. This configures Zig targets only;
// NDK clang/sysroot integration is intentionally out of scope.

const std = @import("std");

pub const Arch = enum {
    aarch64,
    arm,
    x86,
    x86_64,

    pub fn cpuArch(self: Arch) std.Target.Cpu.Arch {
        return switch (self) {
            .aarch64 => .aarch64,
            .arm => .arm,
            .x86 => .x86,
            .x86_64 => .x86_64,
        };
    }

    pub fn abi(self: Arch) std.Target.Abi {
        return switch (self) {
            .arm => .androideabi,
            .aarch64, .x86, .x86_64 => .android,
        };
    }
};

pub fn targetQuery(arch: Arch, api_level: u32) std.Target.Query {
    return .{
        .cpu_arch = arch.cpuArch(),
        .os_tag = .linux,
        .abi = arch.abi(),
        .android_api_level = api_level,
    };
}

fn compareNdkVersion(a: []const u8, b: []const u8) std.math.Order {
    var a_index: usize = 0;
    var b_index: usize = 0;

    while (a_index < a.len and b_index < b.len) {
        const a_digit = std.ascii.isDigit(a[a_index]);
        const b_digit = std.ascii.isDigit(b[b_index]);
        if (a_digit != b_digit) return std.math.order(@intFromBool(a_digit), @intFromBool(b_digit));

        if (a_digit) {
            const a_start = a_index;
            const b_start = b_index;
            while (a_index < a.len and std.ascii.isDigit(a[a_index])) : (a_index += 1) {}
            while (b_index < b.len and std.ascii.isDigit(b[b_index])) : (b_index += 1) {}

            var a_trim = a_start;
            var b_trim = b_start;
            while (a_trim < a_index and a[a_trim] == '0') : (a_trim += 1) {}
            while (b_trim < b_index and b[b_trim] == '0') : (b_trim += 1) {}
            const length_order = std.math.order(a_index - a_trim, b_index - b_trim);
            if (length_order != .eq) return length_order;
            const digits_order = std.mem.order(u8, a[a_trim..a_index], b[b_trim..b_index]);
            if (digits_order != .eq) return digits_order;
        } else {
            const char_order = std.math.order(a[a_index], b[b_index]);
            if (char_order != .eq) return char_order;
            a_index += 1;
            b_index += 1;
        }
    }

    const remaining_order = std.math.order(a.len - a_index, b.len - b_index);
    if (remaining_order != .eq) return remaining_order;
    return std.mem.order(u8, a, b);
}

fn ndkVersionPath(allocator: std.mem.Allocator, sdk_root: []const u8, version: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ sdk_root, "ndk", version });
}

/// Returns an owned NDK path. Direct NDK variables take precedence; otherwise
/// the numerically newest version under `<SDK>/ndk` is selected.
pub fn findNdk(allocator: std.mem.Allocator, b: *std.Build) ![]u8 {
    const env = &b.graph.environ_map;
    for ([_][]const u8{ "ANDROID_NDK_HOME", "NDK_ROOT", "NDK_PATH" }) |name| {
        if (env.get(name)) |path| return allocator.dupe(u8, path);
    }

    const sdk_root = env.get("ANDROID_HOME") orelse env.get("ANDROID_SDK_ROOT") orelse
        return error.NdkNotFound;
    const ndk_root = try std.fs.path.join(allocator, &.{ sdk_root, "ndk" });
    defer allocator.free(ndk_root);

    const io = b.graph.io;
    const ndk_dir = std.Io.Dir.openDirAbsolute(io, ndk_root, .{ .iterate = true }) catch
        return error.NdkNotFound;
    defer ndk_dir.close(io);

    var best: ?[]u8 = null;
    defer if (best) |name| allocator.free(name);

    var iterator = ndk_dir.iterateAssumeFirstIteration();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (best == null or compareNdkVersion(entry.name, best.?) == .gt) {
            const replacement = try allocator.dupe(u8, entry.name);
            if (best) |old| allocator.free(old);
            best = replacement;
        }
    }

    return ndkVersionPath(allocator, sdk_root, best orelse return error.NdkNotFound);
}

pub fn configureAndroidTarget(
    b: *std.Build,
    compile_step: *std.Build.Step.Compile,
    arch: Arch,
    api_level: u32,
) void {
    compile_step.root_module.resolved_target = b.resolveTargetQuery(targetQuery(arch, api_level));
}

pub fn addAndroidExe(
    b: *std.Build,
    name: []const u8,
    src_path: std.Build.LazyPath,
    arch: Arch,
    api_level: u32,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = src_path,
            .target = b.resolveTargetQuery(targetQuery(arch, api_level)),
        }),
    });
    configureAndroidTarget(b, exe, arch, api_level);
    return exe;
}

pub fn addAndroidStep(b: *std.Build, name: []const u8) *std.Build.Step {
    return b.step(name, "Build for Android");
}

test "NDK versions use deterministic numeric ordering" {
    try std.testing.expectEqual(.gt, compareNdkVersion("30.0.15729638", "9.0.0"));
    try std.testing.expectEqual(.gt, compareNdkVersion("26.1.10", "26.1.9"));
    try std.testing.expectEqual(.eq, compareNdkVersion("26.1.0", "26.1.0"));
    try std.testing.expectEqual(.lt, compareNdkVersion("26.1.0-beta1", "26.1.0-beta2"));
    try std.testing.expect(compareNdkVersion("026.1.0", "26.1.0") != .eq);
}

test "NDK version path includes the ndk directory" {
    const path = try ndkVersionPath(std.testing.allocator, "/opt/android-sdk", "30.0.15729638");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/opt/android-sdk/ndk/30.0.15729638", path);
}

test "Android architectures map to Zig target queries" {
    const cases = [_]struct { arch: Arch, cpu: std.Target.Cpu.Arch, abi: std.Target.Abi }{
        .{ .arch = .aarch64, .cpu = .aarch64, .abi = .android },
        .{ .arch = .arm, .cpu = .arm, .abi = .androideabi },
        .{ .arch = .x86, .cpu = .x86, .abi = .android },
        .{ .arch = .x86_64, .cpu = .x86_64, .abi = .android },
    };
    for (cases) |case| {
        const query = targetQuery(case.arch, 24);
        try std.testing.expectEqual(case.cpu, query.cpu_arch.?);
        try std.testing.expectEqual(case.abi, query.abi.?);
        try std.testing.expectEqual(std.Target.Os.Tag.linux, query.os_tag.?);
        try std.testing.expectEqual(@as(?u32, 24), query.android_api_level);
    }
}
