// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Chapter 7 of YAML 1.2.2, "Flow Style Productions": productions
//! [104]–[161] — alias nodes, empty nodes, the three flow scalar styles, and
//! flow sequences and mappings.
//!
//! Scalar content is built in the parser's scratch buffer as the productions
//! match: escapes decoded, lines folded, and whatever the grammar marks as
//! not content (indentation, the whitespace around a fold) left out. That
//! way the value a scalar ends up with is exactly what its productions say,
//! with no second pass over the text.

const std = @import("std");

const basic = @import("basic.zig");
const chars = @import("chars.zig");
const Parser = @import("Parser.zig");
const Context = Parser.Context;
const Error = Parser.Error;

const gt = @import("test_helpers.zig");

// -- [104]–[106] alias and empty nodes ---------------------------------------

/// [104] c-ns-alias-node ::= c-alias ns-anchor-name
pub fn cNsAliasNode(p: *Parser) Error!bool {
    const start = p.pos;
    if (!p.eat('*')) return false;
    const name_start = p.pos;
    if (!basic.nsAnchorName(p)) {
        p.pos = start;
        return false;
    }
    try p.emit(.{ .kind = .alias, .pos = start, .value = p.inputSpan(name_start, p.pos) });
    return true;
}

test cNsAliasNode {
    var r = try gt.run("*a ]", cNsAliasNode, .{});
    defer r.deinit();
    try std.testing.expectEqualStrings(" ]", r.rest());
    try r.expectEvents("=ALI *a");
    try gt.expectNoMatch("* a", cNsAliasNode, .{});
}

// [105] e-scalar ::= ""  and  [106] e-node ::= e-scalar  are
// `Parser.emitEmpty`.

// -- [107]–[116] double-quoted scalars ---------------------------------------

/// [107] nb-double-char ::= c-ns-esc-char | ( nb-json - c-escape - c-double-quote )
fn nbDoubleChar(p: *Parser) Error!bool {
    const b = p.peekByte(0) orelse return false;
    if (b == '\\') return cNsEscChar(p);
    if (b == '"') return false;
    const cp = p.peekCp(0) orelse return false;
    if (!chars.isNbJson(cp.cp)) return false;
    try p.appendContent(p.input[p.pos..][0..cp.len]);
    p.pos += cp.len;
    return true;
}

/// [108] ns-double-char ::= nb-double-char - s-white
fn nsDoubleChar(p: *Parser) Error!bool {
    const b = p.peekByte(0) orelse return false;
    if (b == ' ' or b == '\t') return false;
    return nbDoubleChar(p);
}

/// [62] c-ns-esc-char ::= c-escape ( ns-esc-null | … | ns-esc-32-bit )
fn cNsEscChar(p: *Parser) Error!bool {
    const b = p.peekByte(1) orelse return false;
    const esc = chars.escape(b) orelse return false;
    var cp: u21 = undefined;
    var len: u32 = 2;
    switch (esc) {
        .char => |c| cp = c,
        .hex => |digits| {
            var v: u32 = 0;
            var i: u32 = 0;
            while (i < digits) : (i += 1) {
                const h = p.peekByte(2 + i) orelse return false;
                v = v * 16 + (chars.hexValue(h) orelse return false);
            }
            if (v > 0x10FFFF) return false;
            cp = @intCast(v);
            len += digits;
        },
    }
    var buf: [4]u8 = undefined;
    // A surrogate cannot be encoded; the escape then matches nothing.
    const n = std.unicode.utf8Encode(cp, &buf) catch return false;
    try p.appendContent(buf[0..n]);
    p.pos += len;
    return true;
}

/// [109] c-double-quoted(n,c) ::= c-double-quote nb-double-text(n,c) c-double-quote
pub fn cDoubleQuoted(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    const start = p.pos;
    if (!p.eat('"')) return false;
    const from = p.mark();
    // [110] nb-double-text(n,c)
    switch (c) {
        .block_key, .flow_key => try nbDoubleOneLine(p),
        else => try nbDoubleMultiLine(p, n),
    }
    if (!p.eat('"')) return p.fail(s);
    try p.emitScalar(start, .double_quoted, from, p.input[start + 1 .. p.pos - 1]);
    return true;
}

test cDoubleQuoted {
    try gt.expectEvents("\"a\\x41\\n\"", cDoubleQuoted, .{ 0, .flow_out }, "=VAL \"aA\\n");
    // A line break between words folds to a space.
    try gt.expectEvents("\"a\n  b\"", cDoubleQuoted, .{ 0, .flow_out }, "=VAL \"a b");
    // An escaped line break joins the lines with nothing between them.
    try gt.expectEvents("\"a\\\n  b\"", cDoubleQuoted, .{ 0, .flow_out }, "=VAL \"ab");
    try gt.expectNoMatch("\"open", cDoubleQuoted, .{ 0, .flow_out });
}

/// [111] nb-double-one-line ::= nb-double-char*
fn nbDoubleOneLine(p: *Parser) Error!void {
    while (try nbDoubleChar(p)) {}
}

/// [112] s-double-escaped(n) ::= s-white* c-escape b-non-content l-empty(n,FLOW-IN)* s-flow-line-prefix(n)
///
/// The whitespace before an escaped line break is content; the break is not.
fn sDoubleEscaped(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    const ws = p.pos;
    while (p.eatCp(chars.isWhite)) {}
    try p.appendContent(p.input[ws..p.pos]);
    if (!p.eat('\\')) return p.fail(s);
    if (!basic.bNonContent(p)) return p.fail(s);
    while (try basic.lEmpty(p, n, .flow_in)) {}
    if (!basic.sFlowLinePrefix(p, n)) return p.fail(s);
    return true;
}

/// [113] s-double-break(n) ::= s-double-escaped(n) | s-flow-folded(n)
fn sDoubleBreak(p: *Parser, n: i32) Error!bool {
    return try sDoubleEscaped(p, n) or try basic.sFlowFolded(p, n);
}

/// [114] nb-ns-double-in-line ::= ( s-white* ns-double-char )*
fn nbNsDoubleInLine(p: *Parser) Error!void {
    while (true) {
        const s = p.save();
        const ws = p.pos;
        while (p.eatCp(chars.isWhite)) {}
        try p.appendContent(p.input[ws..p.pos]);
        if (!try nsDoubleChar(p)) {
            p.restore(s);
            return;
        }
    }
}

/// [116] nb-double-multi-line(n) ::= nb-ns-double-in-line ( s-double-next-line(n) | s-white* )
///
/// With [115] s-double-next-line(n) ::=
///   s-double-break(n) ( ns-double-char nb-ns-double-in-line ( s-double-next-line(n) | s-white* ) )?
/// unrolled from its tail recursion into a loop.
fn nbDoubleMultiLine(p: *Parser, n: i32) Error!void {
    try nbNsDoubleInLine(p);
    while (true) {
        if (try sDoubleBreak(p, n)) {
            const s = p.save();
            if (try nsDoubleChar(p)) {
                try nbNsDoubleInLine(p);
                continue;
            }
            p.restore(s);
            return;
        }
        const ws = p.pos;
        while (p.eatCp(chars.isWhite)) {}
        try p.appendContent(p.input[ws..p.pos]);
        return;
    }
}

// -- [117]–[125] single-quoted scalars ---------------------------------------

/// [118] nb-single-char ::= c-quoted-quote | ( nb-json - c-single-quote )
fn nbSingleChar(p: *Parser) Error!bool {
    // [117] c-quoted-quote ::= "''"
    if (p.eatStr("''")) {
        try p.appendByte('\'');
        return true;
    }
    const cp = p.peekCp(0) orelse return false;
    if (cp.cp == '\'' or !chars.isNbJson(cp.cp)) return false;
    try p.appendContent(p.input[p.pos..][0..cp.len]);
    p.pos += cp.len;
    return true;
}

/// [119] ns-single-char ::= nb-single-char - s-white
fn nsSingleChar(p: *Parser) Error!bool {
    const b = p.peekByte(0) orelse return false;
    if (b == ' ' or b == '\t') return false;
    return nbSingleChar(p);
}

/// [120] c-single-quoted(n,c) ::= c-single-quote nb-single-text(n,c) c-single-quote
pub fn cSingleQuoted(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    const start = p.pos;
    if (!p.eat('\'')) return false;
    const from = p.mark();
    // [121] nb-single-text(n,c)
    switch (c) {
        // [122] nb-single-one-line ::= nb-single-char*
        .block_key, .flow_key => while (try nbSingleChar(p)) {},
        else => try nbSingleMultiLine(p, n),
    }
    if (!p.eat('\'')) return p.fail(s);
    try p.emitScalar(start, .single_quoted, from, p.input[start + 1 .. p.pos - 1]);
    return true;
}

test cSingleQuoted {
    try gt.expectEvents("'it''s'", cSingleQuoted, .{ 0, .flow_out }, "=VAL 'it's");
    try gt.expectEvents("'a\n\n  b'", cSingleQuoted, .{ 0, .flow_out }, "=VAL 'a\\nb");
    try gt.expectNoMatch("'open", cSingleQuoted, .{ 0, .flow_out });
}

/// [123] nb-ns-single-in-line ::= ( s-white* ns-single-char )*
fn nbNsSingleInLine(p: *Parser) Error!void {
    while (true) {
        const s = p.save();
        const ws = p.pos;
        while (p.eatCp(chars.isWhite)) {}
        try p.appendContent(p.input[ws..p.pos]);
        if (!try nsSingleChar(p)) {
            p.restore(s);
            return;
        }
    }
}

/// [125] nb-single-multi-line(n) ::= nb-ns-single-in-line ( s-single-next-line(n) | s-white* )
///
/// With [124] s-single-next-line(n) ::=
///   s-flow-folded(n) ( ns-single-char nb-ns-single-in-line ( s-single-next-line(n) | s-white* ) )?
/// unrolled into a loop.
fn nbSingleMultiLine(p: *Parser, n: i32) Error!void {
    try nbNsSingleInLine(p);
    while (true) {
        if (try basic.sFlowFolded(p, n)) {
            const s = p.save();
            if (try nsSingleChar(p)) {
                try nbNsSingleInLine(p);
                continue;
            }
            p.restore(s);
            return;
        }
        const ws = p.pos;
        while (p.eatCp(chars.isWhite)) {}
        try p.appendContent(p.input[ws..p.pos]);
        return;
    }
}

// -- [126]–[135] plain scalars -----------------------------------------------

/// [127] ns-plain-safe(c), with [128] ns-plain-safe-out and [129] ns-plain-safe-in.
fn isPlainSafe(c: Context, cp: u21) bool {
    return switch (c) {
        .flow_in, .flow_key => chars.isNsChar(cp) and !chars.isFlowIndicator(cp),
        else => chars.isNsChar(cp),
    };
}

fn plainSafeAt(p: *const Parser, c: Context, ahead: u32) bool {
    const cp = p.peekCp(ahead) orelse return false;
    return isPlainSafe(c, cp.cp);
}

/// [126] ns-plain-first(c) ::=
///     ( ns-char - c-indicator )
///   | ( ( c-mapping-key | c-mapping-value | c-sequence-entry ) [ lookahead = ns-plain-safe(c) ] )
fn nsPlainFirst(p: *Parser, c: Context) bool {
    const cp = p.peekCp(0) orelse return false;
    if (chars.isNsChar(cp.cp) and !chars.isIndicator(cp.cp)) {
        p.pos += cp.len;
        return true;
    }
    if ((cp.cp == '?' or cp.cp == ':' or cp.cp == '-') and plainSafeAt(p, c, 1)) {
        p.pos += 1;
        return true;
    }
    return false;
}

/// [130] ns-plain-char(c) ::=
///     ( ns-plain-safe(c) - c-mapping-value - c-comment )
///   | ( [ lookbehind = ns-char ] c-comment )
///   | ( c-mapping-value [ lookahead = ns-plain-safe(c) ] )
fn nsPlainChar(p: *Parser, c: Context) bool {
    const cp = p.peekCp(0) orelse return false;
    switch (cp.cp) {
        ':' => if (!plainSafeAt(p, c, 1)) return false,
        '#' => {
            const prev = p.prevCp() orelse return false;
            if (!chars.isNsChar(prev)) return false;
        },
        else => if (!isPlainSafe(c, cp.cp)) return false,
    }
    p.pos += cp.len;
    return true;
}

/// [132] nb-ns-plain-in-line(c) ::= ( s-white* ns-plain-char(c) )*
fn nbNsPlainInLine(p: *Parser, c: Context) Error!void {
    while (true) {
        const start = p.pos;
        while (p.eatCp(chars.isWhite)) {}
        if (!nsPlainChar(p, c)) {
            p.pos = start;
            return;
        }
        try p.appendContent(p.input[start..p.pos]);
    }
}

/// [133] ns-plain-one-line(c) ::= ns-plain-first(c) nb-ns-plain-in-line(c)
fn nsPlainOneLine(p: *Parser, c: Context) Error!bool {
    const start = p.pos;
    if (!nsPlainFirst(p, c)) return false;
    try p.appendContent(p.input[start..p.pos]);
    try nbNsPlainInLine(p, c);
    return true;
}

/// [134] s-ns-plain-next-line(n,c) ::= s-flow-folded(n) ns-plain-char(c) nb-ns-plain-in-line(c)
fn sNsPlainNextLine(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (!try basic.sFlowFolded(p, n)) return false;
    const start = p.pos;
    if (!nsPlainChar(p, c)) return p.fail(s);
    try p.appendContent(p.input[start..p.pos]);
    try nbNsPlainInLine(p, c);
    return true;
}

/// [135] ns-plain-multi-line(n,c) ::= ns-plain-one-line(c) s-ns-plain-next-line(n,c)*
fn nsPlainMultiLine(p: *Parser, n: i32, c: Context) Error!bool {
    if (!try nsPlainOneLine(p, c)) return false;
    while (try sNsPlainNextLine(p, n, c)) {}
    return true;
}

/// [131] ns-plain(n,c), emitting the scalar it matched.
pub fn nsPlain(p: *Parser, n: i32, c: Context) Error!bool {
    const start = p.pos;
    const from = p.mark();
    const matched = switch (c) {
        .block_key, .flow_key => try nsPlainOneLine(p, c),
        else => try nsPlainMultiLine(p, n, c),
    };
    if (!matched) return false;
    try p.emitScalar(start, .plain, from, p.input[start..p.pos]);
    return true;
}

test nsPlain {
    // In a key, a plain scalar ends at `: `...
    var key = try gt.run("a b: c", nsPlain, .{ 0, .block_key });
    defer key.deinit();
    try std.testing.expectEqualStrings(": c", key.rest());
    try key.expectEvents("=VAL :a b");
    // ...in a flow collection at `,`...
    var entry = try gt.run("a, b", nsPlain, .{ 0, .flow_in });
    defer entry.deinit();
    try std.testing.expectEqualStrings(", b", entry.rest());
    // ...and outside both it may run on over lines, folded.
    try gt.expectEvents("a\n b", nsPlain, .{ 0, .flow_out }, "=VAL :a b");
    try gt.expectNoMatch("- ", nsPlain, .{ 0, .flow_out });
}

// -- [136]–[139] flow sequences ----------------------------------------------

/// [137] c-flow-sequence(n,c) ::= c-sequence-start s-separate(n,c)? in-flow(n,c)? c-sequence-end
pub fn cFlowSequence(p: *Parser, n: i32, c: Context) Error!bool {
    if (!p.peekIs('[')) return false;
    return p.memoized(.flow_sequence, cFlowSequenceUnmemoized, n, c);
}

test cFlowSequence {
    try gt.expectEvents("[a, [b]]", cFlowSequence, .{ 0, .flow_out }, "+SEQ [] =VAL :a +SEQ [] =VAL :b -SEQ -SEQ");
    // An entry that is a single key and value is a one-pair mapping.
    try gt.expectEvents("[a: b]", cFlowSequence, .{ 0, .flow_out }, "+SEQ [] +MAP {} =VAL :a =VAL :b -MAP -SEQ");
    try gt.expectNoMatch("[a", cFlowSequence, .{ 0, .flow_out });
}

fn cFlowSequenceUnmemoized(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    const start = p.pos;
    if (!p.eat('[')) return false;
    try p.enter();
    defer p.leave();
    try p.emitNodeStart(.sequence_start, start, true);
    _ = basic.sSeparate(p, n, c);
    // [136] in-flow(n,c)
    _ = try nsSFlowSeqEntries(p, n, c.inFlow());
    if (!p.eat(']')) return p.fail(s);
    try p.emit(.{ .kind = .sequence_end, .pos = p.pos - 1 });
    return true;
}

/// [138] ns-s-flow-seq-entries(n,c) ::=
///   ns-flow-seq-entry(n,c) s-separate(n,c)? ( c-collect-entry s-separate(n,c)? ns-s-flow-seq-entries(n,c)? )?
fn nsSFlowSeqEntries(p: *Parser, n: i32, c: Context) Error!bool {
    if (!try nsFlowSeqEntry(p, n, c)) return false;
    while (true) {
        _ = basic.sSeparate(p, n, c);
        if (!p.eat(',')) return true;
        _ = basic.sSeparate(p, n, c);
        if (!try nsFlowSeqEntry(p, n, c)) return true;
    }
}

/// [139] ns-flow-seq-entry(n,c) ::= ns-flow-pair(n,c) | ns-flow-node(n,c)
fn nsFlowSeqEntry(p: *Parser, n: i32, c: Context) Error!bool {
    return try nsFlowPair(p, n, c) or try nsFlowNode(p, n, c);
}

// -- [140]–[149] flow mappings -----------------------------------------------

/// [140] c-flow-mapping(n,c) ::= c-mapping-start s-separate(n,c)? ns-s-flow-map-entries(n,in-flow(c))? c-mapping-end
pub fn cFlowMapping(p: *Parser, n: i32, c: Context) Error!bool {
    if (!p.peekIs('{')) return false;
    return p.memoized(.flow_mapping, cFlowMappingUnmemoized, n, c);
}

test cFlowMapping {
    try gt.expectEvents("{a: 1, b}", cFlowMapping, .{ 0, .flow_out }, "+MAP {} =VAL :a =VAL :1 =VAL :b =VAL : -MAP");
    try gt.expectEvents("{? [x]: y}", cFlowMapping, .{ 0, .flow_out }, "+MAP {} +SEQ [] =VAL :x -SEQ =VAL :y -MAP");
    try gt.expectNoMatch("{a: 1", cFlowMapping, .{ 0, .flow_out });
}

fn cFlowMappingUnmemoized(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    const start = p.pos;
    if (!p.eat('{')) return false;
    try p.enter();
    defer p.leave();
    try p.emitNodeStart(.mapping_start, start, true);
    _ = basic.sSeparate(p, n, c);
    _ = try nsSFlowMapEntries(p, n, c.inFlow());
    if (!p.eat('}')) return p.fail(s);
    try p.emit(.{ .kind = .mapping_end, .pos = p.pos - 1 });
    return true;
}

/// [141] ns-s-flow-map-entries(n,c) ::=
///   ns-flow-map-entry(n,c) s-separate(n,c)? ( c-collect-entry s-separate(n,c)? ns-s-flow-map-entries(n,c)? )?
fn nsSFlowMapEntries(p: *Parser, n: i32, c: Context) Error!bool {
    if (!try nsFlowMapEntry(p, n, c)) return false;
    while (true) {
        _ = basic.sSeparate(p, n, c);
        if (!p.eat(',')) return true;
        _ = basic.sSeparate(p, n, c);
        if (!try nsFlowMapEntry(p, n, c)) return true;
    }
}

/// `c-mapping-key` as an explicit key indicator: a `?` "not followed by
/// non-ws char", as [142], [150] and [190] annotate it.
fn explicitKeyIndicator(p: *Parser) bool {
    if (!p.peekIs('?')) return false;
    p.pos += 1;
    if (p.notFollowedByNsChar()) return true;
    p.pos -= 1;
    return false;
}

/// [142] ns-flow-map-entry(n,c) ::=
///     ( c-mapping-key s-separate(n,c) ns-flow-map-explicit-entry(n,c) )
///   | ns-flow-map-implicit-entry(n,c)
fn nsFlowMapEntry(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (explicitKeyIndicator(p) and basic.sSeparate(p, n, c) and try nsFlowMapExplicitEntry(p, n, c)) return true;
    p.restore(s);
    return nsFlowMapImplicitEntry(p, n, c);
}

/// [143] ns-flow-map-explicit-entry(n,c) ::= ns-flow-map-implicit-entry(n,c) | ( e-node e-node )
fn nsFlowMapExplicitEntry(p: *Parser, n: i32, c: Context) Error!bool {
    if (try nsFlowMapImplicitEntry(p, n, c)) return true;
    try p.emitEmpty();
    try p.emitEmpty();
    return true;
}

/// [144] ns-flow-map-implicit-entry(n,c) ::=
///   ns-flow-map-yaml-key-entry(n,c) | c-ns-flow-map-empty-key-entry(n,c) | c-ns-flow-map-json-key-entry(n,c)
fn nsFlowMapImplicitEntry(p: *Parser, n: i32, c: Context) Error!bool {
    return try nsFlowMapYamlKeyEntry(p, n, c) or
        try cNsFlowMapEmptyKeyEntry(p, n, c) or
        try cNsFlowMapJsonKeyEntry(p, n, c);
}

/// [145] ns-flow-map-yaml-key-entry(n,c) ::=
///   ns-flow-yaml-node(n,c) ( ( s-separate(n,c)? c-ns-flow-map-separate-value(n,c) ) | e-node )
fn nsFlowMapYamlKeyEntry(p: *Parser, n: i32, c: Context) Error!bool {
    if (!try nsFlowYamlNode(p, n, c)) return false;
    const s = p.save();
    _ = basic.sSeparate(p, n, c);
    if (try cNsFlowMapSeparateValue(p, n, c)) return true;
    p.restore(s);
    try p.emitEmpty();
    return true;
}

/// [146] c-ns-flow-map-empty-key-entry(n,c) ::= e-node c-ns-flow-map-separate-value(n,c)
fn cNsFlowMapEmptyKeyEntry(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    try p.emitEmpty();
    if (try cNsFlowMapSeparateValue(p, n, c)) return true;
    return p.fail(s);
}

/// [147] c-ns-flow-map-separate-value(n,c) ::=
///   c-mapping-value [ lookahead ≠ ns-plain-safe(c) ] ( ( s-separate(n,c) ns-flow-node(n,c) ) | e-node )
fn cNsFlowMapSeparateValue(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (!p.eat(':')) return false;
    if (plainSafeAt(p, c, 0)) return p.fail(s);
    const t = p.save();
    if (basic.sSeparate(p, n, c) and try nsFlowNode(p, n, c)) return true;
    p.restore(t);
    try p.emitEmpty();
    return true;
}

/// [148] c-ns-flow-map-json-key-entry(n,c) ::=
///   c-flow-json-node(n,c) ( ( s-separate(n,c)? c-ns-flow-map-adjacent-value(n,c) ) | e-node )
fn cNsFlowMapJsonKeyEntry(p: *Parser, n: i32, c: Context) Error!bool {
    if (!try cFlowJsonNode(p, n, c)) return false;
    const s = p.save();
    _ = basic.sSeparate(p, n, c);
    if (try cNsFlowMapAdjacentValue(p, n, c)) return true;
    p.restore(s);
    try p.emitEmpty();
    return true;
}

/// [149] c-ns-flow-map-adjacent-value(n,c) ::=
///   c-mapping-value ( ( s-separate(n,c)? ns-flow-node(n,c) ) | e-node )
fn cNsFlowMapAdjacentValue(p: *Parser, n: i32, c: Context) Error!bool {
    if (!p.eat(':')) return false;
    const s = p.save();
    _ = basic.sSeparate(p, n, c);
    if (try nsFlowNode(p, n, c)) return true;
    p.restore(s);
    try p.emitEmpty();
    return true;
}

// -- [150]–[155] single-pair mappings in flow sequences ----------------------

/// [150] ns-flow-pair(n,c) ::=
///     ( c-mapping-key s-separate(n,c) ns-flow-map-explicit-entry(n,c) )
///   | ns-flow-pair-entry(n,c)
///
/// Emits the single-pair mapping around the entry.
fn nsFlowPair(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    try p.emit(.{ .kind = .mapping_start, .pos = p.pos, .flag = true });
    const t = p.save();
    if (explicitKeyIndicator(p) and basic.sSeparate(p, n, c) and try nsFlowMapExplicitEntry(p, n, c)) {
        // matched
    } else {
        p.restore(t);
        if (!try nsFlowPairEntry(p, n, c)) return p.fail(s);
    }
    try p.emit(.{ .kind = .mapping_end, .pos = p.pos });
    return true;
}

/// [151] ns-flow-pair-entry(n,c) ::=
///   ns-flow-pair-yaml-key-entry(n,c) | c-ns-flow-map-empty-key-entry(n,c) | c-ns-flow-pair-json-key-entry(n,c)
fn nsFlowPairEntry(p: *Parser, n: i32, c: Context) Error!bool {
    return try nsFlowPairYamlKeyEntry(p, n, c) or
        try cNsFlowMapEmptyKeyEntry(p, n, c) or
        try cNsFlowPairJsonKeyEntry(p, n, c);
}

/// [152] ns-flow-pair-yaml-key-entry(n,c) ::= ns-s-implicit-yaml-key(FLOW-KEY) c-ns-flow-map-separate-value(n,c)
fn nsFlowPairYamlKeyEntry(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (!try nsSImplicitYamlKey(p, .flow_key)) return false;
    if (try cNsFlowMapSeparateValue(p, n, c)) return true;
    return p.fail(s);
}

/// [153] c-ns-flow-pair-json-key-entry(n,c) ::= c-s-implicit-json-key(FLOW-KEY) c-ns-flow-map-adjacent-value(n,c)
fn cNsFlowPairJsonKeyEntry(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (!try cSImplicitJsonKey(p, .flow_key)) return false;
    if (try cNsFlowMapAdjacentValue(p, n, c)) return true;
    return p.fail(s);
}

/// The "at most 1024 characters altogether" of [154] and [155].
const implicit_key_limit = 1024;

/// Runs an implicit key production with the end of the input brought in to
/// where the key would pass its limit, so that a long node that is not a key
/// costs no more than a short one to rule out.
fn implicitKey(p: *Parser, c: Context, comptime node: fn (*Parser, i32, Context) Error!bool) Error!bool {
    const s = p.save();
    const saved_end = p.end;
    // A character is at most four bytes, so no key can reach this far; and
    // anything that does reach it is more than 1024 characters long and
    // fails the count below, rather than passing for a key that the
    // narrowed end merely cut short.
    const limit: u32 = @intCast(@min(@as(usize, saved_end), @as(usize, p.pos) + 4 * (implicit_key_limit + 1)));
    p.end = limit;
    defer p.end = saved_end;
    if (!try node(p, 0, c)) return false;
    _ = basic.sSeparateInLine(p);
    const key = p.input[s.pos..p.pos];
    if (key.len > implicit_key_limit) {
        const count = std.unicode.utf8CountCodepoints(key) catch return p.fail(s);
        if (count > implicit_key_limit) return p.fail(s);
    }
    return true;
}

/// [154] ns-s-implicit-yaml-key(c) ::= ns-flow-yaml-node(0,c) s-separate-in-line?
///       /* At most 1024 characters altogether */
pub fn nsSImplicitYamlKey(p: *Parser, c: Context) Error!bool {
    return implicitKey(p, c, nsFlowYamlNode);
}

test nsSImplicitYamlKey {
    var r = try gt.run("a b : x", nsSImplicitYamlKey, .{.block_key});
    defer r.deinit();
    try std.testing.expectEqualStrings(": x", r.rest());
    try r.expectEvents("=VAL :a b");
}

/// [155] c-s-implicit-json-key(c) ::= c-flow-json-node(0,c) s-separate-in-line?
///       /* At most 1024 characters altogether */
pub fn cSImplicitJsonKey(p: *Parser, c: Context) Error!bool {
    return implicitKey(p, c, cFlowJsonNode);
}

test cSImplicitJsonKey {
    var r = try gt.run("[a] : x", cSImplicitJsonKey, .{.block_key});
    defer r.deinit();
    try std.testing.expectEqualStrings(": x", r.rest());
    try r.expectEvents("+SEQ [] =VAL :a -SEQ");
    try gt.expectNoMatch("a: x", cSImplicitJsonKey, .{.block_key});
}

// -- [156]–[161] flow nodes --------------------------------------------------

/// [157] c-flow-json-content(n,c) ::= c-flow-sequence(n,c) | c-flow-mapping(n,c) | c-single-quoted(n,c) | c-double-quoted(n,c)
fn cFlowJsonContent(p: *Parser, n: i32, c: Context) Error!bool {
    return try cFlowSequence(p, n, c) or
        try cFlowMapping(p, n, c) or
        try cSingleQuoted(p, n, c) or
        try cDoubleQuoted(p, n, c);
}

/// [158] ns-flow-content(n,c) ::= ns-flow-yaml-content(n,c) | c-flow-json-content(n,c)
///
/// With [156] ns-flow-yaml-content(n,c) ::= ns-plain(n,c).
fn nsFlowContent(p: *Parser, n: i32, c: Context) Error!bool {
    return try nsPlain(p, n, c) or try cFlowJsonContent(p, n, c);
}

/// [159] ns-flow-yaml-node(n,c) ::=
///     c-ns-alias-node
///   | ns-flow-yaml-content(n,c)
///   | ( c-ns-properties(n,c) ( ( s-separate(n,c) ns-flow-yaml-content(n,c) ) | e-scalar ) )
///
/// Deviation: the properties-then-`e-scalar` alternative does not match
/// where JSON-like content follows the properties. In `{ &a [x]: y }` the
/// anchor belongs to the sequence, which `c-flow-json-node` would find; but
/// read as a PEG, this alternative matches first, commits to an empty
/// anchored key, and leaves `[x]` where nothing can take it.
pub fn nsFlowYamlNode(p: *Parser, n: i32, c: Context) Error!bool {
    if (try cNsAliasNode(p)) return true;
    if (try nsPlain(p, n, c)) return true;
    const before = p.save();
    if (!try basic.cNsProperties(p, n, c)) return false;
    const s = p.save();
    if (basic.sSeparate(p, n, c)) {
        if (try nsPlain(p, n, c)) return true;
        if (p.peekByte(0)) |b| switch (b) {
            '[', '{', '\'', '"' => return p.fail(before),
            else => {},
        };
    }
    p.restore(s);
    try p.emitEmpty();
    return true;
}

test nsFlowYamlNode {
    try gt.expectEvents("&x a", nsFlowYamlNode, .{ 0, .flow_out }, "=VAL &x :a");
    try gt.expectEvents("*x", nsFlowYamlNode, .{ 0, .flow_out }, "=ALI *x");
    // Properties with nothing after them make an empty scalar.
    try gt.expectEvents("!!str", nsFlowYamlNode, .{ 0, .flow_out }, "=VAL <tag:yaml.org,2002:str> :");
}

/// [160] c-flow-json-node(n,c) ::= ( c-ns-properties(n,c) s-separate(n,c) )? c-flow-json-content(n,c)
pub fn cFlowJsonNode(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (try basic.cNsProperties(p, n, c)) {
        if (!basic.sSeparate(p, n, c)) p.restore(s);
    }
    if (try cFlowJsonContent(p, n, c)) return true;
    return p.fail(s);
}

test cFlowJsonNode {
    try gt.expectEvents("&x [a]", cFlowJsonNode, .{ 0, .flow_out }, "+SEQ [] &x =VAL :a -SEQ");
    try gt.expectEvents("\"a\"", cFlowJsonNode, .{ 0, .flow_out }, "=VAL \"a");
    try gt.expectNoMatch("a", cFlowJsonNode, .{ 0, .flow_out });
}

/// [161] ns-flow-node(n,c) ::=
///     c-ns-alias-node
///   | ns-flow-content(n,c)
///   | ( c-ns-properties(n,c) ( ( s-separate(n,c) ns-flow-content(n,c) ) | e-scalar ) )
pub fn nsFlowNode(p: *Parser, n: i32, c: Context) Error!bool {
    if (try cNsAliasNode(p)) return true;
    if (try nsFlowContent(p, n, c)) return true;
    if (!try basic.cNsProperties(p, n, c)) return false;
    const s = p.save();
    if (basic.sSeparate(p, n, c) and try nsFlowContent(p, n, c)) return true;
    p.restore(s);
    try p.emitEmpty();
    return true;
}

test nsFlowNode {
    try gt.expectEvents("'a'", nsFlowNode, .{ 0, .flow_out }, "=VAL 'a");
    try gt.expectEvents("*a", nsFlowNode, .{ 0, .flow_out }, "=ALI *a");
    try gt.expectEvents("!t {}", nsFlowNode, .{ 0, .flow_out }, "+MAP {} <!t> -MAP");
    try gt.expectNoMatch("]", nsFlowNode, .{ 0, .flow_out });
}
