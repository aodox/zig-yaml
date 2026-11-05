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

const gt = @import("test_helpers.zig");

// -- [28]–[30] line breaks ---------------------------------------------------

/// [28] b-break ::= ( b-carriage-return b-line-feed ) | b-carriage-return | b-line-feed
pub fn bBreak(p: *Parser) bool {
    if (p.eatStr("\r\n")) return true;
    return p.eat('\r') or p.eat('\n');
}

test bBreak {
    try gt.expectMatch("\r\nx", bBreak, .{}, "x");
    try gt.expectMatch("\rx", bBreak, .{}, "x");
    try gt.expectNoMatch("x", bBreak, .{});
}

/// [29] b-as-line-feed ::= b-break
///
/// A line break that is content, normalized to a single line feed.
pub fn bAsLineFeed(p: *Parser) Error!bool {
    if (!bBreak(p)) return false;
    try p.appendByte('\n');
    return true;
}

test bAsLineFeed {
    var r = try gt.run("\r\nx", bAsLineFeed, .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("\n", r.content());
    try std.testing.expectEqualStrings("x", r.rest());
}

/// [30] b-non-content ::= b-break
pub fn bNonContent(p: *Parser) bool {
    return bBreak(p);
}

test bNonContent {
    var r = try gt.run("\nx", bNonContent, .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("x", r.rest());
    // Not content: nothing is added to the scalar.
    try std.testing.expectEqualStrings("", r.content());
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

test sIndent {
    try gt.expectMatch("   x", sIndent, .{2}, " x");
    try gt.expectMatch("x", sIndent, .{0}, "x");
    try gt.expectNoMatch("   x", sIndent, .{4});
    // A tab is never indentation.
    try gt.expectNoMatch("\tx", sIndent, .{1});
}

/// [64] s-indent-less-than(n) ::= s-space × m /* Where m < n */
pub fn sIndentLessThan(p: *Parser, n: i32) bool {
    var i: i32 = 0;
    while (i + 1 < n and p.eat(' ')) i += 1;
    return true;
}

test sIndentLessThan {
    try gt.expectMatch("   x", sIndentLessThan, .{2}, "  x");
    try gt.expectMatch("x", sIndentLessThan, .{2}, "x");
}

/// [65] s-indent-less-or-equal(n) ::= s-space × m /* Where m ≤ n */
pub fn sIndentLessOrEqual(p: *Parser, n: i32) bool {
    var i: i32 = 0;
    while (i < n and p.eat(' ')) i += 1;
    return true;
}

test sIndentLessOrEqual {
    try gt.expectMatch("   x", sIndentLessOrEqual, .{2}, " x");
    try gt.expectMatch("x", sIndentLessOrEqual, .{2}, "x");
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

test sSeparateInLine {
    try gt.expectMatch(" \t x", sSeparateInLine, .{}, "x");
    // Nothing at all, at the start of a line.
    try gt.expectMatch("x", sSeparateInLine, .{}, "x");
    var p = try Parser.init(std.testing.allocator, "ab");
    defer p.deinit();
    p.pos = 1;
    try std.testing.expect(!sSeparateInLine(&p));
}

/// [67] s-line-prefix(n,c)
pub fn sLinePrefix(p: *Parser, n: i32, c: Context) bool {
    return switch (c) {
        .block_out, .block_in => sBlockLinePrefix(p, n),
        else => sFlowLinePrefix(p, n),
    };
}

test sLinePrefix {
    try gt.expectMatch("   x", sLinePrefix, .{ 2, .block_in }, " x");
    // A flow line prefix takes any whitespace after the indentation too.
    try gt.expectMatch("   x", sLinePrefix, .{ 2, .flow_in }, "x");
}

/// [68] s-block-line-prefix(n) ::= s-indent(n)
pub fn sBlockLinePrefix(p: *Parser, n: i32) bool {
    return sIndent(p, n);
}

test sBlockLinePrefix {
    try gt.expectMatch("   x", sBlockLinePrefix, .{2}, " x");
    try gt.expectNoMatch(" x", sBlockLinePrefix, .{2});
}

/// [69] s-flow-line-prefix(n) ::= s-indent(n) s-separate-in-line?
pub fn sFlowLinePrefix(p: *Parser, n: i32) bool {
    if (!sIndent(p, n)) return false;
    _ = sSeparateInLine(p);
    return true;
}

test sFlowLinePrefix {
    try gt.expectMatch("  \t x", sFlowLinePrefix, .{2}, "x");
    try gt.expectNoMatch("  x", sFlowLinePrefix, .{3});
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

test lEmpty {
    var r = try gt.run("  \nx", lEmpty, .{ 2, .block_in });
    defer r.deinit();
    try std.testing.expectEqualStrings("\n", r.content());
    try std.testing.expectEqualStrings("x", r.rest());
    // Less indentation than the block's is still an empty line.
    try gt.expectMatch("\nx", lEmpty, .{ 2, .block_in }, "x");
    try gt.expectNoMatch("  a\n", lEmpty, .{ 2, .block_in });
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

test bAsLineFeedOrEnd {
    try gt.expectMatch("\nx", bAsLineFeedOrEnd, .{0}, "x");
    var p = try Parser.init(std.testing.allocator, "ab");
    defer p.deinit();
    p.pos = 2;
    // The end of the input ends a line with something on it...
    try std.testing.expect(try bAsLineFeedOrEnd(&p, 0));
    try std.testing.expectEqualStrings("\n", p.scratch.items);
    // ...but only once.
    try std.testing.expect(!try bAsLineFeedOrEnd(&p, 2));
}

/// [71] b-l-trimmed(n,c) ::= b-non-content l-empty(n,c)+
pub fn bLTrimmed(p: *Parser, n: i32, c: Context) Error!bool {
    const s = p.save();
    if (!bNonContent(p)) return false;
    if (!try lEmpty(p, n, c)) return p.fail(s);
    while (try lEmpty(p, n, c)) {}
    return true;
}

test bLTrimmed {
    var r = try gt.run("\n\nx", bLTrimmed, .{ 0, .flow_in });
    defer r.deinit();
    // The first break is dropped; the empty line after it is kept.
    try std.testing.expectEqualStrings("\n", r.content());
    try std.testing.expectEqualStrings("x", r.rest());
    try gt.expectNoMatch("\nx", bLTrimmed, .{ 0, .flow_in });
}

/// [72] b-as-space ::= b-break
pub fn bAsSpace(p: *Parser) Error!bool {
    if (!bBreak(p)) return false;
    try p.appendByte(' ');
    return true;
}

test bAsSpace {
    var r = try gt.run("\nx", bAsSpace, .{});
    defer r.deinit();
    try std.testing.expectEqualStrings(" ", r.content());
}

/// [73] b-l-folded(n,c) ::= b-l-trimmed(n,c) | b-as-space
pub fn bLFolded(p: *Parser, n: i32, c: Context) Error!bool {
    return try bLTrimmed(p, n, c) or try bAsSpace(p);
}

test bLFolded {
    var single = try gt.run("\nx", bLFolded, .{ 0, .flow_in });
    defer single.deinit();
    try std.testing.expectEqualStrings(" ", single.content());
    var double = try gt.run("\n\nx", bLFolded, .{ 0, .flow_in });
    defer double.deinit();
    try std.testing.expectEqualStrings("\n", double.content());
}

/// [74] s-flow-folded(n) ::= s-separate-in-line? b-l-folded(n,FLOW-IN) s-flow-line-prefix(n)
pub fn sFlowFolded(p: *Parser, n: i32) Error!bool {
    const s = p.save();
    _ = sSeparateInLine(p);
    if (try bLFolded(p, n, .flow_in) and sFlowLinePrefix(p, n)) return true;
    return p.fail(s);
}

test sFlowFolded {
    var r = try gt.run(" \n  x", sFlowFolded, .{1});
    defer r.deinit();
    try std.testing.expectEqualStrings(" ", r.content());
    try std.testing.expectEqualStrings("x", r.rest());
    try gt.expectNoMatch(" x", sFlowFolded, .{1});
}

// -- [75]–[79] comments ------------------------------------------------------

/// [75] c-nb-comment-text ::= c-comment nb-char*
pub fn cNbCommentText(p: *Parser) bool {
    if (!p.eat('#')) return false;
    while (p.eatCp(chars.isNbChar)) {}
    return true;
}

test cNbCommentText {
    try gt.expectMatch("# hi\nx", cNbCommentText, .{}, "\nx");
    try gt.expectNoMatch("x", cNbCommentText, .{});
}

/// [76] b-comment ::= b-non-content | <end-of-input>
pub fn bComment(p: *Parser) bool {
    return bNonContent(p) or p.atEnd();
}

test bComment {
    try gt.expectMatch("\nx", bComment, .{}, "x");
    try gt.expectMatch("", bComment, .{}, "");
    try gt.expectNoMatch("x", bComment, .{});
}

/// [77] s-b-comment ::= ( s-separate-in-line c-nb-comment-text? )? b-comment
pub fn sBComment(p: *Parser) bool {
    const s = p.save();
    if (sSeparateInLine(p)) _ = cNbCommentText(p);
    if (bComment(p)) return true;
    return p.fail(s);
}

test sBComment {
    try gt.expectMatch("  # c\nx", sBComment, .{}, "x");
    try gt.expectMatch("\nx", sBComment, .{}, "x");
    try gt.expectNoMatch("  x", sBComment, .{});
}

/// [78] l-comment ::= s-separate-in-line c-nb-comment-text? b-comment
pub fn lComment(p: *Parser) bool {
    const s = p.save();
    if (!sSeparateInLine(p)) return false;
    _ = cNbCommentText(p);
    if (bComment(p)) return true;
    return p.fail(s);
}

test lComment {
    try gt.expectMatch("  # c\nx", lComment, .{}, "x");
    try gt.expectMatch("# c\n", lComment, .{}, "");
    try gt.expectNoMatch("x", lComment, .{});
}

/// [79] s-l-comments ::= ( s-b-comment | <start-of-line> ) l-comment*
pub fn sLComments(p: *Parser) bool {
    if (!sBComment(p) and !p.atStartOfLine()) return false;
    lComments(p);
    return true;
}

test sLComments {
    try gt.expectMatch(" # a\n# b\n\nx", sLComments, .{}, "x");
    try gt.expectMatch("x", sLComments, .{}, "x");
}

/// `l-comment*`. Guarded against the zero-width match `l-comment` makes at
/// the end of the input, which would otherwise repeat forever.
pub fn lComments(p: *Parser) void {
    while (true) {
        const before = p.pos;
        if (!lComment(p) or p.pos == before) break;
    }
}

test lComments {
    try gt.expectMatch("# a\n  # b\nx", lComments, .{}, "x");
    // Ends rather than matching nothing forever at the end of the input.
    try gt.expectMatch("# a", lComments, .{}, "");
}

// -- [80]–[81] separation lines ----------------------------------------------

/// [80] s-separate(n,c)
pub fn sSeparate(p: *Parser, n: i32, c: Context) bool {
    return switch (c) {
        .block_key, .flow_key => sSeparateInLine(p),
        else => sSeparateLines(p, n),
    };
}

test sSeparate {
    // In a key, separation cannot cross a line.
    try gt.expectMatch(" \nx", sSeparate, .{ 0, .block_key }, "\nx");
    try gt.expectMatch(" # c\n x", sSeparate, .{ 0, .flow_in }, "x");
}

/// [81] s-separate-lines(n) ::= ( s-l-comments s-flow-line-prefix(n) ) | s-separate-in-line
pub fn sSeparateLines(p: *Parser, n: i32) bool {
    const s = p.save();
    if (sLComments(p) and sFlowLinePrefix(p, n)) return true;
    p.restore(s);
    return sSeparateInLine(p);
}

test sSeparateLines {
    try gt.expectMatch("\n  x", sSeparateLines, .{2}, "x");
    try gt.expectMatch(" x", sSeparateLines, .{2}, "x");
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

test lDirective {
    var r = try gt.run("%YAML 1.2 # c\n---", lDirective, .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("---", r.rest());
    try std.testing.expectEqualStrings("1.2", r.p.slice(r.p.yaml_version));
    try gt.expectMatch("%FOO bar baz\n", lDirective, .{}, "");
    try gt.expectNoMatch("--- x", lDirective, .{});
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

test nsReservedDirective {
    try gt.expectMatch("FOO bar baz\n", nsReservedDirective, .{}, "\n");
    try gt.expectNoMatch("YAML 1.2", nsReservedDirective, .{});
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

test nsYamlDirective {
    try gt.expectMatch("YAML 1.2 # c", nsYamlDirective, .{}, " # c");
    try gt.expectNoMatch("YAML 1.2x", nsYamlDirective, .{});
    var p = try Parser.init(std.testing.allocator, "YAML 1.2");
    defer p.deinit();
    try std.testing.expect(try nsYamlDirective(&p));
    p.pos = 0;
    try std.testing.expectError(error.DuplicateDirective, nsYamlDirective(&p));
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

test nsTagDirective {
    var r = try gt.run("TAG !e! tag:example.com,2000:\n", nsTagDirective, .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("\n", r.rest());
    try std.testing.expectEqualStrings("!e!", r.p.tag_handles.items[0].handle);
    try std.testing.expectEqualStrings("tag:example.com,2000:", r.p.slice(r.p.tag_handles.items[0].prefix));
    try gt.expectNoMatch("TAG !e!\n", nsTagDirective, .{});
}

/// [89] c-tag-handle ::= c-named-tag-handle | c-secondary-tag-handle | c-primary-tag-handle
pub fn cTagHandle(p: *Parser) bool {
    return cNamedTagHandle(p) or p.eatStr("!!") or p.eat('!');
}

test cTagHandle {
    try gt.expectMatch("!e!x", cTagHandle, .{}, "x");
    try gt.expectMatch("!!str", cTagHandle, .{}, "str");
    try gt.expectMatch("!x", cTagHandle, .{}, "x");
    try gt.expectNoMatch("x", cTagHandle, .{});
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

test nsUriChar {
    try gt.expectMatch("%2Fx", nsUriChar, .{}, "x");
    try gt.expectMatch("/x", nsUriChar, .{}, "x");
    try gt.expectNoMatch("%zz", nsUriChar, .{});
    try gt.expectNoMatch("<", nsUriChar, .{});
}

/// [40] ns-tag-char
pub fn nsTagChar(p: *Parser) bool {
    return percentEscape(p) or p.eatCp(chars.isTagCharSingle);
}

test nsTagChar {
    try gt.expectMatch("%21x", nsTagChar, .{}, "x");
    try gt.expectNoMatch("!x", nsTagChar, .{});
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

test cNsProperties {
    var r = try gt.run("!!str &a x", cNsProperties, .{ 0, .block_in });
    defer r.deinit();
    try std.testing.expectEqualStrings(" x", r.rest());
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", r.p.slice(r.p.props.tag));
    try std.testing.expectEqualStrings("a", r.p.slice(r.p.props.anchor));
    try gt.expectNoMatch("x", cNsProperties, .{ 0, .block_in });
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

test cNsPropertiesUpTo {
    var r = try gt.run("&a !t x", cNsPropertiesUpTo, .{ 0, .block_in, 1 });
    defer r.deinit();
    try std.testing.expectEqualStrings(" !t x", r.rest());
    try std.testing.expect(r.p.props.tag.isNone());
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

test cNsTagProperty {
    const tagOf = struct {
        fn f(input: []const u8, expected: []const u8) !void {
            var r = try gt.run(input, cNsTagProperty, .{});
            defer r.deinit();
            try std.testing.expect(r.matched);
            try std.testing.expectEqualStrings(expected, r.p.slice(r.p.props.tag));
        }
    }.f;
    try tagOf("!<tag:x> y", "tag:x");
    try tagOf("!local y", "!local");
    try tagOf("!!a%21 y", "tag:yaml.org,2002:a!");
    try tagOf("! y", "!");
    var p = try Parser.init(std.testing.allocator, "!e!x y");
    defer p.deinit();
    try std.testing.expectError(error.UndefinedTagHandle, cNsTagProperty(&p));
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

test cNsAnchorProperty {
    var r = try gt.run("&anchor x", cNsAnchorProperty, .{});
    defer r.deinit();
    try std.testing.expectEqualStrings(" x", r.rest());
    try std.testing.expectEqualStrings("anchor", r.p.slice(r.p.props.anchor));
    try gt.expectNoMatch("& x", cNsAnchorProperty, .{});
}

/// [103] ns-anchor-name ::= ns-anchor-char+
pub fn nsAnchorName(p: *Parser) bool {
    if (!p.eatCp(chars.isAnchorChar)) return false;
    while (p.eatCp(chars.isAnchorChar)) {}
    return true;
}

test nsAnchorName {
    // `:` may be in an anchor name; a flow indicator may not.
    try gt.expectMatch("a:b, c", nsAnchorName, .{}, ", c");
    try gt.expectNoMatch(" a", nsAnchorName, .{});
}
