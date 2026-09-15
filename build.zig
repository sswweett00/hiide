const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Engine module (importable by host processes) ──────────────────────────
    const hiide_mod = b.createModule(.{
        .root_source_file = b.path("src/hiide.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Static library with C ABI exports for Tauri / FFI consumers ──────────
    const engine_lib = b.addLibrary(.{
        .name = "hiide_engine",
        .root_module = hiide_mod,
    });
    b.installArtifact(engine_lib);

    // ── Developer harness executable ─────────────────────────────────────────
    const dev_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "hiide", .module = hiide_mod },
        },
    });
    const dev_exe = b.addExecutable(.{
        .name = "hiide-engine-dev",
        .root_module = dev_mod,
    });
    b.installArtifact(dev_exe);

    // ── Unit tests ────────────────────────────────────────────────────────────
    const unit_tests = b.addTest(.{
        .name = "unit-tests",
        .root_module = hiide_mod,
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run engine unit tests");
    test_step.dependOn(&run_tests.step);

    // ── Benchmark harness (opt-in: zig build bench) ───────────────────────────
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "hiide", .module = hiide_mod },
        },
    });
    const bench_exe = b.addExecutable(.{
        .name = "hiide-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run cross-platform benchmark suite");
    bench_step.dependOn(&run_bench.step);

    // ── Agent framework demo (zig build agent-demo) ────────────────────────────
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/agent_demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hiide", .module = hiide_mod },
        },
    });
    const demo_exe = b.addExecutable(.{
        .name = "agent-demo",
        .root_module = demo_mod,
    });
    const run_demo = b.addRunArtifact(demo_exe);
    const demo_step = b.step("agent-demo", "Run the agent framework end-to-end demo");
    demo_step.dependOn(&run_demo.step);

    // ── IPC Server executable ──────────────────────────────────────────────────
    const ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc_server_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "hiide", .module = hiide_mod },
        },
    });
    const ipc_exe = b.addExecutable(.{
        .name = "hiide-ipc-server",
        .root_module = ipc_mod,
    });
    b.installArtifact(ipc_exe);

    const run_ipc = b.addRunArtifact(ipc_exe);
    const ipc_step = b.step("ipc-server", "Run the IPC server for Flutter frontend");
    ipc_step.dependOn(&run_ipc.step);

    // ── Groq chat CLI (zig build groq-chat -- [model] "prompt") ────────────────
    const groq_chat_mod = b.createModule(.{
        .root_source_file = b.path("src/groq_chat_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "hiide", .module = hiide_mod },
        },
    });
    const groq_chat_exe = b.addExecutable(.{
        .name = "hiide-groq-chat",
        .root_module = groq_chat_mod,
    });
    b.installArtifact(groq_chat_exe);

    const run_groq = b.addRunArtifact(groq_chat_exe);
    const groq_step = b.step("groq-chat", "Call Groq chat API (reads groq-api-key)");
    groq_step.dependOn(&run_groq.step);

    // ── Groq coder agent demo (zig build groq-coder-demo -- "instruction") ───────
    const groq_coder_mod = b.createModule(.{
        .root_source_file = b.path("examples/groq_coder_demo.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "hiide", .module = hiide_mod },
        },
    });
    const groq_coder_exe = b.addExecutable(.{
        .name = "groq-coder-demo",
        .root_module = groq_coder_mod,
    });
    b.installArtifact(groq_coder_exe);

    const run_groq_coder = b.addRunArtifact(groq_coder_exe);
    const groq_coder_step = b.step("groq-coder-demo", "Run Groq-based coder agent demo");
    groq_coder_step.dependOn(&run_groq_coder.step);

    // ── Simple Groq coder (zig build simple-groq-coder -- "instruction") ───────
    const simple_groq_coder_mod = b.createModule(.{
        .root_source_file = b.path("examples/simple_groq_coder.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "hiide", .module = hiide_mod },
        },
    });
    const simple_groq_coder_exe = b.addExecutable(.{
        .name = "simple-groq-coder",
        .root_module = simple_groq_coder_mod,
    });
    b.installArtifact(simple_groq_coder_exe);

    const run_simple_groq_coder = b.addRunArtifact(simple_groq_coder_exe);
    const simple_groq_coder_step = b.step("simple-groq-coder", "Run simple Groq coder");
    simple_groq_coder_step.dependOn(&run_simple_groq_coder.step);
}
