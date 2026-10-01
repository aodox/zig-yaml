// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Events from a `std.Io.Reader`, the counterpart of `std.json.Reader`.
//!
//! Unlike its JSON namesake this is not incremental. The YAML grammar
//! backtracks — whether a line is a key can depend on what follows it — so
//! no event can be handed out until the parse has seen the whole stream. The
//! first call reads the stream to its end, up to `max_input_len` bytes, and
//! from then on this is a `Scanner` over what it read.

const std = @import("std");
const Allocator = std.mem.Allocator;

const event = @import("event.zig");
const Scanner = @import("Scanner.zig");

const Reader = @This();

pub const Error = Scanner.Error || std.Io.Reader.LimitedAllocError;
pub const NextError = Error;
pub const PeekError = Error;
pub const AllocError = Allocator.Error;

gpa: Allocator,
reader: *std.Io.Reader,
/// The most the stream may hold.
max_input_len: usize = 64 << 20,
input: ?[]u8 = null,
scanner: Scanner,

pub fn init(gpa: Allocator, reader: *std.Io.Reader) Reader {
    return .{ .gpa = gpa, .reader = reader, .scanner = .initCompleteInput(gpa, "") };
}

pub fn deinit(self: *Reader) void {
    self.scanner.deinit();
    if (self.input) |i| self.gpa.free(i);
    self.* = undefined;
}

/// The scanner that does the work, for setting its limits before the first
/// call.
pub fn inner(self: *Reader) *Scanner {
    return &self.scanner;
}

pub fn enableDiagnostics(self: *Reader, d: *Scanner.Diagnostics) void {
    self.scanner.diagnostics = d;
}

fn fill(self: *Reader) Error!void {
    if (self.input != null) return;
    const input = try self.reader.allocRemaining(self.gpa, .limited(self.max_input_len));
    self.input = input;
    self.scanner.input = input;
    if (self.scanner.diagnostics) |d| d.input = input;
}

pub fn next(self: *Reader) Error!event.Event {
    try self.fill();
    return self.scanner.next();
}

pub fn peek(self: *Reader) Error!event.Event {
    try self.fill();
    return self.scanner.peek();
}

pub fn peekNextEventType(self: *Reader) Error!event.EventType {
    try self.fill();
    return self.scanner.peekNextEventType();
}

pub fn skipValue(self: *Reader) Error!void {
    try self.fill();
    return self.scanner.skipValue();
}

test "parsing from a reader" {
    const static = @import("static.zig");
    var source: std.Io.Reader = .fixed("name: x\nport: 80\n");
    var reader: Reader = .init(std.testing.allocator, &source);
    defer reader.deinit();
    const parsed = try static.parseFromTokenSource(struct { name: []const u8, port: u16 }, std.testing.allocator, &reader, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("x", parsed.value.name);
    try std.testing.expectEqual(80, parsed.value.port);
}
