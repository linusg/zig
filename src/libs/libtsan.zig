const std = @import("std");
const assert = std.debug.assert;

const Compilation = @import("../Compilation.zig");
const build_options = @import("build_options");
const trace = @import("../tracy.zig").trace;
const Module = @import("../Package/Module.zig");

pub const BuildError = error{
    OutOfMemory,
    SubCompilationFailed,
    ZigCompilerNotBuiltWithLLVMExtensions,
    TSANUnsupportedCPUArchitecture,
};

pub fn buildTsan(comp: *Compilation, prog_node: std.Progress.Node) BuildError!void {
    if (!build_options.have_llvm) {
        return error.ZigCompilerNotBuiltWithLLVMExtensions;
    }

    const tracy = trace(@src());
    defer tracy.end();

    var arena_allocator = std.heap.ArenaAllocator.init(comp.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const target = comp.getTarget();
    const root_name = switch (target.os.tag) {
        // On Apple platforms, we use the same name as LLVM because the
        // TSAN library implementation hard-codes a check for these names.
        .driverkit, .macos => "clang_rt.tsan_osx_dynamic",
        .ios => if (target.abi == .simulator) "clang_rt.tsan_iossim_dynamic" else "clang_rt.tsan_ios_dynamic",
        .tvos => if (target.abi == .simulator) "clang_rt.tsan_tvossim_dynamic" else "clang_rt.tsan_tvos_dynamic",
        .visionos => if (target.abi == .simulator) "clang_rt.tsan_xrossim_dynamic" else "clang_rt.tsan_xros_dynamic",
        .watchos => if (target.abi == .simulator) "clang_rt.tsan_watchossim_dynamic" else "clang_rt.tsan_watchos_dynamic",
        else => "tsan",
    };
    const link_mode: std.builtin.LinkMode = if (target.os.tag.isDarwin()) .dynamic else .static;
    const output_mode = .Lib;
    const basename = try std.zig.binNameAlloc(arena, .{
        .root_name = root_name,
        .target = target,
        .output_mode = output_mode,
        .link_mode = link_mode,
    });

    const optimize_mode = comp.compilerRtOptMode();
    const strip = comp.compilerRtStrip();
    const unwind_tables: std.builtin.UnwindTables =
        if (target.cpu.arch == .x86 and target.os.tag == .windows) .none else .async;
    const link_libcpp = target.os.tag.isDarwin();

    const config = Compilation.Config.resolve(.{
        .output_mode = output_mode,
        .link_mode = link_mode,
        .resolved_target = comp.root_mod.resolved_target,
        .is_test = false,
        .have_zcu = false,
        .emit_bin = true,
        .root_optimize_mode = optimize_mode,
        .root_strip = strip,
        .link_libc = true,
        .link_libcpp = link_libcpp,
        .any_unwind_tables = unwind_tables != .none,
        // LLVM disables LTO for its libtsan.
        .lto = .none,
    }) catch |err| {
        comp.setMiscFailure(
            .libtsan,
            "unable to build thread sanitizer runtime: resolving configuration failed: {s}",
            .{@errorName(err)},
        );
        return error.SubCompilationFailed;
    };

    const common_flags = [_][]const u8{
        "-DTSAN_CONTAINS_UBSAN=0",
    };

    const root_mod = Module.create(arena, .{
        .paths = .{
            .root = .zig_lib_root,
            .root_src_path = "",
        },
        .fully_qualified_name = "root",
        .inherited = .{
            .resolved_target = comp.root_mod.resolved_target,
            .strip = strip,
            .stack_check = false,
            .stack_protector = 0,
            .sanitize_c = .off,
            .sanitize_thread = false,
            .red_zone = comp.root_mod.red_zone,
            .omit_frame_pointer = optimize_mode != .Debug and !target.os.tag.isDarwin(),
            .valgrind = false,
            .unwind_tables = unwind_tables,
            .optimize_mode = optimize_mode,
            .structured_cfg = comp.root_mod.structured_cfg,
            .pic = true,
            .no_builtin = true,
            .code_model = comp.root_mod.code_model,
        },
        .global = config,
        .cc_argv = &common_flags,
        .parent = null,
    }) catch |err| {
        comp.setMiscFailure(
            .libtsan,
            "unable to build thread sanitizer runtime: creating module failed: {s}",
            .{@errorName(err)},
        );
        return error.SubCompilationFailed;
    };

    var c_source_files = std.ArrayList(Compilation.CSourceFile).init(arena);
    try c_source_files.ensureUnusedCapacity(tsan_sources.len);

    const tsan_include_path = try comp.dirs.zig_lib.join(arena, &.{"libtsan"});
    for (tsan_sources) |tsan_src| {
        var cflags = std.ArrayList([]const u8).init(arena);

        try cflags.append("-I");
        try cflags.append(tsan_include_path);

        try addCcArgs(target, &cflags);

        c_source_files.appendAssumeCapacity(.{
            .src_path = try comp.dirs.zig_lib.join(arena, &.{ "libtsan", tsan_src }),
            .extra_flags = cflags.items,
            .owner = root_mod,
        });
    }

    const platform_tsan_sources = switch (target.os.tag) {
        .ios, .macos, .watchos, .tvos, .visionos => &darwin_tsan_sources,
        .windows => &windows_tsan_sources,
        else => &unix_tsan_sources,
    };
    try c_source_files.ensureUnusedCapacity(platform_tsan_sources.len);
    for (platform_tsan_sources) |tsan_src| {
        var cflags = std.ArrayList([]const u8).init(arena);

        try cflags.append("-I");
        try cflags.append(tsan_include_path);

        try addCcArgs(target, &cflags);

        c_source_files.appendAssumeCapacity(.{
            .src_path = try comp.dirs.zig_lib.join(arena, &.{ "libtsan", tsan_src }),
            .extra_flags = cflags.items,
            .owner = root_mod,
        });
    }
    {
        const asm_source = switch (target.cpu.arch) {
            .aarch64, .aarch64_be => "tsan_rtl_aarch64.S",
            .loongarch64 => "tsan_rtl_loongarch64.S",
            .mips64, .mips64el => "tsan_rtl_mips64.S",
            .powerpc64, .powerpc64le => "tsan_rtl_ppc64.S",
            .riscv64 => "tsan_rtl_riscv64.S",
            .s390x => "tsan_rtl_s390x.S",
            .x86_64 => "tsan_rtl_amd64.S",
            else => return error.TSANUnsupportedCPUArchitecture,
        };
        var cflags = std.ArrayList([]const u8).init(arena);

        try cflags.append("-I");
        try cflags.append(tsan_include_path);

        try cflags.append("-DNDEBUG");

        c_source_files.appendAssumeCapacity(.{
            .src_path = try comp.dirs.zig_lib.join(arena, &.{ "libtsan", asm_source }),
            .extra_flags = cflags.items,
            .owner = root_mod,
        });
    }

    try c_source_files.ensureUnusedCapacity(sanitizer_common_sources.len);
    const sanitizer_common_include_path = try comp.dirs.zig_lib.join(arena, &.{
        "libtsan", "sanitizer_common",
    });
    for (sanitizer_common_sources) |common_src| {
        var cflags = std.ArrayList([]const u8).init(arena);

        try cflags.append("-I");
        try cflags.append(sanitizer_common_include_path);
        try cflags.append("-I");
        try cflags.append(tsan_include_path);

        try addCcArgs(target, &cflags);

        c_source_files.appendAssumeCapacity(.{
            .src_path = try comp.dirs.zig_lib.join(arena, &.{
                "libtsan", "sanitizer_common", common_src,
            }),
            .extra_flags = cflags.items,
            .owner = root_mod,
        });
    }

    const to_c_or_not_to_c_sources = if (comp.config.link_libc)
        &sanitizer_libcdep_sources
    else
        &sanitizer_nolibc_sources;
    try c_source_files.ensureUnusedCapacity(to_c_or_not_to_c_sources.len);
    for (to_c_or_not_to_c_sources) |c_src| {
        var cflags = std.ArrayList([]const u8).init(arena);

        try cflags.append("-I");
        try cflags.append(sanitizer_common_include_path);
        try cflags.append("-I");
        try cflags.append(tsan_include_path);

        try addCcArgs(target, &cflags);

        c_source_files.appendAssumeCapacity(.{
            .src_path = try comp.dirs.zig_lib.join(arena, &.{
                "libtsan", "sanitizer_common", c_src,
            }),
            .extra_flags = cflags.items,
            .owner = root_mod,
        });
    }

    try c_source_files.ensureUnusedCapacity(sanitizer_symbolizer_sources.len);
    for (sanitizer_symbolizer_sources) |c_src| {
        var cflags = std.ArrayList([]const u8).init(arena);

        try cflags.append("-I");
        try cflags.append(tsan_include_path);

        try addCcArgs(target, &cflags);

        c_source_files.appendAssumeCapacity(.{
            .src_path = try comp.dirs.zig_lib.join(arena, &.{
                "libtsan", "sanitizer_common", c_src,
            }),
            .extra_flags = cflags.items,
            .owner = root_mod,
        });
    }

    const interception_include_path = try comp.dirs.zig_lib.join(arena, &.{"interception"});

    try c_source_files.ensureUnusedCapacity(interception_sources.len);
    for (interception_sources) |c_src| {
        var cflags = std.ArrayList([]const u8).init(arena);

        try cflags.append("-I");
        try cflags.append(interception_include_path);

        try cflags.append("-I");
        try cflags.append(tsan_include_path);

        try addCcArgs(target, &cflags);

        c_source_files.appendAssumeCapacity(.{
            .src_path = try comp.dirs.zig_lib.join(arena, &.{
                "libtsan", "interception", c_src,
            }),
            .extra_flags = cflags.items,
            .owner = root_mod,
        });
    }

    const skip_linker_dependencies = !target.os.tag.isDarwin();
    const linker_allow_shlib_undefined = target.os.tag.isDarwin();
    const install_name = if (target.os.tag.isDarwin())
        try std.fmt.allocPrintSentinel(arena, "@rpath/{s}", .{basename}, 0)
    else
        null;
    // Workaround for https://github.com/llvm/llvm-project/issues/97627
    const headerpad_size: ?u32 = if (target.os.tag.isDarwin()) 32 else null;
    const sub_compilation = Compilation.create(comp.gpa, arena, .{
        .dirs = comp.dirs.withoutLocalCache(),
        .thread_pool = comp.thread_pool,
        .self_exe_path = comp.self_exe_path,
        .cache_mode = .whole,
        .config = config,
        .root_mod = root_mod,
        .root_name = root_name,
        .libc_installation = comp.libc_installation,
        .emit_bin = .yes_cache,
        .c_source_files = c_source_files.items,
        .verbose_cc = comp.verbose_cc,
        .verbose_link = comp.verbose_link,
        .verbose_air = comp.verbose_air,
        .verbose_llvm_ir = comp.verbose_llvm_ir,
        .verbose_llvm_bc = comp.verbose_llvm_bc,
        .verbose_cimport = comp.verbose_cimport,
        .verbose_llvm_cpu_features = comp.verbose_llvm_cpu_features,
        .clang_passthrough_mode = comp.clang_passthrough_mode,
        .skip_linker_dependencies = skip_linker_dependencies,
        .linker_allow_shlib_undefined = linker_allow_shlib_undefined,
        .install_name = install_name,
        .headerpad_size = headerpad_size,
    }) catch |err| {
        comp.setMiscFailure(
            .libtsan,
            "unable to build thread sanitizer runtime: create compilation failed: {s}",
            .{@errorName(err)},
        );
        return error.SubCompilationFailed;
    };
    defer sub_compilation.destroy();

    comp.updateSubCompilation(sub_compilation, .libtsan, prog_node) catch |err| switch (err) {
        error.SubCompilationFailed => return error.SubCompilationFailed,
        else => |e| {
            comp.setMiscFailure(
                .libtsan,
                "unable to build thread sanitizer runtime: compilation failed: {s}",
                .{@errorName(e)},
            );
            return error.SubCompilationFailed;
        },
    };

    const crt_file = try sub_compilation.toCrtFile();
    comp.queuePrelinkTaskMode(crt_file.full_object_path, &config);
    assert(comp.tsan_lib == null);
    comp.tsan_lib = crt_file;
}

fn addCcArgs(target: *const std.Target, args: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    try args.appendSlice(&[_][]const u8{
        "-nostdinc++",
        "-fvisibility=hidden",
        "-fvisibility-inlines-hidden",
        "-std=c++17",
        "-fno-rtti",
        "-fno-exceptions",
        "-w", // Disable all warnings.
    });

    if (target.abi.isAndroid() and target.os.version_range.linux.android >= 29) {
        try args.append("-fno-emulated-tls");
    }

    if (target.isMinGW()) {
        try args.append("-fms-extensions");
    }
}

const tsan_sources = [_][]const u8{
    "tsan_debugging.cpp",
    "tsan_external.cpp",
    "tsan_fd.cpp",
    "tsan_flags.cpp",
    "tsan_ignoreset.cpp",
    "tsan_interceptors_memintrinsics.cpp",
    "tsan_interceptors_posix.cpp",
    "tsan_interface.cpp",
    "tsan_interface_ann.cpp",
    "tsan_interface_atomic.cpp",
    "tsan_interface_java.cpp",
    "tsan_malloc_mac.cpp",
    "tsan_md5.cpp",
    "tsan_mman.cpp",
    "tsan_mutexset.cpp",
    "tsan_new_delete.cpp",
    "tsan_platform_windows.cpp",
    "tsan_preinit.cpp",
    "tsan_report.cpp",
    "tsan_rtl.cpp",
    "tsan_rtl_access.cpp",
    "tsan_rtl_mutex.cpp",
    "tsan_rtl_proc.cpp",
    "tsan_rtl_report.cpp",
    "tsan_rtl_thread.cpp",
    "tsan_stack_trace.cpp",
    "tsan_suppressions.cpp",
    "tsan_symbolize.cpp",
    "tsan_sync.cpp",
    "tsan_vector_clock.cpp",
};

const darwin_tsan_sources = [_][]const u8{
    "tsan_interceptors_mac.cpp",
    "tsan_interceptors_mach_vm.cpp",
    "tsan_platform_mac.cpp",
    "tsan_platform_posix.cpp",
};

const unix_tsan_sources = [_][]const u8{
    "tsan_platform_linux.cpp",
    "tsan_platform_posix.cpp",
};

const windows_tsan_sources = [_][]const u8{
    "tsan_platform_windows.cpp",
};

const sanitizer_common_sources = [_][]const u8{
    "sanitizer_allocator.cpp",
    "sanitizer_chained_origin_depot.cpp",
    "sanitizer_common.cpp",
    "sanitizer_deadlock_detector1.cpp",
    "sanitizer_deadlock_detector2.cpp",
    "sanitizer_errno.cpp",
    "sanitizer_file.cpp",
    "sanitizer_flag_parser.cpp",
    "sanitizer_flags.cpp",
    "sanitizer_fuchsia.cpp",
    "sanitizer_libc.cpp",
    "sanitizer_libignore.cpp",
    "sanitizer_linux.cpp",
    "sanitizer_linux_s390.cpp",
    "sanitizer_mac.cpp",
    "sanitizer_mutex.cpp",
    "sanitizer_netbsd.cpp",
    "sanitizer_platform_limits_freebsd.cpp",
    "sanitizer_platform_limits_linux.cpp",
    "sanitizer_platform_limits_netbsd.cpp",
    "sanitizer_platform_limits_posix.cpp",
    "sanitizer_platform_limits_solaris.cpp",
    "sanitizer_posix.cpp",
    "sanitizer_printf.cpp",
    "sanitizer_procmaps_bsd.cpp",
    "sanitizer_procmaps_common.cpp",
    "sanitizer_procmaps_fuchsia.cpp",
    "sanitizer_procmaps_linux.cpp",
    "sanitizer_procmaps_mac.cpp",
    "sanitizer_procmaps_solaris.cpp",
    "sanitizer_range.cpp",
    "sanitizer_solaris.cpp",
    "sanitizer_stoptheworld_fuchsia.cpp",
    "sanitizer_stoptheworld_mac.cpp",
    "sanitizer_stoptheworld_win.cpp",
    "sanitizer_suppressions.cpp",
    "sanitizer_termination.cpp",
    "sanitizer_thread_arg_retval.cpp",
    "sanitizer_thread_registry.cpp",
    "sanitizer_tls_get_addr.cpp",
    "sanitizer_type_traits.cpp",
    "sanitizer_win.cpp",
    "sanitizer_win_interception.cpp",
};

const sanitizer_nolibc_sources = [_][]const u8{
    "sanitizer_common_nolibc.cpp",
};

const sanitizer_libcdep_sources = [_][]const u8{
    "sanitizer_common_libcdep.cpp",
    "sanitizer_allocator_checks.cpp",
    "sanitizer_dl.cpp",
    "sanitizer_linux_libcdep.cpp",
    "sanitizer_mac_libcdep.cpp",
    "sanitizer_posix_libcdep.cpp",
    "sanitizer_stoptheworld_linux_libcdep.cpp",
    "sanitizer_stoptheworld_netbsd_libcdep.cpp",
};

const sanitizer_symbolizer_sources = [_][]const u8{
    "sanitizer_allocator_report.cpp",
    "sanitizer_stack_store.cpp",
    "sanitizer_stackdepot.cpp",
    "sanitizer_stacktrace.cpp",
    "sanitizer_stacktrace_libcdep.cpp",
    "sanitizer_stacktrace_printer.cpp",
    "sanitizer_stacktrace_sparc.cpp",
    "sanitizer_symbolizer.cpp",
    "sanitizer_symbolizer_libbacktrace.cpp",
    "sanitizer_symbolizer_libcdep.cpp",
    "sanitizer_symbolizer_mac.cpp",
    "sanitizer_symbolizer_markup.cpp",
    "sanitizer_symbolizer_markup_fuchsia.cpp",
    "sanitizer_symbolizer_posix_libcdep.cpp",
    "sanitizer_symbolizer_report.cpp",
    "sanitizer_symbolizer_report_fuchsia.cpp",
    "sanitizer_symbolizer_win.cpp",
    "sanitizer_thread_history.cpp",
    "sanitizer_unwind_linux_libcdep.cpp",
    "sanitizer_unwind_fuchsia.cpp",
    "sanitizer_unwind_win.cpp",
};

const interception_sources = [_][]const u8{
    "interception_linux.cpp",
    "interception_mac.cpp",
    "interception_win.cpp",
    "interception_type_test.cpp",
};
