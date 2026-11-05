// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Turns a complete YAML stream into events, one `next()` at a time — the
//! counterpart of `std.json.Scanner`, with events where that has tokens.
//!
//! The grammar backtracks, so the scanner cannot hand out an event before it
//! knows which parse won: the first call to `next` (or `peekNextEventType`)
//! parses the whole stream, and the rest hand out what that found. A syntax
//! error anywhere in the stream is therefore reported before any event.
//!
//! Aliases are resolved by default. When `resolve_aliases` is set, an alias
//! is never returned: the events of the node it refers to are replayed in its
//! place, so that a consumer sees the tree the document describes. The total
//! number of replayed events is bounded by `max_alias_expansion`, which is
//! what makes a "billion laughs" document an error rather than an
//! out-of-memory condition.

const std = @import("std");
const Allocator = std.mem.Allocator;

const chars = @import("grammar/chars.zig");
const event = @import("event.zig");
const Parser = @import("grammar/Parser.zig");
const Event = event.Event;
const EventType = event.EventType;
const RawEvent = Parser.RawEvent;

const Scanner = @This();

pub const Error = Parser.Error || error{
    /// The input does not match the YAML 1.2.2 grammar.
    SyntaxError,
    /// A UTF-16 or UTF-32 stream that does not decode.
    InvalidEncoding,
    /// An alias names an anchor that no earlier node carries.
    UndefinedAlias,
    /// An alias refers to a node that contains it, which would make the tree
    /// infinite.
    RecursiveAlias,
    /// Replaying aliases produced more than `max_alias_expansion` events.
    AliasExpansionLimit,
};

pub const NextError = Error;
pub const PeekError = Error;
pub const AllocError = Allocator.Error;

gpa: Allocator,
/// The stream as given, before any transcoding.
input: []const u8,
/// The input as UTF-8, when it had to be converted.
transcoded: ?[]u8 = null,
parser: ?Parser = null,
state: enum { unparsed, ready, failed } = .unparsed,
/// The error the parse failed with, returned again by every later call.
failure: Error = error.SyntaxError,

index: u32 = 0,
/// For each node-start event, the index one past its last event; for each
/// alias, the index of the node it refers to.
links: []u32 = &.{},
replay: std.ArrayList(Frame) = .empty,
expanded: usize = 0,

/// Replay aliases rather than returning them.
resolve_aliases: bool = true,
/// The deepest nesting of collections the parser accepts.
max_depth: u32 = 512,
/// The most events alias replay may produce over the whole stream.
max_alias_expansion: usize = 1 << 20,

diagnostics: ?*Diagnostics = null,

const Frame = struct { next: u32, end: u32 };

/// Where the scanner is, for error messages: the position of the event last
/// returned, or of the syntax error that stopped the parse.
pub const Diagnostics = struct {
    input: []const u8 = "",
    offset: usize = 0,

    /// The offset in bytes, counting from 0, into the input as UTF-8 — which
    /// for a UTF-16 or UTF-32 stream is not the input as given.
    pub fn getByteOffset(d: *const Diagnostics) usize {
        return d.offset;
    }

    test getByteOffset {
        const d: Diagnostics = .{ .input = "a: b\nc: d\n", .offset = 8 };
        try std.testing.expectEqual(8, d.getByteOffset());
    }

    /// The line, counting from 1.
    pub fn getLine(d: *const Diagnostics) usize {
        return Parser.lineColumn(d.input, d.offset).line;
    }

    test getLine {
        const d: Diagnostics = .{ .input = "a: b\nc: d\n", .offset = 8 };
        try std.testing.expectEqual(2, d.getLine());
    }

    /// The column in code points, counting from 1.
    pub fn getColumn(d: *const Diagnostics) usize {
        return Parser.lineColumn(d.input, d.offset).column;
    }

    test getColumn {
        // `é` is two bytes and one column, so byte 4 is the `b` in column 4.
        const d: Diagnostics = .{ .input = "é: b\nc: d\n", .offset = 4 };
        try std.testing.expectEqual(4, d.getColumn());
    }
};

/// A scanner over the whole of `input`, which must outlive it. Nothing is
/// parsed until the first call that needs an event.
pub fn initCompleteInput(gpa: Allocator, input: []const u8) Scanner {
    return .{ .gpa = gpa, .input = input };
}

test initCompleteInput {
    var s = initCompleteInput(std.testing.allocator, "key: value\n");
    defer s.deinit();
    try std.testing.expectEqual(.stream_start, try s.next());
}

/// Frees everything the scanner allocated. Every string an event carried
/// that did not point into the input is invalid afterwards.
pub fn deinit(self: *Scanner) void {
    if (self.parser) |*p| p.deinit();
    if (self.transcoded) |t| self.gpa.free(t);
    self.gpa.free(self.links);
    self.replay.deinit(self.gpa);
    self.* = undefined;
}

test deinit {
    var s = initCompleteInput(std.testing.allocator, "- x\n");
    _ = try s.next();
    s.deinit();
}

/// Has `d` track where the scanner is: the position of the event last
/// returned, or of the error that ended the parse. `d` must outlive the
/// scanner.
pub fn enableDiagnostics(self: *Scanner, d: *Diagnostics) void {
    d.input = self.utf8Input();
    self.diagnostics = d;
}

test enableDiagnostics {
    var s = initCompleteInput(std.testing.allocator, "a: b\nc: [d\n");
    defer s.deinit();
    var d: Diagnostics = .{};
    s.enableDiagnostics(&d);
    try std.testing.expectError(error.SyntaxError, s.next());
    try std.testing.expectEqual(3, d.getLine());
}

fn utf8Input(self: *const Scanner) []const u8 {
    return self.transcoded orelse self.input;
}

/// Every event of the stream as the grammar produced it, with aliases
/// unresolved whatever `resolve_aliases` says, in the parser's own
/// representation; `convert` turns one into an `Event`. Parses on first use,
/// and does not move the position `next` reads from.
pub fn rawEvents(self: *Scanner) Error![]const RawEvent {
    try self.ensureParsed();
    return self.parser.?.events.items;
}

test rawEvents {
    var s = initCompleteInput(std.testing.allocator, "a: &x 1\nb: *x\n");
    defer s.deinit();
    const raw = try s.rawEvents();
    // The stream, document and mapping starts, four nodes, and three ends.
    try std.testing.expectEqual(10, raw.len);
    try std.testing.expectEqual(.alias, raw[6].kind);
}

fn ensureParsed(self: *Scanner) Error!void {
    switch (self.state) {
        .ready => return,
        .failed => return self.failure,
        .unparsed => {},
    }
    self.parse() catch |err| {
        self.state = .failed;
        self.failure = err;
        return err;
    };
    self.state = .ready;
}

fn parse(self: *Scanner) Error!void {
    self.transcoded = try chars.toUtf8(self.gpa, self.input);
    const input = self.utf8Input();
    if (self.diagnostics) |d| d.input = input;
    self.parser = try Parser.init(self.gpa, input);
    const p = &self.parser.?;
    p.max_depth = self.max_depth;
    p.parse() catch |err| {
        if (self.diagnostics) |d| d.offset = p.far;
        return err;
    };
    try self.link();
}

/// Matches every collection start with its end and every alias with the node
/// it names, so that replay can find both without searching.
fn link(self: *Scanner) Error!void {
    const events = self.parser.?.events.items;
    self.links = try self.gpa.alloc(u32, events.len);
    @memset(self.links, 0);
    var open: std.ArrayList(u32) = .empty;
    defer open.deinit(self.gpa);
    var anchors: std.StringHashMapUnmanaged(u32) = .empty;
    defer anchors.deinit(self.gpa);
    const p = &self.parser.?;
    for (events, 0..) |ev, i_usize| {
        const i: u32 = @intCast(i_usize);
        switch (ev.kind) {
            .document_start => anchors.clearRetainingCapacity(),
            .sequence_start, .mapping_start => {
                try open.append(self.gpa, i);
                if (!ev.anchor.isNone()) try anchors.put(self.gpa, p.slice(ev.anchor), i);
            },
            .sequence_end, .mapping_end => {
                const start = open.pop().?;
                self.links[start] = i + 1;
            },
            .scalar => {
                self.links[i] = i + 1;
                if (!ev.anchor.isNone()) try anchors.put(self.gpa, p.slice(ev.anchor), i);
            },
            .alias => {
                const target = anchors.get(p.slice(ev.value)) orelse {
                    if (self.diagnostics) |d| d.offset = ev.pos;
                    return error.UndefinedAlias;
                };
                if (self.links[target] == 0) {
                    if (self.diagnostics) |d| d.offset = ev.pos;
                    return error.RecursiveAlias;
                }
                self.links[i] = target;
            },
            .stream_start, .stream_end, .document_end => {},
        }
    }
}

/// The next raw event without consuming it, following replay frames.
fn peekRaw(self: *Scanner) ?u32 {
    var f = self.replay.items.len;
    while (f > 0) {
        f -= 1;
        const frame = self.replay.items[f];
        if (frame.next < frame.end) return frame.next;
    }
    const events = self.parser.?.events.items;
    if (self.index < events.len) return self.index;
    return null;
}

fn advanceRaw(self: *Scanner) ?u32 {
    while (self.replay.items.len > 0) {
        const top = &self.replay.items[self.replay.items.len - 1];
        if (top.next < top.end) {
            defer top.next += 1;
            return top.next;
        }
        _ = self.replay.pop();
    }
    const events = self.parser.?.events.items;
    if (self.index < events.len) {
        defer self.index += 1;
        return self.index;
    }
    return null;
}

/// The next event. The first call parses the whole stream, so a syntax
/// error anywhere is returned before any event; once a call has failed,
/// every later one returns the same error. After `stream_end` it keeps
/// returning `stream_end`.
pub fn next(self: *Scanner) Error!Event {
    try self.ensureParsed();
    const p = &self.parser.?;
    while (true) {
        const i = self.advanceRaw() orelse return .stream_end;
        const ev = p.events.items[i];
        if (self.diagnostics) |d| d.offset = ev.pos;
        if (ev.kind == .alias and self.resolve_aliases) {
            const target = self.links[i];
            const end = self.links[target];
            self.expanded += end - target;
            if (self.expanded > self.max_alias_expansion) return error.AliasExpansionLimit;
            try self.replay.append(self.gpa, .{ .next = target, .end = end });
            continue;
        }
        return self.convert(ev);
    }
}

test next {
    var s = initCompleteInput(std.testing.allocator, "hello\n");
    defer s.deinit();
    try std.testing.expectEqual(.stream_start, try s.next());
    try std.testing.expect(try s.next() == .document_start);
    try std.testing.expectEqualStrings("hello", (try s.next()).scalar.value);
    try std.testing.expect(try s.next() == .document_end);
    try std.testing.expectEqual(.stream_end, try s.next());
    try std.testing.expectEqual(.stream_end, try s.next());
}

/// The event `next` would return, without consuming it.
pub fn peek(self: *Scanner) Error!Event {
    try self.ensureParsed();
    const events = self.parser.?.events.items;
    const i = self.peekRaw() orelse return .stream_end;
    const ev = events[i];
    if (ev.kind == .alias and self.resolve_aliases) return self.convert(events[self.links[i]]);
    return self.convert(ev);
}

test peek {
    var s = initCompleteInput(std.testing.allocator, "hello\n");
    defer s.deinit();
    _ = try s.next();
    _ = try s.next();
    try std.testing.expectEqualStrings("hello", (try s.peek()).scalar.value);
    try std.testing.expectEqualStrings("hello", (try s.next()).scalar.value);
}

/// The type of the event `next` would return, without consuming it — which
/// is all a parser deciding what to do next usually needs to know.
pub fn peekNextEventType(self: *Scanner) Error!EventType {
    try self.ensureParsed();
    const events = self.parser.?.events.items;
    const i = self.peekRaw() orelse return .stream_end;
    const ev = events[i];
    if (ev.kind == .alias and self.resolve_aliases) return kindType(events[self.links[i]].kind);
    return kindType(ev.kind);
}

test peekNextEventType {
    var s = initCompleteInput(std.testing.allocator, "[1, 2]\n");
    defer s.deinit();
    _ = try s.next();
    _ = try s.next();
    try std.testing.expectEqual(.sequence_start, try s.peekNextEventType());
    try std.testing.expect(try s.next() == .sequence_start);
}

/// Skips one whole node — a scalar, an alias, or a collection with
/// everything in it. Running out of events first is `error.SyntaxError`.
pub fn skipValue(self: *Scanner) Error!void {
    var depth: usize = 0;
    while (true) {
        switch (try self.next()) {
            .sequence_start, .mapping_start => depth += 1,
            .sequence_end, .mapping_end => depth -= 1,
            .stream_end => return error.SyntaxError,
            else => {},
        }
        if (depth == 0) return;
    }
}

test skipValue {
    var s = initCompleteInput(std.testing.allocator, "[[1, 2], 3]\n");
    defer s.deinit();
    _ = try s.next(); // stream_start
    _ = try s.next(); // document_start
    _ = try s.next(); // the outer sequence_start
    try s.skipValue(); // [1, 2]
    try std.testing.expectEqualStrings("3", (try s.next()).scalar.value);
}

fn kindType(k: RawEvent.Kind) EventType {
    return switch (k) {
        .stream_start => .stream_start,
        .stream_end => .stream_end,
        .document_start => .document_start,
        .document_end => .document_end,
        .sequence_start => .sequence_start,
        .sequence_end => .sequence_end,
        .mapping_start => .mapping_start,
        .mapping_end => .mapping_end,
        .scalar => .scalar,
        .alias => .alias,
    };
}

fn optSlice(p: *const Parser, s: Parser.Span) ?[]const u8 {
    if (s.isNone()) return null;
    return p.slice(s);
}

/// The public form of a raw event from `rawEvents`. Only meaningful once
/// the stream has been parsed.
pub fn convert(self: *const Scanner, ev: RawEvent) Event {
    const p = &self.parser.?;
    return switch (ev.kind) {
        .stream_start => .stream_start,
        .stream_end => .stream_end,
        .document_start => .{ .document_start = .{ .explicit = ev.flag, .version = optSlice(p, ev.value) } },
        .document_end => .{ .document_end = .{ .explicit = ev.flag } },
        .sequence_start => .{ .sequence_start = .{
            .anchor = optSlice(p, ev.anchor),
            .tag = optSlice(p, ev.tag),
            .style = if (ev.flag) .flow else .block,
        } },
        .sequence_end => .sequence_end,
        .mapping_start => .{ .mapping_start = .{
            .anchor = optSlice(p, ev.anchor),
            .tag = optSlice(p, ev.tag),
            .style = if (ev.flag) .flow else .block,
        } },
        .mapping_end => .mapping_end,
        .scalar => .{ .scalar = .{
            .anchor = optSlice(p, ev.anchor),
            .tag = optSlice(p, ev.tag),
            .value = p.slice(ev.value),
            .style = switch (ev.style) {
                .plain => .plain,
                .single_quoted => .single_quoted,
                .double_quoted => .double_quoted,
                .literal => .literal,
                .folded => .folded,
            },
        } },
        .alias => .{ .alias = .{ .name = p.slice(ev.value) } },
    };
}

test convert {
    var s = initCompleteInput(std.testing.allocator, "!!str &x hello\n");
    defer s.deinit();
    const raw = try s.rawEvents();
    const scalar = s.convert(raw[2]).scalar;
    try std.testing.expectEqualStrings("hello", scalar.value);
    try std.testing.expectEqualStrings("x", scalar.anchor.?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", scalar.tag.?);
}

/// Whether `s` points into the input the scanner was given, which is how a
/// caller parsing with `.alloc_if_needed` knows a string can be kept without
/// copying.
pub fn isInInput(self: *const Scanner, s: []const u8) bool {
    if (self.transcoded != null) return false;
    const lo = @intFromPtr(self.input.ptr);
    const p = @intFromPtr(s.ptr);
    return p >= lo and p + s.len <= lo + self.input.len;
}

test isInInput {
    var s = initCompleteInput(std.testing.allocator, "- plain\n- \"esc\\x41ped\"\n");
    defer s.deinit();
    _ = try s.next(); // stream_start
    _ = try s.next(); // document_start
    _ = try s.next(); // sequence_start
    try std.testing.expect(s.isInInput((try s.next()).scalar.value));
    // An escape had to be decoded, so the content is a copy.
    try std.testing.expect(!s.isInInput((try s.next()).scalar.value));
}

test "aliases are replayed" {
    var s = initCompleteInput(std.testing.allocator, "a: &x [1, 2]\nb: *x\n");
    defer s.deinit();
    var seqs: usize = 0;
    while (true) {
        const ev = try s.next();
        if (ev == .sequence_start) seqs += 1;
        if (ev == .alias) return error.TestUnexpectedResult;
        if (ev == .stream_end) break;
    }
    try std.testing.expectEqual(2, seqs);
}

test "an alias to nothing is an error" {
    var s = initCompleteInput(std.testing.allocator, "a: *nothing\n");
    defer s.deinit();
    try std.testing.expectError(error.UndefinedAlias, s.next());
}

test "alias expansion is bounded" {
    const laughs =
        \\a: &a [x, x, x, x, x, x, x, x]
        \\b: &b [*a, *a, *a, *a, *a, *a, *a, *a]
        \\c: &c [*b, *b, *b, *b, *b, *b, *b, *b]
        \\d: &d [*c, *c, *c, *c, *c, *c, *c, *c]
        \\
    ;
    var s = initCompleteInput(std.testing.allocator, laughs);
    defer s.deinit();
    s.max_alias_expansion = 1000;
    while (true) {
        const ev = s.next() catch |err| {
            try std.testing.expectEqual(error.AliasExpansionLimit, err);
            return;
        };
        if (ev == .stream_end) return error.TestUnexpectedResult;
    }
}
