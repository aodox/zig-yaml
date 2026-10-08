// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Run the fuzz targets in `tests/fuzz.zig` against input this makes up.
//!
//! Zig has a fuzzer of its own and those targets are written for it:
//! `zig build fuzz --fuzz` is the coverage-guided one, and works because
//! `build.zig` compiles the test binary with LLVM. This is the other way in.
//! It has no coverage feedback, only a corpus: it makes an input, hands it to
//! a target, and says so when one comes back with an error. What it has that
//! Zig's fuzzer does not is the yaml-test-suite as seeds, a watchdog for
//! inputs that take too long, and a run that is the same on every machine
//! for a given seed, which is why CI runs this one.
//!
//! ```console
//! $ zig build fuzz-run                                # a minute of each
//! $ zig build fuzz-run -- --seconds 300 --target documents
//! $ zig build fuzz-run -- --seed 12345                # exactly again
//! $ zig build fuzz-run -- --input fuzz-findings/x.bin --target documents
//! ```
//!
//! # What an input is
//!
//! Not a file: a `std.testing.Smith` reads it as a stream of answers, and the
//! encoding is worth knowing before writing a generator for it.
//!
//! * `smith.slice(buf)` reads **four** bytes as a little-endian `u32` length,
//!   then that many bytes of content. A length larger than `buf.len` is not
//!   reduced into range — it yields an *empty* slice. So a string of random
//!   bytes gives almost every target nothing at all to parse, and a generator
//!   that does not write a plausible length is fuzzing nothing.
//! * `smith.value(T)` reads **eight** bytes as a little-endian `u64` and, if
//!   that value is outside the asked-for range, returns the range's minimum
//!   rather than reducing it. For an `i64` every value is in range; for a
//!   `bool` only 0 and 1 are, so random bytes make it false every time.
//!
//! Every target here begins with a `slice`, so `makeInput` writes two
//! length-prefixed chunks — two because a target may ask for two slices, and
//! the second would otherwise only ever see the random tail — and each chunk
//! is a mutation of one of the target's own seeds. That corpus is the whole of
//! what stands in for coverage feedback, and `zig build fuzz-run` adds every
//! document of the yaml-test-suite to it (`--corpus DIR`) for the targets
//! that read YAML: four hundred inputs written by people who knew where the
//! grammar's corners are. Random bytes are almost never YAML of any interest;
//! starting from something that already parses is what gets past the first
//! character.
//!
//! The length is capped at the target's own buffer size, which `Target` has to
//! carry for the reason above: a length larger than the buffer yields nothing
//! rather than a truncation, and getting it wrong is silent — the target runs,
//! reports no failure, and was handed the empty string every time.
//!
//! # The watchdog
//!
//! The grammar backtracks, and a backtracking parser can take time
//! exponential in its input where an alternative re-parses what another
//! already did. The flow collections are memoized against exactly that, and
//! this is what checks the memoizing is enough. A thread watches the clock,
//! and an iteration that outlasts `--timeout` seconds is reported as a hang
//! with the input that caused it. There is no way to unwind out of it, so that
//! ends the run.

const std = @import("std");
const targets = @import("fuzz_targets");

const Smith = std.testing.Smith;

/// Milliseconds on a clock that only goes forwards while the machine is up.
fn nowMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

/// What the watchdog needs to see, written before each iteration begins.
const Watch = struct {
    /// When the running iteration started, or zero between iterations.
    started_ms: std.atomic.Value(i64) = .init(0),
    /// The input it is running, which is what a hang has to report.
    input: []const u8 = &.{},
    target: []const u8 = "",
    timeout_s: u32 = 10,
    dir: []const u8 = "",
};

var watch: Watch = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Two allocators, and they have to be two. The targets are written to run
    // against the testing allocator, which cannot be named outside a test
    // build; this is the same thing by another route, a debug allocator whose
    // outstanding allocations are counted after every input, since a leak is
    // one of the things being fuzzed for. Nothing else may allocate from it --
    // the loop's own buffer would be indistinguishable from a target's leak --
    // so everything here uses the process allocator instead.
    var checked: std.heap.DebugAllocator(.{}) = .init;
    defer _ = checked.deinit();
    targets.backing = checked.allocator();
    const gpa = init.gpa;

    var seconds: u32 = 60;
    var iterations: ?u64 = null;
    var seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Timestamp.now(io, .real).nanoseconds)));
    var only: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var dir: []const u8 = "fuzz-findings";
    var timeout_s: u32 = 10;
    var corpus_dir: ?[]const u8 = null;

    var args: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--seconds")) {
            seconds = std.fmt.parseInt(u32, args.next() orelse "60", 10) catch 60;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            iterations = std.fmt.parseInt(u64, args.next() orelse "0", 10) catch null;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            seed = std.fmt.parseInt(u64, args.next() orelse "0", 10) catch seed;
        } else if (std.mem.eql(u8, arg, "--target")) {
            only = args.next();
        } else if (std.mem.eql(u8, arg, "--input")) {
            input_path = args.next();
        } else if (std.mem.eql(u8, arg, "--findings")) {
            dir = args.next() orelse dir;
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            corpus_dir = args.next();
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            timeout_s = std.fmt.parseInt(u32, args.next() orelse "10", 10) catch 10;
        } else {
            std.debug.print(
                \\usage: fuzz [--target NAME] [--seconds N | --iterations N] [--seed S]
                \\            [--timeout S] [--findings DIR] [--input FILE] [--corpus DIR]
                \\
                \\Targets: {s}
                \\
            , .{targetNames()});
            std.process.exit(2);
        }
    }

    watch.timeout_s = timeout_s;
    watch.dir = dir;

    const thread = try std.Thread.spawn(.{}, watchdog, .{io});
    thread.detach();

    // One input, from a file, and nothing else: this is how a finding is
    // looked at again after it has been fixed.
    if (input_path) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        const name = only orelse targets.all[0].name;
        const target = find(name) orelse {
            std.debug.print("no target called {s}; there are: {s}\n", .{ name, targetNames() });
            std.process.exit(2);
        };
        watch.input = bytes;
        watch.target = target.name;
        watch.started_ms.store(nowMs(io), .release);
        target.run(bytes) catch |err| {
            std.debug.print("{s}: {t}\n", .{ target.name, err });
            show(bytes);
            std.process.exit(1);
        };
        std.debug.print("{s}: that input is fine now\n", .{target.name});
        return;
    }

    var documents: std.ArrayList([]const u8) = .empty;
    defer {
        for (documents.items) |d| gpa.free(d);
        documents.deinit(gpa);
    }
    if (corpus_dir) |path| try loadCorpus(io, gpa, path, &documents);

    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    std.debug.print("seed {d}\n", .{seed});
    var failures: usize = 0;
    for (targets.all) |target| {
        if (only) |name| if (!std.mem.eql(u8, name, target.name)) continue;

        var runs: u64 = 0;
        const deadline = nowMs(io) + @as(i64, seconds) * 1000;
        while (if (iterations) |n| runs < n else nowMs(io) < deadline) : (runs += 1) {
            try makeInput(gpa, &buffer, random, target, if (target.takes_documents) documents.items else &.{});
            watch.input = buffer.items;
            watch.target = target.name;
            watch.started_ms.store(nowMs(io), .release);
            const result = target.run(buffer.items);
            watch.started_ms.store(0, .release);
            if (checked.detectLeaks() != 0) {
                std.debug.print("\n{s}: leaked\n", .{target.name});
                try report(io, dir, target.name, buffer.items);
                std.process.exit(1);
            }
            result catch |err| {
                failures += 1;
                std.debug.print("\n{s}: {t}\n", .{ target.name, err });
                try report(io, dir, target.name, buffer.items);
                // Keep going: one shape of failure is usually many inputs, and
                // stopping at the first says less than a handful does.
                if (failures >= 10) {
                    std.debug.print("ten failures; stopping\n", .{});
                    std.process.exit(1);
                }
            };
        }
        std.debug.print("{s}: {d} runs\n", .{ target.name, runs });
    }
    if (failures != 0) std.process.exit(1);
}

fn find(name: []const u8) ?targets.Target {
    for (targets.all) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

fn targetNames() []const u8 {
    comptime var names: []const u8 = "";
    inline for (targets.all, 0..) |t, i| {
        names = names ++ (if (i == 0) "" else ", ") ++ t.name;
    }
    return names;
}

/// Make the next input: two length-prefixed chunks and a random tail.
///
/// Two, because a target may ask for two slices -- `paths` wants a working
/// directory and then an argument -- and the second would otherwise only ever
/// see whatever random bytes happened to follow. A target that asks for one
/// slice reads the first chunk and leaves the rest for its `value` calls.
///
/// The length is capped at `target.content_max` rather than at some number
/// chosen here, because `Smith.slice` answers a length larger than its buffer
/// with an *empty* slice rather than a truncated one. Getting that wrong is
/// silent: the target runs, reports no failure, and has been handed nothing.
fn makeInput(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    random: std.Random,
    target: targets.Target,
    extra: []const []const u8,
) !void {
    out.clearRetainingCapacity();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);

    for (0..2) |_| {
        content.clearRetainingCapacity();
        const corpus_len = target.corpus.len + extra.len;
        if (corpus_len == 0 or random.uintLessThan(u8, 8) == 0) {
            // Sometimes nothing but noise, so that the shapes nobody thought
            // of are reachable at all.
            const len = random.uintLessThan(usize, target.content_max);
            try content.ensureUnusedCapacity(gpa, len);
            for (0..len) |_| content.appendAssumeCapacity(random.int(u8));
        } else {
            const pick = random.uintLessThan(usize, corpus_len);
            const seed = if (pick < target.corpus.len) target.corpus[pick] else extra[pick - target.corpus.len];
            try content.appendSlice(gpa, seed);
            const rounds = 1 + random.uintLessThan(usize, 8);
            for (0..rounds) |_| try mutate(gpa, &content, random);
        }
        if (content.items.len > target.content_max) {
            content.shrinkRetainingCapacity(target.content_max);
        }

        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(content.items.len), .little);
        try out.appendSlice(gpa, &length);
        try out.appendSlice(gpa, content.items);
    }

    // And a tail, for whatever a target asks after its slices: an `i64` reads
    // eight bytes from here.
    const tail = 16 + random.uintLessThan(usize, 48);
    try out.ensureUnusedCapacity(gpa, tail);
    for (0..tail) |_| out.appendAssumeCapacity(random.int(u8));
}

fn mutate(gpa: std.mem.Allocator, content: *std.ArrayList(u8), random: std.Random) !void {
    if (content.items.len == 0) {
        try content.append(gpa, random.int(u8));
        return;
    }
    switch (random.uintLessThan(u8, 8)) {
        // A byte, replaced: the commonest useful mutation, and the one that
        // turns an indentation into nearly that indentation.
        0, 1 => content.items[random.uintLessThan(usize, content.items.len)] = random.int(u8),
        // A byte, replaced by one of the ones YAML is made of.
        2, 3 => content.items[random.uintLessThan(usize, content.items.len)] =
            interesting[random.uintLessThan(usize, interesting.len)],
        4 => try content.insert(gpa, random.uintLessThan(usize, content.items.len), random.int(u8)),
        5 => try content.insert(
            gpa,
            random.uintLessThan(usize, content.items.len),
            interesting[random.uintLessThan(usize, interesting.len)],
        ),
        // A run on the end, which is how a document grows another line.
        6 => for (0..1 + random.uintLessThan(usize, 16)) |_| {
            try content.append(gpa, interesting[random.uintLessThan(usize, interesting.len)]);
        },
        else => _ = content.orderedRemove(random.uintLessThan(usize, content.items.len)),
    }
}

/// The bytes YAML is made of: every indicator, the spaces and breaks that
/// indentation and folding turn on — several times over, since they decide
/// the structure — and some that are not allowed at all.
const interesting = blk: {
    var set: []const u8 = "\n\n\n\n    \t\r";
    set = set ++ "-?:,[]{}#&*!|>'\"%@`\\";
    set = set ++ "0123456789.+";
    set = set ++ "abcexnotruelfs";
    set = set ++ &[_]u8{ 0x00, 0x7f, 0x80, 0xc3, 0xa9, 0xef, 0xbb, 0xbf, 0xff };
    break :blk set;
};

/// Reads every `in.yaml` under `path`, one level of case directories and one
/// of variants below them, which is how the yaml-test-suite lays them out.
fn loadCorpus(io: std.Io, gpa: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var root = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer root.close(io);
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or entry.name.len != 4) continue;
        var case = root.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer case.close(io);
        if (case.readFileAlloc(io, "in.yaml", gpa, .limited(4096))) |bytes| {
            try out.append(gpa, bytes);
            continue;
        } else |_| {}
        var sub = case.iterate();
        while (try sub.next(io)) |s| {
            if (s.kind != .directory) continue;
            var variant = case.openDir(io, s.name, .{}) catch continue;
            defer variant.close(io);
            const bytes = variant.readFileAlloc(io, "in.yaml", gpa, .limited(4096)) catch continue;
            try out.append(gpa, bytes);
        }
    }
    std.debug.print("{d} documents from {s}\n", .{ out.items.len, path });
}

/// Print a failing input and write it where it can be fed back.
fn report(io: std.Io, dir: []const u8, target: []const u8, input: []const u8) !void {
    show(input);

    var name: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&name, "{s}/{s}-{x:0>16}.bin", .{
        dir,
        target,
        std.hash.Wyhash.hash(0, input),
    }) catch return;

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.debug.print("(could not write {s}: {t})\n", .{ path, err });
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, input) catch {};
    std.debug.print(
        "written to {s}, and `--input {s} --target {s}` runs it again\n",
        .{ path, path, target },
    );
}

/// The input, in hex, and then what a target actually reads out of it.
///
/// The second half earns its lines: an input is a stream of answers rather
/// than a file, so the bytes alone do not say what the parser was given, and
/// that is the first thing anybody wants to see.
fn show(input: []const u8) void {
    std.debug.print("input, {d} bytes:\n ", .{input.len});
    for (input, 0..) |b, i| {
        if (i != 0 and i % 32 == 0) std.debug.print("\n ", .{});
        std.debug.print(" {x:0>2}", .{b});
    }
    std.debug.print("\n", .{});

    var smith: Smith = .{ .in = input };
    var buffer: [4096]u8 = undefined;
    const text = buffer[0..smith.slice(&buffer)];
    std.debug.print("which reads as {d} bytes:\n", .{text.len});
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        std.debug.print("  |{f}\n", .{std.ascii.hexEscape(line, .lower)});
    }
}

/// Watch for an iteration that never ends.
fn watchdog(io: std.Io) void {
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(500), .awake) catch return;
        const started = watch.started_ms.load(.acquire);
        if (started == 0) continue;
        const elapsed = nowMs(io) - started;
        if (elapsed < @as(i64, watch.timeout_s) * 1000) continue;

        std.debug.print(
            "\n{s}: no answer after {d} seconds, which is a hang\n",
            .{ watch.target, @divTrunc(elapsed, 1000) },
        );
        show(watch.input);
        var name: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&name, "{s}/{s}-hang-{x:0>16}.bin", .{
            watch.dir,
            watch.target,
            std.hash.Wyhash.hash(0, watch.input),
        }) catch std.process.exit(3);
        std.Io.Dir.cwd().createDirPath(io, watch.dir) catch {};
        if (std.Io.Dir.cwd().createFile(io, path, .{})) |file| {
            defer file.close(io);
            file.writeStreamingAll(io, watch.input) catch {};
            std.debug.print("written to {s}\n", .{path});
        } else |_| {}
        std.process.exit(3);
    }
}
