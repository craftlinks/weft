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

Every source file opens with a guide for reviewers. Start with `src/weft.zig`, then the guide at
the top of `src/core/graph.zig`, which holds the graph's layout and most of the rules above. The
sections below show each part in use.

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
```

## Layout

```txt
src/
  weft.zig            the library root
  core/
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
test/
  catalog.zig         the sampled signals, rendered as text of hex floats
  golden/signals.txt  the committed samples
tools/
  bench.zig           times four cases of reads, for zig build bench
  regress.zig         compares native and wasm text with the golden, and blesses
  regress_wasm.zig    the catalog on wasm32-freestanding
  regress_wasm.mjs    runs that module under Node and prints its text
play/                 a package of its own: the Play app, on Weft and Patchwork
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
`newtonian`, `chase`, `follow`, `shift`, `delay`, `bounce`, `crossing`, `cues`, `input`,
`recorded`, `oscillator`, and `track`. The builder refuses by name what does not fit or cannot
be evaluated: `error.NodeCapacityExceeded`, `error.SlabCapacityExceeded`, `error.UnknownNode`,
`error.NotFinite`, `error.InvalidRange`, `error.UnknownCue`, `error.InvalidDuration`,
`error.InvalidEase`, `error.InvalidRate`, `error.UnknownGoals`, `error.InvalidOvershoot`,
`error.InvalidLimit`, `error.UnknownRegions`, `error.InvalidTolerance`, `error.InvalidPause`,
`error.InvalidOdds`, `error.InvalidBuckets`, `error.NotADelay`, `error.DelayClosed`,
`error.UnknownSamples`, `error.UnknownTrack`, `error.InvalidParameter`, and `error.InvalidPhase`.

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

**Evals and events on one reader.** An `eval(s)` at a time exactly on a step leaves the slab one
step past it, so an `events(s, ...)` right after it restores a checkpoint. A reader that
interleaves the two, as a scope sampling a window does, can read its events as `(s, s']`, that is
`events(s + 1, s' + 1)` in flicks: that range starts at the very step `eval(s)` left and ends at
the one `eval(s')` needs, so it never restores and runs no step the evals would not. An events
query runs every simulated node's steps across its range, whatever sources the caller wants, so
events of pure sources are cheapest in a pure program of their own (Play's bouncers are one).

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
Sums, products, waves, and noise are exact; an interpolation, a map, a tween, or a motion is
widened by a margin relative to its scale. A spring's range includes its overshoot: one move from
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
`events` per 128-frame block at 48 kHz; and a track write at the playhead at 600 s, then the
frame's eval, which is what a knob costs from now on. It is native only and needs no GPU. Its
numbers depend on the machine, so it has no thresholds and is not part of `test` or `regress`.

## Play

Play is Weft's first client: a Patchwork app with three pages on one 600 s clock.

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

Space or the play button plays and pauses, the page button cycles the pages and 1, 2, and 3 go to
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
```

It needs Patchwork checked out beside Weft, at `../patchwork`, and Patchwork's requirements.
`play/` depends on Weft through `.path = ".."` and on Patchwork through
`.path = "../../patchwork"`, so neither library enters the other's `build.zig.zon`, and Weft's
own package still has no dependencies.

**The two-file rule.** Only `play/signals.zig`, the signal table, and `play/glue.zig` import
`weft`. Everything else in Play (`app.zig`, `scope.zig`, `patch.zig`, `shapes.zig`,
`bouncers.zig`) draws plain numbers: the glue hands time over as a `Clock`, and the samples,
events, ranges, classes, and report as `f32` arrays and plain structs. The glue has a budget of
60 lines of code; growing past it says the boundary or Weft's API is wrong.
