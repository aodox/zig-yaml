// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Prints the events a YAML file parses to, in the yaml-test-suite's
//! `test.event` notation, with aliases left unresolved:
//!
//!     zig build events -- file.yaml
//!
//! A syntax error is reported with the line and column the parser got
//! furthest to, which is usually where the problem is.

const std = @import("std");
const yaml = @import("yaml");
const event_format = @import("event_format");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("usage: yaml-events FILE\n", .{});
        std.process.exit(2);
    };
    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(input);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file.interface;

    var scanner: yaml.Scanner = .initCompleteInput(gpa, input);
    defer scanner.deinit();
    scanner.resolve_aliases = false;
    var diagnostics: yaml.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    while (true) {
        const ev = scanner.next() catch |err| {
            try out.flush();
            std.debug.print("{s}:{d}:{d}: {t}\n", .{ path, diagnostics.getLine(), diagnostics.getColumn(), err });
            std.process.exit(1);
        };
        try event_format.write(out, ev);
        if (ev == .stream_end) break;
    }
    try out.flush();
}
