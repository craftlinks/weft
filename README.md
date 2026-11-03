# Weft

A Zig library for composable motion: motion as an object of its own, separate from whatever it
moves. It has no dependencies and knows nothing about pixels. So far it has a clock, four waves,
seeded noise, easing, tweens on named cues, springs and Newtonian moves toward goals at cues,
simulated signals on a fixed step, and a graph that composes them, with cycles through a delay.

Every frame is a function of t. A reader supplies the time and gets a value, and it can ask for any
time in any order. Nothing on that path allocates, locks, or runs unbounded, and a sampled signal
has the same bits on native and wasm. A simulated signal's work is bounded by the checkpoints its
reader keeps, as Simulated Signals explains.

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
    elementary.zig    sine and cosine in turns, exp, and log, the same bits on every target
    graph.zig         Program, Builder, and State: a flat node array and one slab per reader
    motion.zig        Goals, springs, and Newtonian moves, solved exactly between goal changes
    noise.zig         Noise: smooth and stepped, pure functions of a seed and time
    simulation.zig    the fixed step, seeded draws, the goal follower, and the shift register
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
audio rates. Rounding happens only where a formula meets a time: `seconds` for a duration, `turns`
for a position in a cycle, and `cycles` for that position and the count of cycles before it. Both
stay precise far from zero; see `time.zig`, section 3.

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

The ops are `constant`, `add`, `multiply`, `map_range`, `wave`, `noise`, `tween`, `spring`,
`newtonian`, `chase`, `follow`, `shift`, and `delay`. The builder refuses by name what does not fit
or cannot be evaluated: `error.NodeCapacityExceeded`, `error.SlabCapacityExceeded`,
`error.UnknownNode`, `error.NotFinite`, `error.InvalidRange`, `error.UnknownCue`,
`error.InvalidDuration`, `error.InvalidEase`, `error.InvalidRate`, `error.UnknownGoals`,
`error.InvalidOvershoot`, `error.InvalidLimit`, `error.UnknownRegions`, `error.InvalidTolerance`,
`error.InvalidPause`, `error.InvalidOdds`, `error.InvalidBuckets`, `error.NotADelay`, and
`error.DelayClosed`.

A node can only refer to earlier nodes, so a cycle can only pass through a delay. Neither the node
array nor the slab holds a pointer: copied as bytes, the nodes are the same program and the slab is
a checkpoint. Each reader holds its own state, so readers on different threads never disturb each
other. `graph.zig` explains the layout.

## Noise

```zig
const drift = weft.Noise{ .shape = .smooth, .hz = 0.7, .seed = 42 };
const value = drift.sample(time);              // in [-1, 1], the same at any time, in any order

var builder = weft.Builder.init(&nodes, .{ .slab_count_max = 4, .seed = take });
const wobble = try builder.noise(.{ .shape = .steps, .hz = 4, .seed = 1 });
```

There is no random generator. A noise holds one value per cycle of `hz`, a hash of its seed and the
cycle's index, so it is a pure function of time like a wave. `.steps` holds each value for a cycle;
`.smooth` is a cubic B-spline over them, with continuous velocity and acceleration, and it cannot
leave [-1, 1]. `hz` is above 0 and at most `Noise.hz_max`, 2^19 Hz.

In a graph, a noise's seed is hashed with the graph's seed from `Builder.Options`. So one graph seed
gives a new take of every noise at once, and since a node's seed is a stable id the caller chooses,
not its position, inserting a node does not reshuffle the others. `noise.zig` explains the hash.

## Cues and Tweens

```zig
var times: [8]weft.Time = undefined;           // a bounded table, always in order
var cues = weft.Cues.init(&times);
const beat = try cues.add(.{ .flicks = 2 * weft.time.flicks_per_second });

var nodes: [2]weft.Node = undefined;
var builder = weft.Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
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

## Springs and Newtonian Moves

```zig
var entries: [8]weft.Goal = undefined;         // a bounded table, filled before building
var goals = weft.Goals.init(&entries);
const path = try goals.add(&.{                 // in cue order: a goal changes at each cue
    .{ .cue = beat, .value = 1 },
    .{ .cue = next_beat, .value = 0.25 },
});

var builder = weft.Builder.init(&nodes, .{
    .slab_count_max = 2 * (1 + weft.motion.cursor_count),
    .cues = &cues,
    .goals = goals.table(),
});
const settle = try builder.spring(.{
    .from = 0,                                 // held, at rest, until the first cue
    .goals = path,
    .time = .{ .flicks = weft.time.flicks_per_second / 4 }, // the period: omega is 2 pi / time
    .overshoot = 0.1,                          // the peak of a move from rest; 0 is critical
});
const glide = try builder.newtonian(.{
    .from = 0,
    .goals = path,
    .speed = 2,                                // units per second
    .accel = 8,                                // units per second squared, speeding up
    .decel = 4,                                // and slowing down, to stop exactly on the goal
});
```

Both are solved exactly between goal changes, so the value at any time is computed, not stepped,
and it does not depend on the frame rate. A new goal starts from wherever the last one left the
motion, at that velocity. A spring is settled once what is left of the move is below 2^-53 of its
scale, and from then on it returns its goal exactly; a Newtonian move lands exactly when its plan
ends. Each motion node keeps a cursor after its output in the slab, `weft.motion.cursor_count` f64,
so forward play costs one closed form per frame; it is a cache that cannot change a value, and a
cue move makes it stale. `motion.zig` explains the closed forms and the cursor.

## Simulated Signals

```zig
var region_entries: [2]weft.Region = undefined;
var regions = weft.Regions.init(&region_entries);
const places = try regions.add(&.{ .{ .low = -1, .high = -0.5 }, .{ .low = 0.5, .high = 1 } });

var builder = weft.Builder.init(&nodes, .{
    .slab_count_max = 64,
    .cues = &cues,
    .regions = regions.table(),
    .start = beat,                             // every simulated node starts at this cue
    .seed = take,
});
const lagging = try builder.chase(.{           // a spring whose goal is any signal
    .target = rise,
    .from = 0,
    .time = .{ .flicks = weft.time.flicks_per_second / 2 },
    .overshoot = 0.1,
});
const wander = try builder.follow(.{           // goals drawn from regions, with seeded pauses
    .from = 0,
    .regions = places,
    .pick = .random,                           // or .cycle
    .mover = .{ .spring = .{ .time = quarter_second, .overshoot = 0 } },
    .tolerance = 0.01,                         // arrived: this close, and at most this fast
    .pause_min = tenth_second,
    .pause_max = half_second,
    .seed = 1,
});
const pattern = try builder.shift(.{           // buckets that change with seeded odds
    .buckets = 8,
    .period = two_seconds,
    .low = -1,
    .high = 1,
    .odds = 0.25,
    .shape = .smooth,                          // or .steps, .linear
    .seed = 2,
});
const echo = try builder.delay(0);             // its input one step before
const target = try builder.add(echo, push);
const loop = try builder.chase(.{
    .target = target,
    .from = 0,
    .time = half_second,
    .overshoot = 0,
});
try builder.close(echo, loop);                 // the one way to close a cycle

var checkpoints: [600 * 64]f64 = undefined;    // 600 copies of the slab: ten minutes
var state = weft.State.init_with_checkpoints(program, &slab, &checkpoints);
```

These have no closed form, so they run on one fixed step, `weft.simulation.step`, 1/480 s, the
same for every graph and every reader, from the start cue. A read between two steps interpolates
them linearly, so a reader at any rate gets the same value at the same time. Every random choice
is a hash of a seed, as noise is. Their state sits in the slab after their output, so a checkpoint
is a copy of the slab, and a reader keeps one a second, filled as it plays past them, in memory it
gives `State.init_with_checkpoints`. A read restores the nearest checkpoint before it and steps
forward, at most 479 steps once the checkpoints are filled; evaluating the latest time once, while
loading, fills them all. The checkpoints only change what a read costs, never its value, and a cue
move drops them. `program.simulated` says whether a program has such nodes. `simulation.zig` and
`graph.zig`, sections 9 and 10, explain the step, the draws, and why a cycle needs a delay.

## Regress

`zig build regress` renders `test/catalog.zig` on native and on wasm and compares both with
`test/golden/signals.txt`, byte for byte. It samples each wave, each noise, and a few whole graphs,
among them a spring, a Newtonian move, and each simulated node. There is one sample per line, as a
hex float, so any changed bit fails and the report names the sample:

```txt
regress: native differs from golden at line 700
  golden: triangle 440hz hour 3 0x1.c28f5c28f5c28p-1
  native: triangle 440hz hour 3 0x1.c28f5c28f5c29p-1
```

Bless only for a change the step means to make, in that step's commit.
