// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Chapter 8 of YAML 1.2.2, "Block Style Productions": productions
//! [162]–[201] — literal and folded block scalars, block sequences and block
//! mappings, and the productions that decide which of them a block node is.
//!
//! Several productions here are written in terms of an indentation `m` that
//! is "auto-detected" rather than given. The grammar leaves the detecting to
//! the reader; how it is done here is described at each production.

const std = @import("std");

const basic = @import("basic.zig");
const chars = @import("chars.zig");
const flow = @import("flow.zig");
const Parser = @import("Parser.zig");
const Chomping = Parser.Chomping;
const Context = Parser.Context;
const Error = Parser.Error;

// -- [162]–[169] block scalar headers and chomping ---------------------------

const Header = struct {
    /// The explicit indentation indicator, if there was one.
    indent: ?u8 = null,
    chomping: Chomping = .clip,
};

/// [162] c-b-block-header(t) ::=
///   ( ( c-indentation-indicator c-chomping-indicator(t) )
///   | ( c-chomping-indicator(t) c-indentation-indicator ) ) s-b-comment
///
/// Both indicators are optional, though the production as printed does not
/// mark [163] so.
fn cBBlockHeader(p: *Parser) ?Header {
    const s = p.save();
    var h: Header = .{};
    if (cIndentationIndicator(p)) |i| {
        h.indent = i;
        if (cChompingIndicator(p)) |t| h.chomping = t;
    } else if (cChompingIndicator(p)) |t| {
        h.chomping = t;
        if (cIndentationIndicator(p)) |i| h.indent = i;
    }
    if (!basic.sBComment(p)) {
        p.restore(s);
        return null;
    }
    return h;
}

/// [163] c-indentation-indicator ::= [x31-x39]
fn cIndentationIndicator(p: *Parser) ?u8 {
    const b = p.peekByte(0) orelse return null;
    if (b < '1' or b > '9') return null;
    p.pos += 1;
    return b - '0';
}

/// [164] c-chomping-indicator(t)
fn cChompingIndicator(p: *Parser) ?Chomping {
    if (p.eat('-')) return .strip;
    if (p.eat('+')) return .keep;
    return null;
}

/// [165] b-chomped-last(t)
fn bChompedLast(p: *Parser, t: Chomping) Error!bool {
    return switch (t) {
        .strip => basic.bNonContent(p) or p.atEnd(),
        // The end of the input ends the last line as a line break would, in
        // the test suite's reading and in every implementation's.
        // It only follows a line of content, so there is always something
        // on the line for the end of the input to end.
        .clip, .keep => try basic.bAsLineFeedOrEnd(p, p.pos -| 1) or p.atEnd(),
    };
}

/// [166] l-chomped-empty(n,t)
fn lChompedEmpty(p: *Parser, n: i32, t: Chomping) Error!void {
    switch (t) {
        .strip, .clip => lStripEmpty(p, n),
        .keep => try lKeepEmpty(p, n),
    }
}

/// [167] l-strip-empty(n) ::= ( s-indent-less-or-equal(n) b-non-content )* l-trail-comments(n)?
fn lStripEmpty(p: *Parser, n: i32) void {
    while (true) {
        const s = p.save();
        _ = basic.sIndentLessOrEqual(p, n);
        if (!basic.bNonContent(p)) {
            p.restore(s);
            break;
        }
    }
    _ = lTrailComments(p, n);
}

/// [168] l-keep-empty(n) ::= l-empty(n,BLOCK-IN)* l-trail-comments(n)?
fn lKeepEmpty(p: *Parser, n: i32) Error!void {
    while (try basic.lEmpty(p, n, .block_in)) {}
    _ = lTrailComments(p, n);
}

/// [169] l-trail-comments(n) ::= s-indent-less-than(n) c-nb-comment-text b-comment l-comment*
fn lTrailComments(p: *Parser, n: i32) bool {
    const s = p.save();
    _ = basic.sIndentLessThan(p, n);
    if (!basic.cNbCommentText(p)) return p.fail(s);
    if (!basic.bComment(p)) return p.fail(s);
    basic.lComments(p);
    return true;
}

/// The content indentation of a block scalar with no indentation indicator
/// (§8.1.1.1): the indentation of its first non-empty line.
///
/// If that line is not indented past `n` it is not part of the scalar at
/// all, which then has no content lines; its indentation is taken as the
/// widest of its leading empty lines, so that they are read as empty rather
/// than as lines of spaces. A leading empty line wider than the first content
/// line is an error the spec names but the grammar cannot express.
fn detectIndent(p: *const Parser, n: i32) Error!i32 {
    var i: usize = p.pos;
    const end: usize = p.end;
    var widest: i32 = 0;
    while (i < end) {
        var k: usize = 0;
        while (i + k < end and p.input[i + k] == ' ') k += 1;
        const spaces: i32 = @intCast(k);
        const j = i + k;
        if (j >= end) {
            widest = @max(widest, spaces);
            break;
        }
        switch (p.input[j]) {
            '\n' => i = j + 1,
            '\r' => i = if (j + 1 < end and p.input[j + 1] == '\n') j + 2 else j + 1,
            else => {
                if (spaces > n) {
                    if (widest > spaces) return error.InvalidIndentation;
                    return spaces;
                }
                break;
            },
        }
        widest = @max(widest, spaces);
    }
    return @max(n + 1, widest);
}

fn contentIndent(p: *const Parser, n: i32, h: Header) Error!i32 {
    if (h.indent) |m| return @max(n, 0) + m;
    return detectIndent(p, n);
}

// -- [170]–[173] literal style -----------------------------------------------

/// [170] c-l+literal(n) ::= c-literal c-b-block-header(t) l-literal-content(n+m,t)
fn cLLiteral(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    const start = p.pos;
    if (!p.eat('|')) return false;
    const h = cBBlockHeader(p) orelse return p.fail(s);
    const from = p.mark();
    try lLiteralContent(p, try contentIndent(p, n, h), h.chomping);
    try p.emitScalar(start, .literal, from, null);
    return true;
}

/// [171] l-nb-literal-text(n) ::= l-empty(n,BLOCK-IN)* s-indent(n) nb-char+
fn lNbLiteralText(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    while (try basic.lEmpty(p, n, .block_in)) {}
    if (!basic.sIndent(p, n)) return p.fail(s);
    const start = p.pos;
    if (!p.eatCp(chars.isNbChar)) return p.fail(s);
    while (p.eatCp(chars.isNbChar)) {}
    try p.appendContent(p.input[start..p.pos]);
    return true;
}

/// [172] b-nb-literal-next(n) ::= b-as-line-feed l-nb-literal-text(n)
fn bNbLiteralNext(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    if (!try basic.bAsLineFeed(p)) return false;
    if (!try lNbLiteralText(p, n)) return p.fail(s);
    return true;
}

/// [173] l-literal-content(n,t) ::=
///   ( l-nb-literal-text(n) b-nb-literal-next(n)* b-chomped-last(t) )? l-chomped-empty(n,t)
fn lLiteralContent(p: *Parser, n: i32, t: Chomping) Error!void {
    const s = p.save();
    if (try lNbLiteralText(p, n)) {
        while (try bNbLiteralNext(p, n)) {}
        if (!try bChompedLast(p, t)) p.restore(s);
    }
    try lChompedEmpty(p, n, t);
}

// -- [174]–[182] folded style ------------------------------------------------

/// [174] c-l+folded(n) ::= c-folded c-b-block-header(t) l-folded-content(n+m,t)
fn cLFolded(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    const start = p.pos;
    if (!p.eat('>')) return false;
    const h = cBBlockHeader(p) orelse return p.fail(s);
    const from = p.mark();
    try lFoldedContent(p, try contentIndent(p, n, h), h.chomping);
    try p.emitScalar(start, .folded, from, null);
    return true;
}

/// [175] s-nb-folded-text(n) ::= s-indent(n) ns-char nb-char*
fn sNbFoldedText(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    if (!basic.sIndent(p, n)) return false;
    const start = p.pos;
    if (!p.eatCp(chars.isNsChar)) return p.fail(s);
    while (p.eatCp(chars.isNbChar)) {}
    try p.appendContent(p.input[start..p.pos]);
    return true;
}

/// [176] l-nb-folded-lines(n) ::= s-nb-folded-text(n) ( b-l-folded(n,BLOCK-IN) s-nb-folded-text(n) )*
fn lNbFoldedLines(p: *Parser, n: i32) Error!bool {
    if (!try sNbFoldedText(p, n)) return false;
    while (true) {
        const s = p.save();
        if (try basic.bLFolded(p, n, .block_in) and try sNbFoldedText(p, n)) continue;
        p.restore(s);
        return true;
    }
}

/// [177] s-nb-spaced-text(n) ::= s-indent(n) s-white nb-char*
fn sNbSpacedText(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    if (!basic.sIndent(p, n)) return false;
    const start = p.pos;
    if (!p.eatCp(chars.isWhite)) return p.fail(s);
    while (p.eatCp(chars.isNbChar)) {}
    try p.appendContent(p.input[start..p.pos]);
    return true;
}

/// [178] b-l-spaced(n) ::= b-as-line-feed l-empty(n,BLOCK-IN)*
fn bLSpaced(p: *Parser, n: i32) Error!bool {
    if (!try basic.bAsLineFeed(p)) return false;
    while (try basic.lEmpty(p, n, .block_in)) {}
    return true;
}

/// [179] l-nb-spaced-lines(n) ::= s-nb-spaced-text(n) ( b-l-spaced(n) s-nb-spaced-text(n) )*
fn lNbSpacedLines(p: *Parser, n: i32) Error!bool {
    if (!try sNbSpacedText(p, n)) return false;
    while (true) {
        const s = p.save();
        if (try bLSpaced(p, n) and try sNbSpacedText(p, n)) continue;
        p.restore(s);
        return true;
    }
}

/// [180] l-nb-same-lines(n) ::= l-empty(n,BLOCK-IN)* ( l-nb-folded-lines(n) | l-nb-spaced-lines(n) )
fn lNbSameLines(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    while (try basic.lEmpty(p, n, .block_in)) {}
    if (try lNbFoldedLines(p, n) or try lNbSpacedLines(p, n)) return true;
    return p.fail(s);
}

/// [181] l-nb-diff-lines(n) ::= l-nb-same-lines(n) ( b-as-line-feed l-nb-same-lines(n) )*
fn lNbDiffLines(p: *Parser, n: i32) Error!bool {
    if (!try lNbSameLines(p, n)) return false;
    while (true) {
        const s = p.save();
        if (try basic.bAsLineFeed(p) and try lNbSameLines(p, n)) continue;
        p.restore(s);
        return true;
    }
}

/// [182] l-folded-content(n,t) ::= ( l-nb-diff-lines(n) b-chomped-last(t) )? l-chomped-empty(n,t)
fn lFoldedContent(p: *Parser, n: i32, t: Chomping) Error!void {
    const s = p.save();
    if (try lNbDiffLines(p, n)) {
        if (!try bChompedLast(p, t)) p.restore(s);
    }
    try lChompedEmpty(p, n, t);
}

// -- [183]–[186] block sequences ---------------------------------------------

/// The indentation of the line the parser stands at the start of, as a
/// candidate for a block collection's auto-detected `n+1+m`: it qualifies if
/// it is deeper than `n`.
fn detectCollectionIndent(p: *const Parser, n: i32) ?i32 {
    const k: i32 = @intCast(p.countSpaces());
    return if (k > n) k else null;
}

/// [183] l+block-sequence(n) ::= ( s-indent(n+1+m) c-l-block-seq-entry(n+1+m) )+
///       /* For some fixed auto-detected m > 0 */
///
/// `m` is read off the first entry's line. Where the spec says m > 0 it
/// means the entries are indented past `n`: seq-space passes `n-1` precisely
/// so that a sequence may sit at its parent key's own indentation.
fn lBlockSequence(p: *Parser, n: i32) Error!bool {
    const k = detectCollectionIndent(p, n) orelse return false;
    const s = p.save();
    try p.enter();
    defer p.leave();
    try p.emitNodeStart(.sequence_start, p.pos + @as(u32, @intCast(k)), false);
    var count: usize = 0;
    while (true) : (count += 1) {
        const t = p.save();
        if (basic.sIndent(p, k) and try cLBlockSeqEntry(p, k)) continue;
        p.restore(t);
        break;
    }
    if (count == 0) return p.fail(s);
    try p.emit(.{ .kind = .sequence_end, .pos = p.pos });
    return true;
}

/// [184] c-l-block-seq-entry(n) ::= c-sequence-entry [ lookahead ≠ ns-char ] s-l+block-indented(n,BLOCK-IN)
fn cLBlockSeqEntry(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    if (!p.eat('-')) return false;
    if (!p.notFollowedByNsChar()) return p.fail(s);
    if (try sLBlockIndented(p, n, .block_in)) return true;
    return p.fail(s);
}

/// [185] s-l+block-indented(n,c) ::=
///     ( s-indent(m) ( ns-l-compact-sequence(n+1+m) | ns-l-compact-mapping(n+1+m) ) )
///   | s-l+block-node(n,c)
///   | ( e-node s-l-comments )
///
/// Here `m` is the run of spaces after the indicator, which is what makes the
/// compact collection's indentation line up with its first entry.
fn sLBlockIndented(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    const m: i32 = @intCast(p.countSpaces());
    if (basic.sIndent(p, m)) {
        if (try nsLCompactSequence(p, n + 1 + m) or try nsLCompactMapping(p, n + 1 + m)) return true;
        p.restore(s);
    }
    if (try sLBlockNode(p, n, c)) return true;
    try p.emitEmpty();
    if (basic.sLComments(p)) return true;
    return p.fail(s);
}

/// [186] ns-l-compact-sequence(n) ::= c-l-block-seq-entry(n) ( s-indent(n) c-l-block-seq-entry(n) )*
fn nsLCompactSequence(p: *Parser, n: i32) Error!bool {
    if (!p.peekIs('-')) return false;
    const s = p.save();
    try p.enter();
    defer p.leave();
    try p.emitNodeStart(.sequence_start, p.pos, false);
    if (!try cLBlockSeqEntry(p, n)) return p.fail(s);
    while (true) {
        const t = p.save();
        if (basic.sIndent(p, n) and try cLBlockSeqEntry(p, n)) continue;
        p.restore(t);
        break;
    }
    try p.emit(.{ .kind = .sequence_end, .pos = p.pos });
    return true;
}

// -- [187]–[195] block mappings ----------------------------------------------

/// [187] l+block-mapping(n) ::= ( s-indent(n+1+m) ns-l-block-map-entry(n+1+m) )+
///       /* For some fixed auto-detected m > 0 */
fn lBlockMapping(p: *Parser, n: i32) Error!bool {
    const k = detectCollectionIndent(p, n) orelse return false;
    const s = p.save();
    try p.enter();
    defer p.leave();
    try p.emitNodeStart(.mapping_start, p.pos + @as(u32, @intCast(k)), false);
    var count: usize = 0;
    while (true) : (count += 1) {
        const t = p.save();
        if (basic.sIndent(p, k) and try nsLBlockMapEntry(p, k)) continue;
        p.restore(t);
        break;
    }
    if (count == 0) return p.fail(s);
    try p.emit(.{ .kind = .mapping_end, .pos = p.pos });
    return true;
}

/// [188] ns-l-block-map-entry(n) ::= c-l-block-map-explicit-entry(n) | ns-l-block-map-implicit-entry(n)
fn nsLBlockMapEntry(p: *Parser, n: i32) Error!bool {
    return try cLBlockMapExplicitEntry(p, n) or try nsLBlockMapImplicitEntry(p, n);
}

/// [189] c-l-block-map-explicit-entry(n) ::= c-l-block-map-explicit-key(n) ( l-block-map-explicit-value(n) | e-node )
fn cLBlockMapExplicitEntry(p: *Parser, n: i32) Error!bool {
    if (!try cLBlockMapExplicitKey(p, n)) return false;
    if (try lBlockMapExplicitValue(p, n)) return true;
    try p.emitEmpty();
    return true;
}

/// [190] c-l-block-map-explicit-key(n) ::= c-mapping-key s-l+block-indented(n,BLOCK-OUT)
fn cLBlockMapExplicitKey(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    if (!p.eat('?')) return false;
    if (!p.notFollowedByNsChar()) return p.fail(s);
    if (try sLBlockIndented(p, n, .block_out)) return true;
    return p.fail(s);
}

/// [191] l-block-map-explicit-value(n) ::= s-indent(n) c-mapping-value s-l+block-indented(n,BLOCK-OUT)
fn lBlockMapExplicitValue(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    if (!(basic.sIndent(p, n) and p.eat(':') and p.notFollowedByNsChar())) return p.fail(s);
    if (try sLBlockIndented(p, n, .block_out)) return true;
    return p.fail(s);
}

/// [192] ns-l-block-map-implicit-entry(n) ::= ( ns-s-block-map-implicit-key | e-node ) c-l-block-map-implicit-value(n)
fn nsLBlockMapImplicitEntry(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    if (!try nsSBlockMapImplicitKey(p)) try p.emitEmpty();
    if (try cLBlockMapImplicitValue(p, n)) return true;
    return p.fail(s);
}

/// [193] ns-s-block-map-implicit-key ::= c-s-implicit-json-key(BLOCK-KEY) | ns-s-implicit-yaml-key(BLOCK-KEY)
fn nsSBlockMapImplicitKey(p: *Parser) Error!bool {
    return try flow.cSImplicitJsonKey(p, .block_key) or try flow.nsSImplicitYamlKey(p, .block_key);
}

/// [194] c-l-block-map-implicit-value(n) ::= c-mapping-value ( s-l+block-node(n,BLOCK-OUT) | ( e-node s-l-comments ) )
fn cLBlockMapImplicitValue(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    if (!p.eat(':')) return false;
    if (!p.notFollowedByNsChar()) return p.fail(s);
    if (try sLBlockNode(p, n, .block_out)) return true;
    try p.emitEmpty();
    if (basic.sLComments(p)) return true;
    return p.fail(s);
}

/// [195] ns-l-compact-mapping(n) ::= ns-l-block-map-entry(n) ( s-indent(n) ns-l-block-map-entry(n) )*
fn nsLCompactMapping(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    try p.enter();
    defer p.leave();
    try p.emitNodeStart(.mapping_start, p.pos, false);
    if (!try nsLBlockMapEntry(p, n)) return p.fail(s);
    while (true) {
        const t = p.save();
        if (basic.sIndent(p, n) and try nsLBlockMapEntry(p, n)) continue;
        p.restore(t);
        break;
    }
    try p.emit(.{ .kind = .mapping_end, .pos = p.pos });
    return true;
}

// -- [196]–[201] block nodes -------------------------------------------------

/// [196] s-l+block-node(n,c) ::= s-l+block-in-block(n,c) | s-l+flow-in-block(n)
pub fn sLBlockNode(p: *Parser, n: i32, c: Context) Error!bool {
    return p.memoized(.block_node, sLBlockNodeUnmemoized, n, c);
}

fn sLBlockNodeUnmemoized(p: *Parser, n: i32, c: Context) Error!bool {
    return try sLBlockInBlock(p, n, c) or try sLFlowInBlock(p, n);
}

/// [197] s-l+flow-in-block(n) ::= s-separate(n+1,FLOW-OUT) ns-flow-node(n+1,FLOW-OUT) s-l-comments
fn sLFlowInBlock(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    if (basic.sSeparate(p, n + 1, .flow_out) and
        try flow.nsFlowNode(p, n + 1, .flow_out) and
        basic.sLComments(p)) return true;
    return p.fail(s);
}

/// [198] s-l+block-in-block(n,c) ::= s-l+block-scalar(n,c) | s-l+block-collection(n,c)
fn sLBlockInBlock(p: *Parser, n: i32, c: Context) Error!bool {
    return try sLBlockScalar(p, n, c) or try sLBlockCollection(p, n, c);
}

/// [199] s-l+block-scalar(n,c) ::=
///   s-separate(n+1,c) ( c-ns-properties(n+1,c) s-separate(n+1,c) )? ( c-l+literal(n) | c-l+folded(n) )
fn sLBlockScalar(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (!basic.sSeparate(p, n + 1, c)) return false;
    const t = p.save();
    if (!(try basic.cNsProperties(p, n + 1, c) and basic.sSeparate(p, n + 1, c))) p.restore(t);
    if (try cLLiteral(p, n) or try cLFolded(p, n)) return true;
    return p.fail(s);
}

/// [200] s-l+block-collection(n,c) ::=
///   ( s-separate(n+1,c) c-ns-properties(n+1,c) )? s-l-comments ( seq-space(n,c) | l+block-mapping(n) )
///
/// The optional group is tried both ways. Read as a PEG it would commit to
/// properties it could match, but in `&a key: value` they belong to the
/// first key rather than the mapping — which only comes to light when
/// `s-l-comments` fails to find the end of the line after them.
///
/// Likewise the second of two properties, which may be on the line below
/// the first and belong to that line's key instead: `!!map` then
/// `&a key: value`.
fn sLBlockCollection(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    var count: u2 = 2;
    while (count > 0) : (count -= 1) {
        if (basic.sSeparate(p, n + 1, c) and try basic.cNsPropertiesUpTo(p, n + 1, c, count)) {
            if (basic.sLComments(p) and (try seqSpace(p, n, c) or try lBlockMapping(p, n))) return true;
        }
        p.restore(s);
    }
    if (!basic.sLComments(p)) return p.fail(s);
    if (try seqSpace(p, n, c) or try lBlockMapping(p, n)) return true;
    return p.fail(s);
}

/// [201] seq-space(n,BLOCK-OUT) ::= l+block-sequence(n-1)
///       seq-space(n,BLOCK-IN)  ::= l+block-sequence(n)
fn seqSpace(p: *Parser, n: i32, c: Context) Error!bool {
    return lBlockSequence(p, if (c == .block_out) n - 1 else n);
}
