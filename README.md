# Weft

A Zig library for composable motion: motion as an object of its own, separate from whatever it
moves. It has no dependencies and knows nothing about pixels.

## What Weft Is

A button sliding in, a volume knob wobbling, a ball bouncing between two walls, and a value that
chases the mouse with a springy lag are all just numbers that change over time. Weft computes those
numbers. It does not know about pixels, sound, or windows: your code reads a number out and applies
it to whatever you like.

## The Core Idea: A Frame Is a Function of Time

Most animation code works from history:

> Last frame the value was 0.4. A frame passed. Add a bit. Now it is 0.43.

The value then depends on every frame before it. If frames arrive late the result changes, you
cannot jump to minute 5 without replaying minutes 0 to 5, and two machines can disagree.

Weft asks a different question:

> What is the value at time `t`?

You give it a time and get a value, and you can ask for any time in any order. Most of the design
follows from this one contract, and it gives you:

- **Scrubbing and rewinding** for free, because jumping to any time is just another question.
- **Frame-rate independence.** A 60 Hz reader and a 240 Hz reader see the same value at the same
  moment.
- **Several readers at once.** A UI thread and an audio thread can read the same motion without
  coordinating.

## Building Blocks

Everything is a **signal**: a value defined at every time.

| Kind | What it gives you |
|---|---|
| Wave | Sine, triangle, saw, or square at a given frequency. |
| Noise | Smooth or stepped randomness, worked out from a seed and a time. There is no random generator. |
| Tween | A move from A to B over a duration with an easing curve, starting at a named cue. |
| Spring, Newtonian move | Head toward a goal, springily or by speeding up and braking. A new goal takes over from wherever the motion is. |
| Simulated signal | Things with no formula: a value chasing another signal, a wanderer that picks goals and pauses, a shift register. |
| Live input | A value fed in from outside, such as a microphone level. A recording of it plays back later as an ordinary signal. |

A **cue** is a named moment on the timeline. Tweens and springs start at cues rather than at fixed
times, so moving one cue moves everything attached to it, with no rebuild.

## The Graph: Signals Wired Together

You combine signals into a **graph**: a list of nodes, each one an operation (a wave, an add, a
multiply, a tween, and so on) that refers to earlier nodes by index. For example, a fast wave whose
loudness is shaped by a slow one:

```txt
fast wave ───────────┐
                     ├─ multiply ─> output
slow wave ─> rescale ┘
```

A graph goes through three phases:

1. **Build.** A `Builder` assembles the nodes into arrays whose sizes you provide, and refuses by
   name (`error.NodeCapacityExceeded`, `error.UnknownCue`, ...) what does not fit.
2. **Freeze.** `builder.finish()` returns an immutable `Program`.
3. **Read.** Each reader makes a `State`, a block of memory of its own holding every node's current
   value, then calls `eval(time)` and reads the values it wants.

The program is shared and read-only, and each reader owns its state, so readers never disturb each
other.

## Principles

1. **Indices, not pointers.** Nodes refer to each other by number. A copy of the node array, as raw
   bytes, is the same program, and a copy of a reader's memory is a saved snapshot, a
   *checkpoint*, that it can resume from.
2. **Order means no loops.** A node may only refer to nodes built before it, so reading is one pass
   from top to bottom. The one exception is a **delay**, which reads its input from one step ago.
   Every feedback loop must pass through a delay, so a loop without one cannot be written.
3. **Safe on a deadline.** Reading never allocates memory, takes a lock, or runs an unbounded loop,
   which is what audio code needs. The caller supplies every buffer size.
4. **Exact time.** Time is a whole number of *flicks*, 1/705,600,000 of a second, which divides
   evenly into common frame and audio rates. Integers do not drift, so a motion far from zero stays
   precise.
5. **Same bits everywhere.** The same input gives bit-identical output on native and WebAssembly,
   even for `sin` and `exp`, which Weft computes itself. `zig build regress` checks this.
6. **Caches never change answers.** Simulated signals have no formula, so they advance on a fixed
   step of 1/480 s, the same for every graph and reader, and a read between steps interpolates.
   Replaying from the start would be slow, so each reader keeps a checkpoint a second. Checkpoints
   change what a read costs, never what it returns.
7. **Questions beyond "what is the value".**
   - `events(t0, t1)` lists everything that happened in a range of time, each at an exact flick. The
     ranges do not overlap, so however a reader splits its timeline, each event is reported once.
   - `ranges` gives, for every node, a bound its values never leave. It is never wrong, though it can
     be wider than the truth.
   - `report` says whether a program can be read at any time. Live input has no past, so it cannot
     be, and the report names the node responsible.

A useful picture is a **spreadsheet whose only input is a clock**. Each cell is a formula over
earlier cells, and each reader asks what the sheet shows at time `t`. The few cells that cannot be
written as a formula are simulated on a fixed step, with snapshots so any time is quick to reach and
always gives the same answer.

## Where to Read Next

Every source file opens with a guide for reviewers, which `test/rules.zig` checks. Start with
`src/weft.zig`, then the guide at the top of `src/core/graph.zig`, which holds the graph's layout
and most of the rules above. The sections below show each part in use. An agent new to Weft
starts with [`docs/agents.md`](docs/agents.md): how to learn the toolbox from `weft describe`,
the language on one page, how a Play page is put together, and how to add a primitive.

## What v0.2 Promises

v0.2 means a client can depend on these, not that Weft is finished. Within 0.2, a change to any of
them is a bug or a new minor version, named in this README. 0.1 promised the same list:

- **The library's exports**, `src/weft.zig`: `Builder` and its calls, `Program`, `State` and its
  `eval`, `events`, `events_since`, `events_of` (step 23), `values`, `extent`, `finite`,
  `set_input`, `record`, and `adopt`, the op structs, `Cues`, `Goals`, `Regions`, `Tracks`, `Time`, `Rate`, `Event`, and
  `weft.colour`.
- **The language**: every call and parameter `weft describe` lists, the syntax, the canonical
  format, and the seeds a file's names derive, so a file samples the same values in every 0.2.
- **The command line's JSON**: the fields of `describe`, `sample`, and `parse --json`. A new field
  may appear; none is renamed or removed.
- **The rules**: every frame a function of t, no allocation, lock, or I/O in `src/core` and
  `src/lang`, and the same bits on native and wasm.

Not promised: anything a file of `src/core` or `src/lang` does not export, the layout of the slab
and the node array, `Limits`' defaults, diagnostics' wording, Play, and the bench's numbers.

A file that 0.1.0 accepted and should not have is a bug, so 0.1.1 refuses it: a tween from a
colour to a number, a product of two colours, and a module with two parameters of one name.

**0.1.1** (steps 19 to 22) adds and fixes, and changes no promise: a loop that runs away
saturates and `State.finite` says so; `State.events_since`, and a reader given
`Program.reader_slab_count()` of slab replays one step where it restored a checkpoint; the
checker's holes above, and hints that name real `Limits` fields; `check` prints the least
`Limits` a file needs, `sample` takes `--events` and `--lanes` and any slab size, and `describe`
says how each call takes lanes and what its events carry.

**0.2.0** (steps 23, 26 to 33) adds language surface, so it is a minor version: a string
literal, and a client's nouns that only describe (step 27, see A Client's Nouns); a cue written
after another cue, `cue hit = c1 + 500ms` (step 29); division by a number (step 30); a tween
`after` a tween that leaves out `from` (step 31); `abs`, `min`, and `max`, with `clamp` in `std`
(step 26); and `sin`, `cos`, `exp`, `ln`, `sqrt`, `floor`, `round`, and `pow`, with `quantize` in
`std` (step 33). The core gains the `minimum`, `maximum`, and `apply` ops, `graph.Function`, a
union of the functions of one value, and `Builder.Error.InvalidPower`. No file 0.1 accepted
changes its values, but one that declares a module named after any of these calls, or `clamp` or
`quantize` beside `use std`, is now refused, since the name is taken. `schema.params_max` is 16, where it was 8. The
`weft` command's functions are the module `commands`, so a client's own command can print
`describe` with its nouns, and check and sample its files (step 32). `check`'s limits line for a
file that uses `std` grows with `std`'s text. `State.events_of` reads the events of chosen sources,
stepping nothing when they are all solved, `Compiled.event_sources` gives a binding's, and `weft
sample --events` reads through them, so it keeps a region's bounce with no stagger and a vector's
spring, which it kept nothing of before (step 23). A cue chosen by lane, `at: beat[lane]` in a
`tween` or a `bounce`, and a series written as a list, `cue title = [1s, 1080ms]` (step 28): the
core gains `cue_by_lane` on `Tween`, `Bounce`, and `BounceNode`, false by default, and
`graph.lane_cue`; `check.Value` gains `cue_by_lane`; `schema.Param` gains `by_lane`; and
`describe` prints `"by_lane":true` on the two parameters that take one.

## Requirements

| | |
|---|---|
| Zig | **0.17.0** exactly (`minimum_zig_version`). |
| Node | Only for `zig build regress`, which runs the wasm build. |

The package has an empty dependency list, and the library links nothing, not even libc. Play, in
`play/`, is a package of its own with its own requirements; see Play below.

## Try It

```bash
zig build test                      # unit tests
zig build regress                   # sampled signals against the golden, native and wasm
zig build regress -- --bless        # rewrite the golden, if native and wasm agree
zig build wasm                      # the wasm32-freestanding build
zig build bench -Doptimize=ReleaseFast   # what reads cost on this machine
zig build test-cli                  # the weft command's output against its goldens
./zig-out/bin/weft check play/signals.weft   # after `zig build`; see The weft Command
```

## Layout

```txt
src/
  weft.zig            the library root
  core/
    colour.zig        OKLab and sRGB, both ways, and a gamut map for drawing
    cue.zig           Cues: a sorted, bounded table of times
    ease.zig          Ease: cubic Bezier curves, with a bounded solver
    elementary.zig    sine and cosine in turns, exp, and log, the same bits on every target
    event.zig         Event, and the bounded, sorted buffer that collects them
    graph.zig         Program and Builder: a flat, sorted node array
    graph_test/       the graph's tests, one file a topic
    motion.zig        Goals, springs, and Newtonian moves, solved exactly between goal changes
    noise.zig         Noise: smooth and stepped, pure functions of a seed and time
    range.zig         Range and Class: conservative bounds, and how a reader reaches a time
    recording.zig     Samples and Recording: live input written down and played back
    simulation.zig    the fixed step, seeded draws, the goal follower, and the shift register
    state.zig         State: one slab per reader, the pass, steps, checkpoints, and events
    time.zig          Time and Rate: an integer count of flicks
    track.zig         Tracks: timed values a client writes, read as signals, latched from a time
    wave.zig          Wave: sine, triangle, saw, and square, pure functions of time
  lang/
    lang.zig          Compiled and Syntax: text to a Program, and the limits
    token.zig         the tokenizer
    parse.zig         the parser and its flat tree
    schema.zig        the table of primitives
    check.zig         names, order, types, defaults, and seeds
    graph.zig         the back end: checked declarations to a Program
    format.zig        the canonical format
    error.zig         diagnostics and suggestions
    std.weft          the standard library of modules, `weft.lang.std_library`
cli/
  main.zig            the weft command: arguments, files, and one write of the output
  commands.zig        check, describe, sample, and parse, each a call into the library
test/
  catalog.zig         the sampled signals, rendered as text of hex floats
  lang.zig            the catalog's graphs as text, which compile to its nodes
  modules.zig         modules against the same graphs written by hand
  carry.zig           a recompile's carried reader against a fresh one, bit for bit
  vectors.zig         vectors and colours against the scalar files they stand for
  lanes.zig           lanes in the language against the builder's region, and the lane errors
  rules.zig           every file's guide, and no allocator, thread, lock, or I/O in the library
  cli.zig             the weft command's output against its goldens, and a client's nouns
  nouns.zig           a score: nouns that only describe beside a program, strings, and their errors
  score.zig           that score and its nouns, shared with cli.zig's client command
  division.zig        a quotient by a number against the product with its reciprocal, and refusals
  functions.zig       the functions of a value, clamp, quantize: building, folding, ranges, refusals
  chains.zig          a tween chain with `from` left out against the chain written out
  golden/signals.txt  the committed samples
  golden/cli/         the weft command's committed output
tools/
  bench.zig           times reads and a compile, for zig build bench
  regress.zig         compares native and wasm text with the golden, and blesses
  regress_wasm.zig    the catalog on wasm32-freestanding
  regress_wasm.mjs    runs that module under Node and prints its text
play/                 a package of its own: the Play app, on Weft and Patchwork
docs/
  agents.md           for an agent new to Weft: the toolbox, the language, a Play page, a primitive
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

The ops are `constant`, `add`, `multiply`, `minimum`, `maximum`, `apply` (a `Function` of one
value: `.abs`, `.sin`, `.cos`, `.exp`, `.ln`, `.sqrt`, `.floor`, `.round`, or `.{ .pow = n }`),
`map_range`, `wave`, `noise`, `tween`, `spring`, `newtonian`, `chase`, `follow`, `shift`, `delay`,
`bounce`, `crossing`, `cues`, `input`, `recorded`, `oscillator`, and `track`. The builder refuses
by name what does not fit or cannot be evaluated: `error.NodeCapacityExceeded`, `error.SlabCapacityExceeded`, `error.UnknownNode`,
`error.NotFinite`, `error.InvalidRange`, `error.UnknownCue`, `error.InvalidDuration`,
`error.InvalidEase`, `error.InvalidRate`, `error.UnknownGoals`, `error.InvalidOvershoot`,
`error.InvalidLimit`, `error.UnknownRegions`, `error.InvalidTolerance`, `error.InvalidPause`,
`error.InvalidOdds`, `error.InvalidBuckets`, `error.NotADelay`, `error.DelayClosed`,
`error.UnknownSamples`, `error.UnknownTrack`, `error.InvalidParameter`, `error.InvalidPhase`, and
`error.InvalidPower`.

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

In the language, `previous` is `after:`, and a tween after a tween may leave out `from`, which is
then the earlier tween's `to`: `fall = tween(to: 0.25, at: drop, over: 500ms, after: rise)`. So a
chain says each value once, and the checker builds the call the longer text gives. `after` must be
a name bound to a tween, or to a region of one; otherwise `from` is required.

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
loading, fills them all. A slab of `program.reader_slab_count()` values, rather than
`program.slab_count`, also gives the reader a copy of its simulated nodes at the step before its
own, so a read of the step it has just passed, which an `events` right after an `eval` or a track
written at the time just read makes, replays one step instead of restoring a checkpoint. A step
evaluates only the simulated nodes and the nodes they read, directly or through others (step 34),
so pure nodes beside them cost nothing a step. The checkpoints only change what a read costs, never its value, and a cue
move drops them. `program.simulated` says whether a program has such nodes. `simulation.zig` and
`graph.zig`, sections 9 and 10, explain the step, the draws, and why a cycle needs a delay.

**A runaway loop.** A loop whose gain is above 1 grows without end. Every value a simulated node
reads or stores is clamped to `weft.simulation.state_bound`, 2^256 either way, with NaN read as 0,
so a runaway saturates there and holds, with the same bits in every build mode, and comes back
down if a track turns its gain back. The builder refuses a moving value or a goal that starts past
the bound. Pure nodes downstream of a saturated one can still overflow, so after an `eval` of a
program with a loop, `state.finite()` says whether every value is finite: show a false, and do not
draw it or pass it to `weft.colour`. `simulation.zig`, section 7, explains the bound.

## Events

```zig
const ball = try builder.bounce(.{             // two nodes: position and velocity
    .low = 0,
    .high = 1,
    .speed = 0.7,                              // units per second
    .start = beat,                             // at `low`, at rest, until this cue
});
const loud = try builder.crossing(.{           // a gate: 1 at or above the level, else 0
    .input = lagging,
    .level = 0.8,
    .direction = .rising,                      // or .falling, .both
});
const beats = try builder.cues(.{ .first = beat, .count = 4 }); // how many have passed

var out: [64]weft.Event = undefined;           // the caller's buffer bounds the memory
const result = state.events(t0, t1, &out);     // every event in [t0, t1), in order
for (out[0..result.count]) |event| {           // event.time, .source, .instance, .value
    _ = event;                                 // handle it
}
// result.dropped counts, exactly, the events after the earliest out.len.
```

`eval(t)` gives values at a moment; `events(t0, t1)` gives everything that happened in the
half-open range, so however a reader splits its timeline, each event lands in exactly one range.
Events come from a bounce hitting a wall, a crossing of a level, a spring or a Newtonian move
reaching its goal, a follower arriving, a shift register entering a bucket, and cues. They are
ordered by time, then by the index of the node, then by lane, and an event's time is the first
flick at which it has happened, so `eval(event.time)` already shows it. A bounce, cues, motions,
and shift registers solve their times exactly. A crossing compares its input at consecutive
steps of 1/480 s and interpolates inside the step, so its gate, which is exact at any time, can
differ from its events by up to a step near a crossing, and **an input that crosses and comes
back within one step flips the gate with no event**.

Events are not stored: a past range re-runs from a checkpoint and gives the same events, bit for
bit. A range never brings a simulated state past the step `eval(t1)` needs, so consecutive ranges
run each step once, and an `eval(t1)` after them costs nothing more. `events` leaves the slab's
outputs at no particular time, so `value` asserts until the next `eval`. `graph.zig`, section 11,
and `event.zig` explain the rules.

**Evals and events on one reader.** Each frame, `state.events_since(now, &out)` gives the events
since the last `eval`, `(last, now]`, then evaluates at `now`: one call that never runs a step the
evals would not. Its first call gives the events at exactly `now`, and a repeat or a seek back
gives none. By hand, the same is `events(s + 1, s' + 1)` in flicks. `events(s, s')` after
`eval(s)` starts one step behind the slab, which a reader with `reader_slab_count()` of slab
replays in one step and a reader without restores from a checkpoint.

**Events by source.** `events` runs every simulated node's steps across its range, whatever the
caller wants. `state.events_of(&sources, t0, t1, &out)` gives the events of the listed nodes only,
ids strictly ascending, in the order and with the overflow rule of `events` (step 23). It steps
only when a listed source is a crossing, a follower, or a shift register; over solved sources (a
bounce, cues, a spring, a Newtonian move) it steps nothing and changes nothing in the state, so a
window around the playhead of a program with a chase costs what it costs on a pure one, and the
next `eval` and `value` see what the last `eval` left. A file's binding gives its list with
`compiled.event_sources(name, &ids)`, which follows a region's `spread` and a vector's `pack` to
the nodes that fire. For a subset each frame, the since form is written by hand:

```zig
const found = state.events_of(&sources, .{ .flicks = last.flicks + 1 }, .{ .flicks = now.flicks + 1 }, &out);
state.eval(now);
```

## Ranges and Seekability

```zig
var ranges: [node_count]weft.Range = undefined;
program.ranges(&ranges);                       // a range per node its values never leave
var classes: [node_count]weft.Class = undefined;
program.classes(&classes);                     // .pure, .exact, .simulated, or .live
const report = program.report();               // .seekable, and .live names the node why not

const level = try builder.input(.{ .low = 0, .high = 1 }); // a live value, set each read
state.set_input(level, microphone_level);      // clamped into [low, high]

var entries: [4096]weft.Sample = undefined;
var recording = weft.Recording.init(&entries);
state.record(level, &recording);               // what each pass reads, written down
// Later: Samples.add(recording.table()) gives a clip, and builder.recorded(clip) plays it back.
```

A range is conservative: a stated bound is never wrong, though it can be wider than the truth.
Sums, products, `abs`, `min`, `max`, `sqrt`, `floor`, `round`, `pow`, waves, and noise are exact;
an interpolation, a map, a tween, a motion, `exp`, and `ln` are widened by a margin relative to
their scale, and `sin` and `cos` by a few ulps, reaching 1 or -1 only where a peak or a trough
lies inside the input's range. A spring's range includes its overshoot: one move from
rest overshoots by its peak overshoot, 16.3% at a damping ratio of 0.5, and a spring with more
goals, a chase, or a spring follower stays within (1 + os) / (1 - os) of the half-width of its
inputs around their centre. A Newtonian move stays within its stopping distance,
speed^2 / (2 decel), of its inputs. A loop through a delay is solved as a fixed point, and one
that never settles has infinite ends. Interval arithmetic treats inputs as independent, so
**`x * x` over [-1, 1] is reported as [-1, 1]**.

An input is the fourth signal class, live: it has no past, so a program with one is not
seekable, and the report names it. A backward read still works, reading the value set last. A
state records what its passes read of an input, only forwards, and a `recorded` node plays it back
held forward from each sample, so the recorded program read at the same times gives the same
values, bit for bit, and can be read at any time. `range.zig` and `recording.zig` explain the
rules.

## Live Parameters

```zig
var samples: [4096]weft.Sample = undefined;
var entries: [1]weft.Track = undefined;
var tracks = weft.Tracks.init(&entries);
const knob = try tracks.add(&samples, 0.1, 2, 0.5);      // bounds, and the value before a write
var builder = weft.Builder.init(&nodes, .{ .slab_count_max = 64, .cues = &cues,
    .tracks = &tracks });                                // the program reads the table, as cues
const time = try builder.track(knob);                    // the track's value at each time: pure
const follower = try builder.chase(.{ .target = target, .from = 0, .time = half_second,
    .overshoot = 0.1, .time_from = time });              // its spring's time, read at each step

try tracks.write(knob, now, 1.25);                       // from now on: the past keeps its values
```

A knob can mean two things. A rebuild with a new parameter rewrites history: the whole timeline
changes, which suits a document such as an explainer, and costs a read from the start cue to t for
simulated nodes. A **track** applies from now on, as an instrument does: `write(track, t, v)` holds
v from t until a later write and removes what was written after t, as a latch automation lane
does. A program reads tracks as it reads cues, so it stays a function of t, seekable, and
scrubbing back shows what was played. A write drops only the checkpoints that read a changed
value, so a write at the playhead costs about a microsecond, and one in the past at most a
second's steps.

The parameters of simulated nodes can come from nodes: a chase's `time_from` and
`overshoot_from`, and a follower's `mover_from` (a spring's time and overshoot, or a Newtonian
move's speed, accel, and decel). An `oscillator` is a wave whose rate is a node; its phase is the
rate summed over the steps, so it is simulated. Exact springs toward goals and waves keep constant
parameters, since a varying one would make them simulated. A spring whose stiffness comes from a
node has no range Weft can prove, so it reports an unbounded one; `graph.zig`, section 14,
explains the bounds that hold.

## Language

A program can be written as text and compiled once, at init, into the same nodes the builder
would make, so text costs nothing at `eval`. Play's two signal tables are written in it. A file:

```txt
# Comments run to the end of the line.
seed 7

cue c0 = 0s
cue c1 = 2s
cue bar = 10s..600s every 2s # a series: bar[0] to bar[295], after c1
track chase_s = 0.5 in 0.125..2 # a track: its value before a write, then its bounds

moves = [c1: 1, bar[0]: -0.5] # a path: goals at cues
noise = noise(smooth, 1hz, seed: 1)
spring = spring(moves, time: 0.5s, overshoot: 0.2)
chase = chase(noise, time: chase_s) # a signal sets a parameter, read at each step
sum = noise + spring * 0.5 - 1
glide = follow(
    [0..1], # regions to draw goals from
    by: newtonian(speed: 1, accel: 16, decel: 16),
    pause: 0s..500ms,
)
fb = delay(0)
loop = chase(1 + fb * -0.8, time: 0.5s)
fb <- loop # a cycle goes through a delay
```

```zig
var compiled: weft.lang.Compiled(.{ .nodes = 24, .slab = 112, .cues = 6, .tracks = 4 }) = undefined;
compiled.compile(source) catch {
    for (compiled.errors()) |found| try found.render(source, "signals.weft", writer);
};
const program = compiled.program;
const chase = compiled.signal("chase").?;    // a node
const knob = compiled.track("chase_s").?;    // a track to write
const goal = compiled.goal("spring");        // a path and its from, a chase's target, or none
```

- **Calls match the builder**, by name and parameter, as a table of primitives the checker reads.
  Up to two leading arguments go by position; the rest are named and have defaults where the
  builder's documentation gives one.
- **Times and frequencies carry units**: `2s`, `500ms`, `0.5hz`. A time is a whole number of
  flicks, so seconds are exact to five places and milliseconds to two; anything finer is an error
  naming the nearest flick.
- **A cue is a time, or an earlier cue plus one**: `cue hit = c1 + 500ms`. The sum is worked out
  at compile, so the table holds plain times and `Cues.move` moves one cue.
- **A series** is evenly spaced, `cue bar = 10s..600s every 2s`, or a list of cues in time order,
  `cue title = [1s, 1080ms, c1 + 160ms]`, each item what a cue's time takes (step 28). Either way
  `title[2]` is one of its cues, `cues(title)` counts them, and `Compiled.cue_name` names each.
- **A name is declared above its use**, so the node order is the text order. Calls and names never
  clash, so `tween = tween(...)` is fine. A cycle goes through a delay, fed below by `<-`.
- **Arithmetic** is `+`, `-`, `*`, `/`, and parentheses. `a - b` is `a + b * -1`, exact, so no
  new op. `a / c` is `a * (1 / c)`, so no new op either: the divisor is a number fixed when the
  program is built, not 0, and never a signal, whose range could hold 0. The product is the
  quotient exactly when `c` is a power of two and within one ulp of it otherwise, the same bits on
  every target; two numbers fold to the quotient itself.
- **`abs(x)`, `min(a, b)`, and `max(a, b)`** are pure calls, per component and per lane as `+`
  is: a vector or a colour goes in whole, a number is broadcast, and the call has the lanes of
  what it reads. Their ranges are exact, so `abs` of a signal over [-1, 1] is [0, 1], and
  `std`'s `clamp(x, low, high)` is `min(max(x, low), high)`, exact too. Given only numbers, a
  call folds to its constant. A signed zero has one answer on every target: `abs(-0)` is +0,
  `min` of -0 and +0 is -0, and `max` is +0.
- **`sin`, `cos`, `exp`, `ln`, `sqrt`, `floor`, `round`, and `pow(x, n)`** are the same kind of
  call, on Weft's own code so the bits are the same on every target. `sin` and `cos` take
  radians. Each is total: `sqrt` of a negative is 0, `ln` at and below 0 is held at about
  -744.44 (the log of 2^-1074), `exp` above 709 holds e^709, and the trig functions lose
  accuracy with the size of their input, all of it from 2^53 tau on, where every input is a whole
  number of turns. `round` takes a half away from zero: -0.5 to -1, 2.5 to 3. `pow`'s `n` is a
  whole number from 2 to 8, written as a literal, and `pow(x, 2)` is `x * x` bit for bit with a
  range that knows both factors are x. `floor` and `round` of a smooth signal step, and keep its
  class: of a chase they are simulated, and step where the chase's interpolation crosses, between
  the fixed steps. `std`'s `quantize(x, step)` is `round(x / step) * step`, so `step` is a number
  fixed when the program is built, as a divisor is.
- **Seeds**: an explicit `seed:` wins; otherwise it is a hash of the declaration's name, so a new
  line never reshuffles another.
- **Errors** give a line, a column, a reason, and a hint, as Zig prints its own:

```txt
signals.weft:14:22: error: chase has no parameter `tme`
    chase = chase(noise, tme: chase_s)
                         ^^^
    hint: did you mean `time`?
```

There is one canonical format, which `lang.Syntax` writes: one declaration a line, no lining up,
named arguments in the table's order, and a call written one argument a line exactly when its last
argument has a trailing comma, as `zig fmt` does. `src/lang/lang.zig` explains the stages.

## Modules

A module is a named graph with parameters. It expands where it is used, like a macro with types,
into the nodes the same graph written out would make, so a program never contains a module:

```txt
use std                                     # snappy, heavy, breathe, bob, clamp, quantize

module wobble(t: 0.3s) = spring(time: t)    # a mover, for `by:`
module hop(s, at) in -1..1 = bounce(0..1, speed: s, at: at) * 2 - 1

cue c0 = 0s
moves = [c0: 1]
out = snappy(moves)                         # spring(moves, time: 0.25s)
b = heavy(moves, time: 0.5s)                # a default, overridden by name
f = follow([0..1], by: wobble(), seed: 3)
h = hop(0.7, c0)
```

```zig
compiled.compile_with(&.{.{ .name = "std", .text = weft.lang.std_library }}, source) catch { … };
```

- **Parameters** take arguments by position or by name, and a default is a literal. A parameter's
  kind is not declared: it is whatever the body uses it as, a signal, a number, a cue, or a path.
- **A body sees its parameters**, the primitives, and the modules, never the file's names. A module
  may be used above its declaration.
- **Libraries** are text the client passes by name (`Limits.libraries` of them); `use` brings a
  library's modules in. The core reads no files.
- **Cycles are refused** with the path through them, `a -> b -> a`, and modules nest at most 16
  deep. Using a module inside its own argument, `twice(twice(x))`, is not a cycle.
- **Seeds** inside an instance hash the instance's place, so two instances differ and a new line
  elsewhere never reshuffles one.
- **A declared range**, `in lo..hi`, is checked after the build for an instance bound to a name.
  The range analysis widens each range by a rounding margin, so the declared range is allowed
  that margin too: 2^-40 of its larger end.
- **Errors** inside a library's module are reported on the file's call, with a note naming the
  module and the library.

## Vectors and Colour

A value has a shape: a number, a `vec2`, a `vec3`, or a colour, three components in OKLab. Two
pure ops carry shapes through the graph, `pack`, scalars into one value, and `pick`, one component
out, and arithmetic, `map`, `min`, `max`, and every function of a value such as `abs` or `sin`
work per component, a number broadcast across the others:

```txt
cue c0 = 0s
cue c1 = 2s
path = [c0: vec2(0.2, 0.8), c1: vec2(0.9, 0.3)]
dot = spring(path, from: vec2(0, 0), time: 0.6s, overshoot: 0.3)
sway = vec2(noise(smooth, 0.5hz), noise(smooth, 0.5hz)) * 0.1
place = dot + sway                       # a vec2
height = place.y                         # a number
sweep = tween(from: srgb(0.95, 0.35, 0.2), to: srgb(0.2, 0.45, 0.95), at: c0, over: 4s)
light = sweep.l * 2                      # a colour's components are .l .a .b
```

- **A moving vector** is one scalar node a component, then a pack: a `vec2` spring reads exactly
  what two scalar springs read, bit for bit, and no motion op knows about vectors. `tween`'s ends,
  a path's goals and `from`, and `chase`'s target take a vector or a colour of one shape.
- **Colour** is OKLab, converted only at the two edges: `srgb(r, g, b)` at compile time, and a
  client's read, through `weft.colour.to_srgb`, which keeps the lightness and hue and lowers the
  chroma until the colour fits the sRGB gamut. So a tween between two colours is a straight line
  through OKLab, which neither darkens nor greys in the middle, and a spring that overshoots still
  draws.
- **Shapes are checked** where they are used: a parameter that takes a number takes a number,
  arithmetic takes equal shapes or a number, and a colour and a vector never mix, each with an
  error that says so (`wrong_shape`). `describe` marks the parameters that take a shape, and
  `sample` writes a vector's value as an array of its components.

## Lanes

One program evaluates many elements as lanes: a node's values are lane after lane in the slab, and
each node has its own lane count. `lanes(n, body)` checks its body in a region of n lanes, where
`lane` is each lane's index:

```txt
cue c0 = 0s
rise = lanes(1000, tween(from: 0, to: 1, at: c0, over: 0.6s, ease: out, stagger: 2ms))
height = lanes(1000, map(noise(smooth, 0.25hz), -1..1, to: 0.2..1))
bars = rise * height                     # 1,000 lanes
across = lanes(1000, lane * 0.001)       # each bar's place, from its index
hits = lanes(1000, bounce(0..1, speed: 0.5, at: c0, stagger: 3ms))   # events carry their lane
```

- **Only what varies has lanes.** In a region, a noise, a follower, a shift register, and a delay
  have the region's lanes, each lane its own seed; a wave, a tween, a spring, a Newtonian move,
  and a bounce given a `stagger:` do too, lane i starting i × stagger after lane 0, exact to the
  flick. Anything else has the most lanes of what it reads, so a constant, a knob, or a name bound
  outside the region is one value, broadcast, however many lanes read it.
- **Events carry their lane** as their instance, in the order of time, source, then lane, and a
  full buffer counts what it drops, so a thousand bounces read as one stream.
- **A client reads a lane array** at once: `State.values(id)` is lanes × components f64, lane
  after lane, ready to copy into an instance buffer, and `State.extent(id)` gives the counts.
- **A lane count is fixed** when the program is built. A client whose data changes size
  recompiles, and the carry keeps every simulated node whose size did not change.
- **A cue for each lane** (step 28): `at: beat[lane]` in a `tween` or a `bounce` starts lane i at
  the series' cue i, so lanes can differ by more than a fixed gap. A title whose letters pause
  after a space is a list series and one line:

  ```txt
  cue letters = [1s, 1080ms, 1160ms, 1240ms, 1320ms, 1400ms, 1720ms, 1800ms]
  rise = lanes(8, tween(from: 0, to: 1, at: letters[lane], over: 300ms, ease: out))
  ```

  A cue moved with `Cues.move` moves its lane only. The series needs a cue for every lane, the
  index is `lane` itself (no arithmetic on it), it takes no `stagger:`, and it is the `at` of a
  `tween` or a `bounce` only; each of these is refused with a hint. In the core it is one field,
  `cue_by_lane`, on `Tween`, `Bounce`, and `BounceNode`: lane g reads cue `start + g`
  (`graph.lane_cue`), one load and one add a lane, in `eval` and in `events`.
- **Lanes are checked** where they are written: two counts above 1 meet only when equal, a
  parameter a signal sets takes one value for every lane, regions do not nest, and `lane` and
  `stagger:` belong inside a region, each with an error that says so (`wrong_lanes`). `sample`
  writes a signal of many lanes with `"lanes"`, each value an array of its lanes.

In the core, `Builder.lanes` opens a region and `Builder.Options.lane_first` names its lane 0, so
lane i of a family built together equals lane i built alone, bit for bit, which
`src/core/graph_test/lanes.zig` checks for a thousand lanes. At 100,000 lanes of a noise, a
staggered tween, a map, a product, and a staggered bounce, an eval costs about 2.5 ms on an
i5-13600K, most of it in the noise; `@Vector` loops for the arithmetic made no difference, since
the compiler already vectorizes them.

## A Client's Nouns

The language is a front end, and Weft's signal graph is one back end. A client adds its own
calls to the table of primitives with `Compiled.compile_client(entries, libraries, source)`, in
one of two ways, by the entry's `op`:

| `op` | What it is | What Weft's back end does | What the client does |
|---|---|---|---|
| `client` | A signal the client computes | Refuses the file | Builds its own program from `compiled.checked.calls` |
| `noun` | A thing the client owns: an axis, a caption, a typeface | Builds the signals among its arguments, skips the call | Reads `compiled.nouns()` beside the program |

A `noun` is how one file holds a client's score and its motion. Tapestry's scenes are the case it
was made for:

```txt
cue b1 = 0s
track a = 1 in 0..3
xs = lanes(121, lane * 0.05 - 3)
ax = axes(x: -3..3, y: -1..9)
f = plot(ax, xs, y: a * xs * xs, draw: tween(from: 0, to: 1, at: b1, over: 1s))
n1 = say(b1, "Here is a parabola.")
```

```zig
const nouns = [_]weft.lang.schema.Entry{ axes, plot, say };   // op = .noun
try compiled.compile_client(&nouns, &.{}, source);
var each = compiled.nouns();                                  // in the file's order
while (each.next()) |noun| {
    // noun.name ("f"), noun.entry (plot), noun.values: one for each of the entry's params
    const on = compiled.noun_of(noun.values[0].noun);         // the axes it names
    const y = compiled.node_of(noun.values[2]);               // a signal's node
    const heights = state.values(y);                          // 121 lanes, after an eval
}
```

- **A noun is a declaration, never a value.** It stands alone on a line, bound to a name, which
  is the client's stable id for it. A noun's call or its name where a signal is wanted is an
  error that says so. A module's body is a signal, so a module cannot make a noun.
- **Two kinds are for nouns.** `string` is a literal in double quotes on one line, with no
  escapes: its value is a slice of the source, so a formula's backslashes need no doubling and a
  string cannot hold a double quote. `noun` is the name of a noun declared above; the
  parameter's `words` list the entries it takes, or none for any.
- **Every other kind works as in a primitive**: a number, a range, a cue, a word, a path, and
  `signal`, with `shaped` for a vector or a colour. A `signal` with `.default = .absent` is
  optional and reads as `Value.absent`; a `string` may default to `.{ .text = "…" }`.
- **A noun's signals do not join.** One may have 121 lanes, the next one, and the next a colour's
  three components: each is the client's to read, by `program.nodes[id.index].extent` or
  `state.extent(id)`. `describe` prints its lanes as `apart`.
- **Order is the client's dependency order.** A noun names only nouns above it, so a client that
  resolves them in `nouns()`' order never meets one it has not seen.
- **A recompile carries a noun's simulated signals** like any binding's. A noun's fingerprint
  takes in the nouns it names, so editing an axis starts its plots' simulated signals fresh.
- **An entry has at most 24 parameters** (`schema.params_max`; 16 before step 36), and so has a
  module.
- **A cue's name from its index**: a noun's `cue` value is an index into the cue table, and
  `compiled.cue_name(index)` gives back `.{ .name = "hit" }`, or for a cue of a series its name
  and place, `.{ .name = "bar", .element = 2 }`; null for an index past the table.
- **A client's own command** is a few lines on the module `commands` (`cli/commands.zig`):
  `describe`, `check`, and `sample` take the client's entries, and the `weft` command passes
  none. `check` counts the nouns on its `ok:` line; `sample` lists signals only, so a signal a
  noun reads inline is sampled by binding it on a line of its own. A client's own checks of its
  nouns (a shape, a position) run after `check` returns: they add to
  `compiled.syntax.diagnostics` and the client renders them. `commands.limits` holds two
  libraries, `std` and one of the client's.

## The weft Command

`zig build` installs `zig-out/bin/weft`, the tool an agent uses in place of watching motion. It
needs no window, no GPU, and no Patchwork, and each command is a thin call into the library:

```bash
weft check FILE [--use NAME=PATH]...            # diagnostics, or a summary and its limits
weft describe [--use NAME=PATH]...              # primitives and modules, as JSON
weft sample FILE [--from S] [--to S] [--step S] [--signal NAME]...   # values and events, as JSON
          [--events NAME]... [--lanes A..B]     # only these sources' events, only these lanes
weft parse FILE --json                          # the flat tree, as JSON
```

```txt
$ weft check play/signals.weft
ok: 21 nodes, a slab of 112, 6 cues, 3 goals, 4 regions, 4 tracks, seekable, stepped
limits: .{ .tokens = 561, .tree = 268, .names = 29, .nodes = 21, .slab = 112, .cues = 6, .goals = 3, .regions = 4, .tracks = 4, .modules = 0, .libraries = 0 }
$ weft sample play/signals.weft --to 1 --step 0.5 --signal wave
{"from":0,"to":705600000,"step":352800000,"signals":[{"name":"wave","range":[-1,1],"bounded":true,"values":[0,1,0]}],"events":[{"t":22050000,"source":19,"instance":0,"name":"glide_a","value":0.496…},…]}
```

- **Times** on the command line are seconds; in the output they are flicks, so a grid is exact.
- **`check`'s limits line** is the least `Limits` the file compiles with, ready to paste, from
  `Compiled.needs()`: `track_samples` and `errors` are left to the client. A file with a lane
  region adds `a lane costs N of the slab`. A `Compiled` at the default `Limits` is about 1 MB
  whatever the file, so a client short of static memory sizes one from this line.
- **`sample`** allocates its reader's slab, so a file of any slab size can be sampled (v0.1.0's
  command held 262,144 values). `--events NAME` keeps the events of the signal bound to NAME,
  from the nodes `Compiled.event_sources` gives, so a region's bounce with no stagger and a
  vector's spring keep theirs (step 23), and `--lanes A..B` keeps lanes A to B, both included, of every signal and event of a region:
  each such signal gains `"lane_first"`. Every signal says `"bounded"`, false when its range has
  an infinite end, which prints as `null`.
- **`describe`** gives each primitive's `"lanes"`, how it takes them (`region`, `stagger`,
  `inputs`, `one`, or `makes`), and its `"events"`, what an event's `value` carries, or `null`.
- **At most two `--use`**; a third is an error that says so, as it is from `commands.check` and
  `commands.sample`, which a client's command calls with its own entries (A Client's Nouns).
- **JSON** has its keys in a fixed order and no whitespace, and a value that is not finite, such
  as an unbounded range, is `null`. The output of every command is locked by a golden in
  `test/golden/cli`, so a change to it is a reviewed change.
- **Exit codes**: 0 on success, 1 when the file has errors, 2 for bad arguments or a file that
  cannot be read.
- **A client's nouns**: `Compiled.compile_client` takes entries beside the table of primitives,
  and `describe` lists them under `nouns`. The `weft` command itself registers none, so a
  client's own command checks its files (see A Client's Nouns).

## Regress

`zig build regress` renders `test/catalog.zig` on native and on wasm and compares both with
`test/golden/signals.txt`, byte for byte. It samples each wave, each noise, and a few whole graphs,
among them a spring, a Newtonian move, and each simulated node, then lists the events of a few
more, then samples a recording played back. There is one sample or event per line, values as hex
floats, so any changed bit or flick fails and the report names the line:

```txt
regress: native differs from golden at line 700
  golden: triangle 440hz hour 3 0x1.c28f5c28f5c28p-1
  native: triangle 440hz hour 3 0x1.c28f5c28f5c29p-1
```

Bless only for a change the step means to make, in that step's commit.

## Bench

`zig build bench -Doptimize=ReleaseFast` prints its build mode and one line per case: a pure
graph of 16 waves summed, per eval; four chases on a wave plus noise playing forwards at 60 Hz, per
frame; that graph from a fresh state, the first eval at 60 s and at 600 s; a bounce and cues,
`events` per 128-frame block at 48 kHz; 16 waves, a bounce, and cues, with and without a chase, a
6 s window of events around a playhead at 60 Hz and its eval, by `events` and by `events_of` the
solved sources, and that eval alone (step 23); a track write at the playhead at 600 s, then the
frame's eval, which is what a knob costs from now on; a compile of Play's `signals.weft`; a
compile of modules nested 8 deep, 511 instances; and a region of a noise, a staggered tween, a
map, a product, and a staggered bounce at 1,000 and 100,000 lanes, an eval and a frame's events
per frame; each op's cost a node, 64 nodes of it playing at 60 Hz; a seek back from 600 s with
checkpoints; a pure edit of Play's file at 600 s, compiled, carried, and read; and a reader on its
own thread at audio pace, a block's events and an eval every 2.667 ms for 5 s, for Play's file
and the lanes page, with its worst block and the blocks over budget. It is native only and needs
no GPU. Its numbers depend on the machine, so it has no thresholds and is not part of `test` or
`regress`; the Costs section records them at step 18.

## Costs

Measured with `zig build bench -Doptimize=ReleaseFast` on an i5-13600K, at step 18; step 19's
bound adds about 5% to a stepped node's step. The numbers are ReleaseFast: Debug is about ten
times slower. Play's simulated file is `signals.weft`, 21 nodes: four chases, a follower, a
shift register, an oscillator, tracks, cues, and pure nodes around them. A frame at 60 Hz has
16.7 ms; an audio block of 128 frames at 48 kHz has 2.667 ms.

Since step 34 (2026-11-11) a step skips the nodes no simulated node reads: three chases beside 32
waves and 1,000 lanes they do not read went from 974 ms to 6 ms for a first eval at 90 s, and
Tapestry's steps film from 1.44 s to 0.02 s for a read at 90 s. An eval of every node costs about
0.1 to 0.2 ns more a node on the smallest pure ops, and the seek back and the pure edit of Play's
file below got about a sixth faster; the other figures did not move.

| What | Cost |
| --- | --- |
| A node a frame at 60 Hz, pure: constant, track, cues, map, add, multiply, and since steps 26 and 33 abs, min, max, sqrt, floor, round, pow | 2 to 3 ns |
| … since step 33: exp, ln (of a positive value), cos, sin | 8, 8, 10, and 10 ns |
| … wave, tween, Newtonian move, spring, noise, bounce | 6, 10, 14, 22, 20, and 27 ns |
| … simulated, with its 8 steps a frame: crossing, delay, shift, oscillator, chase, follower | 41, 52, 94, 105, 181, and 235 ns |
| A lane, in a region of a noise, a staggered tween, a map, a product, and a bounce | 25 to 44 ns a frame |
| … so a node of a lane, at 100,000 lanes | about 5 ns |
| A step of Play's file, from cold: 288,000 steps to 600 s | about 0.12 µs, 6 ns a node |
| 1,000 and 100,000 such lanes, an eval | 44 µs and 2.5 ms |
| Play's simulated file (21 nodes) from cold, the first eval at 60 s and at 600 s | 3.4 ms and 34 ms |
| The same reader, checkpoints filled, a seek back from 600 s to 300.99 s | 151 µs |
| A compile of that file, text to program | 15 µs |
| A pure edit of it at 600 s: the compile, the carry, and the first eval | 74 µs |
| A reader on its own thread at audio pace, the worst block of 1,875: Play's file, 1,000 lanes | 262 µs and 346 µs, none over 2.667 ms |

So a reader on an audio thread plays forwards, at a few percent of its budget. A seek costs at
most a second of steps once checkpoints cover the time, 151 µs here, but a cold seek runs every
step from the start, 34 ms at 600 s, so a client warms an audio reader on another thread, or
starts it at the playhead and keeps it there. `test/rules.zig` holds the other half of the
realtime claim: no file of the core or the language names an allocator, a thread, a lock, a file,
or a clock.

## Play

Play is Weft's first client: a Patchwork app with seven pages on one 600 s clock. Its signals are
text, `play/signals.weft`, `play/bouncers.weft`, `play/vectors.weft`, `play/lanes.weft`, and `play/swarm.weft`,
compiled at start, and the first can be edited while it runs.

- **scope** plots eight signals, one or more of each class but live, over a window from one second
  before the playhead to three after it, with each signal's range, its goal where it has one, the
  cues, and a dot at each event: a goal reached, a follower arriving, a bucket entered.
- **shapes** draws lines, a star, a filled pentagon, and a cubic curve whose 11 parameters are
  destinations. Each reads one of 16 sources, the scope's eight and eight more, through the
  source's declared range, so it never leaves its own range. A button beside each destination
  re-points it to the next source, live, without touching the program. Four knobs set parameters
  of the program from now on: each is a track (see Live Parameters), so a turn at t leaves the
  past as it was played, scrubbing back shows the knob as it moved, and a turn costs tens of
  microseconds a frame at any t.
- **bouncers** runs seven bounces between 0 and 1 on a pure program of their own: step 7's worked
  bounce at 0.7 units a second, and six that hit 2 to 7 times a 2 s bar, so the lanes show
  polyrhythms that land together on every bar. Each lane is the scope's window, its triangle a
  stroke whose corners are its hits; a small bouncer beside it flashes the wall it last hit, and a
  log lists the last six hits at their exact times, in seconds and flicks. Every hit is read from
  the graph each frame and none is kept, so a pause, a scrub, or a frame rate never changes what
  a time shows.
- **text** is `signals.weft` in Patchwork's editor, coloured by Weft's own tokenizer, beside the
  scope's rows and four knobs. Each edit recompiles; a text that does not compile keeps the last
  good program running and marks its errors, with the first named under the editor. A program
  that compiles runs from the playhead on, and its readers keep their steps when no simulated
  node changed (Recompiling and Carry, `src/lang/lang.zig`), so such an edit costs under a
  millisecond even at 600 s. A fresh reader would give the same bits, so a spring in flight never
  jumps either way: the carry saves the replay, not the motion. A `seed`, `start`, `use`, or
  `module` line, or a library's text, is global to the carry, so changing one starts every
  stepped node from the start. The knobs here are bound to
  the numbers of the `track` lines: turning one rewrites the number, one undo entry a drag, and
  with it the track's history, unlike the shapes page's knobs, which apply from now on. While a
  knob is dragged, its value is a preview from the playhead on, under a millisecond a step; the
  release rewrites the history once, which runs a simulated program's steps again: about 10 ms
  at 60 s, 90 ms at 600 s.
- **vectors** runs a pure program of its own: a `vec2` spring through four goals, swaying by two
  packed noises, drawn on a plane with its trail over the window, and three colours as strips over
  the window: a colour tween, a colour spring whose overshoot leaves the sRGB gamut and is mapped
  back, and an OKLab colour whose a and b are noises. The dot takes the colour spring's colour.
- **lanes** runs a thousand lanes of one pure program as a field of dots: each rises 3 ms after
  the one before to a height of its own noise, in a colour of its own two noises, and flashes when
  its bounce, 5 ms behind the one before, reaches the top wall. The flashes are every lane's
  events of the last quarter second, read in one buffer each frame, whose count and drops show
  under the field. A frame costs under 0.2 ms at any time.
- **swarm** runs forty-eight lanes of one stepped program: each dot is a follower of its own x and
  y wandering a square, trailed by a ghost, a chase 0.4 s behind it, joined to it by a thread whose
  length is the lag, and ringed while a `crossing` gate on its x reads 1. Its steps run from the
  start, so a scrub to 600 s costs a second or more the first time, which fills the reader's
  checkpoints; playing on costs under 0.1 ms a frame at any time, and a jump to anywhere after
  that costs at most 479 steps. It reads no events, since a window behind the playhead restores a
  checkpoint every frame on a stepped program.

Space or the play button plays and pauses, the page button cycles the pages and 1 to 7 go to
each, the slider scrubs, Home and End go to the ends, Left and Right step 100 ms, and Page Up and
Page Down 10 s.

```bash
cd play
zig build run                       # natively (Wayland, and a GPU through wgpu-native)
zig build serve-play                # in the browser, on localhost
zig build test                      # its tests, with no GPU
zig build regress -Doptimize=ReleaseFast   # its scenarios against test/golden (needs a GPU)
zig build bench -Doptimize=ReleaseFast -- knob_600   # a knob dragged at 600 s, per frame
zig build bench -Doptimize=ReleaseFast -- play_590   # the scope and its dots playing at 590 s
zig build test -Doptimize=ReleaseFast   # prints what an edit and a text knob cost at 60 s and 600 s
```

It needs Patchwork checked out beside Weft, at `../patchwork`, and Patchwork's requirements.
`play/` depends on Weft through `.path = ".."` and on Patchwork through
`.path = "../../patchwork"`, so neither library enters the other's `build.zig.zon`, and Weft's
own package still has no dependencies.

**The two-file rule.** Only `play/signals.zig`, the signal table, and `play/glue.zig` import
`weft`. Everything else in Play (`app.zig`, `scope.zig`, `patch.zig`, `shapes.zig`,
`bouncers.zig`, `vectors.zig`, `field.zig`, `swarm.zig`) draws plain numbers: the glue hands time over as a `Clock`, and the samples,
events, ranges, classes, and report as `f32` arrays and plain structs. The glue was given a
budget of 60 lines of code at step 9; at step 18 it is about 500, most of them one function a page
that reads its program at t and copies the numbers out, and a recompile with its carry. The review
after step 18 reads that as the shape of the bridge a second client would share, not as a wrong
API.
