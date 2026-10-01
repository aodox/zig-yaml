// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Chapter 6 of YAML 1.2.2, "Structural Productions": productions [63]–[103]
//! — indentation, separation, line folding, comments, directives and node
//! properties — together with the line break productions [28]–[30] of
//! chapter 5, which are the only ones there that consume input.
//!
//! Every function here restores the parser when it does not match.

const std = @import("std");

const chars = @import("chars.zig");
const Parser = @import("Parser.zig");
const Context = Parser.Context;
const Error = Parser.Error;

// -- [28]–[30] line breaks ---------------------------------------------------

/// [28] b-break ::= ( b-carriage-return b-line-feed ) | b-carriage-return | b-line-feed
pub fn bBreak(p: *Parser) bool {
    if (p.eatStr("\r\n")) return true;
    return p.eat('\r') or p.eat('\n');
}

/// [29] b-as-line-feed ::= b-break
///
/// A line break that is content, normalized to a single line feed.
pub fn bAsLineFeed(p: *Parser) Error!bool {
    if (!bBreak(p)) return false;
    try p.appendByte('\n');
    return true;
}

/// [30] b-non-content ::= b-break
pub fn bNonContent(p: *Parser) bool {
    return bBreak(p);
}

// -- [63]–[65] indentation ---------------------------------------------------

/// [63] s-indent(n) ::= s-space × n
pub fn sIndent(p: *Parser, n: i32) bool {
    if (n <= 0) return true;
    const count: u32 = @intCast(n);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (p.peekByte(i) != ' ') return false;
    }
    p.pos += count;
    return true;
}

/// [64] s-indent-less-than(n) ::= s-space × m /* Where m < n */
pub fn sIndentLessThan(p: *Parser, n: i32) bool {
    var i: i32 = 0;
    while (i + 1 < n and p.eat(' ')) i += 1;
    return true;
}

/// [65] s-indent-less-or-equal(n) ::= s-space × m /* Where m ≤ n */
pub fn sIndentLessOrEqual(p: *Parser, n: i32) bool {
    var i: i32 = 0;
    while (i < n and p.eat(' ')) i += 1;
    return true;
}

// -- [66]–[69] separation and line prefixes ----------------------------------

/// [66] s-separate-in-line ::= s-white+ | <start-of-line>
pub fn sSeparateInLine(p: *Parser) bool {
    if (p.eatCp(chars.isWhite)) {
        while (p.eatCp(chars.isWhite)) {}
        return true;
    }
    return p.atStartOfLine();
}

/// [67] s-line-prefix(n,c)
pub fn sLinePrefix(p: *Parser, n: i32, c: Context) bool {
    return switch (c) {
        .block_out, .block_in => sBlockLinePrefix(p, n),
        else => sFlowLinePrefix(p, n),
    };
}

/// [68] s-block-line-prefix(n) ::= s-indent(n)
pub fn sBlockLinePrefix(p: *Parser, n: i32) bool {
    return sIndent(p, n);
}

/// [69] s-flow-line-prefix(n) ::= s-indent(n) s-separate-in-line?
pub fn sFlowLinePrefix(p: *Parser, n: i32) bool {
    if (!sIndent(p, n)) return false;
    _ = sSeparateInLine(p);
    return true;
}

// -- [70]–[74] empty lines and line folding ----------------------------------

/// [70] l-empty(n,c) ::= ( s-line-prefix(n,c) | s-indent-less-than(n) ) b-as-line-feed
///
/// An empty line inside a scalar, which is content: a line feed.
///
/// A last line of nothing but spaces, with no line break after it, counts as
/// an empty line too: the test suite reads the end of the input as ending
/// the line, as it does for the last line of a block scalar.
pub fn lEmpty(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (sLinePrefix(p, n, c) and try bAsLineFeedOrEnd(p, s.pos)) return true;
    p.restore(s);
    _ = sIndentLessThan(p, n);
    if (try bAsLineFeedOrEnd(p, s.pos)) return true;
    return p.fail(s);
}

/// `b-as-line-feed`, or the end of the input where it ends a line that has
/// something on it — something consumed since `line`, so that the end of the
/// input can end a line only once.
pub fn bAsLineFeedOrEnd(p: *Parser, line: u32) Error!bool {
    if (try bAsLineFeed(p)) return true;
    if (p.atEnd() and p.pos > line) {
        try p.appendByte('\n');
        return true;
    }
    return false;
}

/// [71] b-l-trimmed(n,c) ::= b-non-content l-empty(n,c)+
pub fn bLTrimmed(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (!bNonContent(p)) return false;
    if (!try lEmpty(p, n, c)) return p.fail(s);
    while (try lEmpty(p, n, c)) {}
    return true;
}

/// [72] b-as-space ::= b-break
pub fn bAsSpace(p: *Parser) Error!bool {
    if (!bBreak(p)) return false;
    try p.appendByte(' ');
    return true;
}

/// [73] b-l-folded(n,c) ::= b-l-trimmed(n,c) | b-as-space
pub fn bLFolded(p: *Parser, n: i32, c: Context) Error!bool {
    return try bLTrimmed(p, n, c) or try bAsSpace(p);
}

/// [74] s-flow-folded(n) ::= s-separate-in-line? b-l-folded(n,FLOW-IN) s-flow-line-prefix(n)
pub fn sFlowFolded(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    _ = sSeparateInLine(p);
    if (try bLFolded(p, n, .flow_in) and sFlowLinePrefix(p, n)) return true;
    return p.fail(s);
}

// -- [75]–[79] comments ------------------------------------------------------

/// [75] c-nb-comment-text ::= c-comment nb-char*
pub fn cNbCommentText(p: *Parser) bool {
    if (!p.eat('#')) return false;
    while (p.eatCp(chars.isNbChar)) {}
    return true;
}

/// [76] b-comment ::= b-non-content | <end-of-input>
pub fn bComment(p: *Parser) bool {
    return bNonContent(p) or p.atEnd();
}

/// [77] s-b-comment ::= ( s-separate-in-line c-nb-comment-text? )? b-comment
pub fn sBComment(p: *Parser) bool {
    const s = p.save();
    if (sSeparateInLine(p)) _ = cNbCommentText(p);
    if (bComment(p)) return true;
    return p.fail(s);
}

/// [78] l-comment ::= s-separate-in-line c-nb-comment-text? b-comment
pub fn lComment(p: *Parser) bool {
    const s = p.save();
    if (!sSeparateInLine(p)) return false;
    _ = cNbCommentText(p);
    if (bComment(p)) return true;
    return p.fail(s);
}

/// [79] s-l-comments ::= ( s-b-comment | <start-of-line> ) l-comment*
pub fn sLComments(p: *Parser) bool {
    if (!sBComment(p) and !p.atStartOfLine()) return false;
    lComments(p);
    return true;
}

/// `l-comment*`. Guarded against the zero-width match `l-comment` makes at
/// the end of the input, which would otherwise repeat forever.
pub fn lComments(p: *Parser) void {
    while (true) {
        const before = p.pos;
        if (!lComment(p) or p.pos == before) break;
    }
}

// -- [80]–[81] separation lines ----------------------------------------------

/// [80] s-separate(n,c)
pub fn sSeparate(p: *Parser, n: i32, c: Context) bool {
    return switch (c) {
        .block_key, .flow_key => sSeparateInLine(p),
        else => sSeparateLines(p, n),
    };
}

/// [81] s-separate-lines(n) ::= ( s-l-comments s-flow-line-prefix(n) ) | s-separate-in-line
pub fn sSeparateLines(p: *Parser, n: i32) bool {
    const s = p.save();
    if (sLComments(p) and sFlowLinePrefix(p, n)) return true;
    p.restore(s);
    return sSeparateInLine(p);
}

// -- [82]–[95] directives ----------------------------------------------------

/// [82] l-directive ::= c-directive ( ns-yaml-directive | ns-tag-directive | ns-reserved-directive ) s-l-comments
pub fn lDirective(p: *Parser) Error!bool {
    const s = p.save();
    if (!p.eat('%')) return false;
    const matched = try nsYamlDirective(p) or try nsTagDirective(p) or nsReservedDirective(p);
    if (matched and sLComments(p)) return true;
    return p.fail(s);
}

/// [83] ns-reserved-directive ::= ns-directive-name ( s-separate-in-line ns-directive-parameter )*
///
/// Deviation: a directive named `YAML` or `TAG` is never a reserved one. The
/// grammar would otherwise let `%YAML 1.2 junk` fail as a YAML directive and
/// then succeed as a reserved directive of the same name, which the test
/// suite (and common sense) says is an error.
pub fn nsReservedDirective(p: *Parser) bool {
    const s = p.save();
    const start = p.pos;
    if (!nsDirectiveName(p)) return false;
    const name = p.input[start..p.pos];
    if (std.mem.eql(u8, name, "YAML") or std.mem.eql(u8, name, "TAG")) return p.fail(s);
    while (true) {
        const t = p.save();
        if (sSeparateInLine(p) and nsDirectiveParameter(p)) continue;
        p.restore(t);
        break;
    }
    return true;
}

/// [84] ns-directive-name ::= ns-char+
fn nsDirectiveName(p: *Parser) bool {
    if (!p.eatCp(chars.isNsChar)) return false;
    while (p.eatCp(chars.isNsChar)) {}
    return true;
}

/// [85] ns-directive-parameter ::= ns-char+
fn nsDirectiveParameter(p: *Parser) bool {
    return nsDirectiveName(p);
}

/// [86] ns-yaml-directive ::= "YAML" s-separate-in-line ns-yaml-version
pub fn nsYamlDirective(p: *Parser) Error!bool {
    const s = p.save();
    if (!p.eatStr("YAML")) return false;
    if (!p.eatCp(chars.isWhite)) return p.fail(s);
    while (p.eatCp(chars.isWhite)) {}
    const start = p.pos;
    if (!nsYamlVersion(p)) return p.fail(s);
    // The version must end the directive: `%YAML 1.2x` is not version 1.2.
    if (!p.notFollowedByNsChar()) return p.fail(s);
    if (!p.yaml_version.isNone()) return error.DuplicateDirective;
    p.yaml_version = p.inputSpan(start, p.pos);
    return true;
}

/// [87] ns-yaml-version ::= ns-dec-digit+ '.' ns-dec-digit+
fn nsYamlVersion(p: *Parser) bool {
    const s = p.save();
    if (!p.eatCp(chars.isDecDigit)) return false;
    while (p.eatCp(chars.isDecDigit)) {}
    if (!p.eat('.')) return p.fail(s);
    if (!p.eatCp(chars.isDecDigit)) return p.fail(s);
    while (p.eatCp(chars.isDecDigit)) {}
    return true;
}

/// [88] ns-tag-directive ::= "TAG" s-separate-in-line c-tag-handle s-separate-in-line ns-tag-prefix
pub fn nsTagDirective(p: *Parser) Error!bool {
    const s = p.save();
    if (!p.eatStr("TAG")) return false;
    if (!p.eatCp(chars.isWhite)) return p.fail(s);
    while (p.eatCp(chars.isWhite)) {}
    const handle_start = p.pos;
    if (!cTagHandle(p)) return p.fail(s);
    const handle = p.input[handle_start..p.pos];
    if (!p.eatCp(chars.isWhite)) return p.fail(s);
    while (p.eatCp(chars.isWhite)) {}
    const prefix_start = p.pos;
    if (!nsTagPrefix(p)) return p.fail(s);
    for (p.tag_handles.items) |h| {
        if (std.mem.eql(u8, h.handle, handle)) return error.DuplicateDirective;
    }
    try p.tag_handles.append(p.gpa, .{ .handle = handle, .prefix = p.inputSpan(prefix_start, p.pos) });
    return true;
}

/// [89] c-tag-handle ::= c-named-tag-handle | c-secondary-tag-handle | c-primary-tag-handle
pub fn cTagHandle(p: *Parser) bool {
    return cNamedTagHandle(p) or p.eatStr("!!") or p.eat('!');
}

/// [92] c-named-tag-handle ::= c-tag ns-word-char+ c-tag
fn cNamedTagHandle(p: *Parser) bool {
    const s = p.save();
    if (!p.eat('!')) return false;
    if (!p.eatCp(chars.isWordChar)) return p.fail(s);
    while (p.eatCp(chars.isWordChar)) {}
    if (!p.eat('!')) return p.fail(s);
    return true;
}

/// [93] ns-tag-prefix ::= c-ns-local-tag-prefix | ns-global-tag-prefix
fn nsTagPrefix(p: *Parser) bool {
    // [94] c-ns-local-tag-prefix ::= c-tag ns-uri-char*
    if (p.eat('!')) {
        while (nsUriChar(p)) {}
        return true;
    }
    // [95] ns-global-tag-prefix ::= ns-tag-char ns-uri-char*
    if (!nsTagChar(p)) return false;
    while (nsUriChar(p)) {}
    return true;
}

/// [39] ns-uri-char
pub fn nsUriChar(p: *Parser) bool {
    return percentEscape(p) or p.eatCp(chars.isUriCharSingle);
}

/// [40] ns-tag-char
pub fn nsTagChar(p: *Parser) bool {
    return percentEscape(p) or p.eatCp(chars.isTagCharSingle);
}

/// The `'%' ns-hex-digit{2}` alternative of [39].
fn percentEscape(p: *Parser) bool {
    if (p.peekByte(0) != '%') return false;
    const h1 = p.peekByte(1) orelse return false;
    const h2 = p.peekByte(2) orelse return false;
    if (chars.hexValue(h1) == null or chars.hexValue(h2) == null) return false;
    p.pos += 3;
    return true;
}

// -- [96]–[103] node properties ----------------------------------------------

/// [96] c-ns-properties(n,c) ::=
///        ( c-ns-tag-property ( s-separate(n,c) c-ns-anchor-property )? )
///      | ( c-ns-anchor-property ( s-separate(n,c) c-ns-tag-property )? )
///
/// Leaves what it read in `p.props` for the node that follows to claim.
pub fn cNsProperties(p: *Parser, n: i32, c: Context) Error!bool {
    return cNsPropertiesUpTo(p, n, c, 2);
}

/// `c-ns-properties` reading at most `count` properties. The second property
/// may be on the next line, where it may instead belong to the first key of
/// a mapping the first property is on — which a caller finds out only later,
/// and settles by reading the first property alone.
pub fn cNsPropertiesUpTo(p: *Parser, n: i32, c: Context, count: u2) Error!bool {
    if (try cNsTagProperty(p)) {
        const s = p.save();
        if (!(count > 1 and sSeparate(p, n, c) and cNsAnchorProperty(p))) p.restore(s);
        return true;
    }
    if (cNsAnchorProperty(p)) {
        const s = p.save();
        if (!(count > 1 and sSeparate(p, n, c) and try cNsTagProperty(p))) p.restore(s);
        return true;
    }
    return false;
}

/// [97] c-ns-tag-property ::= c-verbatim-tag | c-ns-shorthand-tag | c-non-specific-tag
pub fn cNsTagProperty(p: *Parser) Error!bool {
    const start = p.pos;
    const s = p.save();
    // [98] c-verbatim-tag ::= "!<" ns-uri-char+ '>'
    if (p.eatStr("!<")) {
        const uri_start = p.pos;
        if (nsUriChar(p)) {
            while (nsUriChar(p)) {}
            const uri_end = p.pos;
            if (p.eat('>')) {
                p.props.tag = p.inputSpan(uri_start, uri_end);
                p.props.tag_pos = start;
                return true;
            }
        }
        return p.fail(s);
    }
    // [99] c-ns-shorthand-tag ::= c-tag-handle ns-tag-char+
    if (cTagHandle(p)) {
        const handle = p.input[start..p.pos];
        const suffix_start = p.pos;
        if (nsTagChar(p)) {
            while (nsTagChar(p)) {}
            p.props.tag = try expandTag(p, handle, p.input[suffix_start..p.pos]);
            p.props.tag_pos = start;
            return true;
        }
        p.restore(s);
    }
    // [100] c-non-specific-tag ::= '!'
    if (p.eat('!')) {
        p.props.tag = p.inputSpan(start, p.pos);
        p.props.tag_pos = start;
        return true;
    }
    return false;
}

/// Resolves a tag shorthand against the document's `%TAG` directives and the
/// two default handles (§6.8.2.2), percent-decoding the suffix.
fn expandTag(p: *Parser, handle: []const u8, suffix: []const u8) Error!Parser.Span {
    var prefix: []const u8 = undefined;
    for (p.tag_handles.items) |h| {
        if (std.mem.eql(u8, h.handle, handle)) {
            prefix = p.slice(h.prefix);
            break;
        }
    } else if (std.mem.eql(u8, handle, "!")) {
        prefix = "!";
    } else if (std.mem.eql(u8, handle, "!!")) {
        prefix = "tag:yaml.org,2002:";
    } else {
        return error.UndefinedTagHandle;
    }
    const off: u32 = @intCast(p.buffer.items.len);
    try p.buffer.appendSlice(p.gpa, prefix);
    var i: usize = 0;
    while (i < suffix.len) : (i += 1) {
        // ns-tag-char only admits a '%' followed by two hex digits.
        if (suffix[i] == '%' and i + 2 < suffix.len) {
            const hi = chars.hexValue(suffix[i + 1]).?;
            const lo = chars.hexValue(suffix[i + 2]).?;
            try p.buffer.append(p.gpa, hi * 16 + lo);
            i += 2;
        } else {
            try p.buffer.append(p.gpa, suffix[i]);
        }
    }
    return .{ .off = off, .len = @intCast(p.buffer.items.len - off), .src = .buffer };
}

/// [101] c-ns-anchor-property ::= c-anchor ns-anchor-name
pub fn cNsAnchorProperty(p: *Parser) bool {
    const start = p.pos;
    if (!p.eat('&')) return false;
    const name_start = p.pos;
    if (!nsAnchorName(p)) {
        p.pos = start;
        return false;
    }
    p.props.anchor = p.inputSpan(name_start, p.pos);
    p.props.anchor_pos = start;
    return true;
}

/// [103] ns-anchor-name ::= ns-anchor-char+
pub fn nsAnchorName(p: *Parser) bool {
    if (!p.eatCp(chars.isAnchorChar)) return false;
    while (p.eatCp(chars.isAnchorChar)) {}
    return true;
}
