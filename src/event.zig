// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What a `Scanner` produces: the YAML event stream of §3.1.2, the
//! serialization tree flattened into the order a depth-first walk meets it.
//!
//! A stream is `stream_start`, any number of documents, and `stream_end`. A
//! document is `document_start`, exactly one node, and `document_end`. A node
//! is a `scalar`, an `alias`, or a collection: `sequence_start` and its
//! entries then `sequence_end`, or `mapping_start`, keys and values
//! alternating, then `mapping_end`.
//!
//! The strings an event carries point into the input or into the scanner's
//! own buffer, and are valid until the scanner is deinitialized.

pub const Event = union(enum) {
    stream_start,
    stream_end,
    document_start: DocumentStart,
    document_end: DocumentEnd,
    sequence_start: CollectionStart,
    sequence_end,
    mapping_start: CollectionStart,
    mapping_end,
    scalar: Scalar,
    alias: Alias,
};

pub const EventType = @import("std").meta.Tag(Event);

pub const DocumentStart = struct {
    /// Whether the document began with a `---` marker.
    explicit: bool,
    /// The version of a `%YAML` directive, if there was one.
    version: ?[]const u8 = null,
};

pub const DocumentEnd = struct {
    /// Whether the document ended with a `...` marker.
    explicit: bool,
};

pub const CollectionStyle = enum { block, flow };

pub const ScalarStyle = enum { plain, single_quoted, double_quoted, literal, folded };

pub const CollectionStart = struct {
    anchor: ?[]const u8 = null,
    /// The tag, fully expanded: `!!map` arrives as `tag:yaml.org,2002:map`.
    /// The non-specific tag `!` arrives as `!`; a node with no tag at all has
    /// null.
    tag: ?[]const u8 = null,
    style: CollectionStyle,
};

pub const Scalar = struct {
    anchor: ?[]const u8 = null,
    /// As for `CollectionStart.tag`.
    tag: ?[]const u8 = null,
    /// The content, with escapes decoded, lines folded and chomping applied.
    value: []const u8,
    style: ScalarStyle,
};

pub const Alias = struct {
    /// The anchor the alias refers to, without the `*`.
    name: []const u8,
};
