// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Writes an event stream in the notation of the yaml-test-suite's
//! `test.event` files, one event per line:
//!
//!     +STR  -STR            stream start and end
//!     +DOC ---  -DOC ...    document start and end, with explicit markers
//!     +MAP {} &a <tag>      mapping start: flow style, anchor, tag
//!     +SEQ [] &a <tag>      sequence start, likewise
//!     -MAP  -SEQ            collection ends
//!     =VAL &a <tag> :text   scalar; the character before the text is its
//!                           style: `:` plain, `'` `"` quoted, `|` `>` block
//!     =ALI *a               alias
//!
//! with backslash, line feed, carriage return, tab and backspace in scalar
//! text written as escapes so that each event stays on one line.

const std = @import("std");
const yaml = @import("yaml");

pub fn write(w: *std.Io.Writer, ev: yaml.Event) std.Io.Writer.Error!void {
    switch (ev) {
        .stream_start => try w.writeAll("+STR"),
        .stream_end => try w.writeAll("-STR"),
        .document_start => |d| try w.writeAll(if (d.explicit) "+DOC ---" else "+DOC"),
        .document_end => |d| try w.writeAll(if (d.explicit) "-DOC ..." else "-DOC"),
        .sequence_start => |c| {
            try w.writeAll("+SEQ");
            if (c.style == .flow) try w.writeAll(" []");
            try properties(w, c.anchor, c.tag);
        },
        .mapping_start => |c| {
            try w.writeAll("+MAP");
            if (c.style == .flow) try w.writeAll(" {}");
            try properties(w, c.anchor, c.tag);
        },
        .sequence_end => try w.writeAll("-SEQ"),
        .mapping_end => try w.writeAll("-MAP"),
        .scalar => |s| {
            try w.writeAll("=VAL");
            try properties(w, s.anchor, s.tag);
            try w.writeByte(' ');
            try w.writeByte(switch (s.style) {
                .plain => ':',
                .single_quoted => '\'',
                .double_quoted => '"',
                .literal => '|',
                .folded => '>',
            });
            for (s.value) |b| switch (b) {
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                else => try w.writeByte(b),
            };
        },
        .alias => |a| try w.print("=ALI *{s}", .{a.name}),
    }
    try w.writeByte('\n');
}

fn properties(w: *std.Io.Writer, anchor: ?[]const u8, tag: ?[]const u8) std.Io.Writer.Error!void {
    if (anchor) |a| try w.print(" &{s}", .{a});
    if (tag) |t| try w.print(" <{s}>", .{t});
}

/// Renders the whole event stream of `input`, with aliases left as aliases.
pub fn render(gpa: std.mem.Allocator, input: []const u8) (yaml.Scanner.Error || std.Io.Writer.Error)![]u8 {
    var scanner: yaml.Scanner = .initCompleteInput(gpa, input);
    defer scanner.deinit();
    scanner.resolve_aliases = false;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    while (true) {
        const ev = try scanner.next();
        try write(&out.writer, ev);
        if (ev == .stream_end) break;
    }
    return out.toOwnedSlice();
}
