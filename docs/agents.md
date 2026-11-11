# Weft for Agents

This is the page to read first if you are an agent who has never seen Weft. It says how to learn
the toolbox from the command line, how to write a file, how Play puts a page together, and how to
add a primitive. The README says why things are as they are; this says what to do.

## 1. Learn the Toolbox From the Tool

Build the command once, from the root of the repository:

```bash
zig build                                  # zig-out/bin/weft
```

Then ask it, rather than guessing:

```bash
zig-out/bin/weft describe --use std=src/lang/std.weft   # every call and module, as JSON
zig-out/bin/weft check FILE                              # ok, or errors with hints
zig-out/bin/weft check FILE --use std=src/lang/std.weft  # a file that says `use std`
zig-out/bin/weft sample FILE --to 4 --step 0.25          # every signal's values and events
zig-out/bin/weft sample FILE --signal NAME               # one signal
```

- **`describe`** lists every primitive: its parameters in order, which may go by position, each
  one's kind (`number`, `time`, `frequency`, `signal`, `cue`, `path`, …), its default, whether a
  signal may set it (`live`), and whether it takes a vector or a colour (`shaped`). Then every
  module of the standard library, with its body. Read it before writing a call.
- **`check`** prints `ok:` with the program's counts and whether it is seekable and stepped,
  then `limits: .{ … }`, the least `Limits` the file compiles with, ready to paste, and for a
  file with a region what a lane costs of the slab. Or it prints each error with a line, a
  column, and a hint. The hint is usually the fix.
- **`sample`** is how you see motion you cannot watch: each signal's range, its value at each time,
  and the events in the window. A signal of many lanes prints `"lanes"` and each value as an
  array of lanes; a vector prints `"components"`. Sample a short window first: `--to 2 --step 0.1`.
  The output's times are flicks (705,600,000 a second), and each event has its source node, its
  `instance` (the lane), the `name` bound to its source, and its `value`. With 700 events or
  20,000 lanes, add `--events NAME` and `--lanes 0..4` to read a few.
- **A chain or a trail** is chases of chases: `a = chase(lead, time: 0.2s)`, `b = chase(a, …)`,
  each link a line. A `chase` takes a vector target (`describe` marks it `shaped`), so
  `chase(vec2(x, y), time: 0.2s)` follows a point.
- **Which calls take lanes**: `describe` gives each call's `"lanes"`. In `lanes(n, …)`, `noise`,
  `follow`, `shift`, and `delay` have the region's lanes (`region`), and so do `wave`, `tween`,
  `spring`, `newtonian`, and `bounce` given a `stagger:` (`stagger`). Every other call, `chase`,
  `crossing`, `map`, `oscillator` and the arithmetic among them, has the most lanes of the
  signals it reads (`inputs`).

## 2. Write a File

One declaration a line, a name above its use. Times carry units (`2s`, `500ms`), frequencies
`hz`. Every idea, once:

```txt
seed 7                                   # the file's seed; every noise draws from it
cue c0 = 0s                              # a named time
cue bar = 0s..60s every 2s               # a series: bar[0] to bar[30]
cue late = bar[30] + 500ms               # a cue after a cue, summed when the file compiles
track speed = 0.5 in 0..2                # a value a client writes, from a time on

wave = wave(sine, 0.5hz)                 # pure: a function of t
noise = noise(smooth, 1hz)               # pure, seeded from its name
rise = tween(from: 0, to: 1, at: c0, over: 1s, ease: in_out)
moves = [c0: 1, bar[2]: -0.5]            # a path: goals at cues
spring = spring(moves, time: 0.5s, overshoot: 0.2)      # exact between goals
chase = chase(noise, time: speed)        # simulated: follows a signal; a track sets its time
hit = bounce(0..1, speed: 0.7, at: c0)   # its hits at the walls are events
up = hit.velocity                        # a call's second output
sum = wave * 0.5 + rise - 1              # arithmetic: + - * / and parentheses
place = vec2(noise, wave) * 0.1          # a vector; place.x is a number
tint = srgb(0.9, 0.4, 0.2)               # a colour, kept as OKLab; tint.l is its lightness
dots = lanes(100, noise(smooth, 1hz))    # 100 lanes, each its own noise
fall = lanes(100, tween(from: 1, to: 0, at: c0, over: 1s, stagger: 10ms))   # one after another
index = lanes(100, lane * 0.01)          # each lane's index
fb = delay(0)
loop = chase(1 + fb * -0.8, time: 0.5s)
fb <- loop                               # a cycle goes through a delay, fed by name
use std                                  # the standard library: pass --use std=src/lang/std.weft
soft = snappy(moves)                     # a module: a macro with types
module bob2(base, amount: 0.1) = base + amount * wave(sine, 2hz)
```

Rules that trip agents most often:

- **Number parameters take literals.** A tween's `from` and `to`, a spring's goals, a bounce's
  range are fixed when the program is built. Only a parameter `describe` marks `live` takes a
  signal, and only a `signal` parameter takes an expression. To scale a tween by a signal, multiply
  the tween: `tween(from: 0, to: 1, …) * height`.
- **A divisor is a number**, fixed when the program is built: `lane / 1000`, `x / -4`, or a
  module's parameter bound to one. `x / 4` is `x * 0.25`, the same nodes. Dividing by a signal,
  a track, `lane`, a time, or 0 is an error: to scale by a signal, multiply by it.
- **A tween `after` a tween may leave out `from`**, and starts from that tween's `to`:
  `tween(to: 0, at: c1, over: 1s, after: rise)`. `after` must be a name bound to a tween;
  anything else needs `from`.
- **A delay is a declaration of its own**, `fb = delay(0)`, fed once below with `fb <- …`.
- **A loop with gain above 1 saturates** near 2^256 rather than crashing; values computed from it
  can still overflow, so a client calls `state.finite()` after `eval` on a program with a loop.
- **Lanes meet where their counts are equal or one side has one lane.** A name bound outside a
  region is shared by every lane. `lane` and `stagger:` belong inside `lanes(n, …)`.
- **Spring and Newtonian goals are at cues**, not times: declare the cues first.
- **A simulated signal** (chase, follow, shift, delay, crossing, oscillator) runs from the start
  cue, the first cue unless `start c` names another, so the file needs a cue.
- **The format is canonical.** `weft.lang.Syntax.format_into` writes it; Play's tests compare its
  files with it, so write one space after a comma and around `=`, `+`, `-`, `*`, none inside
  parentheses, and no trailing spaces.

## 3. How Play Puts a Page Together

Play is a Patchwork app in `play/`, its own package. Only `signals.zig` and `glue.zig` import
`weft` (the two-file rule; `language.zig` only for its tokenizer); every drawing file sees plain
`f32` arrays. A page is four parts, and the lanes page (`lanes.weft`, `field.zig`) is the
smallest complete one to copy:

1. **The file**, `play/NAME.weft`, embedded with `@embedFile`.
2. **The program**, in `signals.zig`: a struct holding a `weft.lang.Compiled` sized by `Limits`, the
   ids it reads by name, and a `build` that compiles and asserts the node and slab counts. The
   counts are exact: `weft check` prints every one a `Limits` needs, so size it from that and
   assert the node and slab counts; a test then locks a few values. A `Limits` too small makes
   `compile` fail with `error.Invalid`, and `compiled.errors()` says which limit to raise, so
   render them while you are sizing it.
3. **The glue**, in `glue.zig`: a plain struct of what a frame draws (`f32` arrays, counts), and a
   `Motion.sample_NAME(clock, out)` that evals the page's own reader at `clock.t`, copies values
   out (colours through `weft.colour.to_srgb`), and reads events with `reader.events(t0, t1, buf)`.
   Its reader and slab are `Motion` fields, set up in `Motion.build`, with a `Report` for the label;
   a stepped program of its own sets `first_name` to the binding of its first stepped node.
4. **The drawing**, `play/NAME.zig`, which does not import `weft`, and the app's wiring in
   `app.zig`: the `Page` enum and `next`, the number key, `draw`'s switch, the label's report, a
   field for the frame, the `test {}` list, two regress scenarios (`NAME`, still at a time, and
   `NAME_play`, playing), the page cycle test, and a ReleaseFast test that prints the frame's cost
   at 60 s and 600 s. Raise a draw pool's `cap` in `App.config` if the page draws many quads;
   the tests fail on any refused draw.

**A stepped page** (one with `follow`, `chase`, `shift`, `delay`, `crossing`, or `oscillator`)
costs what its steps cost, so plan for three things. Its reader needs checkpoint memory,
`(1 + seconds) * slab` f64, given to `State.init_with_checkpoints`. Its first read at a time it
has not reached runs every step from the start: about 1.5 s at 600 s for 48 lanes of followers
and chases, once, while the checkpoints fill. And a window of events behind the playhead, as the
lanes page reads, restores a checkpoint and steps again every frame, so read a stepped page's
values, or its events since the last frame with `state.events_since(now, &out)`, not a window
behind it, and give its reader `program.reader_slab_count()` of slab rather than `slab_count`.

Then, in `play/`:

```bash
zig build test                                  # Play's tests, with no GPU
zig build run                                   # look at it; press its number key
zig build regress                               # every scenario against the goldens
./zig-out/bin/play --regress --bless            # only once the new images look right
```

Look at `zig-out/regress/play/NAME-high-on.new.png` before blessing: it is the frame the golden
will lock. Each scenario's image is drawn on the regress clock, 1/60 s a frame. The goldens are
hashes, so to see what changed in an old scenario, render it from the tree before your change with
`./zig-out/bin/play --render NAME --out DIR` and compare the two images; `--regress --only NAME`
runs one scenario.

## 3a. A Client With Nouns of Its Own

A client such as Tapestry registers nouns, calls that describe what it owns, and compiles a file
with `compile_client`. In such a file you will meet two things plain Weft does not have:

```txt
ax = axes(x: -3..3, y: -1..9)            # a noun: a line of its own, bound to a name
f = plot(ax, xs, y: a * xs * xs)         # a noun names a noun above it; its signals are Weft's
n1 = say(b1, "Here is a parabola.")      # a string: double quotes, one line, no escapes
```

- The `weft` command does not know a client's nouns, so check such a file with the client's own
  command. Its `describe` lists them under `nouns`.
- A noun is not a signal: `ax + 1` and `lanes(3, axes(…))` are errors. Bind every signal a noun
  reads on a line of its own first if you want to `sample` it.
- To add nouns to a client, see the README's A Client's Nouns: an `Entry` with `op = .noun`, and
  `compiled.nouns()` to read them.

## 4. Add a Primitive

Add one only when no composition of the ones `describe` lists can express it, and say why in the
op's doc comment. Every op appears in the same places, in this order:

1. **`src/core/graph.zig`**
   - the op's struct, with a doc comment for each field, and its source struct if the client's
     description differs from what the node holds;
   - a field of `Op`, then `Op.cache_count` (slab after the output), `Op.simulated`, `Op.class`,
     and `Op.inputs`;
   - `Program.assert_valid` (what its node may refer to) and `Program.node_range` (a range its
     values never leave, sound for any inputs in their ranges);
   - a `Builder` method that refuses every input it cannot evaluate, by a named `Error`, before it
     builds anything, and picks its extent: `push` for one value, `source_extent` for a seeded
     source, `staggered_extent` for a timed one, `joined` for one that reads other nodes;
   - a section of the guide if the op brings a new idea.
2. **`src/core/state.zig`**: its arm in `eval_node`; if simulated, in `update_node` and
   `reset_node`; if it fires events, in `State.events` (closed form) or `report_step` (on the
   step). Add it to the `unreachable` lists the compiler names.
3. **Tests**: a topic file in `src/core/graph_test/`, and a graph in `test/catalog.zig`, then
   `zig build regress -- --bless` only after reading the new lines.
4. **`src/lang/schema.zig`**: a value of `Op` and an entry: its parameters in the builder's
   order and names, their kinds, defaults, and which are `positional`, `live`, or `shaped`.
5. **`src/lang/check.zig`**: only if it takes a vector (`call_shape`) or behaves differently in a
   lane region (`call_lanes`).
6. **`src/lang/graph.zig`**: its arm in `build_call`, and a message in `refuse` for each builder
   error a checked file can still reach.
7. **Goldens**: `zig-out/bin/weft describe --use std=src/lang/std.weft >
   test/golden/cli/describe.json`, then read the diff. Add the op's text to `test/lang.zig`, which
   compiles the catalog's graphs as text.
8. **Docs**: its section of the README, and `docs/agents.md` if agents will meet it.

Run every tier before calling it done:

```bash
zig build test && zig fmt --check src test tools cli build.zig
zig build regress && zig build regress -Doptimize=ReleaseFast
(cd play && zig build test && zig build regress)
```
