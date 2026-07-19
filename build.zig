// build.zig — Pipeline for vizg static library, main exe, and run step (Zig 0.16).
const std = @import("std");
const android = @import("android.build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Keep the documented pre-0.16 spelling working while also accepting
    // Zig 0.16's native `--release=safe` form.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Compatibility optimization mode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)",
    ) orelse b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Portable Zig package. It has no ABI or native-adapter dependency.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .pic = true,
    });
    const vizg_cabi = b.addModule("vizg-abi", .{
        .root_source_file = b.path("Lib/vizg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .pic = true,
    });
    vizg_cabi.addImport("vizg-impl", lib_mod);
    const vizg_declarations = b.addModule("vizg-declarations", .{
        .root_source_file = b.path("Lib/vizg_declarations.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    vizg_declarations.addIncludePath(b.path("Lib"));
    const vizg_lib = b.addLibrary(.{
        .name = "vizg",
        .root_module = vizg_cabi,
    });
    // Unique dependency-facing alias. The upstream graph has several artifacts
    // named `vizg`, so consumers cannot select the native archive by name.
    const vizg_consumer_lib = b.addLibrary(.{
        .name = "vizg-vzed",
        .root_module = vizg_cabi,
    });
    b.installArtifact(vizg_consumer_lib);

    // A fixed Debug build keeps runtime safety checks enabled regardless of the
    // caller's selected optimization mode. It is the adversarial audit gate.
    const safety_impl = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    const safety_abi = b.createModule(.{
        .root_source_file = b.path("Lib/vizg.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    safety_abi.addImport("vizg-impl", safety_impl);
    const safety_tests = b.addRunArtifact(b.addTest(.{ .root_module = safety_impl }));
    const safety_step = b.step("audit-safety", "Run the portable suite with Zig runtime safety enabled");
    safety_step.dependOn(&safety_tests.step);

    // Compile the OS-independent frontend/types/semantics layers for a small
    // representative target matrix. Objects are compiled only: no foreign
    // executable is linked or run, and Android does not require an NDK here.
    const cross_check_step = b.step("cross-check", "Compile generic layers for representative targets");
    const cross_targets = [_]struct {
        name: []const u8,
        query: std.Target.Query,
    }{
        .{ .name = "x86_64-linux", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
        .{ .name = "aarch64-linux", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux } },
        .{ .name = "x86_64-windows", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
        .{ .name = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "x86_64-macos", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "wasm32-wasi", .query = .{ .cpu_arch = .wasm32, .os_tag = .wasi } },
        .{ .name = "aarch64-linux-android.24", .query = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .android,
            .android_api_level = 24,
        } },
    };
    for (cross_targets) |cross_target| {
        const probe = b.addObject(.{
            .name = b.fmt("vizg-cross-{s}", .{cross_target.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("cross_check.zig"),
                .target = b.resolveTargetQuery(cross_target.query),
                .optimize = .Debug,
            }),
        });
        cross_check_step.dependOn(&probe.step);
    }

    const portable_core_probe = b.addObject(.{
        .name = "vizg-portable-core-lint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("portable_core_check.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .Debug,
        }),
    });
    const portable_core_lint_step = b.step(
        "lint-portable-core",
        "Reject OS, native-adapter, and ABI dependencies in src/root.zig",
    );
    portable_core_lint_step.dependOn(&portable_core_probe.step);

    const module_host_boundary = b.addSystemCommand(&.{
        "sh",
        "tools/check_module_host_boundary.sh",
        ".",
    });
    const module_host_boundary_step = b.step(
        "lint-module-host-boundary",
        "Reject concrete module-resolution policy in the portable core and public ABI",
    );
    module_host_boundary_step.dependOn(&module_host_boundary.step);
    // Compile the same static-library graph installed for consumers, plus a C
    // translation unit that includes the public header, for every matrix target.
    // This is compile-only: no foreign archive is installed or executed.
    const abi_cross_check_step = b.step("abi-cross-check", "Compile C ABI archives for representative targets");
    for (cross_targets) |cross_target| {
        const cross_target_resolved = b.resolveTargetQuery(cross_target.query);
        const cross_impl = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target_resolved,
            .optimize = .Debug,
            .link_libc = false,
            .pic = true,
        });
        const cross_abi = b.createModule(.{
            .root_source_file = b.path("Lib/vizg.zig"),
            .target = cross_target_resolved,
            .optimize = .Debug,
            .link_libc = false,
            .pic = true,
        });
        cross_abi.addImport("vizg-impl", cross_impl);
        cross_abi.addIncludePath(b.path("Lib"));
        cross_abi.addCSourceFile(.{
            .file = b.path("test/c_abi/layout_probe.c"),
            .flags = &.{"-std=c11"},
        });
        const cross_archive = b.addLibrary(.{
            .name = b.fmt("vizg-abi-cross-{s}", .{cross_target.name}),
            .root_module = cross_abi,
        });
        abi_cross_check_step.dependOn(&cross_archive.step);
    }

    // Produce a consumer-ready Android AArch64/API 24 package. Zig supplies
    // the target headers for compilation; final application linkage remains
    // the responsibility of the Android/NDK build consuming this archive.
    const android_target = b.resolveTargetQuery(android.targetQuery(.aarch64, 24));
    const android_impl = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
        .link_libc = false,
        .pic = true,
    });
    const android_abi = b.createModule(.{
        .root_source_file = b.path("Lib/vizg.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
        .link_libc = false,
        .pic = true,
    });
    android_abi.addImport("vizg-impl", android_impl);
    const android_lib = b.addLibrary(.{
        .name = "vizg",
        .root_module = android_abi,
    });

    const android_consumer_source = b.addWriteFiles().add("android_minimal.c",
        \\#include "vizg.h"
        \\int main(void) { return VIZG_ABI_VERSION > 0 ? 0 : 1; }
    );
    const android_consumer_mod = b.createModule(.{
        .target = android_target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    android_consumer_mod.addIncludePath(b.path("Lib"));
    android_consumer_mod.addCSourceFile(.{
        .file = android_consumer_source,
        .flags = &.{"-std=c11"},
    });
    const android_consumer = b.addObject(.{
        .name = "vizg-android-aarch64-consumer",
        .root_module = android_consumer_mod,
    });

    const install_android_lib = b.addInstallArtifact(android_lib, .{
        .dest_dir = .{ .override = .{ .custom = "android-aarch64/lib" } },
    });
    const install_android_header = b.addInstallFile(
        b.path("Lib/vizg.h"),
        "android-aarch64/include/vizg.h",
    );
    const android_lib_step = b.step(
        "android-aarch64-lib",
        "Build Android AArch64/API 24 libvizg.a, header, and C compile probe",
    );
    android_lib_step.dependOn(&install_android_lib.step);
    android_lib_step.dependOn(&install_android_header.step);
    android_lib_step.dependOn(&android_consumer.step);

    // Link the official ABI v1 without WASI, libc, or an entry point. The host
    // grows exported linear memory and supplies workspace/input ranges.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_impl = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const wasm_abi = b.createModule(.{
        .root_source_file = b.path("Lib/vizg.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_abi.addImport("vizg-impl", wasm_impl);
    const wasm_module = b.addExecutable(.{
        .name = "vizg",
        .root_module = wasm_abi,
    });
    wasm_module.entry = .disabled;
    wasm_module.rdynamic = true;
    wasm_module.export_memory = true;

    const install_wasm = b.addInstallArtifact(wasm_module, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });
    const wasm_host_test = b.addSystemCommand(&.{
        "node",
        "test/wasm/official_abi_v1.mjs",
    });
    wasm_host_test.addArtifactArg(wasm_module);
    const wasm_freestanding_step = b.step(
        "wasm-freestanding",
        "Build and test the official ABI v1 for wasm32-freestanding",
    );
    wasm_freestanding_step.dependOn(&portable_core_probe.step);
    wasm_freestanding_step.dependOn(&install_wasm.step);
    wasm_freestanding_step.dependOn(&wasm_host_test.step);
    const wasm_step = b.step("wasm", "Alias for the wasm32-freestanding ABI build");
    wasm_step.dependOn(wasm_freestanding_step);

    // -------------------------------------------------------------------
    // 2. Install step — default prefix is zig-out/.
    //       zig build → installs everything into the prefix (default: zig-out)
    //       zig-out/lib/libvizg.a     ← library archive
    // -------------------------------------------------------------------
    const install_lib = b.addInstallArtifact(vizg_lib, .{});
    const install_headers = b.addInstallHeaderFile(b.path("Lib/vizg.h"), "vizg.h");

    const lib_step = b.step("lib", "Build & install: zig-out/lib/libvizg.a");
    lib_step.dependOn(&install_lib.step);

    // Make `zig build` (default step) also produce the static archive.
    b.getInstallStep().dependOn(&install_lib.step);
    b.getInstallStep().dependOn(&install_headers.step);

    // -------------------------------------------------------------------
    // 3. Run step — main executable (dev/testing only).
    // -------------------------------------------------------------------
    const run_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    run_mod.addImport("vizg-core", lib_mod);
    const run_fs_validation_host = b.createModule(.{
        .root_source_file = b.path("test/support/fs_validation_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    run_fs_validation_host.addImport("vizg-core", lib_mod);
    run_mod.addImport("fs-validation-host", run_fs_validation_host);

    const main_exe = b.addExecutable(.{
        .name = "vizg",
        .root_module = run_mod,
    });

    const install_exe = b.addInstallArtifact(main_exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(main_exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run the main executable (for testing only)");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // 4. Test step — register the public package's complete test tree.
    //    Unit tests are compiled with src/root.zig as root so all internal
    //    tests within `modules/`, `semantics/`, etc. get wired in.
    // -------------------------------------------------------------------
    // 4a. Portable structural checks implemented as Zig tests.
    const lint_silent = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build_checks.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    }));
    const lint_silent_step = b.step("lint-silent", "Assert public library is silent by default (Goal-041)");
    lint_silent_step.dependOn(&lint_silent.step);

    // 4b. Final test step: portable structural, unit, ABI, and helper tests.
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_test_mod.addImport("vizg-core", unit_test_mod);
    const test_fs_validation_host = b.createModule(.{
        .root_source_file = b.path("test/support/fs_validation_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_fs_validation_host.addImport("vizg-core", unit_test_mod);
    cli_test_mod.addImport("fs-validation-host", test_fs_validation_host);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = unit_test_mod }));
    const run_cli_tests = b.addRunArtifact(b.addTest(.{ .root_module = cli_test_mod }));
    const abi_lifecycle_mod = b.createModule(.{
        .root_source_file = b.path("test/abi_lifecycle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_lifecycle_mod.addIncludePath(b.path("Lib"));
    abi_lifecycle_mod.addCSourceFile(.{
        .file = b.path("test/c_abi/hostile_pointer_probe.c"),
        .flags = &.{"-std=c11"},
    });
    abi_lifecycle_mod.linkLibrary(vizg_lib);
    const abi_lifecycle_tests = b.addRunArtifact(b.addTest(.{
        .root_module = abi_lifecycle_mod,
    }));
    const abi_internal_tests = b.addRunArtifact(b.addTest(.{
        .root_module = vizg_cabi,
    }));
    const abi_layout_mod = b.createModule(.{
        .root_source_file = b.path("test/c_abi/layout_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_layout_mod.addImport("vizg-abi", vizg_cabi);
    abi_layout_mod.addIncludePath(b.path("Lib"));
    abi_layout_mod.addCSourceFile(.{
        .file = b.path("test/c_abi/layout_probe.c"),
        .flags = &.{"-std=c11"},
    });
    const abi_layout_tests = b.addRunArtifact(b.addTest(.{
        .root_module = abi_layout_mod,
    }));
    const abi_layout_step = b.step("abi-layout-test", "Compare Zig and C public ABI layouts");
    abi_layout_step.dependOn(&abi_layout_tests.step);
    const abi_symbols = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\archive="$1"
        \\actual="$(nm -g --defined-only "$archive" | awk '$2 ~ /^[TDBR]$/ && $3 ~ /^vizg_/ { print $3 }' | LC_ALL=C sort -u)"
        \\expected='vizg_abi_version
        \\vizg_external_module_api_version
        \\vizg_hir_api_version
        \\vizg_hir_binding_detail_at
        \\vizg_hir_block_detail_at
        \\vizg_hir_block_parameter_at
        \\vizg_hir_detail_api_version
        \\vizg_hir_function_capture_at
        \\vizg_hir_function_completion_type
        \\vizg_hir_function_detail_at
        \\vizg_hir_function_parameter_at
        \\vizg_hir_function_signature
        \\vizg_hir_function_storage_detail_at
        \\vizg_hir_module_dependency_at
        \\vizg_hir_module_detail_at
        \\vizg_hir_module_export_at
        \\vizg_hir_module_import_at
        \\vizg_hir_operation_at
        \\vizg_hir_operation_item_at
        \\vizg_hir_origin_detail_at
        \\vizg_hir_payload_api_version
        \\vizg_hir_record_at
        \\vizg_hir_region_count
        \\vizg_hir_region_detail_at
        \\vizg_hir_region_protected_block_at
        \\vizg_hir_signature_parameter_at
        \\vizg_hir_summary
        \\vizg_hir_terminator_at
        \\vizg_hir_terminator_item_at
        \\vizg_hir_type_detail_at
        \\vizg_project_add_global_root
        \\vizg_project_add_source
        \\vizg_project_analyze_source
        \\vizg_project_create
        \\vizg_project_destroy
        \\vizg_project_finish
        \\vizg_project_limit_kind
        \\vizg_project_register_ambient_globals
        \\vizg_project_register_ambient_globals_v2
        \\vizg_project_register_source_host_bindings
        \\vizg_project_respond_external
        \\vizg_project_respond_external_v2
        \\vizg_project_respond_failure
        \\vizg_project_respond_source
        \\vizg_project_result_destroy
        \\vizg_project_result_diagnostic
        \\vizg_project_result_edge
        \\vizg_project_result_export
        \\vizg_project_result_import
        \\vizg_project_result_module
        \\vizg_project_result_summary
        \\vizg_project_step
        \\vizg_project_workspace_alignment
        \\vizg_project_workspace_overhead'
        \\if [ "$actual" != "$expected" ]; then
        \\    echo "unexpected public ABI symbols:" >&2
        \\    printf '%s\n' "$actual" >&2
        \\    exit 1
        \\fi
        \\imports="$(nm -g --undefined-only "$archive" | awk 'NF && $NF !~ /:$/ { print $NF }' | LC_ALL=C sort -u)"
        \\expected_imports="$2"
        \\if [ "$imports" != "$expected_imports" ]; then
        \\    echo "unexpected native archive imports:" >&2
        \\    printf '%s\n' "$imports" >&2
        \\    exit 1
        \\fi
        ,
        "abi-symbols",
    });
    abi_symbols.addArtifactArg(vizg_lib);
    abi_symbols.addArg(switch (optimize) {
        .Debug =>
        \\_DYNAMIC
        \\__divti3
        \\__modti3
        \\__tls_get_addr
        \\getauxval
        \\memcpy
        \\memmove
        ,
        .ReleaseSafe =>
        \\_DYNAMIC
        \\__divti3
        \\__tls_get_addr
        \\__zig_probe_stack
        \\getauxval
        \\memcpy
        \\memmove
        \\memset
        ,
        .ReleaseFast, .ReleaseSmall =>
        \\memcpy
        \\memmove
        \\memset
        ,
    });
    const abi_symbols_step = b.step("abi-symbols-test", "Enforce the official ABI v1 symbol allowlist");
    abi_symbols_step.dependOn(&abi_symbols.step);

    // Regression gate: the installed archive must link into the default PIE
    // produced by the documented native C compiler command.
    const native_consumer_link = b.addSystemCommand(&.{ "cc", "-std=c11", "-I", "Lib" });
    if (target.result.os.tag == .linux) native_consumer_link.addArg("-Wl,-z,noexecstack");
    native_consumer_link.addFileArg(b.path("example/hir_consumer.c"));
    native_consumer_link.addArtifactArg(vizg_lib);
    native_consumer_link.addArg("-o");
    const native_consumer_exe = native_consumer_link.addOutputFileArg("official_abi_v1_consumer");
    const native_consumer_run = b.addSystemCommand(&.{ "sh", "-c", "exec \"$1\"", "native-consumer" });
    native_consumer_run.addFileArg(native_consumer_exe);
    const native_consumer_step = b.step("abi-native-consumer-test", "Link and run the official ABI v1 from C");
    native_consumer_step.dependOn(&native_consumer_run.step);
    if (target.result.os.tag == .linux) {
        const native_stack_check = b.addSystemCommand(&.{
            "sh",
            "-c",
            \\set -eu
            \\flags="$(readelf -W -l "$1" | awk '$1 == "GNU_STACK" { print $(NF - 1) }')"
            \\case "$flags" in
            \\    *E*|'') echo "native ABI consumer has an executable or missing GNU_STACK" >&2; exit 1 ;;
            \\esac
            ,
            "native-stack-check",
        });
        native_stack_check.addFileArg(native_consumer_exe);
        native_consumer_step.dependOn(&native_stack_check.step);
    }
    const android_helper_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("android.build.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    }));
    const test_step = b.step("test", "Compile & run all unit tests");
    test_step.dependOn(lint_silent_step);
    test_step.dependOn(portable_core_lint_step);
    test_step.dependOn(module_host_boundary_step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&abi_lifecycle_tests.step);
    test_step.dependOn(&abi_internal_tests.step);
    test_step.dependOn(abi_layout_step);
    test_step.dependOn(abi_symbols_step);
    test_step.dependOn(native_consumer_step);
    test_step.dependOn(&android_helper_tests.step);

    // 5. Portable validation: install public artifacts, run all tests, and
    //    exercise argument forwarding through the CLI without shell helpers.
    const validate_cli = b.addRunArtifact(main_exe);
    validate_cli.addArgs(&.{ "check", "test/frontend/vizg_capabilities_test.ts" });

    const validate_step = b.step("validate", "Install artifacts and run portable project checks");
    validate_step.dependOn(b.getInstallStep());
    validate_step.dependOn(test_step);
    validate_step.dependOn(&validate_cli.step);
}
