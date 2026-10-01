// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What the library must do with input nobody wrote.
//!
//! Everything here is a property rather than an example:
//!
//! - **documents**: whatever bytes arrive, the scanner terminates and either
//!   rejects them or produces events; whatever it accepts and loads as a
//!   `Value`, `Stringify` writes out in a form that reads back as an equal
//!   `Value`, in block style and in flow style.
//! - **values**: whatever tree of values is built — strings full of
//!   indicators, line breaks, quotes and control characters, keys that are
//!   collections — `Stringify` writes something that reads back as the same
//!   tree. This is the emitter's half of the round trip, reached directly
//!   rather than only through what the parser happens to produce.
//! - **typed**: whatever arrives, parsing into a struct either fails or gives
//!   a value that writes out and reads back unchanged.
//!
//! Each target is an ordinary test as well as a fuzz target: without
//! `--fuzz` it runs its seeds, so `zig build test` checks the same properties
//! on input that has already been interesting once. `tools/fuzz.zig` drives
//! them with made-up input, since Zig 0.16.0's own fuzzer has no coverage
//! feedback; `flake.nix` says why.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Smith = std.testing.Smith;

const yaml = @import("yaml");

/// The allocator the targets run against: the testing allocator under
/// `zig build test`, and a checked allocator `tools/fuzz.zig` supplies,
/// since that cannot name the testing allocator outside a test build.
pub var backing: Allocator = if (builtin.is_test) testing.allocator else undefined;

/// Nesting is kept shallow: the property is the same at any depth, and a
/// fuzzer that builds deep inputs spends its time recursing.
const max_depth = 64;

const load_options: yaml.ParseOptions = .{
    .duplicate_field_behavior = .use_last,
    .max_depth = max_depth,
    .max_alias_expansion = 1 << 14,
};

/// Writes `values` as a stream and reads them back, failing unless they
/// arrive unchanged.
fn roundTrip(arena: Allocator, values: []const yaml.Value, options: yaml.Stringify.Options) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: yaml.Stringify = .init(&out.writer, options);
    for (values) |v| try w.write(v);
    if (values.len > 0) try w.endDocument();
    const again = yaml.parseAllFromSliceLeaky(yaml.Value, arena, out.written(), load_options) catch |err| {
        std.debug.print("output does not parse ({t}):\n{s}\n", .{ err, out.written() });
        return error.OutputDoesNotParse;
    };
    if (again.len != values.len) return error.RoundTripChangedDocuments;
    for (values, again) |a, b| if (!a.eql(b)) {
        std.debug.print("round trip changed the data:\n{s}\n", .{out.written()});
        return error.RoundTripChangedData;
    };
}

// -- documents ---------------------------------------------------------------

pub const document_seeds = [_][]const u8{
    "a: b\n",
    "- a\n- b: c\n  d: e\n",
    "{a: [b, c], ? d : e}\n",
    "key: |\n  literal\n  text\n",
    "key: >-\n  folded\n\n  text\n",
    "--- &a !!str x\n--- *a\n...\n",
    "%TAG !e! tag:example.com,2000:\n--- !e!foo bar\n",
    "\"double \\u00e9\\n\" : 'single ''q'''\n",
    "? - complex\n: value\n",
    "a:\n- b\n-\n  - c\n",
    "[a, [b, [c, [d]]]]",
    "plain\n  continued\n\n  paragraph\n",
    "- ? a\n  : b\n",
    "&x [*x]",
    "- !!int 12\n- !!float 1\n- !!bool true\n- !foo bar\n",
    "\xef\xbb\xbfbom: yes\n",
    "",
    "#",
    ":",
    "-",
    "?",
    "'",
    "\t",
};

fn documentProperty(input: []const u8) !void {
    var scanner: yaml.Scanner = .initCompleteInput(backing, input);
    defer scanner.deinit();
    scanner.max_depth = max_depth;
    scanner.max_alias_expansion = load_options.max_alias_expansion;
    while (true) {
        const ev = scanner.next() catch return;
        if (ev == .stream_end) break;
    }

    var arena_state: std.heap.ArenaAllocator = .init(backing);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Loading can refuse what the grammar accepts — `!!int x`, an alias
    // expanding past the limit — and that is not a finding.
    const values = yaml.parseAllFromSliceLeaky(yaml.Value, arena, input, load_options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    try roundTrip(arena, values, .{});
    try roundTrip(arena, values, .{ .style = .flow });
    try roundTrip(arena, values, .{ .indent = 1, .multiline_strings = .double_quoted });
}

fn fuzzDocument(_: void, smith: *Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len = smith.slice(&buffer);
    try documentProperty(buffer[0..len]);
}

test "fuzz documents" {
    for (document_seeds) |seed| try documentProperty(seed);
    try testing.fuzz({}, fuzzDocument, .{});
}

// -- values ------------------------------------------------------------------

/// Builds a tree of values from bytes, one byte per decision.
///
/// Not `Smith.value`, which reads eight bytes per answer and answers the
/// minimum for anything out of range — a byte stream from the driver would
/// then build nothing but nulls.
const Builder = struct {
    bytes: []const u8,
    arena: Allocator,

    fn byte(b: *Builder) u8 {
        if (b.bytes.len == 0) return 0;
        defer b.bytes = b.bytes[1..];
        return b.bytes[0];
    }

    /// Pieces strings are made of: every indicator, every kind of line
    /// break and space, quotes, escapes, the spellings the core schema
    /// resolves, and some text that is merely text.
    const pieces = [_][]const u8{
        "a",      "word",   " ",        "  ",       "\t",       "\n",        "\n\n",     "\r",    "\r\n",
        ":",      ": ",     "#",        " #",       "-",        "- ",        "?",        "? ",    ",",
        "[",      "]",      "{",        "}",        "&",        "*",         "!",        "|",     ">",
        "'",      "\"",     "%",        "@",        "`",        "\\",        "~",        "null",  "true",
        "False",  "0",      "12",       "0x1F",     "0o7",      "1.5",       ".inf",     "-.NaN", "1e3",
        "---",    "...",    "\x00",     "\x07",     "\x1b",     "\x7f",
        "é",
        "日本",
        "\u{85}", "\u{a0}", "\u{2028}", "\u{2029}", "\u{feff}", "\u{1F600}", "\u{fffe}", "<<",    "=",
    };

    fn string(b: *Builder) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const n = b.byte() % 8;
        for (0..n) |_| try out.appendSlice(b.arena, pieces[b.byte() % pieces.len]);
        return out.items;
    }

    fn value(b: *Builder, depth: usize) !yaml.Value {
        const kind = b.byte() % @as(u8, if (depth >= 6) 7 else 9);
        return switch (kind) {
            0 => .null,
            1 => .{ .bool = b.byte() & 1 == 1 },
            2 => .{ .integer = @as(i64, @as(i8, @bitCast(b.byte()))) * (@as(i64, 1) << @intCast(b.byte() % 56)) },
            3 => .{
                .float = switch (b.byte() % 6) {
                    0 => std.math.inf(f64),
                    1 => -std.math.inf(f64),
                    2 => std.math.nan(f64),
                    3 => -0.0,
                    4 => @as(f64, @floatFromInt(b.byte())) / 7.0,
                    // Anywhere in the exponent range, where decimal and
                    // scientific notation part ways.
                    else => @as(f64, @floatFromInt(@as(i8, @bitCast(b.byte())))) *
                        std.math.pow(f64, 10, @as(f64, @floatFromInt(@as(i16, b.byte()) * 2 - 255)) * 1.2),
                },
            },
            4 => .{ .number_string = "123456789012345678901234567890" },
            5, 6 => .{ .string = try b.string() },
            7 => {
                var seq: yaml.Sequence = .empty;
                for (0..b.byte() % 4) |_| try seq.append(b.arena, try b.value(depth + 1));
                return .{ .sequence = seq };
            },
            else => {
                var map: yaml.Mapping = .empty;
                for (0..b.byte() % 4) |_| {
                    const key = try b.value(depth + 1);
                    try map.put(b.arena, key, try b.value(depth + 1));
                }
                return .{ .mapping = map };
            },
        };
    }
};

pub const value_seeds = [_][]const u8{
    "",
    "\x05\x03\x01\x02\x03",
    "\x08\x03\x05\x02\x10\x11\x07\x02\x05\x01\x14\x05\x04\x05\x06\x07",
    "\x07\x03\x08\x02\x00\x01\x05\x06\x0c\x0d\x0e\x0f\x10\x11",
    "\x05\x07\x05\x06\x07\x08\x09\x1f\x33",
};

fn valueProperty(input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(backing);
    defer arena_state.deinit();
    var builder: Builder = .{ .bytes = input, .arena = arena_state.allocator() };
    var values: [2]yaml.Value = undefined;
    for (&values) |*v| v.* = try builder.value(0);
    try roundTrip(builder.arena, &values, .{});
    try roundTrip(builder.arena, &values, .{ .style = .flow });
    try roundTrip(builder.arena, &values, .{ .indent = 4, .escape_unicode = true });
}

fn fuzzValue(_: void, smith: *Smith) !void {
    var buffer: [1024]u8 = undefined;
    const len = smith.slice(&buffer);
    try valueProperty(buffer[0..len]);
}

test "fuzz values" {
    for (value_seeds) |seed| try valueProperty(seed);
    try testing.fuzz({}, fuzzValue, .{});
}

// -- typed -------------------------------------------------------------------

const Config = struct {
    name: []const u8 = "",
    port: ?u16 = null,
    ratio: f64 = 0,
    enabled: bool = false,
    mode: enum { fast, slow } = .fast,
    tags: []const []const u8 = &.{},
    limits: struct { cpu: i32 = 0, memory: u64 = 0 } = .{},
    shape: ?union(enum) { circle: f32, square: [2]u8, none } = null,
};

pub const typed_seeds = [_][]const u8{
    "name: x\nport: 80\n",
    "{name: \"a: b\", ratio: .5, enabled: True, mode: slow}\n",
    "tags: [a, 'b', \"c\\n\"]\nlimits: {cpu: -1, memory: 0x10}\n",
    "shape: {circle: 1.5}\n",
    "shape: none\n",
    "shape:\n  square: [1, 2]\n",
    "port: ~\n",
};

fn typedProperty(input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(backing);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options: yaml.ParseOptions = .{ .ignore_unknown_fields = true, .max_depth = max_depth, .max_alias_expansion = 1 << 14 };
    const first = yaml.parseFromSliceLeaky(Config, arena, input, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    const text = try yaml.Stringify.valueAlloc(arena, first, .{});
    const second = yaml.parseFromSliceLeaky(Config, arena, text, options) catch |err| {
        std.debug.print("output does not parse ({t}):\n{s}\n", .{ err, text });
        return error.OutputDoesNotParse;
    };
    const again = try yaml.Stringify.valueAlloc(arena, second, .{});
    if (!std.mem.eql(u8, text, again)) {
        std.debug.print("round trip changed the data:\n{s}\n---\n{s}\n", .{ text, again });
        return error.RoundTripChangedData;
    }
}

fn fuzzTyped(_: void, smith: *Smith) !void {
    var buffer: [2048]u8 = undefined;
    const len = smith.slice(&buffer);
    try typedProperty(buffer[0..len]);
}

test "fuzz typed parsing" {
    for (typed_seeds) |seed| try typedProperty(seed);
    try testing.fuzz({}, fuzzTyped, .{});
}

// -- for a driver that is not the test runner --------------------------------

/// One fuzz target, addressable by name.
pub const Target = struct {
    name: []const u8,
    run: *const fn (input: []const u8) anyerror!void,
    /// Inputs worth mutating, which stand in for coverage feedback.
    corpus: []const []const u8,
    /// The buffer this target reads its input into. `Smith.slice` yields an
    /// empty slice for a longer length rather than a truncated one, so the
    /// driver must not exceed it.
    content_max: usize,
    /// Whether YAML documents from elsewhere — the test suite — make useful
    /// seeds for it.
    takes_documents: bool,
};

fn Driven(comptime one: fn (void, *Smith) anyerror!void) type {
    return struct {
        fn run(input: []const u8) anyerror!void {
            var smith: Smith = .{ .in = input };
            return one({}, &smith);
        }
    };
}

pub const all = [_]Target{
    .{ .name = "documents", .run = Driven(fuzzDocument).run, .corpus = &document_seeds, .content_max = 4096, .takes_documents = true },
    .{ .name = "values", .run = Driven(fuzzValue).run, .corpus = &value_seeds, .content_max = 1024, .takes_documents = false },
    .{ .name = "typed", .run = Driven(fuzzTyped).run, .corpus = &typed_seeds, .content_max = 2048, .takes_documents = true },
};
