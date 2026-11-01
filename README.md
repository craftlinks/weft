# Weft

A Zig library for composable motion: motion as an object of its own, separate from whatever it
moves. It has no dependencies and knows nothing about pixels. So far it has a clock, four waves,
easing, tweens on named cues, and a graph that composes them.

Every frame is a function of t. A reader supplies the time and gets a value, and it can ask for any
time in any order. Nothing on that path allocates, locks, or runs unbounded, and a sampled signal
has the same bits on native and wasm.

## Requirements

| | |
|---|---|
| Zig | **0.17.0** exactly (`minimum_zig_version`). |
| Node | Only for `zig build regress`, which runs the wasm build. |

The package has an empty dependency list, and the library links nothing, not even libc.

## Try It

```bash
zig build test                      # unit tests
zig build regress                   # sampled signals against the golden, native and wasm
zig build regress -- --bless        # rewrite the golden, if native and wasm agree
zig build wasm                      # the wasm32-freestanding build
```

## Layout

```txt
src/
  weft.zig            the library root
  core/
    cue.zig           Cues: a sorted, bounded table of times
    ease.zig          Ease: cubic Bezier curves, with a bounded solver
    graph.zig         Program, Builder, and State: a flat node array and one slab per reader
    time.zig          Time and Rate: an integer count of flicks
    wave.zig          Wave: sine, triangle, saw, and square, pure functions of time
test/
  catalog.zig         the sampled signals, rendered as text of hex floats
  golden/signals.txt  the committed samples
tools/
  regress.zig         compares native and wasm text with the golden, and blesses
  regress_wasm.zig    the catalog on wasm32-freestanding
  regress_wasm.mjs    runs that module under Node and prints its text
```

Every file starts with a guide for reviewers: `//! … # Deep Architectural Guide for Reviewers:`.

## Time

```zig
const weft = @import("weft");

const rate = weft.Rate.from_hz(60).?;          // null if a tick is not a whole number of flicks
const time = weft.Time.from_ticks(90, rate).?; // null if it does not fit in an i64
const wave = weft.Wave{ .shape = .sine, .hz = 0.7 };
const value = wave.sample(time);               // in [-1, 1]
```

`Time` is a signed 64-bit count of flicks, 1/705,600,000 s, which is exact for the common frame and
audio rates. Rounding happens only where a formula meets a time: `seconds` for a duration, and
`turns` for a position in a cycle. `turns` stays precise far from zero; see `time.zig`, section 3.

## Graph

```zig
var nodes: [4]weft.Node = undefined;           // capacities come from the caller
var builder = weft.Builder.init(&nodes, .{ .slab_count_max = 4 });
const fast = try builder.wave(.{ .shape = .sine, .hz = 440 });
const slow = try builder.wave(.{ .shape = .triangle, .hz = 0.7 });
const depth = try builder.map_range(.{
    .input = slow,
    .input_low = -1,
    .input_high = 1,
    .output_low = 0.25,
    .output_high = 1,
});
const output = try builder.multiply(fast, depth);
const program = builder.finish();              // immutable from here

var slab: [4]f64 = undefined;                  // one reader's memory
var state = weft.State.init(program, &slab);
state.eval(time);                              // allocates nothing, locks nothing
const value = state.value(output);
```

The ops are `constant`, `add`, `multiply`, `map_range`, `wave`, and `tween`. The builder refuses by
name what does not fit or cannot be evaluated: `error.NodeCapacityExceeded`,
`error.SlabCapacityExceeded`, `error.UnknownNode`, `error.NotFinite`, `error.InvalidRange`,
`error.UnknownCue`, `error.InvalidDuration`, and `error.InvalidEase`.

A node can only refer to earlier nodes, so a cycle cannot be expressed. Neither the node array nor
the slab holds a pointer: copied as bytes, the nodes are the same program and the slab is a
checkpoint. Each reader holds its own state, so readers on different threads never disturb each
other. `graph.zig` explains the layout.

## Cues and Tweens

```zig
var times: [8]weft.Time = undefined;           // a bounded table, always in order
var cues = weft.Cues.init(&times);
const beat = try cues.add(.{ .flicks = 2 * weft.time.flicks_per_second });

var nodes: [2]weft.Node = undefined;
var builder = weft.Builder.init(&nodes, .{ .slab_count_max = 2, .cues = cues.table() });
const rise = try builder.tween(.{
    .from = 0,
    .to = 1,
    .duration = .{ .flicks = weft.time.flicks_per_second },
    .ease = .in_out,                           // or .linear, .in, .out, or any Bezier
    .start = beat,
    .previous = null,                          // what to follow before the cue: null holds `from`
});

try cues.move(beat, new_time);                 // readers see it at their next eval
```

A tween is one more pure node, and it refers to a cue, so moving the cue moves the tween by exactly
that time, with no rebuild. It lands on `to` bit for bit. A cue's id is its position, so a move that
would pass a neighbour is refused, and the table stays in order. A move must not overlap an eval: a
reader on another thread takes its own copy of the table.

A chain through `previous` is a sequence. A gap holds the earlier value, and in an overlap the later
tween wins from its start. `cue.zig` and `graph.zig`, section 6, explain why.

## Regress

`zig build regress` renders `test/catalog.zig` on native and on wasm and compares both with
`test/golden/signals.txt`, byte for byte. It samples each wave and a few whole graphs. There is one
sample per line, as a hex float, so any changed bit fails and the report names the sample:

```txt
regress: native differs from golden at line 700
  golden: triangle 440hz hour 3 0x1.c28f5c28f5c28p-1
  native: triangle 440hz hour 3 0x1.c28f5c28f5c29p-1
```

Bless only for a change the step means to make, in that step's commit.
