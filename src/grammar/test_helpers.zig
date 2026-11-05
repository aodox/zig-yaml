// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What the grammar's doctests share: running one production on a string
//! and saying what it did — whether it matched, what of the input it left,
//! what content it built, and what events it emitted.
//!
//! Events are written in a compact form of the yaml-test-suite's notation,
//! separated by spaces: `+SEQ [] =VAL :a -SEQ`. A scalar's text follows the
//! character for its style (`:` plain, `'` `"` quoted, `|` `>` block), with
//! a line feed written `\n`.

const std = @import("std");
const testing = std.testing;

const Parser = @import("Parser.zig");

/// A production run on an input, which holds the parser it ran on.
pub const Run = struct {
    p: Parser,
    matched: bool,

    /// Frees the parser, and with it everything the run produced.
    pub fn deinit(r: *Run) void {
        r.p.deinit();
    }

    /// The input after where the production stopped.
    pub fn rest(r: *const Run) []const u8 {
        return r.p.input[r.p.pos..];
    }

    /// Scalar content built in the scratch buffer and not yet emitted.
    pub fn content(r: *const Run) []const u8 {
        return r.p.scratch.items;
    }

    /// Checks the events emitted against `expected`, in the notation above.
    pub fn expectEvents(r: *const Run, expected: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const w = &out.writer;
        for (r.p.events.items, 0..) |ev, i| {
            if (i > 0) try w.writeByte(' ');
            try writeEvent(&r.p, w, ev);
        }
        try testing.expectEqualStrings(expected, out.written());
    }
};

fn writeEvent(p: *const Parser, w: *std.Io.Writer, ev: Parser.RawEvent) !void {
    switch (ev.kind) {
        .stream_start => try w.writeAll("+STR"),
        .stream_end => try w.writeAll("-STR"),
        .document_start => try w.writeAll(if (ev.flag) "+DOC ---" else "+DOC"),
        .document_end => try w.writeAll(if (ev.flag) "-DOC ..." else "-DOC"),
        .sequence_start, .mapping_start => {
            const flow_marker = if (ev.kind == .sequence_start) " []" else " {}";
            try w.writeAll(if (ev.kind == .sequence_start) "+SEQ" else "+MAP");
            if (ev.flag) try w.writeAll(flow_marker);
            try properties(p, w, ev);
        },
        .sequence_end => try w.writeAll("-SEQ"),
        .mapping_end => try w.writeAll("-MAP"),
        .scalar => {
            try w.writeAll("=VAL");
            try properties(p, w, ev);
            try w.writeByte(' ');
            try w.writeByte(switch (ev.style) {
                .plain => ':',
                .single_quoted => '\'',
                .double_quoted => '"',
                .literal => '|',
                .folded => '>',
            });
            for (p.slice(ev.value)) |b| switch (b) {
                '\n' => try w.writeAll("\\n"),
                else => try w.writeByte(b),
            };
        },
        .alias => try w.print("=ALI *{s}", .{p.slice(ev.value)}),
    }
}

fn properties(p: *const Parser, w: *std.Io.Writer, ev: Parser.RawEvent) !void {
    if (!ev.anchor.isNone()) try w.print(" &{s}", .{p.slice(ev.anchor)});
    if (!ev.tag.isNone()) try w.print(" <{s}>", .{p.slice(ev.tag)});
}

/// Runs `production` on `input` with the parser first and `args` after it.
/// A production returning `void`, or an error union of it, always matches.
pub fn run(input: []const u8, comptime production: anytype, args: anytype) !Run {
    var p = try Parser.init(testing.allocator, input);
    errdefer p.deinit();
    const returned = @call(.auto, production, .{&p} ++ args);
    const result = if (@typeInfo(@TypeOf(returned)) == .error_union) try returned else returned;
    const matched = if (@TypeOf(result) == void) true else result;
    return .{ .p = p, .matched = matched };
}

test run {
    var r = try run("ab", Parser.eat, .{'a'});
    defer r.deinit();
    try testing.expect(r.matched);
    try testing.expectEqualStrings("b", r.rest());
}

/// Checks that `production` matches `input`, leaving `rest` unread.
pub fn expectMatch(input: []const u8, comptime production: anytype, args: anytype, rest: []const u8) !void {
    var r = try run(input, production, args);
    defer r.deinit();
    try testing.expect(r.matched);
    try testing.expectEqualStrings(rest, r.rest());
}

test expectMatch {
    try expectMatch("---\n", Parser.eatStr, .{"---"}, "\n");
}

/// Checks that `production` does not match `input`, and that it left the
/// parser as it found it.
pub fn expectNoMatch(input: []const u8, comptime production: anytype, args: anytype) !void {
    var r = try run(input, production, args);
    defer r.deinit();
    try testing.expect(!r.matched);
    try testing.expectEqual(0, r.p.pos);
    try testing.expectEqual(0, r.p.events.items.len);
    try testing.expectEqual(0, r.p.scratch.items.len);
    try testing.expect(r.p.props.isEmpty());
}

test expectNoMatch {
    try expectNoMatch("ab", Parser.eatStr, .{"ac"});
}

/// Checks that `production` matches all of `input` and emits `expected`.
pub fn expectEvents(input: []const u8, comptime production: anytype, args: anytype, expected: []const u8) !void {
    var r = try run(input, production, args);
    defer r.deinit();
    try testing.expect(r.matched);
    try testing.expectEqualStrings("", r.rest());
    try r.expectEvents(expected);
}

test expectEvents {
    try expectEvents("", Parser.emitEmpty, .{}, "=VAL :");
}

test Run {
    var r = try run("x", Parser.appendContent, .{"built"});
    defer r.deinit();
    try testing.expectEqualStrings("built", r.content());
    try testing.expectEqualStrings("x", r.rest());
    try r.expectEvents("");
}
