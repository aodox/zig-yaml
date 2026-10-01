// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! YAML 1.2.2 for Zig, with the shape of `std.json`.
//!
//! Parsing into a type:
//!
//!     const Config = struct { name: []const u8, port: u16 = 8080 };
//!     const parsed = try yaml.parseFromSlice(Config, gpa, source, .{});
//!     defer parsed.deinit();
//!
//! into a tree of values when there is no type (`Value`), or event by event
//! (`Scanner`). Writing is `Stringify.value`, `Stringify.valueAlloc`, or `fmt`
//! for a format string.
//!
//! The parser is written from the grammar of the YAML 1.2.2 specification —
//! one function per numbered production, in `grammar/` — and passes every
//! case of the yaml-test-suite.

const std = @import("std");

const event = @import("event.zig");
pub const Event = event.Event;
pub const EventType = event.EventType;
pub const ScalarStyle = event.ScalarStyle;
pub const CollectionStyle = event.CollectionStyle;

pub const Scanner = @import("Scanner.zig");
pub const Diagnostics = Scanner.Diagnostics;
pub const Reader = @import("Reader.zig");

const schema = @import("schema.zig");
pub const Schema = schema.Schema;

const dynamic = @import("dynamic.zig");
pub const Value = dynamic.Value;
pub const Sequence = dynamic.Sequence;
pub const Mapping = dynamic.Mapping;

const static = @import("static.zig");
pub const ParseOptions = static.ParseOptions;
pub const AllocWhen = static.AllocWhen;
pub const ParseError = static.ParseError;
pub const ParseFromValueError = static.ParseFromValueError;
pub const Parsed = static.Parsed;
pub const parseFromSlice = static.parseFromSlice;
pub const parseFromSliceLeaky = static.parseFromSliceLeaky;
pub const parseAllFromSlice = static.parseAllFromSlice;
pub const parseAllFromSliceLeaky = static.parseAllFromSliceLeaky;
pub const parseFromTokenSource = static.parseFromTokenSource;
pub const parseFromTokenSourceLeaky = static.parseFromTokenSourceLeaky;
pub const parseAllFromTokenSource = static.parseAllFromTokenSource;
pub const parseAllFromTokenSourceLeaky = static.parseAllFromTokenSourceLeaky;
pub const parseFromValue = static.parseFromValue;
pub const parseFromValueLeaky = static.parseFromValueLeaky;
pub const innerParse = static.innerParse;
pub const innerParseFromValue = static.innerParseFromValue;

pub const Stringify = @import("Stringify.zig");

/// A formatter for `{f}` that writes `value` as a YAML document.
pub fn fmt(value: anytype, options: Stringify.Options) Formatter(@TypeOf(value)) {
    return .{ .value = value, .options = options };
}

pub fn Formatter(comptime T: type) type {
    return struct {
        value: T,
        options: Stringify.Options,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try Stringify.value(self.value, self.options, writer);
        }
    };
}

/// The grammar, for tools that want the raw event list.
pub const grammar = struct {
    pub const Parser = @import("grammar/Parser.zig");
};

test fmt {
    var buf: [64]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{f}", .{fmt(.{ .a = 1 }, .{})});
    try std.testing.expectEqualStrings("a: 1\n", out);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("grammar/chars.zig");
    _ = @import("grammar/basic.zig");
    _ = @import("grammar/flow.zig");
    _ = @import("grammar/block.zig");
    _ = @import("grammar/stream.zig");
    _ = @import("tests.zig");
}
