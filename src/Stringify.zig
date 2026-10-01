// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Writes YAML to a `std.Io.Writer`, the counterpart of `std.json.Stringify`.
//!
//! Most callers want `value`, `valueAlloc` or the `fmt` formatter in the
//! module root, which write a whole Zig value at once. For output that is
//! not a single Zig value, the write stream can be driven by hand:
//!
//!     <document> = beginDocument? <node> endDocument?
//!     <node>     = <sequence> | <mapping> | write | print
//!     <sequence> = beginSequence ( <node> )* endSequence
//!     <mapping>  = beginMapping ( <node> <node> )* endMapping
//!
//! A mapping's key is written like any other node, so it can be a number or
//! a collection as well as a string; `mappingKey` is shorthand for a string.
//!
//! Collections are written in block style — one entry to a line, nesting
//! shown by indentation — unless `Options.style` asks for flow style, and an
//! empty collection is always written `[]` or `{}`. A collection used as a
//! key is written in flow style after a `?` indicator.
//!
//! Every string is written in the plainest style that reads back as the
//! same string: plain if it cannot be mistaken for anything else — not
//! `true`, not `12`, not `- x`, not `a: b` — otherwise single-quoted, or
//! double-quoted when it needs an escape. A string of several lines becomes
//! a literal block scalar where that can represent it exactly.
//!
//! A type takes over its own output by declaring
//!
//!     pub fn yamlStringify(self: @This(), yw: *Stringify) !void

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const chars = @import("grammar/chars.zig");
const schema = @import("schema.zig");

const Stringify = @This();

pub const Error = Writer.Error;

pub const Options = struct {
    /// Spaces per level of block indentation, from 1 to 9.
    indent: u4 = 2,
    /// Block style puts each entry on its own line; flow style writes each
    /// document on one line, `{a: 1, b: [x, y]}`, much like JSON.
    style: enum { block, flow } = .block,
    /// Whether a struct field that is an optional holding null is written as
    /// `field: null` or left out.
    emit_null_optional_fields: bool = true,
    /// Begin even the first document with `---`.
    explicit_document_start: bool = false,
    /// How strings containing line breaks are written in block style: as
    /// literal block scalars where they can be, or always double-quoted with
    /// `\n` escapes.
    multiline_strings: enum { literal, double_quoted } = .literal,
    /// Write only ASCII, escaping everything else in double-quoted strings.
    escape_unicode: bool = false,
};

/// The deepest nesting the write stream holds, the same as the parser's
/// default limit, so that anything parsed with default options can be
/// written back out.
pub const max_depth = 512;

const Frame = struct {
    kind: enum { sequence, mapping },
    flow: bool,
    /// The column a block collection's entries start at.
    indent: usize,
    /// What the collection follows, which decides where its first entry goes.
    lead: enum { root, after_dash, after_key },
    /// Entries written: sequence entries begun, mapping pairs completed.
    count: usize = 0,
    /// A mapping has written a key and its value is due.
    want_value: bool = false,
    /// The key being written was introduced with `? `.
    explicit_key: bool = false,
};

writer: *Writer,
options: Options = .{},
stack: [max_depth]Frame = undefined,
depth: usize = 0,
at_line_start: bool = true,
/// Documents begun so far.
documents: usize = 0,
/// The current document's root node has been written.
root_written: bool = false,
in_document: bool = false,

pub fn init(writer: *Writer, options: Options) Stringify {
    return .{ .writer = writer, .options = options };
}

/// Writes `v` as a YAML document.
pub fn value(v: anytype, options: Options, writer: *Writer) Error!void {
    var s: Stringify = .init(writer, options);
    try s.write(v);
    try s.endDocument();
}

/// Writes `v` as a YAML document into a newly allocated buffer.
pub fn valueAlloc(gpa: Allocator, v: anytype, options: Options) error{OutOfMemory}![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    value(v, options, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// -- documents ---------------------------------------------------------------

/// Begins a document, writing `---` unless this is the first document and
/// `explicit_document_start` is off. A document is begun automatically when
/// a node is written outside one.
pub fn beginDocument(self: *Stringify) Error!void {
    if (self.in_document) try self.endDocument();
    if (self.documents > 0 or self.options.explicit_document_start) {
        try self.writer.writeAll("---\n");
    }
    self.documents += 1;
    self.in_document = true;
    self.root_written = false;
    self.at_line_start = true;
}

pub fn endDocument(self: *Stringify) Error!void {
    std.debug.assert(self.depth == 0);
    if (!self.at_line_start) try self.newline();
    self.in_document = false;
}

// -- positioning -------------------------------------------------------------

const Ctx = enum { root, block_value, block_key, flow_value, flow_key };
const NodeKind = enum { scalar, flow_collection, block_collection };

fn top(self: *Stringify) *Frame {
    return &self.stack[self.depth - 1];
}

fn newline(self: *Stringify) Error!void {
    try self.writer.writeByte('\n');
    self.at_line_start = true;
}

fn indentTo(self: *Stringify, column: usize) Error!void {
    try self.writer.splatByteAll(' ', column);
    self.at_line_start = column == 0;
}

/// Moves to where the next entry of a block collection starts.
fn entryStart(self: *Stringify, f: *const Frame) Error!void {
    // The first entry of a collection that is itself an entry of a sequence
    // goes on the same line as its `- `: `- - a` or `- key: value`.
    if (f.count == 0 and f.lead == .after_dash) return;
    if (!self.at_line_start) try self.newline();
    try self.indentTo(f.indent);
}

/// Writes whatever has to come before a node in the current position, and
/// says what position that is.
fn beginNode(self: *Stringify, kind: NodeKind) Error!Ctx {
    if (self.depth == 0) {
        if (!self.in_document or self.root_written) try self.beginDocument();
        self.root_written = true;
        return .root;
    }
    const f = self.top();
    if (f.flow) switch (f.kind) {
        .sequence => {
            if (f.count > 0) try self.writer.writeAll(", ");
            f.count += 1;
            return .flow_value;
        },
        .mapping => {
            if (f.want_value) return .flow_value;
            if (f.count > 0) try self.writer.writeAll(", ");
            return .flow_key;
        },
    };
    switch (f.kind) {
        .sequence => {
            try self.entryStart(f);
            try self.writer.writeAll("- ");
            self.at_line_start = false;
            f.count += 1;
            return .block_value;
        },
        .mapping => {
            if (!f.want_value) {
                try self.entryStart(f);
                if (kind != .scalar) {
                    try self.writer.writeAll("? ");
                    self.at_line_start = false;
                    f.explicit_key = true;
                }
                return .block_key;
            }
            if (kind != .block_collection) {
                try self.writer.writeByte(' ');
                self.at_line_start = false;
            }
            return .block_value;
        },
    }
}

/// Records that a node has been completely written.
fn endNode(self: *Stringify) Error!void {
    if (self.depth == 0) {
        if (!self.at_line_start) try self.newline();
        return;
    }
    const f = self.top();
    if (f.flow) {
        if (f.kind == .mapping) {
            if (!f.want_value) {
                try self.writer.writeAll(": ");
                f.want_value = true;
            } else {
                f.want_value = false;
                f.count += 1;
            }
        }
        return;
    }
    switch (f.kind) {
        .sequence => if (!self.at_line_start) try self.newline(),
        .mapping => if (!f.want_value) {
            if (f.explicit_key) {
                try self.newline();
                try self.indentTo(f.indent);
            }
            try self.writer.writeByte(':');
            self.at_line_start = false;
            f.want_value = true;
        } else {
            if (!self.at_line_start) try self.newline();
            f.want_value = false;
            f.explicit_key = false;
            f.count += 1;
        },
    }
}

// -- collections -------------------------------------------------------------

/// Whether a collection begun now is written in flow style.
fn nextIsFlow(self: *Stringify) bool {
    if (self.options.style == .flow) return true;
    if (self.depth == 0) return false;
    const f = self.top();
    // Inside flow everything is flow, and a key is written as a flow node.
    return f.flow or (f.kind == .mapping and !f.want_value);
}

fn beginCollection(self: *Stringify, kind: @FieldType(Frame, "kind")) Error!void {
    std.debug.assert(self.depth < max_depth);
    const flow = self.nextIsFlow();
    const ctx = try self.beginNode(if (flow) .flow_collection else .block_collection);
    if (flow) {
        try self.writer.writeByte(if (kind == .sequence) '[' else '{');
        self.at_line_start = false;
    }
    const parent_indent: usize = if (self.depth == 0) 0 else self.top().indent;
    self.stack[self.depth] = .{
        .kind = kind,
        .flow = flow,
        .indent = switch (ctx) {
            .root => 0,
            // A `- ` is two columns, whatever the indentation step.
            .block_value => if (self.top().kind == .sequence) parent_indent + 2 else parent_indent + self.options.indent,
            else => parent_indent,
        },
        .lead = switch (ctx) {
            .root => .root,
            .block_value => if (self.top().kind == .sequence) .after_dash else .after_key,
            else => .after_key,
        },
    };
    self.depth += 1;
}

fn endCollection(self: *Stringify, kind: @FieldType(Frame, "kind")) Error!void {
    const f = self.top();
    std.debug.assert(f.kind == kind and !f.want_value);
    if (f.flow) {
        try self.writer.writeByte(if (kind == .sequence) ']' else '}');
    } else if (f.count == 0) {
        // An empty block collection has no entries to show it; it is
        // written in flow style instead.
        if (f.lead == .after_key) try self.writer.writeByte(' ');
        try self.writer.writeAll(if (kind == .sequence) "[]" else "{}");
        self.at_line_start = false;
    }
    self.depth -= 1;
    try self.endNode();
}

pub fn beginSequence(self: *Stringify) Error!void {
    return self.beginCollection(.sequence);
}

pub fn endSequence(self: *Stringify) Error!void {
    return self.endCollection(.sequence);
}

pub fn beginMapping(self: *Stringify) Error!void {
    return self.beginCollection(.mapping);
}

pub fn endMapping(self: *Stringify) Error!void {
    return self.endCollection(.mapping);
}

/// Writes a string key; the value is written next.
pub fn mappingKey(self: *Stringify, key: []const u8) Error!void {
    std.debug.assert(self.depth > 0 and self.top().kind == .mapping and !self.top().want_value);
    return self.writeString(key);
}

// -- scalars -----------------------------------------------------------------

/// Writes a node whose text is produced by `fmt` and `args`, verbatim. The
/// text must be a valid plain scalar in the position it is written — it is
/// meant for numbers kept as text, like `Value.number_string`.
pub fn print(self: *Stringify, comptime fmt: []const u8, args: anytype) Error!void {
    _ = try self.beginNode(.scalar);
    try self.writer.print(fmt, args);
    self.at_line_start = false;
    try self.endNode();
}

fn writeRaw(self: *Stringify, text: []const u8) Error!void {
    _ = try self.beginNode(.scalar);
    try self.writer.writeAll(text);
    self.at_line_start = false;
    try self.endNode();
}

fn writeString(self: *Stringify, s: []const u8) Error!void {
    const is_flow = self.depth > 0 and self.top().flow;
    const ctx = try self.beginNode(.scalar);
    switch (ctx) {
        .flow_value, .flow_key => try self.writeInlineString(s, true),
        .block_key => {
            // An implicit key is limited to 1024 characters. Render it
            // first to see whether it fits, and write a longer one after an
            // explicit `? ` instead.
            var buf: [1000]u8 = undefined;
            var w: Writer = .fixed(&buf);
            var probe: Stringify = .init(&w, self.options);
            if (probe.writeInlineString(s, is_flow)) |_| {
                try self.writer.writeAll(w.buffered());
            } else |_| {
                try self.writer.writeAll("? ");
                self.top().explicit_key = true;
                try self.writeInlineString(s, is_flow);
            }
        },
        .root, .block_value => {
            if (self.options.multiline_strings == .literal and std.mem.findScalar(u8, s, '\n') != null) {
                const n: ?usize = if (ctx == .root) null else self.top().indent;
                if (literalShape(s, n != null)) |shape| {
                    try self.writeLiteral(s, shape, n);
                    return self.endNode();
                }
            }
            try self.writeInlineString(s, false);
        },
    }
    self.at_line_start = false;
    try self.endNode();
}

/// A one-line rendering of `s`: plain, single-quoted or double-quoted.
fn writeInlineString(self: *Stringify, s: []const u8, flow: bool) Error!void {
    if (self.plainOk(s, flow)) return self.writer.writeAll(s);
    if (self.singleQuotedOk(s)) {
        try self.writer.writeByte('\'');
        var rest = s;
        while (std.mem.findScalar(u8, rest, '\'')) |i| {
            try self.writer.writeAll(rest[0 .. i + 1]);
            try self.writer.writeByte('\'');
            rest = rest[i + 1 ..];
        }
        try self.writer.writeAll(rest);
        return self.writer.writeByte('\'');
    }
    return self.writeDoubleQuoted(s);
}

/// Code points that are printable but read as line breaks by YAML 1.1 and
/// other readers, and so are never written bare.
fn isAmbiguousBreak(cp: u21) bool {
    return cp == 0x85 or cp == 0x2028 or cp == 0x2029;
}

fn plainOk(self: *const Stringify, s: []const u8, flow: bool) bool {
    if (s.len == 0) return false;
    // It must not read back as a null, a boolean or a number.
    if (schema.resolvePlain(.core, s) != .str) return false;
    if (chars.isIndicator(s[0]) or s[0] == ' ' or s[0] == '\t') return false;
    const last = s[s.len - 1];
    if (last == ' ' or last == '\t' or last == ':') return false;
    if (std.mem.startsWith(u8, s, "...")) return false;
    var i: usize = 0;
    var prev: u21 = 0;
    while (i < s.len) {
        const cp = chars.decode(s[i..]) orelse return false;
        i += cp.len;
        const c = cp.cp;
        if (!chars.isNbChar(c) or c == '\t' or isAmbiguousBreak(c)) return false;
        if (self.options.escape_unicode and c >= 0x80) return false;
        if (flow and chars.isFlowIndicator(c)) return false;
        if (c == '#' and prev == ' ') return false;
        if (c == ':') {
            // `:` continues a plain scalar only when a character that could
            // itself be plain follows it.
            const next = if (i < s.len) (chars.decode(s[i..]) orelse return false).cp else return false;
            if (!chars.isNsChar(next) or (flow and chars.isFlowIndicator(next))) return false;
        }
        prev = c;
    }
    return true;
}

fn singleQuotedOk(self: *const Stringify, s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const cp = chars.decode(s[i..]) orelse return false;
        i += cp.len;
        if (!chars.isNbChar(cp.cp) or isAmbiguousBreak(cp.cp)) return false;
        if (self.options.escape_unicode and cp.cp >= 0x80) return false;
    }
    return true;
}

fn writeDoubleQuoted(self: *Stringify, s: []const u8) Error!void {
    const w = self.writer;
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        // Callers only get here with valid UTF-8; a stray byte is escaped
        // rather than trusted.
        const cp = chars.decode(s[i..]) orelse chars.Cp{ .cp = s[i], .len = 1 };
        const c = cp.cp;
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x00 => try w.writeAll("\\0"),
            0x07 => try w.writeAll("\\a"),
            0x08 => try w.writeAll("\\b"),
            '\t' => try w.writeAll("\\t"),
            '\n' => try w.writeAll("\\n"),
            0x0B => try w.writeAll("\\v"),
            0x0C => try w.writeAll("\\f"),
            '\r' => try w.writeAll("\\r"),
            0x1B => try w.writeAll("\\e"),
            0x85 => try w.writeAll("\\N"),
            0x2028 => try w.writeAll("\\L"),
            0x2029 => try w.writeAll("\\P"),
            else => if (c < 0x20 or c == 0x7F or (c >= 0x80 and c <= 0x9F)) {
                try w.print("\\x{X:0>2}", .{c});
            } else if (!chars.isPrintable(c) or c == chars.byte_order_mark or
                (self.options.escape_unicode and c >= 0x80))
            {
                if (c > 0xFFFF) try w.print("\\U{X:0>8}", .{c}) else try w.print("\\u{X:0>4}", .{c});
            } else {
                try w.writeAll(s[i..][0..cp.len]);
            },
        }
        i += cp.len;
    }
    try w.writeByte('"');
}

const LiteralShape = struct {
    /// The string less its trailing line feeds.
    body: []const u8,
    trailing: usize,
    /// Its first line begins with a space, so the content indentation cannot
    /// be detected and has to be given.
    needs_indicator: bool,
};

/// Whether `s` can be written as a literal block scalar, and how.
fn literalShape(s: []const u8, indicator_allowed: bool) ?LiteralShape {
    const body = std.mem.trimEnd(u8, s, "\n");
    if (body.len == 0) return null;
    var i: usize = 0;
    var has_content = false;
    while (i < body.len) {
        const cp = chars.decode(body[i..]) orelse return null;
        i += cp.len;
        if (cp.cp == '\n') continue;
        if (!chars.isNbChar(cp.cp) or isAmbiguousBreak(cp.cp)) return null;
        if (cp.cp != ' ') has_content = true;
    }
    if (!has_content) return null;
    const first_line = body[0 .. std.mem.findScalar(u8, body, '\n') orelse body.len];
    const needs_indicator = (first_line.len > 0 and first_line[0] == ' ') or
        (first_line.len == 0 and startsWithSpacedLine(body));
    if (needs_indicator and !indicator_allowed) return null;
    return .{ .body = body, .trailing = s.len - body.len, .needs_indicator = needs_indicator };
}

/// Whether the first line that is not empty begins with a space.
fn startsWithSpacedLine(body: []const u8) bool {
    const rest = std.mem.trimStart(u8, body, "\n");
    return rest.len > 0 and rest[0] == ' ';
}

/// Writes a literal block scalar for a node at indentation `n` (null at the
/// root of a document).
fn writeLiteral(self: *Stringify, s: []const u8, shape: LiteralShape, n: ?usize) Error!void {
    _ = s;
    const w = self.writer;
    const step: usize = @max(self.options.indent, 1);
    const content_indent = (n orelse 0) + step;
    try w.writeByte('|');
    if (shape.needs_indicator) try w.writeByte('0' + @as(u8, @intCast(step)));
    switch (shape.trailing) {
        0 => try w.writeByte('-'),
        1 => {},
        else => try w.writeByte('+'),
    }
    try w.writeByte('\n');
    var lines = std.mem.splitScalar(u8, shape.body, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            try w.splatByteAll(' ', content_indent);
            try w.writeAll(line);
        }
        try w.writeByte('\n');
    }
    if (shape.trailing > 1) try w.splatByteAll('\n', shape.trailing - 1);
    self.at_line_start = true;
}

fn writeFloat(self: *Stringify, f: f64) Error!void {
    if (std.math.isNan(f)) return self.writeRaw(".nan");
    if (std.math.isInf(f)) return self.writeRaw(if (f < 0) "-.inf" else ".inf");
    // Shortest round-trip form either way; decimal unless that would run to
    // hundreds of digits, as `{d}` of 1e300 or 5e-324 does.
    var buf: [64]u8 = undefined;
    const magnitude = @abs(f);
    const scientific = magnitude != 0 and (magnitude >= 1e16 or magnitude < 1e-5);
    var text = (if (scientific)
        std.fmt.bufPrint(&buf, "{e}", .{f})
    else
        std.fmt.bufPrint(&buf, "{d}", .{f})) catch unreachable;
    // A whole number written without a point would read back as an integer.
    if (std.mem.findAny(u8, text, ".eE") == null) {
        buf[text.len] = '.';
        buf[text.len + 1] = '0';
        text = buf[0 .. text.len + 2];
    }
    return self.writeRaw(text);
}

// -- values ------------------------------------------------------------------

/// Writes any Zig value as a node.
pub fn write(self: *Stringify, v: anytype) Error!void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .int => return self.print("{d}", .{v}),
        .comptime_int => return self.write(@as(std.math.IntFittingRange(v, v), v)),
        .float => return self.writeFloat(@floatCast(v)),
        .comptime_float => return self.writeFloat(v),
        .bool => return self.writeRaw(if (v) "true" else "false"),
        .null, .void => return self.writeRaw("null"),
        .optional => return if (v) |payload| self.write(payload) else self.writeRaw("null"),
        .enum_literal => return self.writeString(@tagName(v)),
        .@"enum" => |info| {
            if (comptime std.meta.hasFn(T, "yamlStringify")) return v.yamlStringify(self);
            if (!info.is_exhaustive) {
                inline for (info.fields) |field| {
                    if (v == @field(T, field.name)) return self.writeString(field.name);
                }
                return self.write(@intFromEnum(v));
            }
            return self.writeString(@tagName(v));
        },
        .error_set => return self.writeString(@errorName(v)),
        .@"union" => |info| {
            if (comptime std.meta.hasFn(T, "yamlStringify")) return v.yamlStringify(self);
            if (info.tag_type == null) @compileError("Unable to stringify untagged union '" ++ @typeName(T) ++ "'");
            switch (v) {
                inline else => |payload, tag| {
                    // A variant with no payload is just its name, which is
                    // also what parsing accepts for one.
                    if (@TypeOf(payload) == void) return self.writeString(@tagName(tag));
                    try self.beginMapping();
                    try self.writeString(@tagName(tag));
                    try self.write(payload);
                    try self.endMapping();
                },
            }
        },
        .@"struct" => |info| {
            if (comptime std.meta.hasFn(T, "yamlStringify")) return v.yamlStringify(self);
            if (info.is_tuple) {
                try self.beginSequence();
                inline for (info.fields) |field| try self.write(@field(v, field.name));
                return self.endSequence();
            }
            try self.beginMapping();
            inline for (info.fields) |field| {
                const skip = field.type == void or
                    (@typeInfo(field.type) == .optional and !self.options.emit_null_optional_fields and @field(v, field.name) == null);
                if (!skip) {
                    try self.writeString(field.name);
                    try self.write(@field(v, field.name));
                }
            }
            return self.endMapping();
        },
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => return self.write(@as([]const std.meta.Elem(info.child), v)),
                else => return self.write(v.*),
            },
            .slice => {
                if (info.child == u8 and std.unicode.utf8ValidateSlice(v)) return self.writeString(v);
                try self.beginSequence();
                for (v) |item| try self.write(item);
                return self.endSequence();
            },
            .many, .c => {
                if (info.sentinel() == null) @compileError("Unable to stringify unbounded pointer '" ++ @typeName(T) ++ "'");
                return self.write(std.mem.span(v));
            },
        },
        .array => return self.write(&v),
        .vector => |info| {
            const array: [info.len]info.child = v;
            return self.write(&array);
        },
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }
}

fn expectOutput(expected: []const u8, v: anytype, options: Options) !void {
    const out = try valueAlloc(std.testing.allocator, v, options);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "block style" {
    const Point = struct { x: i32, y: i32 };
    try expectOutput(
        \\name: example
        \\points:
        \\  - x: 1
        \\    y: 2
        \\  - x: 3
        \\    y: 4
        \\tags: []
        \\nested:
        \\  - - a
        \\    - b
        \\  - []
        \\
    , .{
        .name = "example",
        .points = &[_]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } },
        .tags = &[_][]const u8{},
        .nested = &[_][]const []const u8{ &.{ "a", "b" }, &.{} },
    }, .{});
}

test "flow style" {
    try expectOutput("{a: 1, b: [x, 'y, z'], c: {}}\n", .{
        .a = 1,
        .b = &[_][]const u8{ "x", "y, z" },
        .c = struct {}{},
    }, .{ .style = .flow });
}

test "strings are quoted only when they must be" {
    try expectOutput(
        \\- plain text
        \\- 'true'
        \\- '12'
        \\- ''
        \\- '- item'
        \\- 'a: b'
        \\- a:b
        \\- 'x #y'
        \\- x#y
        \\- ' padded '
        \\- it's
        \\- 'it''s: here'
        \\- 'null'
        \\- "\e"
        \\
    , &[_][]const u8{ "plain text", "true", "12", "", "- item", "a: b", "a:b", "x #y", "x#y", " padded ", "it's", "it's: here", "null", "\x1b" }, .{});
}

test "a tab needs quoting but no escape" {
    try expectOutput("'tab\there'\n", "tab\there", .{});
}

test "multi-line strings" {
    try expectOutput(
        \\text: |
        \\  one
        \\  two
        \\stripped: |-
        \\  one
        \\  two
        \\kept: |+
        \\  one
        \\
        \\indented: |2
        \\    one
        \\  two
        \\
    , .{
        .text = "one\ntwo\n",
        .stripped = "one\ntwo",
        .kept = "one\n\n",
        .indented = "  one\ntwo\n",
    }, .{});
}

test "floats of any size read back as the same float" {
    for ([_]f64{ 1e300, -1e300, 5e-324, 1.7976931348623157e308, 1e16, 9.999e15, 1e-5, 9.99e-6, 0.1, -0.0, 123456.789 }) |f| {
        const out = try valueAlloc(std.testing.allocator, f, .{});
        defer std.testing.allocator.free(out);
        const text = std.mem.trimEnd(u8, out, "\n");
        try std.testing.expectEqual(schema.Kind.float, schema.resolvePlain(.core, text).?);
        try std.testing.expectEqual(f, try schema.parseFloat(f64, .core, text));
    }
}

test "numbers and nulls" {
    try expectOutput("- 1.0\n- 0.5\n- .inf\n- -.inf\n- .nan\n- null\n- -3\n", .{ @as(f64, 1), 0.5, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64), null, -3 }, .{});
}

test "unions and enums" {
    const U = union(enum) { none, number: i32 };
    const E = enum { red, green };
    try expectOutput("- none\n- number: 4\n- green\n", .{ U.none, U{ .number = 4 }, E.green }, .{});
}

test "keys that are not strings" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var s: Stringify = .init(&out.writer, .{});
    try s.beginMapping();
    try s.write(1);
    try s.write("one");
    try s.beginSequence();
    try s.write("a");
    try s.write("b");
    try s.endSequence();
    try s.write("pair");
    try s.endMapping();
    try s.endDocument();
    try std.testing.expectEqualStrings("1: one\n? [a, b]\n: pair\n", out.written());
}

test "several documents" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var s: Stringify = .init(&out.writer, .{});
    try s.write("first");
    try s.write(.{ .second = 2 });
    try s.endDocument();
    try std.testing.expectEqualStrings("first\n---\nsecond: 2\n", out.written());
}
