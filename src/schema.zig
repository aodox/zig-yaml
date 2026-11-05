// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Chapter 10 of YAML 1.2.2, "Recommended Schemas": how a scalar's text
//! becomes a null, a boolean, a number or a string.
//!
//! The grammar decides only what a scalar's text *is*; whether `true` is a
//! boolean or four letters is decided here, by the schema. Only plain
//! scalars with no tag are resolved this way — a quoted or block scalar, or
//! one tagged `!`, is a string — and each schema resolves by matching the
//! regular expressions the specification gives, which are hand-written here
//! as matchers rather than compiled.

const std = @import("std");

pub const Schema = enum {
    /// §10.1: every scalar is a string.
    failsafe,
    /// §10.2: only JSON's literals are recognized, and a plain scalar that is
    /// not one of them is an error.
    json,
    /// §10.3: JSON's literals and the common human spellings of them — `~`,
    /// `True`, `0x1F`, `.inf` — with anything else a string. The default.
    core,
};

/// The prefix of the tags in the YAML tag repository, which `!!` expands to.
pub const tag_prefix = "tag:yaml.org,2002:";

pub const Kind = enum { null, bool, int, float, str };

/// The kind a standard tag names, or null for any other tag.
pub fn tagKind(tag: []const u8) ?Kind {
    if (!std.mem.startsWith(u8, tag, tag_prefix)) return null;
    const name = tag[tag_prefix.len..];
    const map = std.StaticStringMap(Kind).initComptime(.{
        .{ "null", .null }, .{ "bool", .bool }, .{ "int", .int }, .{ "float", .float }, .{ "str", .str },
    });
    return map.get(name);
}

test tagKind {
    try std.testing.expectEqual(.int, tagKind("tag:yaml.org,2002:int"));
    try std.testing.expectEqual(null, tagKind("tag:yaml.org,2002:map"));
    try std.testing.expectEqual(null, tagKind("!local"));
}

/// Resolves an untagged plain scalar. Null means the JSON schema has no
/// resolution for it, which that schema makes an error.
pub fn resolvePlain(schema: Schema, text: []const u8) ?Kind {
    return switch (schema) {
        .failsafe => .str,
        .json => if (isJsonNull(text))
            .null
        else if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false"))
            .bool
        else if (isJsonInt(text))
            .int
        else if (isJsonFloat(text))
            .float
        else
            null,
        .core => if (isCoreNull(text))
            .null
        else if (parseCoreBool(text) != null)
            .bool
        else if (isCoreInt(text))
            .int
        else if (isCoreFloat(text))
            .float
        else
            .str,
    };
}

// -- null --------------------------------------------------------------------

fn isJsonNull(text: []const u8) bool {
    return std.mem.eql(u8, text, "null");
}

/// `null | Null | NULL | ~` and the empty scalar.
pub fn isCoreNull(text: []const u8) bool {
    const forms = [_][]const u8{ "", "~", "null", "Null", "NULL" };
    for (forms) |f| if (std.mem.eql(u8, text, f)) return true;
    return false;
}

test isCoreNull {
    try std.testing.expect(isCoreNull(""));
    try std.testing.expect(isCoreNull("~"));
    try std.testing.expect(!isCoreNull("nULL"));
}

/// Whether `text` is spelled as a null in `schema`; never, in the failsafe
/// schema.
pub fn isNull(schema: Schema, text: []const u8) bool {
    return switch (schema) {
        .failsafe => false,
        .json => isJsonNull(text),
        .core => isCoreNull(text),
    };
}

test isNull {
    try std.testing.expect(isNull(.core, "~"));
    try std.testing.expect(!isNull(.json, "~"));
    try std.testing.expect(!isNull(.failsafe, "null"));
}

// -- bool --------------------------------------------------------------------

/// `true | True | TRUE | false | False | FALSE`
pub fn parseCoreBool(text: []const u8) ?bool {
    const map = std.StaticStringMap(bool).initComptime(.{
        .{ "true", true },   .{ "True", true },   .{ "TRUE", true },
        .{ "false", false }, .{ "False", false }, .{ "FALSE", false },
    });
    return map.get(text);
}

test parseCoreBool {
    try std.testing.expectEqual(true, parseCoreBool("True"));
    try std.testing.expectEqual(null, parseCoreBool("yes"));
}

/// The boolean `text` spells, or null if it spells none. The failsafe
/// schema reads them as the core schema does, for typed parsing, which has
/// the target type to say a boolean is wanted.
pub fn parseBool(schema: Schema, text: []const u8) ?bool {
    return switch (schema) {
        .json => if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else null,
        .failsafe, .core => parseCoreBool(text),
    };
}

test parseBool {
    try std.testing.expectEqual(false, parseBool(.core, "FALSE"));
    try std.testing.expectEqual(null, parseBool(.json, "FALSE"));
    try std.testing.expectEqual(true, parseBool(.failsafe, "true"));
}

// -- int ---------------------------------------------------------------------

fn allDigits(s: []const u8, comptime pred: fn (u8) bool) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!pred(c)) return false;
    return true;
}

fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}

/// `-? ( 0 | [1-9] [0-9]* )`
fn isJsonInt(text: []const u8) bool {
    const digits = if (std.mem.startsWith(u8, text, "-")) text[1..] else text;
    if (!allDigits(digits, std.ascii.isDigit)) return false;
    return digits.len == 1 or digits[0] != '0';
}

/// `[-+]? [0-9]+ | 0o [0-7]+ | 0x [0-9a-fA-F]+`
pub fn isCoreInt(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "0o")) return allDigits(text[2..], isOctal);
    if (std.mem.startsWith(u8, text, "0x")) return allDigits(text[2..], std.ascii.isHex);
    const digits = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    return allDigits(digits, std.ascii.isDigit);
}

test isCoreInt {
    try std.testing.expect(isCoreInt("+12"));
    try std.testing.expect(isCoreInt("0o17"));
    try std.testing.expect(!isCoreInt("0b101"));
    try std.testing.expect(!isCoreInt("-0x1F"));
}

pub const IntError = error{ InvalidNumber, Overflow };

/// Parses an integer in any form the schema recognizes. Under the core
/// schema that includes octal and hexadecimal, and — as `std.json` does for
/// a JSON number — a float whose value happens to be whole. The failsafe
/// schema reads numbers as the core schema does.
pub fn parseInt(comptime T: type, schema: Schema, text: []const u8) IntError!T {
    const is_int = switch (schema) {
        .json => isJsonInt(text),
        .failsafe, .core => isCoreInt(text),
    };
    if (is_int) {
        if (std.mem.startsWith(u8, text, "0o")) return std.fmt.parseInt(T, text[2..], 8) catch |e| mapIntError(e);
        if (std.mem.startsWith(u8, text, "0x")) return std.fmt.parseInt(T, text[2..], 16) catch |e| mapIntError(e);
        return std.fmt.parseInt(T, text, 10) catch |e| mapIntError(e);
    }
    const is_float = switch (schema) {
        .json => isJsonFloat(text),
        .failsafe, .core => isCoreFloat(text),
    };
    if (!is_float) return error.InvalidNumber;
    const f = parseFloat(f128, schema, text) catch return error.InvalidNumber;
    return floatToInt(T, f);
}

/// A whole float as an integer of type `T`.
pub fn floatToInt(comptime T: type, f: anytype) IntError!T {
    if (std.math.isNan(f) or std.math.isInf(f) or @round(f) != f) return error.InvalidNumber;
    // Compared in f128, where the bounds of every integer up to 64 bits are
    // exact; `maxInt + 1` is a power of two and exact for any width.
    const x: f128 = @floatCast(f);
    const hi: f128 = @as(f128, @floatFromInt(std.math.maxInt(T))) + 1;
    const lo: f128 = @floatFromInt(std.math.minInt(T));
    if (x >= hi or x < lo) return error.Overflow;
    return @intFromFloat(x);
}

test floatToInt {
    try std.testing.expectEqual(255, floatToInt(u8, @as(f64, 255.0)));
    try std.testing.expectError(error.Overflow, floatToInt(u8, @as(f64, 256.0)));
    try std.testing.expectError(error.InvalidNumber, floatToInt(u8, @as(f64, 1.5)));
}

fn mapIntError(e: std.fmt.ParseIntError) IntError {
    return switch (e) {
        error.Overflow => error.Overflow,
        error.InvalidCharacter => error.InvalidNumber,
    };
}

// -- float -------------------------------------------------------------------

/// `-? ( 0 | [1-9] [0-9]* ) ( \. [0-9]* )? ( [eE] [-+]? [0-9]+ )?`
fn isJsonFloat(text: []const u8) bool {
    var i: usize = 0;
    if (i < text.len and text[i] == '-') i += 1;
    if (i >= text.len or !std.ascii.isDigit(text[i])) return false;
    if (text[i] == '0') i += 1 else while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    }
    return exponent(text, i);
}

/// `[eE] [-+]? [0-9]+` to the end of `text`, or nothing at all.
fn exponent(text: []const u8, start: usize) bool {
    var i = start;
    if (i == text.len) return true;
    if (text[i] != 'e' and text[i] != 'E') return false;
    i += 1;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) i += 1;
    return allDigits(text[i..], std.ascii.isDigit);
}

const inf_forms = [_][]const u8{ ".inf", ".Inf", ".INF" };
const nan_forms = [_][]const u8{ ".nan", ".NaN", ".NAN" };

fn isOneOf(text: []const u8, forms: []const []const u8) bool {
    for (forms) |f| if (std.mem.eql(u8, text, f)) return true;
    return false;
}

/// `[-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?`,
/// `[-+]? ( \.inf | \.Inf | \.INF )` and `\.nan | \.NaN | \.NAN`.
pub fn isCoreFloat(text: []const u8) bool {
    if (isOneOf(text, &nan_forms)) return true;
    var i: usize = 0;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) i += 1;
    if (isOneOf(text[i..], &inf_forms)) return true;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start) return false;
    } else {
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start) return false;
        if (i < text.len and text[i] == '.') {
            i += 1;
            while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        }
    }
    return exponent(text, i);
}

test isCoreFloat {
    try std.testing.expect(isCoreFloat(".5"));
    try std.testing.expect(isCoreFloat("-.inf"));
    try std.testing.expect(isCoreFloat("1e3"));
    try std.testing.expect(!isCoreFloat("-.nan"));
}

/// Parses a float in any form the schema recognizes, integers included. The
/// failsafe schema reads numbers as the core schema does.
pub fn parseFloat(comptime T: type, schema: Schema, text: []const u8) error{InvalidNumber}!T {
    switch (schema) {
        .json => if (!isJsonFloat(text) and !isJsonInt(text)) return error.InvalidNumber,
        .failsafe, .core => {
            if (isOneOf(text, &nan_forms)) return std.math.nan(T);
            const unsigned = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
            if (isOneOf(unsigned, &inf_forms)) {
                return if (text[0] == '-') -std.math.inf(T) else std.math.inf(T);
            }
            if (isCoreInt(text) and (std.mem.startsWith(u8, text, "0o") or std.mem.startsWith(u8, text, "0x"))) {
                const v = parseInt(i128, schema, text) catch return error.InvalidNumber;
                return @floatFromInt(v);
            }
            if (!isCoreFloat(text) and !isCoreInt(text)) return error.InvalidNumber;
        },
    }
    return std.fmt.parseFloat(T, text) catch error.InvalidNumber;
}

test resolvePlain {
    const t = std.testing;
    try t.expectEqual(Kind.null, resolvePlain(.core, "~").?);
    try t.expectEqual(Kind.null, resolvePlain(.core, "").?);
    try t.expectEqual(Kind.bool, resolvePlain(.core, "True").?);
    try t.expectEqual(Kind.int, resolvePlain(.core, "0x1F").?);
    try t.expectEqual(Kind.int, resolvePlain(.core, "+12").?);
    try t.expectEqual(Kind.float, resolvePlain(.core, "1.5e3").?);
    try t.expectEqual(Kind.float, resolvePlain(.core, "-.INF").?);
    try t.expectEqual(Kind.float, resolvePlain(.core, ".5").?);
    try t.expectEqual(Kind.float, resolvePlain(.core, "1.").?);
    try t.expectEqual(Kind.str, resolvePlain(.core, "1.2.3").?);
    try t.expectEqual(Kind.str, resolvePlain(.core, "yes").?);
    try t.expectEqual(Kind.str, resolvePlain(.core, ".").?);
    try t.expectEqual(Kind.str, resolvePlain(.core, "0x").?);
    try t.expectEqual(Kind.str, resolvePlain(.core, "1e").?);
    try t.expectEqual(null, resolvePlain(.json, "True"));
    try t.expectEqual(Kind.int, resolvePlain(.json, "-0").?);
    try t.expectEqual(null, resolvePlain(.json, "01"));
    try t.expectEqual(Kind.str, resolvePlain(.failsafe, "null").?);
}

test parseInt {
    const t = std.testing;
    try t.expectEqual(31, try parseInt(u8, .core, "0x1F"));
    try t.expectEqual(15, try parseInt(u8, .core, "0o17"));
    try t.expectEqual(-12, try parseInt(i8, .core, "-12"));
    try t.expectEqual(1000, try parseInt(u16, .core, "1e3"));
    try t.expectError(error.Overflow, parseInt(u8, .core, "256"));
    try t.expectError(error.InvalidNumber, parseInt(u8, .core, "1.5"));
    try t.expectError(error.InvalidNumber, parseInt(u8, .json, "0x1F"));
}

test parseFloat {
    const t = std.testing;
    try t.expectEqual(1.5, try parseFloat(f64, .core, "1.5"));
    try t.expectEqual(0.5, try parseFloat(f64, .core, ".5"));
    try t.expectEqual(-std.math.inf(f64), try parseFloat(f64, .core, "-.inf"));
    try t.expect(std.math.isNan(try parseFloat(f64, .core, ".NaN")));
    try t.expectEqual(31, try parseFloat(f64, .core, "0x1F"));
    try t.expectError(error.InvalidNumber, parseFloat(f64, .core, "one"));
}
