// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Chapter 9 of YAML 1.2.2, "Document Stream Productions": productions
//! [202]–[211] — document markers, the three kinds of document, and the
//! stream that holds them.
//!
//! This is where the document events are emitted, and where the one
//! restriction the grammar states in prose rather than productions is
//! enforced: a bare document excludes `c-forbidden` content, which the
//! parser does by treating the first document marker at the start of a line
//! as the end of the input for as long as the document is being parsed.

const std = @import("std");

const basic = @import("basic.zig");
const block = @import("block.zig");
const chars = @import("chars.zig");
const Parser = @import("Parser.zig");
const Error = Parser.Error;

/// [202] l-document-prefix ::= c-byte-order-mark? l-comment*
fn lDocumentPrefix(p: *Parser) void {
    _ = p.eatStr(chars.bom_utf8);
    basic.lComments(p);
}

/// `l-document-prefix*`. A prefix can match nothing, so the repetition stops
/// as soon as one does.
fn lDocumentPrefixes(p: *Parser) void {
    while (true) {
        const before = p.pos;
        lDocumentPrefix(p);
        if (p.pos == before) return;
    }
}

/// [203] c-directives-end ::= "---"
fn cDirectivesEnd(p: *Parser) bool {
    return p.eatStr("---");
}

/// [204] c-document-end ::= "..." /* (not followed by non-ws char) */
fn cDocumentEnd(p: *Parser) bool {
    const s = p.save();
    if (!p.eatStr("...")) return false;
    if (!p.notFollowedByNsChar()) return p.fail(s);
    return true;
}

/// [205] l-document-suffix ::= c-document-end s-l-comments
fn lDocumentSuffix(p: *Parser) bool {
    const s = p.save();
    if (cDocumentEnd(p) and basic.sLComments(p)) return true;
    return p.fail(s);
}

/// [206] c-forbidden ::= <start-of-line> ( c-directives-end | c-document-end ) ( b-char | s-white | <end-of-input> )
///
/// Finds the first position at or after `from` where it matches, which is
/// where a bare document starting at `from` has to end.
fn forbiddenLimit(input: []const u8, from: u32, end: u32) u32 {
    var i: usize = from;
    if (!chars.isStartOfLine(input, i)) i = nextLine(input, i, end);
    while (i < end) {
        if (i + 3 <= end and
            (std.mem.eql(u8, input[i..][0..3], "---") or std.mem.eql(u8, input[i..][0..3], "...")))
        {
            if (i + 3 == end) return @intCast(i);
            switch (input[i + 3]) {
                ' ', '\t', '\n', '\r' => return @intCast(i),
                else => {},
            }
        }
        i = nextLine(input, i, end);
    }
    return end;
}

fn nextLine(input: []const u8, from: usize, end: usize) usize {
    var i = from;
    while (i < end) : (i += 1) {
        switch (input[i]) {
            '\n' => return i + 1,
            '\r' => return if (i + 1 < end and input[i + 1] == '\n') i + 2 else i + 1,
            else => {},
        }
    }
    return end;
}

/// [207] l-bare-document ::= s-l+block-node(-1,BLOCK-IN) /* Excluding c-forbidden content */
fn lBareDocument(p: *Parser) Error!bool {
    const saved_end = p.end;
    p.end = forbiddenLimit(p.input, p.pos, saved_end);
    // Memo entries depend on where the input ends, so none may outlive the
    // limit they were computed under.
    p.clearMemo();
    defer {
        p.end = saved_end;
        p.clearMemo();
    }
    return block.sLBlockNode(p, -1, .block_in);
}

/// [208] l-explicit-document ::= c-directives-end ( l-bare-document | ( e-node s-l-comments ) )
fn lExplicitDocument(p: *Parser) Error!bool {
    const s = p.save();
    const start = p.pos;
    if (!cDirectivesEnd(p)) return false;
    try p.emit(.{ .kind = .document_start, .pos = start, .flag = true, .value = p.yaml_version });
    if (try lBareDocument(p)) return true;
    try p.emitEmpty();
    if (basic.sLComments(p)) return true;
    return p.fail(s);
}

/// [209] l-directive-document ::= l-directive+ l-explicit-document
fn lDirectiveDocument(p: *Parser) Error!bool {
    const s = p.save();
    if (!try basic.lDirective(p)) return false;
    while (try basic.lDirective(p)) {}
    if (try lExplicitDocument(p)) return true;
    return p.fail(s);
}

/// Forgets the directives of the previous document: `%TAG` and `%YAML` are
/// scoped to the document they precede (§6.8).
fn resetDirectives(p: *Parser) void {
    p.tag_handles.clearRetainingCapacity();
    p.yaml_version = .none;
}

/// [210] l-any-document ::= l-directive-document | l-explicit-document | l-bare-document
fn lAnyDocument(p: *Parser) Error!bool {
    resetDirectives(p);
    if (try lDirectiveDocument(p)) return true;
    resetDirectives(p);
    if (try lExplicitDocument(p)) return true;
    const s = p.save();
    try p.emit(.{ .kind = .document_start, .pos = p.pos });
    if (try lBareDocument(p)) return true;
    return p.fail(s);
}

/// [211] l-yaml-stream ::=
///   l-document-prefix* l-any-document?
///   ( ( l-document-suffix+ l-document-prefix* l-any-document? )
///   | c-byte-order-mark
///   | l-comment
///   | l-explicit-document )*
///
/// The stream must also account for the whole input, which the production
/// leaves implicit.
pub fn lYamlStream(p: *Parser) Error!bool {
    try p.emit(.{ .kind = .stream_start, .pos = 0 });
    lDocumentPrefixes(p);
    var open = try lAnyDocument(p);
    while (true) {
        const before = p.pos;
        if (lDocumentSuffix(p)) {
            if (open) try p.emit(.{ .kind = .document_end, .pos = before, .flag = true });
            while (lDocumentSuffix(p)) {}
            lDocumentPrefixes(p);
            open = try lAnyDocument(p);
        } else if (p.eatStr(chars.bom_utf8)) {
            // A byte order mark may start any document.
        } else if (basic.lComment(p)) {
            // Stops the loop below when it matched nothing at the end.
        } else {
            const s = p.save();
            if (open) try p.emit(.{ .kind = .document_end, .pos = p.pos });
            resetDirectives(p);
            if (try lExplicitDocument(p)) {
                open = true;
            } else {
                p.restore(s);
                break;
            }
        }
        if (p.pos == before) break;
    }
    if (open) try p.emit(.{ .kind = .document_end, .pos = p.pos });
    if (!p.atEnd()) return false;
    try p.emit(.{ .kind = .stream_end, .pos = p.pos });
    return true;
}

test forbiddenLimit {
    try std.testing.expectEqual(4, forbiddenLimit("foo\n--- bar", 0, 11));
    // Not a marker unless whitespace or the end follows it.
    try std.testing.expectEqual(10, forbiddenLimit("foo\n---bar", 0, 10));
    try std.testing.expectEqual(3, forbiddenLimit("a\r\n...", 0, 6));
    // A marker on the starting line only counts if the line starts there.
    try std.testing.expectEqual(6, forbiddenLimit("--- a\n---\n", 3, 10));
}
