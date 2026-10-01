// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The state a YAML 1.2.2 parse runs on, and the few primitives every
//! production is written in terms of.
//!
//! The grammar itself lives beside this file, one file per chapter of the
//! specification, as one function per numbered production. Each function
//! takes the parser and the production's parameters — the indentation `n`,
//! the context `c`, the chomping `t` — and answers whether the production
//! matched at the current position. A production that does not match leaves
//! the parser exactly as it found it, which is what lets alternatives be
//! written as a plain `if … else if …` chain and repetition as a `while`.
//!
//! What the grammar recognizes it also reports, as a list of `RawEvent`s: the
//! semantic actions sit at the production boundaries where a node begins and
//! ends. Backtracking truncates that list along with the position, so what is
//! left when the stream production succeeds is exactly the event stream of
//! the parse that won.

const std = @import("std");
const Allocator = std.mem.Allocator;

const chars = @import("chars.zig");
const stream = @import("stream.zig");

const Parser = @This();

/// The errors a production can raise. A production that merely does not
/// match returns `false`; these are the conditions that end the parse
/// outright, wherever they are found.
pub const Error = Allocator.Error || error{
    /// Nesting went past `max_depth`. The grammar is recursive, so the bound
    /// is what stands between a hostile input and a stack overflow.
    NestingTooDeep,
    /// A tag shorthand used a named handle no `%TAG` directive declared.
    UndefinedTagHandle,
    /// Two `%YAML` directives, or two `%TAG` directives for one handle, in
    /// the same document.
    DuplicateDirective,
    /// A block scalar's leading empty line held more spaces than its first
    /// content line (§8.1.1.1).
    InvalidIndentation,
    /// The input is longer than the 4 GiB that event offsets can address.
    InputTooLong,
};

/// The context parameter `c` of the productions (§4.1).
pub const Context = enum(u3) {
    block_in,
    block_out,
    block_key,
    flow_in,
    flow_out,
    flow_key,

    /// `in-flow(c)`, the context a flow collection's entries are parsed in:
    /// inside a key the entries are keys too, everywhere else they are
    /// ordinary flow content.
    pub fn inFlow(c: Context) Context {
        return switch (c) {
            .flow_out, .flow_in => .flow_in,
            .block_key, .flow_key => .flow_key,
            // Not reached: the productions only ask this of flow and key
            // contexts. Treated as flow content for want of anything better.
            .block_in, .block_out => .flow_in,
        };
    }

    pub fn isKey(c: Context) bool {
        return c == .block_key or c == .flow_key;
    }
};

/// The chomping parameter `t` of the block scalar productions (§8.1.1.2).
pub const Chomping = enum { strip, clip, keep };

/// Where a string an event carries is to be found. Offsets rather than
/// slices, because the buffer they point into grows and moves while the
/// parse runs.
pub const Span = struct {
    off: u32 = 0,
    len: u32 = 0,
    src: Source = .none,

    pub const Source = enum(u2) { none, input, buffer };

    pub const none: Span = .{};

    pub fn isNone(s: Span) bool {
        return s.src == .none;
    }
};

pub const ScalarStyle = enum(u3) { plain, single_quoted, double_quoted, literal, folded };

pub const RawEvent = struct {
    kind: Kind,
    /// Where in the input the node or marker begins.
    pos: u32,
    anchor: Span = .none,
    tag: Span = .none,
    /// A scalar's content, an alias's name, or a document's `%YAML` version.
    value: Span = .none,
    /// Explicit `---` / `...` for documents, flow style for collections.
    flag: bool = false,
    style: ScalarStyle = .plain,

    pub const Kind = enum(u4) {
        stream_start,
        stream_end,
        document_start,
        document_end,
        sequence_start,
        sequence_end,
        mapping_start,
        mapping_end,
        scalar,
        alias,
    };
};

/// Node properties that have been read and not yet attached to a node. The
/// node that follows claims them when it emits its first event.
pub const Props = struct {
    anchor: Span = .none,
    tag: Span = .none,
    /// Input positions of the two properties, which is what identifies them
    /// to the memo table: the expanded tag lives at a buffer offset that
    /// differs every time the same text is parsed again.
    anchor_pos: u32 = std.math.maxInt(u32),
    tag_pos: u32 = std.math.maxInt(u32),

    pub fn isEmpty(p: Props) bool {
        return p.anchor.isNone() and p.tag.isNone();
    }
};

/// Everything a failed production has to put back.
pub const State = struct {
    pos: u32,
    events: u32,
    scratch: u32,
    props: Props,
};

pub const TagHandle = struct {
    handle: []const u8,
    prefix: Span,
};

gpa: Allocator,
input: []const u8,
pos: u32 = 0,
/// Where the input ends as far as the productions are concerned. Inside a
/// bare document it is the first `c-forbidden` marker (§9.1.4), since the
/// grammar's "excluding c-forbidden content" is a restriction on the whole
/// document that no single production can see.
end: u32,

events: std.ArrayList(RawEvent) = .empty,
/// Scalar content under construction. Truncated on backtracking, so that a
/// scalar is always contiguous at its end.
scratch: std.ArrayList(u8) = .empty,
/// Finished scalar content and expanded tags. Only ever appended to, so a
/// span into it stays valid however far the parse later backtracks — which
/// is what lets memoized events be replayed.
buffer: std.ArrayList(u8) = .empty,
props: Props = .{},

depth: u32 = 0,
max_depth: u32 = 512,

/// The furthest position any production reached before failing. When the
/// whole parse fails, this is where the error is most likely to be.
far: u32 = 0,

/// `%TAG` directives of the current document.
tag_handles: std.ArrayList(TagHandle) = .empty,
yaml_version: Span = .none,

memo: std.AutoHashMapUnmanaged(MemoKey, MemoValue) = .empty,
memo_events: std.ArrayList(RawEvent) = .empty,

pub fn init(gpa: Allocator, input: []const u8) Error!Parser {
    if (input.len >= std.math.maxInt(u32)) return error.InputTooLong;
    return .{ .gpa = gpa, .input = input, .end = @intCast(input.len) };
}

pub fn deinit(p: *Parser) void {
    p.events.deinit(p.gpa);
    p.scratch.deinit(p.gpa);
    p.buffer.deinit(p.gpa);
    p.tag_handles.deinit(p.gpa);
    p.memo.deinit(p.gpa);
    p.memo_events.deinit(p.gpa);
    p.* = undefined;
}

/// Parses the whole input as a `l-yaml-stream`. On success `events` holds
/// the stream; on failure `far` is the best guess at where the error is.
pub fn parse(p: *Parser) (Error || error{SyntaxError})!void {
    if (!try stream.lYamlStream(p)) return error.SyntaxError;
}

/// The string a span refers to. Valid until the buffer next grows, so only
/// safe to hold once the parse is over.
pub fn slice(p: *const Parser, s: Span) []const u8 {
    return switch (s.src) {
        .none => "",
        .input => p.input[s.off..][0..s.len],
        .buffer => p.buffer.items[s.off..][0..s.len],
    };
}

// -- state -------------------------------------------------------------------

pub fn save(p: *const Parser) State {
    return .{
        .pos = p.pos,
        .events = @intCast(p.events.items.len),
        .scratch = @intCast(p.scratch.items.len),
        .props = p.props,
    };
}

pub fn restore(p: *Parser, s: State) void {
    if (p.pos > p.far) p.far = p.pos;
    p.pos = s.pos;
    p.events.shrinkRetainingCapacity(s.events);
    p.scratch.shrinkRetainingCapacity(s.scratch);
    p.props = s.props;
}

/// Restores `s` and reports failure, so that a production can end with
/// `return p.fail(s);`.
pub fn fail(p: *Parser, s: State) bool {
    p.restore(s);
    return false;
}

/// Counts one level of nesting on the way into a node.
pub fn enter(p: *Parser) Error!void {
    if (p.depth >= p.max_depth) return error.NestingTooDeep;
    p.depth += 1;
}

pub fn leave(p: *Parser) void {
    p.depth -= 1;
}

// -- looking at the input ----------------------------------------------------

pub fn atEnd(p: *const Parser) bool {
    return p.pos >= p.end;
}

/// The byte at `pos + ahead`, or null past the end.
pub fn peekByte(p: *const Parser, ahead: u32) ?u8 {
    const i = p.pos + ahead;
    if (i >= p.end) return null;
    return p.input[i];
}

pub fn peekIs(p: *const Parser, b: u8) bool {
    return p.peekByte(0) == b;
}

/// The code point at `pos + ahead` bytes, or null past the end or where the
/// input is not valid UTF-8 — which then matches no production at all.
pub fn peekCp(p: *const Parser, ahead: u32) ?chars.Cp {
    const i = p.pos + ahead;
    if (i >= p.end) return null;
    return chars.decode(p.input[i..p.end]);
}

/// The code point ending just before the current position.
pub fn prevCp(p: *const Parser) ?u21 {
    return chars.decodeLast(p.input[0..p.pos]);
}

/// `<start-of-line>`: the beginning of the input, just after a line break,
/// or just after a byte order mark that itself starts a line.
pub fn atStartOfLine(p: *const Parser) bool {
    return chars.isStartOfLine(p.input, p.pos);
}

pub fn eat(p: *Parser, b: u8) bool {
    if (p.peekByte(0) == b) {
        p.pos += 1;
        return true;
    }
    return false;
}

pub fn eatStr(p: *Parser, s: []const u8) bool {
    if (p.pos + s.len > p.end) return false;
    if (!std.mem.eql(u8, p.input[p.pos..][0..s.len], s)) return false;
    p.pos += @intCast(s.len);
    return true;
}

/// Consumes one code point if `pred` holds for it.
pub fn eatCp(p: *Parser, comptime pred: fn (u21) bool) bool {
    const cp = p.peekCp(0) orelse return false;
    if (!pred(cp.cp)) return false;
    p.pos += cp.len;
    return true;
}

/// Counts the spaces from the current position, without consuming them.
pub fn countSpaces(p: *const Parser) u32 {
    var i: u32 = 0;
    while (p.peekByte(i) == ' ') i += 1;
    return i;
}

/// `[ lookahead ≠ ns-char ]`: the indicator just read stands on its own.
pub fn notFollowedByNsChar(p: *const Parser) bool {
    const cp = p.peekCp(0) orelse return true;
    return !chars.isNsChar(cp.cp);
}

// -- building events ---------------------------------------------------------

pub fn emit(p: *Parser, ev: RawEvent) Allocator.Error!void {
    try p.events.append(p.gpa, ev);
}

/// Emits the first event of a node, which claims any pending properties.
pub fn emitNodeStart(p: *Parser, kind: RawEvent.Kind, pos: u32, flag: bool) Allocator.Error!void {
    try p.emit(.{ .kind = kind, .pos = pos, .anchor = p.props.anchor, .tag = p.props.tag, .flag = flag });
    p.props = .{};
}

/// Emits a scalar whose content is `scratch[from..]`, and takes that content
/// out of the scratch buffer. `source` is where in the input the scalar's
/// text lies, if it lies in one piece: when the content is exactly that text,
/// the event points at the input rather than copying it.
pub fn emitScalar(p: *Parser, pos: u32, style: ScalarStyle, from: u32, source: ?[]const u8) Allocator.Error!void {
    const content = p.scratch.items[from..];
    const value: Span = if (source != null and std.mem.eql(u8, content, source.?)) .{
        .off = @intCast(source.?.ptr - p.input.ptr),
        .len = @intCast(source.?.len),
        .src = .input,
    } else try p.keep(content);
    p.scratch.shrinkRetainingCapacity(from);
    try p.emit(.{ .kind = .scalar, .pos = pos, .anchor = p.props.anchor, .tag = p.props.tag, .value = value, .style = style });
    p.props = .{};
}

/// `e-scalar` / `e-node`: an empty plain scalar, carrying whatever properties
/// are pending.
pub fn emitEmpty(p: *Parser) Allocator.Error!void {
    try p.emit(.{ .kind = .scalar, .pos = p.pos, .anchor = p.props.anchor, .tag = p.props.tag, .value = .{ .src = .input, .off = p.pos } });
    p.props = .{};
}

/// Copies `bytes` into the permanent buffer.
pub fn keep(p: *Parser, bytes: []const u8) Allocator.Error!Span {
    const off: u32 = @intCast(p.buffer.items.len);
    try p.buffer.appendSlice(p.gpa, bytes);
    return .{ .off = off, .len = @intCast(bytes.len), .src = .buffer };
}

pub fn inputSpan(p: *const Parser, from: u32, to: u32) Span {
    _ = p;
    return .{ .off = from, .len = to - from, .src = .input };
}

pub fn appendContent(p: *Parser, bytes: []const u8) Allocator.Error!void {
    try p.scratch.appendSlice(p.gpa, bytes);
}

pub fn appendByte(p: *Parser, b: u8) Allocator.Error!void {
    try p.scratch.append(p.gpa, b);
}

/// The scratch length now, which is where a scalar about to be built starts.
pub fn mark(p: *const Parser) u32 {
    return @intCast(p.scratch.items.len);
}

// -- memoization -------------------------------------------------------------
//
// The grammar backtracks, and some of its alternatives re-parse the same text
// in a different role: every entry of a flow sequence is first tried as the
// key of a single-pair mapping and only then as a node, and the key attempt
// parses any collection inside it the same two ways. Unchecked, that doubles
// the work at every level of nesting.
//
// So the flow collections are memoized. In a key context — the attempt that
// is usually wasted — the whole outcome is kept, events and all, and replayed
// when the same collection is wanted again; a key is at most 1024 characters,
// so what is kept is small. Elsewhere only failure is remembered, which costs
// no events and is what stops a failing alternative from being explored again
// from every level above it. Block nodes, which are retried with and without
// the properties in front of them, remember their failures the same way.

pub const Rule = enum(u8) { flow_sequence, flow_mapping, block_node };

pub const MemoKey = struct {
    rule: Rule,
    c: Context,
    n: i32,
    pos: u32,
    /// Where the input ends for this attempt, which an implicit key narrows.
    end: u32,
    anchor_pos: u32,
    tag_pos: u32,
};

pub const MemoValue = struct {
    matched: bool,
    end: u32 = 0,
    events_from: u32 = 0,
    events_to: u32 = 0,
};

/// Runs `func(p, n, c)` through the memo table.
pub fn memoized(
    p: *Parser,
    comptime rule: Rule,
    comptime func: fn (*Parser, i32, Context) Error!bool,
    n: i32,
    c: Context,
) Error!bool {
    const keep_success = c.isKey();
    const key: MemoKey = .{
        .rule = rule,
        .c = c,
        // In a key context the indentation plays no part: nothing in a key
        // may cross a line.
        .n = if (c.isKey()) 0 else n,
        .pos = p.pos,
        .end = p.end,
        .anchor_pos = p.props.anchor_pos,
        .tag_pos = p.props.tag_pos,
    };
    if (p.memo.get(key)) |hit| {
        if (!hit.matched) return false;
        try p.events.appendSlice(p.gpa, p.memo_events.items[hit.events_from..hit.events_to]);
        p.pos = hit.end;
        p.props = .{};
        return true;
    }
    const first: u32 = @intCast(p.events.items.len);
    const matched = try func(p, n, c);
    if (!matched) {
        try p.memo.put(p.gpa, key, .{ .matched = false });
    } else if (keep_success) {
        const from: u32 = @intCast(p.memo_events.items.len);
        try p.memo_events.appendSlice(p.gpa, p.events.items[first..]);
        try p.memo.put(p.gpa, key, .{
            .matched = true,
            .end = p.pos,
            .events_from = from,
            .events_to = @intCast(p.memo_events.items.len),
        });
    }
    return matched;
}

/// Forgets the memo table: its entries are only valid within one document,
/// whose end and whose tag directives they were computed against.
pub fn clearMemo(p: *Parser) void {
    p.memo.clearRetainingCapacity();
    p.memo_events.clearRetainingCapacity();
}

/// The line and column (both counted from 1) of a byte offset.
pub fn lineColumn(input: []const u8, offset: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var col: usize = 1;
    var i: usize = 0;
    const stop = @min(offset, input.len);
    while (i < stop) : (i += 1) {
        switch (input[i]) {
            '\n' => {
                line += 1;
                col = 1;
            },
            '\r' => {
                if (i + 1 < input.len and input[i + 1] == '\n') continue;
                line += 1;
                col = 1;
            },
            else => {
                // Columns count code points, not bytes.
                if (input[i] & 0xC0 != 0x80) col += 1;
            },
        }
    }
    return .{ .line = line, .column = col };
}

test lineColumn {
    const lc = lineColumn("ab\ncd\r\nef", 8);
    try std.testing.expectEqual(3, lc.line);
    try std.testing.expectEqual(2, lc.column);
}
