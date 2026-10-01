// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Runs every case of the yaml-test-suite (https://github.com/yaml/yaml-test-suite),
//! the conformance data the YAML project maintains alongside the
//! specification.
//!
//! A case is a directory named by a four-character ID, or a numbered
//! subdirectory of one when a case comes in variants. Each holds `in.yaml`
//! and some of:
//!
//! - `error`: the input is invalid, and parsing it must fail;
//! - `test.event`: the event stream a valid input produces, which ours must
//!   match line for line;
//! - `in.json`: the same data as JSON, one value per document, which our
//!   `Value` of each document must equal.
//!
//! Every valid case is also written back out with `Stringify`, in block and
//! in flow style, and must parse again to an equal `Value`.
//!
//! `zig build test -Dsuite-filter=ID` runs just the cases whose path starts
//! with ID and prints what went wrong in detail.

const std = @import("std");
const yaml = @import("yaml");
const build_options = @import("build_options");
const event_format = @import("event_format.zig");

const Io = std.Io;

/// Cases known not to pass, and why. The goal is for this to be empty.
const skip = [_][]const u8{};

const Outcome = enum { pass, fail };

/// How many cases each check was applied to, so that the summary shows the
/// checks ran rather than only that nothing failed.
var json_checked: usize = 0;
var round_tripped: usize = 0;
var errors_checked: usize = 0;

const Stats = struct {
    passed: usize = 0,
    failed: std.ArrayList([]const u8) = .empty,
    unexpectedly_passed: std.ArrayList([]const u8) = .empty,
};

test "yaml-test-suite" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root = try Io.Dir.cwd().openDir(io, build_options.suite_dir, .{ .iterate = true });
    defer root.close(io);

    const cases = try listCases(arena, io, root);
    const filter = build_options.suite_filter;
    const verbose = filter.len > 0;

    var stats: Stats = .{};
    for (cases) |case| {
        if (!std.mem.startsWith(u8, case, filter)) continue;
        const outcome = try runCase(gpa, arena, io, root, case, verbose);
        const skipped = isSkipped(case);
        switch (outcome) {
            .pass => {
                stats.passed += 1;
                if (skipped) try stats.unexpectedly_passed.append(arena, case);
            },
            .fail => if (!skipped) try stats.failed.append(arena, case),
        }
    }

    std.debug.print("yaml-test-suite: {d} passed, {d} failed, {d} skipped " ++
        "({d} invalid inputs rejected, {d} compared with in.json, {d} round-tripped)\n", .{
        stats.passed, stats.failed.items.len, skip.len, errors_checked, json_checked, round_tripped,
    });
    if (stats.failed.items.len > 0) {
        std.debug.print("failed:", .{});
        for (stats.failed.items) |c| std.debug.print(" {s}", .{c});
        std.debug.print("\n", .{});
    }
    if (stats.unexpectedly_passed.items.len > 0) {
        std.debug.print("in the skip list but passing:", .{});
        for (stats.unexpectedly_passed.items) |c| std.debug.print(" {s}", .{c});
        std.debug.print("\n", .{});
    }
    if (stats.failed.items.len > 0 or stats.unexpectedly_passed.items.len > 0)
        return error.TestUnexpectedResult;
}

fn isSkipped(case: []const u8) bool {
    for (skip) |s| if (std.mem.eql(u8, s, case)) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every case path, sorted: `ABCD` or `ABCD/00`.
fn listCases(arena: std.mem.Allocator, io: Io, root: Io.Dir) ![]const []const u8 {
    var cases: std.ArrayList([]const u8) = .empty;
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        // Case IDs are four digits and capitals; `name` and `tags` are
        // indexes of symlinks to the same cases.
        if (entry.kind != .directory or !isCaseId(entry.name)) continue;
        const name = try arena.dupe(u8, entry.name);
        if (exists(io, root, try std.fmt.allocPrint(arena, "{s}/in.yaml", .{name}))) {
            try cases.append(arena, name);
            continue;
        }
        var sub = try root.openDir(io, name, .{ .iterate = true });
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (try sub_it.next(io)) |s| {
            if (s.kind != .directory) continue;
            try cases.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ name, s.name }));
        }
    }
    std.mem.sort([]const u8, cases.items, {}, lessThan);
    return cases.items;
}

fn isCaseId(name: []const u8) bool {
    if (name.len != 4) return false;
    for (name) |c| if (!std.ascii.isDigit(c) and !std.ascii.isUpper(c)) return false;
    return true;
}

fn exists(io: Io, dir: Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn readCaseFile(arena: std.mem.Allocator, io: Io, root: Io.Dir, case: []const u8, file: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ case, file });
    return root.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn runCase(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, root: Io.Dir, case: []const u8, verbose: bool) !Outcome {
    const input = (try readCaseFile(arena, io, root, case, "in.yaml")).?;
    const expect_error = exists(io, root, try std.fmt.allocPrint(arena, "{s}/error", .{case}));

    const events = event_format.render(gpa, input) catch |err| {
        if (expect_error) {
            errors_checked += 1;
            return .pass;
        }
        if (verbose) std.debug.print("{s}: unexpected {t}\n--- input ---\n{s}\n", .{ case, err, input });
        return .fail;
    };
    defer gpa.free(events);

    if (expect_error) {
        // The grammar accepted it; perhaps what makes it invalid is not
        // syntactic. Alias resolution is the other check a scanner makes.
        var scanner: yaml.Scanner = .initCompleteInput(gpa, input);
        defer scanner.deinit();
        while (true) {
            const ev = scanner.next() catch {
                errors_checked += 1;
                return .pass;
            };
            if (ev == .stream_end) break;
        }
        if (verbose) std.debug.print("{s}: parsed, but should have failed\n--- input ---\n{s}\n--- got ---\n{s}\n", .{ case, input, events });
        return .fail;
    }

    const expected = (try readCaseFile(arena, io, root, case, "test.event")).?;
    if (!std.mem.eql(u8, events, expected)) {
        if (verbose) std.debug.print("{s}: events differ\n--- input ---\n{s}\n--- expected ---\n{s}--- got ---\n{s}", .{ case, input, expected, events });
        return .fail;
    }

    // Duplicate keys are a matter for the loader, not the grammar, and a
    // few cases have them.
    const options: yaml.ParseOptions = .{ .duplicate_field_behavior = .use_last };
    const values = yaml.parseAllFromSliceLeaky(yaml.Value, arena, input, options) catch |err| {
        if (verbose) std.debug.print("{s}: loading as Value failed: {t}\n", .{ case, err });
        return .fail;
    };

    if (try readCaseFile(arena, io, root, case, "in.json")) |json| {
        const expected_values = try parseJsonDocuments(arena, json);
        var ok = expected_values.len == values.len;
        if (ok) for (values, expected_values) |ours, theirs| {
            if (!matchesJson(ours, theirs)) ok = false;
        };
        if (!ok) {
            if (verbose) std.debug.print("{s}: does not match in.json\n--- input ---\n{s}\n--- in.json ---\n{s}\n", .{ case, input, json });
            return .fail;
        }
        json_checked += 1;
    }

    for ([_]yaml.Stringify.Options{ .{}, .{ .style = .flow } }) |stringify_options| {
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: yaml.Stringify = .init(&out.writer, stringify_options);
        for (values) |v| try w.write(v);
        if (values.len > 0) try w.endDocument();
        const again = yaml.parseAllFromSliceLeaky(yaml.Value, arena, out.written(), options) catch |err| {
            if (verbose) std.debug.print("{s}: output does not parse: {t}\n--- input ---\n{s}\n--- output ---\n{s}\n", .{ case, err, input, out.written() });
            return .fail;
        };
        var ok = again.len == values.len;
        if (ok) for (values, again) |a, b| {
            if (!a.eql(b)) ok = false;
        };
        if (!ok) {
            if (verbose) std.debug.print("{s}: round trip changed the data\n--- input ---\n{s}\n--- output ---\n{s}\n", .{ case, input, out.written() });
            return .fail;
        }
    }
    round_tripped += 1;
    return .pass;
}

/// Splits concatenated JSON texts, as `in.json` holds one per document, and
/// parses each.
fn parseJsonDocuments(arena: std.mem.Allocator, text: []const u8) ![]const std.json.Value {
    var docs: std.ArrayList(std.json.Value) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) break;
        const start = i;
        var depth: usize = 0;
        var in_string = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (in_string) {
                if (c == '\\') {
                    i += 1;
                } else if (c == '"') {
                    in_string = false;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
                continue;
            }
            switch (c) {
                '"' => in_string = true,
                '[', '{' => depth += 1,
                ']', '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                },
                else => if (depth == 0 and std.ascii.isWhitespace(c)) break,
            }
        }
        try docs.append(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, text[start..i], .{}));
    }
    return docs.items;
}

fn matchesJson(ours: yaml.Value, theirs: std.json.Value) bool {
    return switch (ours) {
        .null => theirs == .null,
        .bool => |b| theirs == .bool and theirs.bool == b,
        .integer => |n| switch (theirs) {
            .integer => |m| n == m,
            .float => |f| @as(f64, @floatFromInt(n)) == f,
            else => false,
        },
        .float => |f| switch (theirs) {
            .float => |g| f == g,
            .integer => |m| f == @as(f64, @floatFromInt(m)),
            else => false,
        },
        .number_string => |s| theirs == .number_string and std.mem.eql(u8, s, theirs.number_string),
        .string => |s| theirs == .string and std.mem.eql(u8, s, theirs.string),
        .sequence => |seq| theirs == .array and theirs.array.items.len == seq.items.len and for (seq.items, theirs.array.items) |a, b| {
            if (!matchesJson(a, b)) break false;
        } else true,
        .mapping => |m| {
            if (theirs != .object or theirs.object.count() != m.count()) return false;
            var it = m.iterator();
            while (it.next()) |e| {
                // JSON keys are strings; a YAML scalar key compares by the
                // text JSON would have had to give it.
                var buf: [64]u8 = undefined;
                const key: []const u8 = switch (e.key_ptr.*) {
                    .string => |k| k,
                    .null => "",
                    .integer => |n| std.fmt.bufPrint(&buf, "{d}", .{n}) catch return false,
                    .bool => |b| if (b) "true" else "false",
                    else => return false,
                };
                const other = theirs.object.get(key) orelse return false;
                if (!matchesJson(e.value_ptr.*, other)) return false;
            }
            return true;
        },
    };
}
