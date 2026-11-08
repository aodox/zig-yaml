// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("yaml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run the unit tests and the yaml-test-suite");
    const check_step = b.step("check", "Compile everything without running it");

    // LLVM rather than the self-hosted backend, which emits no coverage
    // instrumentation and no debug info kcov can use: without it
    // `zig build fuzz --fuzz` fuzzes blind and a coverage report is empty.
    const unit_tests = b.addTest(.{ .root_module = mod, .use_llvm = true });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    check_step.dependOn(&unit_tests.step);

    // -- conformance ---------------------------------------------------------
    //
    // Zig 0.17 fetches a lazy dependency as soon as `lazyDependency` runs,
    // including when a parent project builds this package. The suite is not
    // part of the library. Windows also cannot unpack its symlinks
    // (PRIVILEGE_NOT_HELD). Fetch only with `-Dyaml-suite`.
    const fetch_suite = b.option(
        bool,
        "yaml-suite",
        "Fetch yaml-test-suite for conformance and the fuzz corpus",
    ) orelse false;
    const suite_filter = b.option(
        []const u8,
        "suite-filter",
        "Run only the yaml-test-suite cases whose ID starts with this, and explain their failures",
    ) orelse "";
    // -- fuzzing --------------------------------------------------------------
    //
    // The fuzz targets are ordinary tests too, so `zig build test` checks the
    // same properties on the seeds beside them.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yaml", .module = mod }},
    });
    const fuzz_filter = b.option(
        []const u8,
        "fuzz-filter",
        "Fuzz or test only the targets whose name contains this",
    );
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
        .filters = if (fuzz_filter) |f| &.{f} else &.{},
        .use_llvm = true,
    });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // `zig build fuzz --fuzz` is Zig's own coverage-guided fuzzer;
    // `fuzz-run` is the loop in tools/fuzz.zig, seeded from the test suite.
    const fuzz_step = b.step("fuzz", "The fuzz targets: add --fuzz to fuzz them");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // Optimized, because a fuzzer's whole job is how many inputs it gets
    // through, and ReleaseSafe keeps every check that makes a failure a
    // failure.
    const fuzz_run = b.addExecutable(.{
        .name = "zig-yaml-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "fuzz_targets", .module = b.createModule(.{
                .root_source_file = b.path("tests/fuzz.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
                .imports = &.{.{ .name = "yaml", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = b.graph.host,
                    .optimize = .ReleaseSafe,
                }) }},
            }) }},
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_run);
    run_fuzz.stdio = .inherit;
    const fuzz_run_step = b.step("fuzz-run", "Fuzz the targets with a loop of our own");
    fuzz_run_step.dependOn(&run_fuzz.step);
    check_step.dependOn(&fuzz_run.step);

    if (fetch_suite) if (b.lazyDependency("yaml_test_suite", .{})) |suite| {
        // Every document in the suite seeds the fuzzer.
        run_fuzz.addArg("--corpus");
        run_fuzz.addDirectoryArg(suite.path("."));
    };
    run_fuzz.addPassthruArgs();

    if (fetch_suite) if (b.lazyDependency("yaml_test_suite", .{})) |suite| {
        const options = b.addOptions();
        options.addOptionPathDirectory("suite_dir", suite.path("."));
        options.addOption([]const u8, "suite_filter", suite_filter);
        const suite_mod = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaml", .module = mod },
                .{ .name = "build_options", .module = options.createModule() },
            },
        });
        const suite_tests = b.addTest(.{ .root_module = suite_mod });
        const run_suite = b.addRunArtifact(suite_tests);
        // The data does not change, but the parser does: always rerun.
        run_suite.has_side_effects = true;
        test_step.dependOn(&run_suite.step);
        check_step.dependOn(&suite_tests.step);
    };

    // A small tool for looking at what the parser makes of a file, in the
    // test suite's event notation: `zig build events -- file.yaml`.
    const events_exe = b.addExecutable(.{
        .name = "yaml-events",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/events.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaml", .module = mod },
                .{ .name = "event_format", .module = b.createModule(.{
                    .root_source_file = b.path("tests/event_format.zig"),
                    .imports = &.{.{ .name = "yaml", .module = mod }},
                }) },
            },
        }),
    });
    const run_events = b.addRunArtifact(events_exe);
    run_events.stdio = .inherit;
    run_events.addPassthruArgs();
    const events_step = b.step("events", "Print the events a YAML file parses to");
    events_step.dependOn(&run_events.step);
    check_step.dependOn(&events_exe.step);

    // -- documentation -------------------------------------------------------
    //
    // Zig emits the API documentation as a side effect of compiling, so the
    // module is built as a library purely to get at it. What comes out is not
    // a page but a program: a WebAssembly viewer, its javascript, and a tar of
    // the sources it reads from.
    const library = b.addLibrary(.{ .name = "yaml", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // That viewer fetches `sources.tar` and `main.wasm` at runtime, which a
    // browser refuses to do from a `file://` page, so reading the docs
    // locally means serving them.
    const docs_port = b.option(u16, "docs-port", "Port for `zig build docs-serve` (default 8000)") orelse 8000;

    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always the machine running the build, never whatever -Dtarget
            // the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.addDirectoryArg(library.getEmittedDocs());
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // It runs until interrupted, so its output has to reach the terminal
    // rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    // It has a test of its own; without this it would never run. And nothing
    // else builds it, so it belongs in `check` too.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = docs_server.root_module }),
    ).step);
    check_step.dependOn(&docs_server.step);
}
