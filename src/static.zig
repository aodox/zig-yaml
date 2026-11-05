// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Parsing YAML into Zig types, the way `std.json.parseFromSlice` parses
//! JSON into them.
//!
//! The target type decides how each node is read:
//!
//! | Type | Node |
//! | --- | --- |
//! | `bool` | a scalar spelled as a boolean (`true`, `False`, …) |
//! | integers | a scalar spelled as an integer (`12`, `0x1F`, `0o17`), or as a float with a whole value |
//! | floats | a scalar spelled as a number (`1.5`, `.inf`, `-.NaN`, `12`) |
//! | `?T` | a null scalar (`null`, `~`, nothing at all), or whatever `T` accepts |
//! | enums | a scalar naming a tag, or its integer value |
//! | tagged unions | a single-pair mapping from the tag to its payload; a bare scalar naming the tag for a `void` payload |
//! | structs | a mapping from field names to values; tuples, a sequence |
//! | `[N]T`, `@Vector` | a sequence of exactly N entries; `[N]u8` also a string of exactly N bytes |
//! | `[]T` | a sequence |
//! | `[]u8` and the like | any scalar, as its text: `version: 1.10` gives `"1.10"` |
//! | `*T` | whatever `T` accepts, allocated |
//! | `Value` | anything |
//!
//! Scalars are matched on their text, whatever their style, so `"8080"`
//! parses as a `u16` just as `8080` does — as `std.json` accepts a number in
//! a string.
//!
//! A type takes over its own parsing by declaring either or both of
//!
//!     pub fn yamlParse(allocator: Allocator, source: anytype, options: ParseOptions) !@This()
//!     pub fn yamlParseFromValue(allocator: Allocator, source: Value, options: ParseOptions) !@This()
//!
//! where `source` is a `*Scanner` or `*Reader` positioned at the node, which
//! the function must consume exactly. `innerParse` and `innerParseFromValue`
//! are how such a function parses the parts it does not handle itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const dynamic = @import("dynamic.zig");
const event = @import("event.zig");
const schema_mod = @import("schema.zig");
const Scanner = @import("Scanner.zig");
const Value = dynamic.Value;
const Schema = schema_mod.Schema;

pub const AllocWhen = enum { alloc_if_needed, alloc_always };

pub const ParseOptions = struct {
    /// What to do with a key that appears twice in a mapping: in a struct,
    /// the same field twice; in a `Value`, two equal keys. The spec requires
    /// keys to be unique, so it is an error by default.
    duplicate_field_behavior: enum { use_first, @"error", use_last } = .@"error",

    /// Skip mapping keys that name no field of the struct being parsed,
    /// rather than failing with `error.UnknownField`.
    ignore_unknown_fields: bool = false,

    /// Whether strings may point into the input rather than being copied.
    /// Null means `.alloc_if_needed` for a `Scanner`, whose input is the
    /// caller's, and `.alloc_always` for a `Reader`, whose buffer is its own.
    /// Mutable slices (`[]u8`) are always copied.
    allocate: ?AllocWhen = null,

    /// How untagged plain scalars are resolved into a `Value`, and which
    /// spellings of booleans and numbers typed parsing accepts.
    schema: Schema = .core,

    /// The deepest nesting of collections accepted, bounding the recursion
    /// both of the grammar and of the parse into types. Applied by the
    /// `…FromSlice` functions; a `Scanner` or `Reader` handed to a
    /// `…FromTokenSource` function keeps its own `max_depth`.
    max_depth: u32 = 512,

    /// The most events aliases may expand to across a stream. Applied as
    /// `max_depth` is.
    max_alias_expansion: usize = 1 << 20,

    /// What to do with a tag this library does not know. Ignoring it parses
    /// the node as though it were untagged, except that a scalar is then a
    /// string (the tag having said it is not to be resolved by its text).
    unknown_tag_behavior: enum { ignore, @"error" } = .ignore,
};

pub const ParseFromValueError = schema_mod.IntError || Allocator.Error || error{
    /// The node was not of a kind the target type accepts.
    UnexpectedToken,
    /// A number too large for the target type.
    Overflow,
    InvalidNumber,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
    /// A scalar whose text its tag, or the JSON schema, does not allow:
    /// `!!int twelve`.
    InvalidScalar,
    /// A tag this library does not know, with `unknown_tag_behavior = .error`.
    UnknownTag,
    /// A single value was asked for and the stream holds more than one
    /// document.
    MultipleDocuments,
};

/// The errors parsing from a `Source` — a `Scanner` or a `Reader` — can
/// return: those of `ParseFromValueError`, and those of reading the source.
pub fn ParseError(comptime Source: type) type {
    return ParseFromValueError || Source.NextError || Source.PeekError || Source.AllocError;
}

test ParseError {
    // Both what the scanner reports and what the target type rejects.
    const result: ParseError(Scanner)!Parsed(u8) = parseFromSlice(u8, std.testing.allocator, "[", .{});
    try std.testing.expectError(error.SyntaxError, result);
    try std.testing.expectError(error.Overflow, parseFromSlice(u8, std.testing.allocator, "256", .{}));
}

/// A value and the arena everything it points to was allocated in. `deinit`
/// frees the arena, and with it the value.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *ArenaAllocator,
        value: T,

        /// Frees the value and everything it points to.
        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

test Parsed {
    const parsed: Parsed([]const u8) = try parseFromSlice([]const u8, std.testing.allocator, "\"text\"", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("text", parsed.value);
}

fn configure(scanner: *Scanner, options: ParseOptions) void {
    scanner.max_depth = options.max_depth;
    scanner.max_alias_expansion = options.max_alias_expansion;
}

/// Parses a stream holding one document (or none, which reads as a null
/// node) into a `T`. A second document is `error.MultipleDocuments`;
/// `parseAllFromSlice` takes them all. Strings may point into `s`, as
/// `ParseOptions.allocate` describes, so `s` must outlive the result.
pub fn parseFromSlice(comptime T: type, gpa: Allocator, s: []const u8, options: ParseOptions) ParseError(Scanner)!Parsed(T) {
    var scanner: Scanner = .initCompleteInput(gpa, s);
    defer scanner.deinit();
    configure(&scanner, options);
    return parseFromTokenSource(T, gpa, &scanner, options);
}

test parseFromSlice {
    const Config = struct { name: []const u8, port: u16 = 8080 };
    const parsed = try parseFromSlice(Config, std.testing.allocator, "name: web\n", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("web", parsed.value.name);
    try std.testing.expectEqual(8080, parsed.value.port);
}

/// As `parseFromSlice`, allocating into `allocator` with no arena of its own;
/// meant for an arena the caller manages.
pub fn parseFromSliceLeaky(comptime T: type, allocator: Allocator, s: []const u8, options: ParseOptions) ParseError(Scanner)!T {
    var scanner: Scanner = .initCompleteInput(allocator, s);
    defer scanner.deinit();
    configure(&scanner, options);
    return parseFromTokenSourceLeaky(T, allocator, &scanner, options);
}

test parseFromSliceLeaky {
    var arena: ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseFromSliceLeaky([]const u32, arena.allocator(), "[1, 2, 3]", .{});
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, list);
}

/// Parses every document of a stream, each into a `T`. A stream with no
/// documents gives an empty slice.
pub fn parseAllFromSlice(comptime T: type, gpa: Allocator, s: []const u8, options: ParseOptions) ParseError(Scanner)!Parsed([]T) {
    var scanner: Scanner = .initCompleteInput(gpa, s);
    defer scanner.deinit();
    configure(&scanner, options);
    return parseAllFromTokenSource(T, gpa, &scanner, options);
}

test parseAllFromSlice {
    const parsed = try parseAllFromSlice(u8, std.testing.allocator, "1\n---\n2\n", .{});
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, parsed.value);
}

/// As `parseAllFromSlice`, allocating into `allocator` with no arena of its
/// own; meant for an arena the caller manages.
pub fn parseAllFromSliceLeaky(comptime T: type, allocator: Allocator, s: []const u8, options: ParseOptions) ParseError(Scanner)![]T {
    var scanner: Scanner = .initCompleteInput(allocator, s);
    defer scanner.deinit();
    configure(&scanner, options);
    return parseAllFromTokenSourceLeaky(T, allocator, &scanner, options);
}

test parseAllFromSliceLeaky {
    var arena: ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const docs = try parseAllFromSliceLeaky([]const u8, arena.allocator(), "--- a\n--- b\n", .{});
    try std.testing.expectEqual(2, docs.len);
    try std.testing.expectEqualStrings("b", docs[1]);
}

/// As `parseFromSlice`, from `source`: a `*Scanner` or a `*Reader` that has
/// not yet been read from. The source's own `max_depth` and
/// `max_alias_expansion` apply rather than those of `options`.
pub fn parseFromTokenSource(comptime T: type, gpa: Allocator, source: anytype, options: ParseOptions) ParseError(@TypeOf(source.*))!Parsed(T) {
    var parsed: Parsed(T) = .{ .arena = try gpa.create(ArenaAllocator), .value = undefined };
    errdefer gpa.destroy(parsed.arena);
    parsed.arena.* = .init(gpa);
    errdefer parsed.arena.deinit();
    parsed.value = try parseFromTokenSourceLeaky(T, parsed.arena.allocator(), source, options);
    return parsed;
}

test parseFromTokenSource {
    var source: std.Io.Reader = .fixed("[x, y]");
    var reader: @import("Reader.zig") = .init(std.testing.allocator, &source);
    defer reader.deinit();
    const parsed = try parseFromTokenSource([2][]const u8, std.testing.allocator, &reader, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("y", parsed.value[1]);
}

/// As `parseAllFromSlice`, from `source`: a `*Scanner` or a `*Reader` that
/// has not yet been read from.
pub fn parseAllFromTokenSource(comptime T: type, gpa: Allocator, source: anytype, options: ParseOptions) ParseError(@TypeOf(source.*))!Parsed([]T) {
    var parsed: Parsed([]T) = .{ .arena = try gpa.create(ArenaAllocator), .value = undefined };
    errdefer gpa.destroy(parsed.arena);
    parsed.arena.* = .init(gpa);
    errdefer parsed.arena.deinit();
    parsed.value = try parseAllFromTokenSourceLeaky(T, parsed.arena.allocator(), source, options);
    return parsed;
}

test parseAllFromTokenSource {
    var scanner: Scanner = .initCompleteInput(std.testing.allocator, "--- true\n--- false\n");
    defer scanner.deinit();
    const parsed = try parseAllFromTokenSource(bool, std.testing.allocator, &scanner, .{});
    defer parsed.deinit();
    try std.testing.expectEqualSlices(bool, &.{ true, false }, parsed.value);
}

fn withDefaults(comptime Source: type, options: ParseOptions) ParseOptions {
    var opts = options;
    if (opts.allocate == null) opts.allocate = if (Source == Scanner) .alloc_if_needed else .alloc_always;
    return opts;
}

/// As `parseFromTokenSource`, allocating into `allocator` with no arena of
/// its own; meant for an arena the caller manages.
pub fn parseFromTokenSourceLeaky(comptime T: type, allocator: Allocator, source: anytype, options: ParseOptions) ParseError(@TypeOf(source.*))!T {
    const opts = withDefaults(@TypeOf(source.*), options);
    try expect(source, .stream_start);
    if (try source.peekNextEventType() == .stream_end) {
        _ = try source.next();
        return parseFromValueLeaky(T, allocator, .null, opts);
    }
    const value = try parseDocument(T, allocator, source, opts);
    if (try source.peekNextEventType() == .document_start) return error.MultipleDocuments;
    try expect(source, .stream_end);
    return value;
}

test parseFromTokenSourceLeaky {
    var arena: ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var scanner: Scanner = .initCompleteInput(arena.allocator(), "1.5");
    const f = try parseFromTokenSourceLeaky(f32, arena.allocator(), &scanner, .{});
    try std.testing.expectEqual(1.5, f);
}

/// As `parseAllFromTokenSource`, allocating into `allocator` with no arena
/// of its own; meant for an arena the caller manages.
pub fn parseAllFromTokenSourceLeaky(comptime T: type, allocator: Allocator, source: anytype, options: ParseOptions) ParseError(@TypeOf(source.*))![]T {
    const opts = withDefaults(@TypeOf(source.*), options);
    try expect(source, .stream_start);
    var values: std.ArrayList(T) = .empty;
    while (try source.peekNextEventType() == .document_start) {
        try values.append(allocator, try parseDocument(T, allocator, source, opts));
    }
    try expect(source, .stream_end);
    return values.toOwnedSlice(allocator);
}

test parseAllFromTokenSourceLeaky {
    var arena: ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var scanner: Scanner = .initCompleteInput(arena.allocator(), "");
    const none = try parseAllFromTokenSourceLeaky(u8, arena.allocator(), &scanner, .{});
    try std.testing.expectEqual(0, none.len);
}

fn parseDocument(comptime T: type, allocator: Allocator, source: anytype, options: ParseOptions) ParseError(@TypeOf(source.*))!T {
    try expect(source, .document_start);
    const value = try innerParse(T, allocator, source, options);
    try expect(source, .document_end);
    return value;
}

fn expect(source: anytype, comptime kind: event.EventType) ParseError(@TypeOf(source.*))!void {
    const ev = try source.next();
    if (ev != kind) return error.UnexpectedToken;
}

fn nextScalar(source: anytype) ParseError(@TypeOf(source.*))!event.Scalar {
    return switch (try source.next()) {
        .scalar => |s| s,
        else => error.UnexpectedToken,
    };
}

/// The schema typed parsing reads numbers and booleans with: the one asked
/// for, except that the failsafe schema — which would recognize none — reads
/// them as the core schema does, the target type having said what to expect.
fn typedSchema(options: ParseOptions) Schema {
    return if (options.schema == .json) .json else .core;
}

const null_tag = schema_mod.tag_prefix ++ "null";

/// Whether a scalar is null: tagged `!!null`, or untagged, plain and
/// spelled as a null in the schema typed parsing uses.
pub fn isNullScalar(s: event.Scalar, options: ParseOptions) bool {
    if (s.tag) |tag| return std.mem.eql(u8, tag, null_tag);
    return s.style == .plain and schema_mod.isNull(typedSchema(options), s.value);
}

test isNullScalar {
    try std.testing.expect(isNullScalar(.{ .value = "~", .style = .plain }, .{}));
    try std.testing.expect(!isNullScalar(.{ .value = "~", .style = .single_quoted }, .{}));
    try std.testing.expect(!isNullScalar(.{ .value = "~", .style = .plain }, .{ .schema = .json }));
}

fn keepString(allocator: Allocator, source: anytype, s: []const u8, options: ParseOptions) Allocator.Error![]const u8 {
    if (options.allocate == .alloc_if_needed and @hasDecl(@TypeOf(source.*), "isInInput") and source.isInInput(s)) return s;
    return allocator.dupe(u8, s);
}

/// Parses the node the source is positioned at as a `T`, consuming exactly
/// that node. This is what a `yamlParse` function calls for the parts of
/// itself it leaves to the defaults. Its `options.allocate` must already be
/// set to keep strings in the input; null copies every one.
pub fn innerParse(comptime T: type, allocator: Allocator, source: anytype, options: ParseOptions) ParseError(@TypeOf(source.*))!T {
    switch (@typeInfo(T)) {
        .bool => {
            const s = try nextScalar(source);
            return schema_mod.parseBool(typedSchema(options), s.value) orelse error.UnexpectedToken;
        },
        .float, .comptime_float => {
            const s = try nextScalar(source);
            return schema_mod.parseFloat(T, typedSchema(options), s.value);
        },
        .int, .comptime_int => {
            const s = try nextScalar(source);
            return schema_mod.parseInt(T, typedSchema(options), s.value);
        },
        .optional => |info| {
            switch (try source.peek()) {
                .scalar => |s| if (isNullScalar(s, options)) {
                    _ = try source.next();
                    return null;
                },
                else => {},
            }
            return try innerParse(info.child, allocator, source, options);
        },
        .void => {
            try source.skipValue();
            return {};
        },
        .@"enum" => {
            if (comptime std.meta.hasFn(T, "yamlParse")) return T.yamlParse(allocator, source, options);
            const s = try nextScalar(source);
            return enumFromText(T, s.value, options);
        },
        .@"union" => |info| {
            if (comptime std.meta.hasFn(T, "yamlParse")) return T.yamlParse(allocator, source, options);
            if (info.tag_type == null) @compileError("Unable to parse into untagged union '" ++ @typeName(T) ++ "'");
            // A bare scalar naming a variant with no payload.
            if (try source.peekNextEventType() == .scalar) {
                const s = try nextScalar(source);
                inline for (info.field_names, info.field_types) |name, F| {
                    if (F == void and std.mem.eql(u8, name, s.value)) return @unionInit(T, name, {});
                }
                return error.UnknownField;
            }
            try expect(source, .mapping_start);
            const key = try nextScalar(source);
            inline for (info.field_names, info.field_types) |name, F| {
                if (std.mem.eql(u8, name, key.value)) {
                    const result = @unionInit(T, name, try innerParse(F, allocator, source, options));
                    try expect(source, .mapping_end);
                    return result;
                }
            }
            return error.UnknownField;
        },
        .@"struct" => |info| {
            if (comptime std.meta.hasFn(T, "yamlParse")) return T.yamlParse(allocator, source, options);
            if (info.is_tuple) {
                try expect(source, .sequence_start);
                var r: T = undefined;
                inline for (info.field_types, 0..) |F, i| {
                    if (try source.peekNextEventType() == .sequence_end) return error.LengthMismatch;
                    r[i] = try innerParse(F, allocator, source, options);
                }
                if (try source.peekNextEventType() != .sequence_end) return error.LengthMismatch;
                _ = try source.next();
                return r;
            }
            try expect(source, .mapping_start);
            var r: T = undefined;
            var seen: [info.field_names.len]bool = @splat(false);
            while (true) {
                if (try source.peekNextEventType() == .mapping_end) {
                    _ = try source.next();
                    break;
                }
                if (try source.peekNextEventType() != .scalar) {
                    // A key that is a collection can name no field.
                    if (!options.ignore_unknown_fields) return error.UnknownField;
                    try source.skipValue();
                    try source.skipValue();
                    continue;
                }
                const key = try nextScalar(source);
                const matched = inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
                    if (attrs.@"comptime") @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ name);
                    if (std.mem.eql(u8, name, key.value)) {
                        if (seen[i]) switch (options.duplicate_field_behavior) {
                            .use_first => {
                                try source.skipValue();
                                break true;
                            },
                            .@"error" => return error.DuplicateField,
                            .use_last => {},
                        };
                        @field(r, name) = try innerParse(F, allocator, source, options);
                        seen[i] = true;
                        break true;
                    }
                } else false;
                if (!matched) {
                    if (!options.ignore_unknown_fields) return error.UnknownField;
                    try source.skipValue();
                }
            }
            try fillDefaults(T, &r, &seen);
            return r;
        },
        .array => |info| {
            if (info.child == u8 and try source.peekNextEventType() == .scalar) {
                const s = try nextScalar(source);
                if (s.value.len != info.len) return error.LengthMismatch;
                var r: T = undefined;
                @memcpy(r[0..], s.value);
                return r;
            }
            try expect(source, .sequence_start);
            var r: T = undefined;
            for (&r) |*item| {
                if (try source.peekNextEventType() == .sequence_end) return error.LengthMismatch;
                item.* = try innerParse(info.child, allocator, source, options);
            }
            if (try source.peekNextEventType() != .sequence_end) return error.LengthMismatch;
            _ = try source.next();
            return r;
        },
        .vector => |info| {
            try expect(source, .sequence_start);
            var r: T = undefined;
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                if (try source.peekNextEventType() == .sequence_end) return error.LengthMismatch;
                r[i] = try innerParse(info.child, allocator, source, options);
            }
            if (try source.peekNextEventType() != .sequence_end) return error.LengthMismatch;
            _ = try source.next();
            return r;
        },
        .pointer => |info| switch (info.size) {
            .one => {
                const r = try allocator.create(info.child);
                r.* = try innerParse(info.child, allocator, source, options);
                return r;
            },
            .slice => {
                if (info.child == u8 and try source.peekNextEventType() == .scalar) {
                    const s = try nextScalar(source);
                    if (info.sentinel()) |sentinel| {
                        if (sentinel != 0) @compileError("only a zero sentinel is supported for strings: " ++ @typeName(T));
                        return allocator.dupeSentinel(u8, s.value, 0);
                    }
                    if (info.attrs.@"const") return keepString(allocator, source, s.value, options);
                    return allocator.dupe(u8, s.value);
                }
                try expect(source, .sequence_start);
                var list: std.ArrayList(info.child) = .empty;
                while (try source.peekNextEventType() != .sequence_end) {
                    try list.append(allocator, try innerParse(info.child, allocator, source, options));
                }
                _ = try source.next();
                if (info.sentinel()) |sentinel| return list.toOwnedSliceSentinel(allocator, sentinel);
                return list.toOwnedSlice(allocator);
            },
            else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
        },
        else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
    }
}

test innerParse {
    // A point written as `x,y`, parsed through a hook that leaves the
    // splitting of the text to itself and the numbers to `innerParse`.
    const Point = struct {
        x: i32,
        y: i32,

        pub fn yamlParse(allocator: Allocator, source: anytype, options: ParseOptions) !@This() {
            const text = try innerParse([]const u8, allocator, source, options);
            const comma = std.mem.findScalar(u8, text, ',') orelse return error.UnexpectedToken;
            const parse = std.fmt.parseInt;
            return .{
                .x = parse(i32, text[0..comma], 10) catch return error.InvalidNumber,
                .y = parse(i32, text[comma + 1 ..], 10) catch return error.InvalidNumber,
            };
        }
    };
    const parsed = try parseFromSlice([]const Point, std.testing.allocator, "[\"1,2\", \"3,4\"]", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(4, parsed.value[1].y);
}

test "strings with a sentinel" {
    var arena: ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const from_events = try parseFromSliceLeaky([:0]const u8, a, "text", .{});
    try std.testing.expectEqualStrings("text", from_events);
    const from_value = try parseFromValueLeaky([:0]const u8, a, .{ .string = "text" }, .{});
    try std.testing.expectEqualStrings("text", from_value);
    try std.testing.expectEqual(0, from_value[from_value.len]);
}

fn enumFromText(comptime T: type, text: []const u8, options: ParseOptions) error{InvalidEnumTag}!T {
    if (std.meta.stringToEnum(T, text)) |v| return v;
    const Int = @typeInfo(T).@"enum".tag_type;
    const n = schema_mod.parseInt(Int, typedSchema(options), text) catch return error.InvalidEnumTag;
    return std.enums.fromInt(T, n) orelse error.InvalidEnumTag;
}

fn fillDefaults(comptime T: type, r: *T, seen: []const bool) error{MissingField}!void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
        if (!seen[i]) {
            if (attrs.defaultValue(F)) |default| {
                @field(r, name) = default;
            } else return error.MissingField;
        }
    }
}

/// Parses a `Value` already in hand as a `T`, by the same rules as parsing
/// from events. Strings are copied, so the result does not depend on
/// `source` once this returns.
pub fn parseFromValue(comptime T: type, gpa: Allocator, source: Value, options: ParseOptions) ParseFromValueError!Parsed(T) {
    var parsed: Parsed(T) = .{ .arena = try gpa.create(ArenaAllocator), .value = undefined };
    errdefer gpa.destroy(parsed.arena);
    parsed.arena.* = .init(gpa);
    errdefer parsed.arena.deinit();
    parsed.value = try parseFromValueLeaky(T, parsed.arena.allocator(), source, options);
    return parsed;
}

test parseFromValue {
    const tree = try parseFromSlice(Value, std.testing.allocator, "kind: circle\nradius: 1.5\n", .{});
    defer tree.deinit();
    const Circle = struct { radius: f64 };
    // Look at the tree first, then parse the part of it that is understood.
    try std.testing.expectEqualStrings("circle", tree.value.get("kind").?.string);
    const circle = try parseFromValue(Circle, std.testing.allocator, tree.value, .{ .ignore_unknown_fields = true });
    defer circle.deinit();
    try std.testing.expectEqual(1.5, circle.value.radius);
}

/// As `parseFromValue`, allocating into `allocator` with no arena of its
/// own; meant for an arena the caller manages.
pub fn parseFromValueLeaky(comptime T: type, allocator: Allocator, source: Value, options: ParseOptions) ParseFromValueError!T {
    return innerParseFromValue(T, allocator, source, options);
}

test parseFromValueLeaky {
    var arena: ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseFromValueLeaky(u8, arena.allocator(), .{ .string = "0x1F" }, .{});
    try std.testing.expectEqual(31, n);
}

/// The counterpart of `innerParse` for a `Value`: what a
/// `yamlParseFromValue` function calls for the parts of itself it leaves to
/// the defaults.
pub fn innerParseFromValue(comptime T: type, allocator: Allocator, source: Value, options: ParseOptions) ParseFromValueError!T {
    switch (@typeInfo(T)) {
        .bool => return switch (source) {
            .bool => |b| b,
            .string => |s| schema_mod.parseBool(typedSchema(options), s) orelse error.UnexpectedToken,
            else => error.UnexpectedToken,
        },
        .float, .comptime_float => return switch (source) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            .number_string, .string => |s| try schema_mod.parseFloat(T, typedSchema(options), s),
            else => error.UnexpectedToken,
        },
        .int, .comptime_int => return switch (source) {
            .integer => |i| std.math.cast(T, i) orelse error.Overflow,
            .float => |f| try schema_mod.floatToInt(T, f),
            .number_string, .string => |s| try schema_mod.parseInt(T, typedSchema(options), s),
            else => error.UnexpectedToken,
        },
        .optional => |info| return switch (source) {
            .null => null,
            else => try innerParseFromValue(info.child, allocator, source, options),
        },
        .void => return {},
        .@"enum" => {
            if (comptime std.meta.hasFn(T, "yamlParseFromValue")) return T.yamlParseFromValue(allocator, source, options);
            return switch (source) {
                .string => |s| enumFromText(T, s, options),
                .integer => |i| std.enums.fromInt(T, i) orelse error.InvalidEnumTag,
                else => error.UnexpectedToken,
            };
        },
        .@"union" => |info| {
            if (comptime std.meta.hasFn(T, "yamlParseFromValue")) return T.yamlParseFromValue(allocator, source, options);
            if (info.tag_type == null) @compileError("Unable to parse into untagged union '" ++ @typeName(T) ++ "'");
            switch (source) {
                .string => |s| {
                    inline for (info.field_names, info.field_types) |name, F| {
                        if (F == void and std.mem.eql(u8, name, s)) return @unionInit(T, name, {});
                    }
                    return error.UnknownField;
                },
                .mapping => |m| {
                    if (m.count() != 1) return error.UnexpectedToken;
                    const key = m.keys()[0];
                    if (key != .string) return error.UnexpectedToken;
                    inline for (info.field_names, info.field_types) |name, F| {
                        if (std.mem.eql(u8, name, key.string))
                            return @unionInit(T, name, try innerParseFromValue(F, allocator, m.values()[0], options));
                    }
                    return error.UnknownField;
                },
                else => return error.UnexpectedToken,
            }
        },
        .@"struct" => |info| {
            if (comptime std.meta.hasFn(T, "yamlParseFromValue")) return T.yamlParseFromValue(allocator, source, options);
            if (info.is_tuple) {
                if (source != .sequence) return error.UnexpectedToken;
                const items = source.sequence.items;
                if (items.len != info.field_types.len) return error.LengthMismatch;
                var r: T = undefined;
                inline for (info.field_types, 0..) |F, i| {
                    r[i] = try innerParseFromValue(F, allocator, items[i], options);
                }
                return r;
            }
            if (source != .mapping) return error.UnexpectedToken;
            var r: T = undefined;
            var seen: [info.field_names.len]bool = @splat(false);
            var it = source.mapping.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const matched = key == .string and inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
                    if (attrs.@"comptime") @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ name);
                    if (std.mem.eql(u8, name, key.string)) {
                        @field(r, name) = try innerParseFromValue(F, allocator, entry.value_ptr.*, options);
                        seen[i] = true;
                        break true;
                    }
                } else false;
                if (!matched and !options.ignore_unknown_fields) return error.UnknownField;
            }
            try fillDefaults(T, &r, &seen);
            return r;
        },
        .array => |info| switch (source) {
            .string => |s| {
                if (info.child != u8) return error.UnexpectedToken;
                if (s.len != info.len) return error.LengthMismatch;
                var r: T = undefined;
                @memcpy(r[0..], s);
                return r;
            },
            .sequence => |seq| {
                if (seq.items.len != info.len) return error.LengthMismatch;
                var r: T = undefined;
                for (&r, seq.items) |*dst, item| dst.* = try innerParseFromValue(info.child, allocator, item, options);
                return r;
            },
            else => return error.UnexpectedToken,
        },
        .vector => |info| {
            if (source != .sequence) return error.UnexpectedToken;
            if (source.sequence.items.len != info.len) return error.LengthMismatch;
            var r: T = undefined;
            for (source.sequence.items, 0..) |item, i| r[i] = try innerParseFromValue(info.child, allocator, item, options);
            return r;
        },
        .pointer => |info| switch (info.size) {
            .one => {
                const r = try allocator.create(info.child);
                r.* = try innerParseFromValue(info.child, allocator, source, options);
                return r;
            },
            .slice => switch (source) {
                .string, .number_string => |s| {
                    if (info.child != u8) return error.UnexpectedToken;
                    if (info.sentinel()) |sentinel| {
                        if (sentinel != 0) @compileError("only a zero sentinel is supported for strings: " ++ @typeName(T));
                        return allocator.dupeSentinel(u8, s, 0);
                    }
                    return allocator.dupe(u8, s);
                },
                .sequence => |seq| {
                    const r = if (info.sentinel()) |sentinel|
                        try allocator.allocSentinel(info.child, seq.items.len, sentinel)
                    else
                        try allocator.alloc(info.child, seq.items.len);
                    for (r, seq.items) |*dst, item| dst.* = try innerParseFromValue(info.child, allocator, item, options);
                    return r;
                },
                else => return error.UnexpectedToken,
            },
            else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
        },
        else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
    }
}

test innerParseFromValue {
    // A temperature written either as a number or as `<n>C`.
    const Celsius = struct {
        degrees: f32,

        pub fn yamlParseFromValue(allocator: Allocator, source: Value, options: ParseOptions) !@This() {
            if (source == .string and std.mem.endsWith(u8, source.string, "C")) {
                const text = source.string[0 .. source.string.len - 1];
                return .{ .degrees = try innerParseFromValue(f32, allocator, .{ .string = text }, options) };
            }
            return .{ .degrees = try innerParseFromValue(f32, allocator, source, options) };
        }
    };
    var arena: ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(21.5, (try innerParseFromValue(Celsius, a, .{ .string = "21.5C" }, .{})).degrees);
    try std.testing.expectEqual(20, (try innerParseFromValue(Celsius, a, .{ .integer = 20 }, .{})).degrees);
}
