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

/// A reader over `reader`, which is not read from until the first call to
/// `next`, `peek`, `peekNextEventType` or `skipValue`. `gpa` holds the
/// stream once it is read, and everything the scanner allocates.
pub fn init(gpa: Allocator, reader: *std.Io.Reader) Reader {
    return .{ .gpa = gpa, .reader = reader, .scanner = .initCompleteInput(gpa, "") };
}

test init {
    var source: std.Io.Reader = .fixed("a: 1\n");
    var reader: Reader = .init(std.testing.allocator, &source);
    defer reader.deinit();
    try std.testing.expectEqual(.stream_start, try reader.peekNextEventType());
}

/// Frees the stream and everything parsed from it. Every string an event
/// carried is invalid afterwards.
pub fn deinit(self: *Reader) void {
    self.scanner.deinit();
    if (self.input) |i| self.gpa.free(i);
    self.* = undefined;
}

test deinit {
    var source: std.Io.Reader = .fixed("- x\n");
    var reader: Reader = .init(std.testing.allocator, &source);
    _ = try reader.next();
    reader.deinit();
}

/// The scanner that does the work, for setting its limits —
/// `resolve_aliases`, `max_depth`, `max_alias_expansion` — before the first
/// call.
pub fn inner(self: *Reader) *Scanner {
    return &self.scanner;
}

test inner {
    var source: std.Io.Reader = .fixed("a: &x 1\nb: *x\n");
    var reader: Reader = .init(std.testing.allocator, &source);
    defer reader.deinit();
    reader.inner().resolve_aliases = false;
    var aliases: usize = 0;
    while (true) switch (try reader.next()) {
        .alias => aliases += 1,
        .stream_end => break,
        else => {},
    };
    try std.testing.expectEqual(1, aliases);
}

/// Has `d` track where the reader is, so that an error can be reported by
/// line and column. `d` must outlive the reader.
pub fn enableDiagnostics(self: *Reader, d: *Scanner.Diagnostics) void {
    self.scanner.enableDiagnostics(d);
}

test enableDiagnostics {
    var source: std.Io.Reader = .fixed("a: b\nc: [d\n");
    var reader: Reader = .init(std.testing.allocator, &source);
    defer reader.deinit();
    var diagnostics: Scanner.Diagnostics = .{};
    reader.enableDiagnostics(&diagnostics);
    try std.testing.expectError(error.SyntaxError, reader.next());
    try std.testing.expectEqual(3, diagnostics.getLine());
}

fn fill(self: *Reader) Error!void {
    if (self.input != null) return;
    const input = try self.reader.allocRemaining(self.gpa, .limited(self.max_input_len));
    self.input = input;
    self.scanner.input = input;
    if (self.scanner.diagnostics) |d| d.input = input;
}

/// The next event, as `Scanner.next`. The first call reads the whole stream.
pub fn next(self: *Reader) Error!event.Event {
    try self.fill();
    return self.scanner.next();
}

test next {
    var source: std.Io.Reader = .fixed("hello\n");
    var reader: Reader = .init(std.testing.allocator, &source);
    defer reader.deinit();
    try std.testing.expectEqual(.stream_start, try reader.next());
    try std.testing.expect(try reader.next() == .document_start);
    try std.testing.expectEqualStrings("hello", (try reader.next()).scalar.value);
}

/// The event `next` would return, without consuming it.
pub fn peek(self: *Reader) Error!event.Event {
    try self.fill();
    return self.scanner.peek();
}

test peek {
    var source: std.Io.Reader = .fixed("hello\n");
    var reader: Reader = .init(std.testing.allocator, &source);
    defer reader.deinit();
    try std.testing.expectEqual(.stream_start, try reader.peek());
    try std.testing.expectEqual(.stream_start, try reader.next());
}

/// The type of the event `next` would return, without consuming it.
pub fn peekNextEventType(self: *Reader) Error!event.EventType {
    try self.fill();
    return self.scanner.peekNextEventType();
}

test peekNextEventType {
    var source: std.Io.Reader = .fixed("[1, 2]\n");
    var reader: Reader = .init(std.testing.allocator, &source);
    defer reader.deinit();
    _ = try reader.next();
    _ = try reader.next();
    try std.testing.expectEqual(.sequence_start, try reader.peekNextEventType());
}

/// Skips one whole node, as `Scanner.skipValue`.
pub fn skipValue(self: *Reader) Error!void {
    try self.fill();
    return self.scanner.skipValue();
}

test skipValue {
    var source: std.Io.Reader = .fixed("[[1, 2], 3]\n");
    var reader: Reader = .init(std.testing.allocator, &source);
    defer reader.deinit();
    _ = try reader.next(); // stream_start
    _ = try reader.next(); // document_start
    _ = try reader.next(); // the outer sequence_start
    try reader.skipValue(); // [1, 2]
    try std.testing.expectEqualStrings("3", (try reader.next()).scalar.value);
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
