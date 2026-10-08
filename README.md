<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-yaml

A YAML 1.2.2 parser and emitter for Zig 0.17, with the same shape as
`std.json`. The parser is built directly on the grammar of the YAML 1.2.2
specification [1]. It passes every case of the yaml-test-suite [2].

The API documentation is generated from the doc comments. CI publishes it
from `main` to <https://jeff.jcollie.page/zig-yaml/>, and
`zig build docs-serve` serves the same documentation locally.

## Where this lives

The repository lives in three places, all carrying the same history. The
Forgejo instance at <https://git.jcollie.dev/jeff/zig-yaml> is the one with a
web interface:

```console
$ git clone https://git.jcollie.dev/jeff/zig-yaml.git
```

It is mirrored on Tangled at <https://tangled.org/jcollie.dev/zig-yaml>. It is
also on the Radicle network, with the repository ID

```
rad:z2vTvxxTzoSo75cpepS4VFqUFo8x3
```

and `rad clone rad:z2vTvxxTzoSo75cpepS4VFqUFo8x3` fetches it from any node that
seeds it. Each of the three holds the whole project.

## Adding it to a project

```console
$ zig fetch --save git+https://git.jcollie.dev/jeff/zig-yaml.git
```

then, in `build.zig`:

```zig
const yaml = b.dependency("zig_yaml", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("yaml", yaml.module("yaml"));
```

`main` needs Zig 0.17.0. For Zig 0.16.0, use the `zig-0.16` branch, which
holds the last of zig-yaml to build with it:

```console
$ zig fetch --save git+https://git.jcollie.dev/jeff/zig-yaml.git#zig-0.16
```

The `v0.1.0` tag is the same commit.

## Using it

If you know `std.json`, you already know most of this API.

```zig
const yaml = @import("yaml");

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
// parsed.value.port == 8080

const text = try yaml.Stringify.valueAlloc(gpa, parsed.value, .{});
defer gpa.free(text);
// host: example.com
// port: 8080
// tags:
//   - web
//   - prod
```

This example is also a test in `src/tests.zig`, so it stays correct.

### API overview

| `std.json` | zig-yaml | Notes |
| --- | --- | --- |
| `parseFromSlice`, `…Leaky` | `parseFromSlice`, `…Leaky` | Takes exactly one document. An empty stream reads as a null node. |
| — | `parseAllFromSlice`, `…Leaky` | Takes every document of a stream, as `[]T`. |
| `parseFromTokenSource` | `parseFromTokenSource` | Takes a `*Scanner` or a `*Reader`. |
| `parseFromValue` | `parseFromValue` | |
| `innerParse`, `innerParseFromValue` | the same | For use inside parse hooks. |
| `Parsed(T)` | `Parsed(T)` | Holds the value and its arena. |
| `Value` | `Value` | Mapping keys can be any `Value`, not only strings. |
| `Scanner` (tokens) | `Scanner` (events) | `next`, `peek`, `peekNextEventType`, `skipValue`. |
| `Reader` | `Reader` | Reads the whole `std.Io.Reader` before parsing; see below. |
| `Stringify` | `Stringify` | `value`, `valueAlloc`, and a write stream. |
| `fmt` | `fmt` | Use with `{f}`. |

### Customization hooks

A type can take over its own parsing or output by declaring any of these
functions, the same way it would for `std.json`:

```zig
pub fn yamlParse(allocator: Allocator, source: anytype, options: yaml.ParseOptions) !@This()
pub fn yamlParseFromValue(allocator: Allocator, source: yaml.Value, options: yaml.ParseOptions) !@This()
pub fn yamlStringify(self: @This(), yw: *yaml.Stringify) !void
```

### How nodes map to Zig types

The target type decides how each node is read:

- **Scalars are matched by their text, not their style.** `"8080"` parses as a
  `u16`, the same way `std.json` accepts a number in a string.
- **Strings accept any scalar.** `version: 1.10` read into a `[]const u8`
  gives `"1.10"`, not a float.
- **Booleans and numbers use the core schema's spellings.** That includes
  `True`, `0x1F`, `0o17`, `.inf` and `~`. With `.schema = .json`, only JSON's
  spellings are accepted.
- **Tagged unions** are written as a single-pair mapping, `circle: 1.5`. A
  variant with a `void` payload can also be written as its bare name.
- **Aliases are expanded.** `ParseOptions.max_alias_expansion` caps how many
  events alias expansion can produce, so a "billion laughs" document is an
  error rather than running out of memory.

When there is no target type, `Value` resolves untagged plain scalars with the
schema in `ParseOptions.schema`: core (the default), JSON or failsafe. Explicit
tags such as `!!int` and `!!str` are honored. Unknown tags are ignored by
default, or rejected with `.unknown_tag_behavior = .@"error"`.

### Output

`Stringify` writes block style by default and flow style when
`.style = .flow`. It writes each string in the plainest style that reads back
as the same string:

1. **Plain**, unless the text could be mistaken for a null, boolean, number or
   indicator.
2. **Single-quoted**, if the plain form would be misread.
3. **Double-quoted**, when the string needs an escape.
4. **Literal block scalar**, for multi-line strings it can represent exactly.

Collection keys are written after a `?` indicator. Formatting is data-only:
comments and the original scalar styles are not preserved.

### What this is not

**It is not incremental.** The YAML grammar backtracks: whether a line is a
mapping key can depend on text after it. No event can be returned until the
whole stream has been parsed. `Reader` therefore reads the whole stream
first, up to `max_input_len` (64 MiB by default).

## How the parser is built

`src/grammar/` holds one file per chapter of the specification. Each numbered
production is one function that carries the production's number and text in
its doc comment. For example, `[187] l+block-mapping(n)` is `lBlockMapping` in
`block.zig`.

Functions take the spec's own parameters: the indentation `n`, the context
`c` and the chomping `t`. Each returns whether it matched, and restores the
parser's state if it did not. Events are emitted where a node begins and ends,
and backtracking takes them back.

Backtracking alone would make some inputs take exponential time. Two measures
keep it polynomial:

- **Flow collections are memoized.** In a key context the whole result is
  stored, events included. Elsewhere only failures are stored.
- **Implicit keys are bounded.** While a key attempt runs, the input is
  narrowed to the spec's 1024-character key limit.

Nesting is limited to `max_depth` (512) collections. Deeper input is an
`error.NestingTooDeep`, not a stack overflow.

### Where the implementation goes beyond the printed grammar

Read as written, the grammar is ambiguous in places. Where it is, the
yaml-test-suite decides how it is read. Each case below is commented at its
production:

- **Optional groups are retried both ways when PEG ordering would get them
  wrong.** In `[200] s-l+block-collection`, properties followed by a key on
  the same line (`&a key: value`) belong to the key, not to the mapping. A
  second property on the next line can belong to that line's key
  (`!!map` then `&a key: v`).
- **Properties followed by JSON-like content are not an empty key.**
  `[159] ns-flow-yaml-node` does not match properties followed by nothing when
  JSON-like content comes next, so `{ &a [x]: y }` anchors the sequence.
- **A `%YAML` or `%TAG` directive that fails to parse is an error.** `[83]`
  never falls back to reading it as a reserved directive of the same name.
- **The end of the input ends the last line.** It acts as a line break for
  block scalar chomping and for a trailing line of spaces.
- **Both block scalar indicators are optional.** `[163]` is printed without
  its `?`.
- **Block scalars with no content lines take their indentation from their
  empty lines.** The indentation is the widest leading empty line, so those
  lines are read as empty rather than as content.
- **Directives, anchors and the forbidden markers are handled outside the
  grammar.** `%TAG` handles, `%YAML` versions and anchors are scoped to their
  document. The "excluding c-forbidden content" restriction of `[207]` is
  enforced by treating the first `---` or `...` at the start of a line as the
  end of the input while a bare document is parsed.

## Testing

```console
$ nix develop
$ zig build test                       # unit tests and the whole yaml-test-suite
$ zig build test -Dsuite-filter=9KAX   # one suite case, with details on failure
$ zig build events -- file.yaml        # events for a file, in the suite's notation
$ zig build fuzz-run -- --seconds 600  # fuzz every target for ten minutes each
$ zig build fuzz --fuzz                # Zig's own fuzzer, until interrupted
```

The yaml-test-suite [2] is a lazy dependency, so a project that depends on
this package never fetches it. The suite runner checks every case three ways:

- **Errors and events.** Each invalid input must be rejected, and each valid
  input must produce exactly the expected event stream.
- **JSON.** Where a case has a JSON equivalent, the parsed `Value` must equal
  it under RFC 8259 [3].
- **Round trip.** Each valid case is written back out in block and flow style
  and must parse back to an equal `Value`.

All 402 cases pass. That covers 94 invalid inputs rejected, 279 JSON
comparisons and 308 round trips.

`tests/fuzz.zig` holds the fuzzing properties. Two fuzzers drive them.
`zig build fuzz --fuzz` is Zig's own, which is guided by coverage; the test
binaries are compiled with LLVM because the self-hosted backend emits no
coverage instrumentation. `tools/fuzz.zig` is a loop of our own with no
coverage, which mutates inputs seeded from the test suite instead. The
properties are:

- Any input either fails or round-trips.
- Any generated `Value` tree round-trips through `Stringify`.
- Typed parsing round-trips.

A watchdog flags any input that takes too long. CI runs a short campaign
on every push.

## Building

The development shell in `flake.nix` provides Zig 0.17, `reuse`,
`git-pages-cli` and `zon2nix`. `build.zig.zon.nix` is generated from
`build.zig.zon`. When a dependency changes, regenerate it with:

```console
$ nix develop -c zon2nix --17 --nix=build.zig.zon.nix build.zig.zon
```

CI fetches the Zig dependencies through Nix, from the `zig-deps` flake
output, by passing `--system`.

## License

MIT. The project follows the [REUSE](https://reuse.software/) specification.

## References cited

1. Ben-Kiki, O., Evans, C., & döt Net, I. (2021, October 1). *YAML Ain’t
   Markup Language (YAML™) revision 1.2.2*. YAML Language Development Team.
   <https://yaml.org/spec/1.2.2/>
2. YAML Language Development Team. (2022). *YAML Test Suite* (Version
   data-2022-01-17) [Data set]. GitHub.
   <https://github.com/yaml/yaml-test-suite>
3. Bray, T. (Ed.). (2017, December). *The JavaScript Object Notation (JSON)
   Data Interchange Format* (RFC 8259; STD 90). RFC Editor.
   <https://www.rfc-editor.org/info/rfc8259>
