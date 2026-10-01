// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A YAML document as a tree of values, when there is no Zig type to parse it
//! into — the counterpart of `std.json.Value`.
//!
//! A mapping's keys may be any value, not only strings, since YAML allows
//! `[1, 2]: pair` and `? {a: b}`; keys are compared by value, so the mapping
//! still rejects (or folds, per `duplicate_field_behavior`) two keys that are
//! equal. Insertion order is kept. For the common case of a string key,
//! `Value.get` looks one up without building a `Value` to do it.
//!
//! Aliases are expanded: a `Value` is a tree, and an alias becomes a copy of
//! the node it names.

const std = @import("std");
const Allocator = std.mem.Allocator;

const schema = @import("schema.zig");
const static = @import("static.zig");
const event = @import("event.zig");
const Stringify = @import("Stringify.zig");
const ParseOptions = static.ParseOptions;
const ParseError = static.ParseError;

pub const Sequence = std.ArrayList(Value);
pub const Mapping = std.ArrayHashMapUnmanaged(Value, Value, Value.HashContext, true);

pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    /// An integer too large for `i64`, as it was written.
    number_string: []const u8,
    string: []const u8,
    sequence: Sequence,
    mapping: Mapping,

    /// Hashes and compares values by content, for `Mapping`.
    pub const HashContext = struct {
        pub fn hash(_: HashContext, v: Value) u32 {
            return @truncate(v.hash64());
        }
        pub fn eql(_: HashContext, a: Value, b: Value, _: usize) bool {
            return a.eql(b);
        }
    };

    /// Looks up a string key without making a `Value` of it.
    const StringAdapter = struct {
        pub fn hash(_: StringAdapter, key: []const u8) u32 {
            var h: std.hash.Wyhash = .init(0);
            hashString(&h, key);
            return @truncate(h.final());
        }
        pub fn eql(_: StringAdapter, key: []const u8, v: Value, _: usize) bool {
            return v == .string and std.mem.eql(u8, key, v.string);
        }
    };

    fn hashString(h: *std.hash.Wyhash, s: []const u8) void {
        h.update(&.{@intFromEnum(std.meta.Tag(Value).string)});
        h.update(s);
    }

    pub fn hash64(v: Value) u64 {
        var h: std.hash.Wyhash = .init(0);
        v.hashInto(&h);
        return h.final();
    }

    fn hashInto(v: Value, h: *std.hash.Wyhash) void {
        switch (v) {
            .string => |s| return hashString(h, s),
            else => h.update(&.{@intFromEnum(std.meta.activeTag(v))}),
        }
        switch (v) {
            .null, .string => {},
            .bool => |b| h.update(&.{@intFromBool(b)}),
            .integer => |i| h.update(std.mem.asBytes(&i)),
            .float => |f| {
                // Equal floats must hash alike: every NaN, and both zeros.
                const canonical: f64 = if (std.math.isNan(f)) std.math.nan(f64) else if (f == 0) 0 else f;
                h.update(std.mem.asBytes(&canonical));
            },
            .number_string => |s| h.update(s),
            .sequence => |seq| for (seq.items) |item| item.hashInto(h),
            .mapping => |m| {
                // Mappings are unordered, so the entries are combined in a
                // way that does not depend on their order.
                var sum: u64 = 0;
                var it = m.iterator();
                while (it.next()) |e| sum +%= e.key_ptr.hash64() *% 31 +% e.value_ptr.hash64();
                h.update(std.mem.asBytes(&sum));
            },
        }
    }

    /// Deep equality. Mappings are equal when they hold equal keys with
    /// equal values in any order; NaN equals NaN, so that a value always
    /// equals itself and can always be found as a key.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .bool => |x| x == b.bool,
            .integer => |x| x == b.integer,
            .float => |x| x == b.float or (std.math.isNan(x) and std.math.isNan(b.float)),
            .number_string => |x| std.mem.eql(u8, x, b.number_string),
            .string => |x| std.mem.eql(u8, x, b.string),
            .sequence => |x| {
                if (x.items.len != b.sequence.items.len) return false;
                for (x.items, b.sequence.items) |p, q| if (!p.eql(q)) return false;
                return true;
            },
            .mapping => |x| {
                if (x.count() != b.mapping.count()) return false;
                var it = x.iterator();
                while (it.next()) |e| {
                    const other = b.mapping.get(e.key_ptr.*) orelse return false;
                    if (!e.value_ptr.eql(other)) return false;
                }
                return true;
            },
        };
    }

    /// The value of the string key `key` of a mapping, or null if the value
    /// is not a mapping or has no such key.
    pub fn get(v: Value, key: []const u8) ?Value {
        if (v != .mapping) return null;
        return v.mapping.getAdapted(key, StringAdapter{});
    }

    pub fn yamlParse(allocator: Allocator, source: anytype, options: ParseOptions) ParseError(@TypeOf(source.*))!Value {
        return switch (try source.next()) {
            .scalar => |s| scalarValue(allocator, source, s, options),
            .sequence_start => |c| {
                try checkCollectionTag(c.tag, &.{ "seq", "omap", "pairs" }, options);
                var seq: Sequence = .empty;
                while (try source.peekNextEventType() != .sequence_end) {
                    try seq.append(allocator, try yamlParse(allocator, source, options));
                }
                _ = try source.next();
                return .{ .sequence = seq };
            },
            .mapping_start => |c| {
                try checkCollectionTag(c.tag, &.{ "map", "set" }, options);
                var map: Mapping = .empty;
                while (try source.peekNextEventType() != .mapping_end) {
                    const key = try yamlParse(allocator, source, options);
                    const value = try yamlParse(allocator, source, options);
                    const gop = try map.getOrPut(allocator, key);
                    if (gop.found_existing) switch (options.duplicate_field_behavior) {
                        .use_first => continue,
                        .@"error" => return error.DuplicateField,
                        .use_last => {},
                    };
                    gop.value_ptr.* = value;
                }
                _ = try source.next();
                return .{ .mapping = map };
            },
            else => error.UnexpectedToken,
        };
    }

    pub fn yamlParseFromValue(allocator: Allocator, source: Value, options: ParseOptions) !Value {
        _ = allocator;
        _ = options;
        return source;
    }

    pub fn yamlStringify(v: Value, yw: *Stringify) Stringify.Error!void {
        switch (v) {
            .null => try yw.write(null),
            .bool => |b| try yw.write(b),
            .integer => |i| try yw.write(i),
            .float => |f| try yw.write(f),
            .number_string => |s| try yw.print("{s}", .{s}),
            .string => |s| try yw.write(s),
            .sequence => |seq| {
                try yw.beginSequence();
                for (seq.items) |item| try item.yamlStringify(yw);
                try yw.endSequence();
            },
            .mapping => |m| {
                try yw.beginMapping();
                var it = m.iterator();
                while (it.next()) |e| {
                    try e.key_ptr.yamlStringify(yw);
                    try e.value_ptr.yamlStringify(yw);
                }
                try yw.endMapping();
            },
        }
    }

    /// Writes the value to stderr as YAML, for debugging.
    pub fn dump(v: Value) void {
        var buffer: [4096]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();
        Stringify.value(v, .{}, &stderr.file_writer.interface) catch return;
        stderr.file_writer.interface.flush() catch {};
    }
};

fn checkCollectionTag(tag: ?[]const u8, comptime known: []const []const u8, options: ParseOptions) error{UnknownTag}!void {
    const t = tag orelse return;
    if (options.unknown_tag_behavior == .ignore or std.mem.eql(u8, t, "!")) return;
    inline for (known) |name| if (std.mem.eql(u8, t, schema.tag_prefix ++ name)) return;
    return error.UnknownTag;
}

fn scalarValue(allocator: Allocator, source: anytype, s: event.Scalar, options: ParseOptions) ParseError(@TypeOf(source.*))!Value {
    const kind: schema.Kind = if (s.tag) |tag| k: {
        if (std.mem.eql(u8, tag, "!")) break :k .str;
        if (schema.tagKind(tag)) |k| break :k k;
        if (options.unknown_tag_behavior == .@"error") return error.UnknownTag;
        break :k .str;
    } else if (s.style != .plain)
        .str
    else
        schema.resolvePlain(options.schema, s.value) orelse return error.InvalidScalar;

    // An explicit tag holds the text to the core schema's spellings whatever
    // schema resolves untagged scalars: `!!bool True` is a boolean even
    // under the JSON schema.
    const spelling: schema.Schema = if (s.tag != null or options.schema == .failsafe) .core else options.schema;
    return switch (kind) {
        .null => if (s.tag == null or schema.isCoreNull(s.value)) .null else error.InvalidScalar,
        .bool => .{ .bool = schema.parseBool(spelling, s.value) orelse return error.InvalidScalar },
        .int => if (schema.parseInt(i64, spelling, s.value)) |i|
            .{ .integer = i }
        else |err| switch (err) {
            error.Overflow => .{ .number_string = try allocator.dupe(u8, s.value) },
            error.InvalidNumber => error.InvalidScalar,
        },
        .float => .{ .float = schema.parseFloat(f64, spelling, s.value) catch return error.InvalidScalar },
        .str => .{ .string = if (options.allocate == .alloc_if_needed and
            @hasDecl(@TypeOf(source.*), "isInInput") and source.isInInput(s.value))
            s.value
        else
            try allocator.dupe(u8, s.value) },
    };
}

test "a mapping with a non-string key" {
    const gpa = std.testing.allocator;
    const parsed = try static.parseFromSlice(Value, gpa, "[1, 2]: pair\nname: x\n", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(2, parsed.value.mapping.count());
    try std.testing.expectEqualStrings("x", parsed.value.get("name").?.string);
    try std.testing.expectEqualStrings("pair", parsed.value.mapping.values()[0].string);
}

test "scalar resolution" {
    const gpa = std.testing.allocator;
    const parsed = try static.parseFromSlice(Value, gpa,
        \\- ~
        \\- True
        \\- 0x1F
        \\- 1.5
        \\- "12"
        \\- !!int "12"
        \\- 123456789012345678901234567890
        \\- .inf
    , .{});
    defer parsed.deinit();
    const items = parsed.value.sequence.items;
    try std.testing.expect(items[0] == .null);
    try std.testing.expect(items[1].bool);
    try std.testing.expectEqual(31, items[2].integer);
    try std.testing.expectEqual(1.5, items[3].float);
    try std.testing.expectEqualStrings("12", items[4].string);
    try std.testing.expectEqual(12, items[5].integer);
    try std.testing.expectEqualStrings("123456789012345678901234567890", items[6].number_string);
    try std.testing.expect(std.math.isInf(items[7].float));
}

test "duplicate keys" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.DuplicateField, static.parseFromSlice(Value, gpa, "a: 1\na: 2\n", .{}));
    const parsed = try static.parseFromSlice(Value, gpa, "a: 1\na: 2\n", .{ .duplicate_field_behavior = .use_last });
    defer parsed.deinit();
    try std.testing.expectEqual(2, parsed.value.get("a").?.integer);
}
