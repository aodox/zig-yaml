// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Chapter 5 of YAML 1.2.2, "Character Productions": productions [1]–[62].
//!
//! These are character classes rather than productions that consume input,
//! so they are predicates over a code point. The escape sequences of [41]–
//! [62] are decoded here too, since what an escape *means* is a property of
//! the characters rather than of the double-quoted scalar that uses it.
//!
//! Also here is the encoding detection of §5.2: a YAML stream may be UTF-8,
//! UTF-16 or UTF-32, and everything after this file assumes UTF-8.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A decoded code point and the number of bytes it took.
pub const Cp = struct { cp: u21, len: u3 };

/// Decodes the code point at the start of `bytes`, or null if it is not
/// valid UTF-8.
pub fn decode(bytes: []const u8) ?Cp {
    if (bytes.len == 0) return null;
    const b0 = bytes[0];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(b0) catch return null;
    if (bytes.len < len) return null;
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return null;
    return .{ .cp = cp, .len = @intCast(len) };
}

test decode {
    try std.testing.expectEqual(Cp{ .cp = 'a', .len = 1 }, decode("ab").?);
    try std.testing.expectEqual(Cp{ .cp = 0x20AC, .len = 3 }, decode("€").?);
    try std.testing.expectEqual(null, decode("\xE2\x82")); // cut short
    try std.testing.expectEqual(null, decode(""));
}

/// Decodes the code point that ends `bytes`, or null if `bytes` does not
/// end with a whole, valid UTF-8 sequence.
pub fn decodeLast(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    var i = bytes.len - 1;
    var n: usize = 0;
    while (n < 3 and i > 0 and bytes[i] & 0xC0 == 0x80) : (n += 1) i -= 1;
    const cp = decode(bytes[i..]) orelse return null;
    if (i + cp.len != bytes.len) return null;
    return cp.cp;
}

/// `<start-of-line>`, which the grammar uses without defining. The start of
/// the input, just after a line break, or just after a byte order mark that
/// itself stands at the start of a line (§9.1.1 allows one before each
/// document).
pub fn isStartOfLine(input: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    const prev = input[pos - 1];
    if (prev == '\n' or prev == '\r') return true;
    if (pos >= 3 and std.mem.eql(u8, input[pos - 3 .. pos], bom_utf8))
        return isStartOfLine(input, pos - 3);
    return false;
}

test isStartOfLine {
    try std.testing.expect(isStartOfLine("a\nb", 0));
    try std.testing.expect(!isStartOfLine("a\nb", 1));
    try std.testing.expect(isStartOfLine("a\nb", 2));
    try std.testing.expect(isStartOfLine(bom_utf8 ++ "a", 3));
}

pub const bom_utf8 = "\xEF\xBB\xBF";

/// [1] c-printable
pub fn isPrintable(c: u21) bool {
    return switch (c) {
        0x09, 0x0A, 0x0D, 0x20...0x7E, 0x85 => true,
        0xA0...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF => true,
        else => false,
    };
}

test isPrintable {
    try std.testing.expect(isPrintable('\t'));
    try std.testing.expect(isPrintable(0x1F600));
    try std.testing.expect(!isPrintable(0x07));
    try std.testing.expect(!isPrintable(0xFFFE));
}

/// [2] nb-json
pub fn isNbJson(c: u21) bool {
    return c == 0x09 or c >= 0x20;
}

test isNbJson {
    try std.testing.expect(isNbJson('\t'));
    try std.testing.expect(isNbJson(0x07) == false);
    try std.testing.expect(isNbJson(0xFFFE));
}

/// [3] c-byte-order-mark
pub const byte_order_mark: u21 = 0xFEFF;

/// [22] c-indicator
pub fn isIndicator(c: u21) bool {
    return switch (c) {
        '-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => true,
        else => false,
    };
}

test isIndicator {
    try std.testing.expect(isIndicator('&'));
    try std.testing.expect(isIndicator('`'));
    try std.testing.expect(!isIndicator('a'));
}

/// [23] c-flow-indicator
pub fn isFlowIndicator(c: u21) bool {
    return switch (c) {
        ',', '[', ']', '{', '}' => true,
        else => false,
    };
}

test isFlowIndicator {
    try std.testing.expect(isFlowIndicator(','));
    try std.testing.expect(!isFlowIndicator(':'));
}

/// [26] b-char
pub fn isBreak(c: u21) bool {
    return c == '\n' or c == '\r';
}

test isBreak {
    try std.testing.expect(isBreak('\r'));
    try std.testing.expect(!isBreak(0x85)); // NEL is not a line break in YAML 1.2
}

/// [27] nb-char
pub fn isNbChar(c: u21) bool {
    return isPrintable(c) and !isBreak(c) and c != byte_order_mark;
}

test isNbChar {
    try std.testing.expect(isNbChar(' '));
    try std.testing.expect(!isNbChar('\n'));
    try std.testing.expect(!isNbChar(byte_order_mark));
}

/// [33] s-white
pub fn isWhite(c: u21) bool {
    return c == ' ' or c == '\t';
}

test isWhite {
    try std.testing.expect(isWhite('\t'));
    try std.testing.expect(!isWhite(0xA0));
}

/// [34] ns-char
pub fn isNsChar(c: u21) bool {
    return isNbChar(c) and !isWhite(c);
}

test isNsChar {
    try std.testing.expect(isNsChar('x'));
    try std.testing.expect(!isNsChar(' '));
    try std.testing.expect(!isNsChar('\n'));
}

/// [35] ns-dec-digit
pub fn isDecDigit(c: u21) bool {
    return c >= '0' and c <= '9';
}

test isDecDigit {
    try std.testing.expect(isDecDigit('7'));
    try std.testing.expect(!isDecDigit('a'));
}

/// [36] ns-hex-digit
pub fn isHexDigit(c: u21) bool {
    return isDecDigit(c) or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f');
}

test isHexDigit {
    try std.testing.expect(isHexDigit('f'));
    try std.testing.expect(isHexDigit('F'));
    try std.testing.expect(!isHexDigit('g'));
}

/// [37] ns-ascii-letter
pub fn isAsciiLetter(c: u21) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

test isAsciiLetter {
    try std.testing.expect(isAsciiLetter('Z'));
    try std.testing.expect(!isAsciiLetter('é'));
}

/// [38] ns-word-char
pub fn isWordChar(c: u21) bool {
    return isDecDigit(c) or isAsciiLetter(c) or c == '-';
}

test isWordChar {
    try std.testing.expect(isWordChar('-'));
    try std.testing.expect(!isWordChar('_'));
}

/// [39] ns-uri-char, less its `'%' ns-hex-digit{2}` alternative, which spans
/// three characters and is matched by the caller.
pub fn isUriCharSingle(c: u21) bool {
    if (isWordChar(c)) return true;
    return switch (c) {
        '#', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '_', '.', '!', '~', '*', '\'', '(', ')', '[', ']' => true,
        else => false,
    };
}

test isUriCharSingle {
    try std.testing.expect(isUriCharSingle('/'));
    try std.testing.expect(!isUriCharSingle('%')); // only as part of an escape
    try std.testing.expect(!isUriCharSingle('<'));
}

/// [40] ns-tag-char, likewise less the percent escape.
pub fn isTagCharSingle(c: u21) bool {
    return isUriCharSingle(c) and c != '!' and !isFlowIndicator(c);
}

test isTagCharSingle {
    try std.testing.expect(isTagCharSingle(':'));
    try std.testing.expect(!isTagCharSingle('!'));
    try std.testing.expect(!isTagCharSingle(','));
}

/// [102] ns-anchor-char
pub fn isAnchorChar(c: u21) bool {
    return isNsChar(c) and !isFlowIndicator(c);
}

test isAnchorChar {
    try std.testing.expect(isAnchorChar(':'));
    try std.testing.expect(!isAnchorChar(']'));
}

/// [41]–[62] c-ns-esc-char, less the leading backslash: what the escape
/// introduced by `c` stands for, and how many hex digits follow it.
pub const Escape = union(enum) {
    char: u21,
    hex: u4,
};

/// What the escape `\c` stands for in a double-quoted scalar, or null if
/// there is no such escape.
pub fn escape(c: u8) ?Escape {
    return switch (c) {
        '0' => .{ .char = 0x00 }, // [42] ns-esc-null
        'a' => .{ .char = 0x07 }, // [43] ns-esc-bell
        'b' => .{ .char = 0x08 }, // [44] ns-esc-backspace
        't', '\t' => .{ .char = 0x09 }, // [45] ns-esc-horizontal-tab
        'n' => .{ .char = 0x0A }, // [46] ns-esc-line-feed
        'v' => .{ .char = 0x0B }, // [47] ns-esc-vertical-tab
        'f' => .{ .char = 0x0C }, // [48] ns-esc-form-feed
        'r' => .{ .char = 0x0D }, // [49] ns-esc-carriage-return
        'e' => .{ .char = 0x1B }, // [50] ns-esc-escape
        ' ' => .{ .char = 0x20 }, // [51] ns-esc-space
        '"' => .{ .char = '"' }, // [52] ns-esc-double-quote
        '/' => .{ .char = '/' }, // [53] ns-esc-slash
        '\\' => .{ .char = '\\' }, // [54] ns-esc-backslash
        'N' => .{ .char = 0x85 }, // [55] ns-esc-next-line
        '_' => .{ .char = 0xA0 }, // [56] ns-esc-non-breaking-space
        'L' => .{ .char = 0x2028 }, // [57] ns-esc-line-separator
        'P' => .{ .char = 0x2029 }, // [58] ns-esc-paragraph-separator
        'x' => .{ .hex = 2 }, // [59] ns-esc-8-bit
        'u' => .{ .hex = 4 }, // [60] ns-esc-16-bit
        'U' => .{ .hex = 8 }, // [61] ns-esc-32-bit
        else => null,
    };
}

test escape {
    try std.testing.expectEqual(Escape{ .char = '\n' }, escape('n').?);
    try std.testing.expectEqual(Escape{ .hex = 4 }, escape('u').?);
    try std.testing.expectEqual(null, escape('q'));
}

/// The value of a hexadecimal digit, or null if `c` is not one.
pub fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test hexValue {
    try std.testing.expectEqual(11, hexValue('b'));
    try std.testing.expectEqual(null, hexValue('g'));
}

// -- §5.2 character encodings -----------------------------------------------

/// The encodings §5.2 allows a stream to be in.
pub const Encoding = enum { utf8, utf16le, utf16be, utf32le, utf32be };

/// Detects the encoding of a stream from its first bytes, by the table in
/// §5.2: a byte order mark if there is one, otherwise the pattern of null
/// bytes an ASCII first character makes.
pub fn detectEncoding(b: []const u8) Encoding {
    if (b.len >= 4 and b[0] == 0 and b[1] == 0 and b[2] == 0xFE and b[3] == 0xFF) return .utf32be;
    if (b.len >= 4 and b[0] == 0 and b[1] == 0 and b[2] == 0 and b[3] != 0) return .utf32be;
    if (b.len >= 4 and b[0] == 0xFF and b[1] == 0xFE and b[2] == 0 and b[3] == 0) return .utf32le;
    if (b.len >= 4 and b[0] != 0 and b[1] == 0 and b[2] == 0 and b[3] == 0) return .utf32le;
    if (b.len >= 2 and b[0] == 0xFE and b[1] == 0xFF) return .utf16be;
    if (b.len >= 2 and b[0] == 0 and b[1] != 0) return .utf16be;
    if (b.len >= 2 and b[0] == 0xFF and b[1] == 0xFE) return .utf16le;
    if (b.len >= 2 and b[0] != 0 and b[1] == 0) return .utf16le;
    return .utf8;
}

/// Converts a UTF-16 or UTF-32 stream to UTF-8, keeping any byte order mark
/// (as its UTF-8 encoding), since the grammar has a place for it. Returns
/// null when the input is UTF-8 already.
pub fn toUtf8(gpa: Allocator, input: []const u8) (Allocator.Error || error{InvalidEncoding})!?[]u8 {
    const enc = detectEncoding(input);
    if (enc == .utf8) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    switch (enc) {
        .utf8 => unreachable,
        .utf16le, .utf16be => {
            if (input.len % 2 != 0) return error.InvalidEncoding;
            while (i < input.len) {
                const unit = readUnit16(input[i..][0..2], enc == .utf16be);
                i += 2;
                var cp: u21 = unit;
                if (unit >= 0xD800 and unit <= 0xDBFF) {
                    if (i + 2 > input.len) return error.InvalidEncoding;
                    const low = readUnit16(input[i..][0..2], enc == .utf16be);
                    if (low < 0xDC00 or low > 0xDFFF) return error.InvalidEncoding;
                    i += 2;
                    cp = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (low - 0xDC00);
                } else if (unit >= 0xDC00 and unit <= 0xDFFF) return error.InvalidEncoding;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEncoding;
                try out.appendSlice(gpa, buf[0..n]);
            }
        },
        .utf32le, .utf32be => {
            if (input.len % 4 != 0) return error.InvalidEncoding;
            while (i < input.len) : (i += 4) {
                const unit = if (enc == .utf32be)
                    std.mem.readInt(u32, input[i..][0..4], .big)
                else
                    std.mem.readInt(u32, input[i..][0..4], .little);
                if (unit > 0x10FFFF) return error.InvalidEncoding;
                const n = std.unicode.utf8Encode(@intCast(unit), &buf) catch return error.InvalidEncoding;
                try out.appendSlice(gpa, buf[0..n]);
            }
        },
    }
    return try out.toOwnedSlice(gpa);
}

fn readUnit16(b: *const [2]u8, big: bool) u16 {
    return if (big) std.mem.readInt(u16, b, .big) else std.mem.readInt(u16, b, .little);
}

test detectEncoding {
    try std.testing.expectEqual(Encoding.utf8, detectEncoding("a: b"));
    try std.testing.expectEqual(Encoding.utf16le, detectEncoding("a\x00:\x00"));
    try std.testing.expectEqual(Encoding.utf16be, detectEncoding("\xFE\xFF\x00a"));
    try std.testing.expectEqual(Encoding.utf32le, detectEncoding("a\x00\x00\x00"));
    try std.testing.expectEqual(Encoding.utf32be, detectEncoding("\x00\x00\x00a"));
}

test toUtf8 {
    const gpa = std.testing.allocator;
    const out = (try toUtf8(gpa, "\xFF\xFEa\x00\xe9\x00")).?;
    defer gpa.free(out);
    try std.testing.expectEqualStrings("\xEF\xBB\xBFa\xC3\xA9", out);
    try std.testing.expectEqual(null, try toUtf8(gpa, "plain"));
}

test decodeLast {
    try std.testing.expectEqual('a', decodeLast("xa").?);
    try std.testing.expectEqual(0xE9, decodeLast("x\xC3\xA9").?);
    try std.testing.expectEqual(null, decodeLast(""));
}
