// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Tests of the public API as a whole: parsing into types, the hooks, and
//! the round trip through `Stringify`.

const std = @import("std");
const testing = std.testing;
const yaml = @import("root.zig");

const Allocator = std.mem.Allocator;

test "parsing into a struct" {
    const Config = struct {
        name: []const u8,
        port: u16 = 8080,
        debug: bool,
        ratio: f32,
        tags: []const []const u8,
        owner: ?[]const u8,
        mode: enum { fast, slow },
        limits: struct { cpu: u8, memory: u32 },
        pair: struct { i32, []const u8 },
    };
    const source =
        \\# A comment
        \\name: example
        \\debug: yes-but-quoted-means-string
        \\
    ;
    try testing.expectError(error.UnexpectedToken, yaml.parseFromSlice(Config, testing.allocator, source, .{}));

    const parsed = try yaml.parseFromSlice(Config, testing.allocator,
        \\name: "example"
        \\debug: True
        \\ratio: .5
        \\tags: [a, b]
        \\owner: ~
        \\mode: slow
        \\limits:
        \\  cpu: 0x10
        \\  memory: 1e6
        \\pair:
        \\  - -3
        \\  - three
    , .{});
    defer parsed.deinit();
    const c = parsed.value;
    try testing.expectEqualStrings("example", c.name);
    try testing.expectEqual(8080, c.port);
    try testing.expect(c.debug);
    try testing.expectEqual(0.5, c.ratio);
    try testing.expectEqual(2, c.tags.len);
    try testing.expectEqualStrings("b", c.tags[1]);
    try testing.expectEqual(null, c.owner);
    try testing.expectEqual(.slow, c.mode);
    try testing.expectEqual(16, c.limits.cpu);
    try testing.expectEqual(1_000_000, c.limits.memory);
    try testing.expectEqual(-3, c.pair[0]);
    try testing.expectEqualStrings("three", c.pair[1]);
}

test "any scalar reads as a string" {
    const parsed = try yaml.parseFromSlice(struct { version: []const u8, on: []const u8 }, testing.allocator, "version: 1.10\non: true\n", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("1.10", parsed.value.version);
    try testing.expectEqualStrings("true", parsed.value.on);
}

test "unknown, missing and duplicate fields" {
    const T = struct { a: u8 };
    try testing.expectError(error.UnknownField, yaml.parseFromSlice(T, testing.allocator, "a: 1\nb: 2\n", .{}));
    try testing.expectError(error.MissingField, yaml.parseFromSlice(T, testing.allocator, "{}", .{}));
    try testing.expectError(error.DuplicateField, yaml.parseFromSlice(T, testing.allocator, "a: 1\na: 2\n", .{}));
    const parsed = try yaml.parseFromSlice(T, testing.allocator, "a: 1\nb: [x, {y: z}]\na: 3\n", .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    });
    defer parsed.deinit();
    try testing.expectEqual(3, parsed.value.a);
}

test "tagged unions" {
    const Shape = union(enum) { circle: f32, square: struct { side: f32 }, none };
    const parsed = try yaml.parseFromSlice([]const Shape, testing.allocator,
        \\- circle: 1.5
        \\- square: {side: 2}
        \\- none
    , .{});
    defer parsed.deinit();
    try testing.expectEqual(1.5, parsed.value[0].circle);
    try testing.expectEqual(2, parsed.value[1].square.side);
    try testing.expect(parsed.value[2] == .none);
}

test "aliases are expanded for typed parsing" {
    const T = struct { base: struct { x: u8 }, copy: struct { x: u8 } };
    const parsed = try yaml.parseFromSlice(T, testing.allocator, "base: &b {x: 7}\ncopy: *b\n", .{});
    defer parsed.deinit();
    try testing.expectEqual(7, parsed.value.copy.x);
}

test "documents" {
    try testing.expectError(error.MultipleDocuments, yaml.parseFromSlice(u8, testing.allocator, "1\n---\n2\n", .{}));
    const all = try yaml.parseAllFromSlice(u8, testing.allocator, "1\n---\n2\n...\n", .{});
    defer all.deinit();
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, all.value);
    // An empty stream is a null node.
    const empty = try yaml.parseFromSlice(?u8, testing.allocator, "# nothing\n", .{});
    defer empty.deinit();
    try testing.expectEqual(null, empty.value);
}

test "strings point into the input when they can" {
    const input = "a: plain\nb: \"esc\\n\"\n";
    const parsed = try yaml.parseFromSlice(struct { a: []const u8, b: []const u8 }, testing.allocator, input, .{});
    defer parsed.deinit();
    try testing.expectEqual(input.ptr + 3, parsed.value.a.ptr);
    try testing.expectEqualStrings("esc\n", parsed.value.b);
}

/// A type with every hook, storing a duration written as `90s` or `2m`.
const Duration = struct {
    seconds: u32,

    fn fromText(text: []const u8) !Duration {
        if (text.len < 2) return error.InvalidNumber;
        const n = try std.fmt.parseInt(u32, text[0 .. text.len - 1], 10);
        return switch (text[text.len - 1]) {
            's' => .{ .seconds = n },
            'm' => .{ .seconds = n * 60 },
            else => error.InvalidNumber,
        };
    }

    pub fn yamlParse(_: Allocator, source: anytype, _: yaml.ParseOptions) !Duration {
        return switch (try source.next()) {
            .scalar => |s| fromText(s.value) catch error.InvalidNumber,
            else => error.UnexpectedToken,
        };
    }

    pub fn yamlParseFromValue(_: Allocator, source: yaml.Value, _: yaml.ParseOptions) !Duration {
        if (source != .string) return error.UnexpectedToken;
        return fromText(source.string) catch error.InvalidNumber;
    }

    pub fn yamlStringify(self: Duration, yw: *yaml.Stringify) !void {
        try yw.print("{d}s", .{self.seconds});
    }
};

test "customization hooks" {
    const T = struct { timeout: Duration };
    const parsed = try yaml.parseFromSlice(T, testing.allocator, "timeout: 2m\n", .{});
    defer parsed.deinit();
    try testing.expectEqual(120, parsed.value.timeout.seconds);

    const value = try yaml.parseFromSlice(yaml.Value, testing.allocator, "timeout: 90s\n", .{});
    defer value.deinit();
    const from_value = try yaml.parseFromValue(T, testing.allocator, value.value, .{});
    defer from_value.deinit();
    try testing.expectEqual(90, from_value.value.timeout.seconds);

    const out = try yaml.Stringify.valueAlloc(testing.allocator, parsed.value, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("timeout: 120s\n", out);
}

test "round trip through Value" {
    const source =
        \\name: round trip
        \\list: [1, 2.5, true, ~, "quoted: yes"]
        \\text: |
        \\  line one
        \\  line two
        \\? [complex, key]
        \\: value
        \\nested: {a: {b: [c]}}
        \\empty: []
        \\
    ;
    const first = try yaml.parseFromSlice(yaml.Value, testing.allocator, source, .{});
    defer first.deinit();
    for ([_]yaml.Stringify.Options{ .{}, .{ .style = .flow }, .{ .indent = 4 } }) |options| {
        const out = try yaml.Stringify.valueAlloc(testing.allocator, first.value, options);
        defer testing.allocator.free(out);
        const second = try yaml.parseFromSlice(yaml.Value, testing.allocator, out, .{});
        defer second.deinit();
        try testing.expect(first.value.eql(second.value));
    }
}

test "diagnostics say where a syntax error is" {
    var scanner: yaml.Scanner = .initCompleteInput(testing.allocator, "a: b\nc: [d\n");
    defer scanner.deinit();
    var diagnostics: yaml.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    try testing.expectError(error.SyntaxError, scanner.next());
    try testing.expectEqual(3, diagnostics.getLine());
}

// The example in README.md, kept here word for word so that it cannot stop
// compiling without a test noticing.
test "README example" {
    const gpa = testing.allocator;

    const Server = struct {
        host: []const u8,
        port: u16 = 8080,
        tags: []const []const u8 = &.{},
    };

    const source =
        \\host: example.com
        \\tags: [web, "prod"]
    ;
    const parsed = try yaml.parseFromSlice(Server, gpa, source, .{});
    defer parsed.deinit();
    try testing.expectEqual(8080, parsed.value.port);

    const text = try yaml.Stringify.valueAlloc(gpa, parsed.value, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\host: example.com
        \\port: 8080
        \\tags:
        \\  - web
        \\  - prod
        \\
    , text);
}
