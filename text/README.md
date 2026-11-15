# Weft's Text Package

Weft's text front end, a package of its own (module `weft_text`): Weft's table of calls, its back
end that turns a checked file into a `Program`, `Compiled`, the standard library `std`, and the
`weft` command. The language, [Jig](../../jig), is a repository of its own, and the core is
[Weft](..). This package depends on both (`..` and `../../jig`), and Weft's root package depends
on nothing.

## Depending on It

A client that reads text declares the one dependency, `weft_text`, and takes the modules from it,
so its build holds one instance of each. If the client took Jig from a dependency of its own and
this package took it from another, the two `jig.schema.Entry` could be two types, and the
client's entries would not pass to `Compiled`.

```zig
// build.zig.zon: .dependencies = .{ .weft_text = .{ .path = "../weft/text" } },
// build.zig
const text = b.dependency("weft_text", .{});
const imports = &.{
    .{ .name = "weft", .module = text.module("weft") },           // the core
    .{ .name = "jig", .module = text.module("jig") },             // the language
    .{ .name = "weft_text", .module = text.module("weft_text") }, // the table, back end, Compiled
    // .{ .name = "commands", .module = text.module("commands") },  // the command's functions
};
```

`jig.…` is the language (`schema`, `check`, `parse`, `format`, `diagnostic`, `token`, `File`),
`weft_text.…` is Weft's (`Compiled`, `Limits`, `Syntax`, `table`, `entries_of`, `std_library`),
and `weft.…` is the core. Nothing is re-exported. The README of Weft's root explains the language
and the command; this one only says where things are.

## Layout

```txt
text.zig            the module's root: Compiled, Syntax, Limits, entries_of, std_library
src/table.zig       Weft's vocabulary for Jig: the table of primitives and four functions
src/graph.zig       the back end: checked declarations to a Program
src/std.jig         the standard library of modules
cli/                the weft command (main.zig) and its functions (commands.zig, module `commands`)
test/               the tests that compile text, and golden/cli, the command's committed output
tools/bench.zig     times reads and a compile
examples/starter    the smallest client: a Patchwork app that reads a program
```

## Check

```bash
zig build test --summary all
zig build test-cli
zig fmt --check .
zig build bench -Doptimize=ReleaseFast     # what a compile and a read cost on this machine
```

The core's tests, `zig build regress` (native and wasm), and the sampled golden are Weft's root.
