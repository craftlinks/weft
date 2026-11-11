# Weft Under the Hood

How Weft 0.1 is built, for a programmer who has not worked on animation engines, signal
processing, or compilers. It assumes you have read `docs/tutorial.md` or used Weft once, and that
you can read Zig or C.

This is the high-level pass. It explains each mechanism in a page or less and names the source
file that holds it. Section 14 lists the topics that deserve a closer look of their own.

---

## 1. The Shape of the Whole Thing

Weft is about 13,000 lines of Zig with no dependencies, in two halves:

| Half | Lines | Job |
|---|---|---|
| `src/core/` | 7,000 (+4,000 of tests) | The engine: programs, readers, and every kind of signal |
| `src/lang/` | 5,800 | The text language: a compiler from `.weft` text to an engine program |

Around them sit a command-line tool (`cli/`, 500 lines), a demo app (`play/`), and the tests.

There are three things in the engine, and understanding Weft is understanding these three and how
little each one does:

```txt
                     built once                         one per reader
  text ──compile──▶  ┌──────────────┐                  ┌───────────────┐
        or           │   Program    │ ◀── reads ────── │     State     │ ◀── eval(t)
  Builder calls ──▶  │ (immutable)  │                  │ (a slab of    │ ──▶ value(id)
                     │ array of     │                  │  f64 numbers) │ ──▶ events(t0, t1)
                     │ nodes        │                  └───────────────┘
                     └──────┬───────┘
                            │ points at
                   small tables: cues, goals, regions, tracks
```

- A **program** is a flat array of *nodes*. Each node is one operation: "a sine wave at 0.5 Hz",
  "add node 0 and node 3", "a spring toward these goals". It never changes after it is built.
- A **state** is one reader's scratch memory: a flat array of 64-bit floats called the *slab*,
  with a slot for every node's output.
- **`eval(t)`** walks the node array once, top to bottom, and fills the slab with every node's
  value at time `t`.

That is the entire runtime model. There is no scene graph, no object per animation, no scheduler,
no callback, and no clock inside Weft. The caller owns time.

Everything interesting in the implementation comes from one requirement placed on that loop:

> The value at time `t` must depend on `t` alone. Not on which times were asked before, not on
> the frame rate, not on the machine.

The rest of this document is the list of problems that requirement creates and how each one is
solved.

---

## 2. A Program Is an Array

Here is a real program. The text:

```txt
cue go = 1s
slide = tween(from: 0, to: 1, at: go, over: 800ms, ease: out)
breath = wave(sine, 0.5hz) * 0.05
x = slide + breath
bob = spring([go: 1], time: 0.5s, overshoot: 0.2)
lag = chase(x, time: 0.5s)
dots = lanes(4, noise(smooth, 1hz))
place = vec2(lag, bob)
```

And what the compiler makes of it, printed from the actual structures:

```txt
node  operation   slab offset   output          extra slots   class
  0   tween            0        1 value              0        pure
  1   wave             1        1 value              0        pure
  2   constant         2        1 value              0        pure        (the 0.05)
  3   multiply         3        1 value              0        pure        (breath)
  4   add              4        1 value              0        pure        (x)
  5   motion           5        1 value              4        exact       (bob, the spring)
  6   chase           10        1 value              3        simulated   (lag)
  7   noise           14        4 lanes              0        pure        (dots)
  8   pack            18        1 value of 2 parts   0        simulated   (place)
                                                              slab: 20 numbers in all
```

Four properties of this layout carry most of the design. `src/core/graph.zig` holds it.

**Nodes refer to each other by index, never by pointer.** Node 4 says "add nodes 0 and 3". Because
nothing holds a memory address, the node array can be copied as raw bytes and is still the same
program, and a copy of a slab is a complete saved snapshot of a reader. This one decision is what
makes checkpoints (section 5) a single `memcpy`.

**A node may only refer to nodes before it.** The builder enforces this. So the array is already
in dependency order, and evaluating is one forward loop with no sorting, no recursion, and no
cycle detection. The one exception, the *delay*, is covered in section 5.

**The slab has no gaps.** Each node's output sits at a fixed offset, followed by any private
slots the node needs. Node 5, the spring, keeps four extra numbers after its output; node 6, the
chase, keeps three. Those extras are caches and simulation state, and they live in the slab so
that copying the slab copies them too.

**Every size is the caller's.** The builder is handed an array for nodes and a maximum slab size.
It never allocates. If something does not fit, it returns a named error such as
`error.SlabCapacityExceeded`. The same holds for every table in the library.

A node is 112 bytes: a tagged union of the twenty-odd operations, an offset, and an extent (how
many lanes and components its output has). The loop reads them in order, so the cost is memory
prefetch, not cache misses.

---

## 3. The Pass

`eval(t)` is, at its heart, this (from `src/core/state.zig`):

```zig
pub fn pass(program: *const Program, slab: []f64, time: Time, sampling: Sampling) void {
    for (program.nodes) |*node| eval_node(program, slab, node, time, sampling);
}
```

`eval_node` is one `switch` over the operation. Some arms, abridged:

```zig
.constant => |constant| @memset(out, constant),
.add      => |op| add_into(out, …, slab values of op.left, slab values of op.right),
.wave     => |wave| @memset(out, wave.sample(time)),
.track    => |id| @memset(out, program.tracks.value(id, time)),
.crossing => |*op| for (out, inputs) |*gate, input| gate.* = if (input >= op.level) 1 else 0,
```

A `switch` rather than function pointers is deliberate: the compiler sees every arm, inlines the
small ones, and there is no indirect call per node. A pure node costs 2 to 27 nanoseconds.

For a program made only of formulas, this loop *is* Weft. The difficulty is that not every
signal is a formula of `t`. The nodes fall into four classes by how hard it is to honour the
requirement of section 1, and the next two sections take them in order of difficulty.

| Class | Examples | To get the value at `t` |
|---|---|---|
| **pure** | wave, noise, tween, bounce | Compute a formula of `t` |
| **exact** | spring, Newtonian move | Walk the goal changes before `t`, a formula for each stretch |
| **simulated** | chase, follow, shift, delay | Run fixed steps from a known state |
| **live** | input | Read what the caller last set; it has no past |

---

## 4. Pure and Exact Signals: Formulas Done Carefully

### Time is an integer

A `Time` is a signed 64-bit count of *flicks*, 1/705,600,000 of a second. That odd number is
divisible by every common video frame rate and audio sample rate, so "frame 90 at 60 Hz" and
"sample 72,000 at 48 kHz" are the same exact integer. Adding and comparing times never rounds.

Floating point enters only at the moment a formula needs it, and there the code is careful. The
naive way to find where a 440 Hz wave is in its cycle is `fraction(440 * seconds)`. After an hour
that product is about 1.6 million, and a 64-bit float has spent 21 of its 53 bits on the whole
part, so the fraction has lost precision. Weft instead splits the time into whole seconds and
the remainder, discards whole cycles from each piece separately, and adds the leftovers
(`Time.turns`, in `src/core/time.zig`). A wave is as precise in hour ten as in second one.

### Randomness without a random number generator

A conventional generator has hidden state: each number depends on how many were drawn before.
That breaks the requirement at once, since the value at `t` would depend on how many frames ran.

Weft's noise is a *hash function* instead (`src/core/noise.zig`). Divide time into cycles; cycle
number `n` of a noise with seed `s` has the value `hash(s, n)`, scaled into `[-1, 1)`. The hash is
a few lines of integer multiplies, shifts, and XORs, so it gives identical results on every
machine. Stepped noise holds each cycle's value. Smooth noise blends the four nearest cycles'
values with a cubic B-spline, which gives a curve with no corners and, provably, no value outside
`[-1, 1]`.

Every random choice anywhere in Weft is a hash of *(a seed, a purpose, a counter)*. There is no
generator to seed and nothing to replay.

### Motion toward goals: exact, with a cursor

A spring heading for a fixed goal has a textbook closed-form solution: a decaying sine wave. So
between two goal changes, the position at any moment is computed directly.

Goals change, though, at cues. To find the value at `t`, the code walks the goal changes before
`t`: use the formula to carry position and velocity from the first cue to the second, start a
fresh formula there, carry to the third, and so on, then evaluate the last stretch at `t`. This
is a *fold*, and it costs one formula per goal change (`src/core/motion.zig`).

A reader playing forward would repeat that walk every frame. So each spring node keeps a
**cursor** in its four extra slab slots: "at goal number *k* I was at position *p* with velocity
*v*". The next read starts from the cursor when it can.

This is the first appearance of the most important idea in the implementation:

> **A cache may change what a read costs. It may never change what a read returns.**

The cursor holds exactly the numbers the full walk would have produced at that goal, so starting
from it performs the same arithmetic the walk would. A reader cannot tell whether the cursor was
used. Ask for a time before the cursor and it is ignored.

A spring never mathematically arrives, so Weft declares it *settled* once the remaining distance
is below 2⁻⁵³ of the move's size, the point where it can no longer change a 64-bit float. From
then on the node returns the goal itself, exactly. That is why a client can compare against the
goal with `==` and go idle.

---

## 5. Simulated Signals: Keeping the Promise Without a Formula

A value chasing a moving target has no closed form: its position now depends on where the target
was at every moment before. A wanderer that picks a new goal when it arrives has none either.
These are genuinely step-by-step processes. Three mechanisms make them functions of `t` anyway.
They live in `src/core/simulation.zig` and `src/core/state.zig`.

### One fixed step, shared by everyone

Simulated nodes advance on a grid of **1/480 s**, measured from a start cue. Step 0 is the
program's initial state. Step *n*+1 is a function of step *n* and the number *n*, nothing else.
The step size is a constant of the library, not of the program or the reader.

This is the crucial separation: **the reader's frame rate never reaches the simulation.** A
30 Hz reader and a 240 Hz reader both cause the same steps to run. 480 was chosen because it is a
multiple of 24, 30, 60, 120, and 240, so those readers land exactly on steps.

### Interpolation between steps

A reader that asks about a time between step *k* and step *k*+1 gets a straight-line blend of the
two. Each simulated node keeps both values in the slab (its value "before" and "after"), and the
pass computes `before * (1 - w) + after * w`. So every time has one defined answer, whatever
grid the reader is on.

```txt
 steps:    k-1         k          k+1         k+2
            ●───────────●───────────●───────────●
                            ▲
                            t  →  value = blend of step k and step k+1
```

### Checkpoints make any time reachable

Reaching step 288,000 (ten minutes in) by running 288,000 steps costs milliseconds to seconds.
So a reader saves a copy of its whole slab once a second of simulated time, into memory the
caller provides. A read then restores the nearest checkpoint before the target and runs at most
479 steps.

This is where "no pointers in the slab" pays off: saving a checkpoint is one `memcpy`, and so is
restoring one. And because each step is a pure function of the one before, a state rebuilt from
a checkpoint is bit-identical to one reached by running from zero. Checkpoints are a cache in
exactly the sense of the box above.

```txt
 eval(t):  restore nearest checkpoint ≤ t  →  run ≤ 479 steps  →  one pass at t
           (or carry on from where the slab already is, when that is closer)
```

Playing forward, none of this is visible: the slab is already at the previous frame's step, and
a 60 Hz frame runs 8 steps.

### Feedback: the delay

"A node may only refer to nodes before it" forbids loops, yet feedback is useful: an echo, a
value that reacts to its own past. Weft allows exactly one way to close a loop. A **delay** node
outputs its input's value *from one step earlier*, and its input may be any node, including a
later one.

Within one pass there is still no cycle, because the delay does not read its input during the
pass; it is updated afterwards. So every loop must pass through a delay, and a loop without one
cannot be written down at all. This turns an entire class of bugs, the algebraic loop where A
needs B and B needs A at the same instant, into something the builder rejects by construction.

### What a step looks like

One step is: a pass over every node at the step's time, then an update of each simulated node
from the values that pass produced. A chase reads its target's new value and advances its spring
by 1/480 s. A follower checks whether it has arrived, counts down its pause, or draws a new goal
by hashing its seed with its goal count. Their state sits in the slab after their output, as
section 2 showed.

---

## 6. Events: A Second Question

`eval` answers "what are the values now?" **`events(t0, t1)`** answers "what happened between
these two times?", which is what a sound trigger or a flash needs. An event is 24 bytes: an exact
time in flicks, the node that fired it, its lane, and one number.

Events are **never stored**. They are recomputed from the program each time they are asked for,
which is the same requirement as section 1 applied to a range instead of a point. There are two
ways a node finds its events (`src/core/state.zig`, `src/core/event.zig`):

**Solved.** A bounce between two walls at constant speed hits a wall at a time given by
arithmetic: hit number *k* is at `ceil(k × leg)` flicks. Asking for the hits in a range is a
division, with no stepping. Cues, a spring reaching its goal, and a shift register entering a
bucket are found the same way. These are exact.

**Stepped.** A `crossing` watches an arbitrary signal for the moment it passes a level, which has
no general solution. So it compares its input at consecutive 1/480 s steps, and when the two
straddle the level, interpolates to place the crossing inside the step. The cost of this honesty
is the one documented imprecision in Weft: an input that crosses and returns within a single step
flips the gate and fires nothing.

Two details make events safe to build on:

- **Ranges are half-open**, `[t0, t1)`. Cut a timeline into consecutive ranges any way you like
  and each event appears in exactly one of them. A 60 Hz UI and a 375-blocks-a-second audio thread
  see the same events at the same flicks.
- **The caller's buffer bounds the memory.** When it fills, the collector keeps the *earliest*
  events and counts the rest exactly in `dropped`. Nothing is silently lost.

**By source.** `events` runs the step over its whole range whenever the program has a simulated
node, even when the caller only wants a bounce. `events_of(sources, t0, t1)` takes a sorted list
of node ids and gives only their events, in the same order and with the same overflow rule. It
steps only when a listed source is stepped (a crossing, a follower, a shift register); over solved
sources it touches nothing in the reader, so a window of a bounce's hits around the playhead of a
program with a chase costs microseconds instead of a millisecond, and the next `eval` is the one
it would have been. `Compiled.event_sources(name)` turns a binding into its list, following a
region's `spread` and a vector's `pack` to the nodes that actually fire.

---

## 7. What May Change Under a Running Program

A program is immutable, but two small tables it reads are not, because they are how the outside
world reaches in. Both use the same trick to keep caches honest.

**Cues** (`src/core/cue.zig`) are a sorted array of times. A tween stores "start at cue 3", not a
time, so moving cue 3 moves the tween with no rebuild. The array stays sorted, and a move that
would pass a neighbour is refused; this keeps lookups an array read and keeps everything stored
in cue order in time order.

**Tracks** (`src/core/track.zig`) are how a knob works. A track is a list of *(time, value)*
writes; reading it at `t` finds the last write at or before `t` by binary search. Because the
track is data indexed by time, a program that reads one is still a function of `t`: scrub
backwards and the knob's old positions are still there.

Both tables carry a **generation counter** that increases on each change. Every cache remembers
the generation it was computed under: a spring's cursor, a reader's checkpoints. A mismatch means
"stale, recompute". For tracks there is a refinement: the table also remembers *when* its recent
writes were, so a reader discards only the checkpoints at or after the earliest changed time. A
knob turned at the playhead invalidates nothing behind it, which is why a turn costs about a
microsecond.

The third way in, a **live input**, is different in kind. It has no time index at all: the slab
slot simply holds what the caller last set. It is the single place Weft gives up the
requirement, and the program says so (`report().seekable` is false, naming the node). To get the
requirement back, a reader can *record* what its passes read of an input; the recording replays
as an ordinary pure node (`src/core/recording.zig`).

---

## 8. Proving Things Without Running Anything

Because a program is plain data, it can be analysed. `src/core/range.zig` holds two analyses.

**Ranges.** For each node, Weft works out a `[low, high]` the value can never leave, in one
forward pass over the array: a sine is in `[-1, 1]`; the sum of two ranges is the sum of their
ends; a product is the hull of the four corner products; `min` and `max` take the smaller or
larger of each end, and `abs` folds a range across zero at 0; a monotone function such as `exp`
or `floor` is its value at the ends, and `sin` and `cos` add 1 or -1 where a peak lies inside.
This is *interval arithmetic*. For a
spring it uses a result from control theory that bounds how far a spring can swing past its
inputs, as a function of its overshoot. For a loop through a delay it iterates to a fixed point,
and reports infinity if the loop does not settle.

The rule is **conservative, never wrong**: a range may be wider than reality, but the value is
guaranteed inside it. Clients use it to map any signal onto a slider or a pixel range without
clamping. The cost of the rule shows in two places: `x * x` over `[-1, 1]` is reported as
`[-1, 1]` because the analysis does not know both factors are the same signal, and a tiny safety
margin is added wherever floating-point rounding could exceed the mathematical bound.

**Classes.** The same pass labels each node pure, exact, simulated, or live: the "highest" class
among the node and everything it reads. That is how `weft check` can say `seekable, stepped`
without evaluating anything.

---

## 9. The Same Bits Everywhere

Weft promises bit-identical results on native x86-64 and in WebAssembly. That is harder than it
sounds, and it shapes several parts of the code.

- **Its own `sin`, `cos`, `exp`, `log`** (`src/core/elementary.zig`). The standard ones are
  provided by whichever maths library the final program links, and those differ in the last bit.
  Weft computes them from additions, multiplications, and divisions only, which the IEEE 754
  standard defines exactly on every machine. The sine works in *turns* rather than radians, so
  a quarter turn is an exact number and the wave's zeros and peaks are exact.
- **A hash it owns**, rather than one from the standard library that a future Zig could change.
- **Integer time**, so no two platforms round a time differently.
- **OKLab conversion matrices inverted at compile time**, rather than copied from a paper with
  ten-digit rounding.

The enforcement is `zig build regress`: a catalogue of signals is sampled on native and on wasm
(run under Node), each value printed as a hexadecimal float, and both compared byte for byte with
a committed file of 3,888 lines. One differing bit in one sample fails the build and names the
line.

---

## 10. Many Elements and Many Components

A node's output is not one number but `lanes × components` numbers, laid out consecutively in the
slab. Two features share this one mechanism (`src/core/graph.zig`, sections 15 and 16).

**Components** are vectors and colours. Surprisingly little supports them: two operations,
`pack` (several numbers into one value) and `pick` (one number out), plus arithmetic that loops
over components. *No motion operation knows about vectors.* A 2D spring is two ordinary scalar
springs and a `pack`, built by the compiler. A colour is three components in OKLab, a colour
space designed so that equal numeric steps look like equal visual steps; it is converted to sRGB
only when the client draws.

**Lanes** are how one program moves a thousand things. Inside a `lanes(n, …)` region, the nodes
whose values genuinely differ per element get `n` slots: a noise (lane *i* hashes its seed with
*i*), a staggered tween (lane *i* reads time `t − i × stagger`), the lane index itself. Everything
else has as many lanes as its inputs, and a one-lane input is broadcast. So a constant or a knob
costs one number however many lanes read it.

A stagger gives every lane the same gap. **A cue for each lane** (step 28) lets the gaps differ:
a tween or a bounce with `cue_by_lane` starts lane *i* at cue `start + i` of the cue table, which
the language writes `at: letters[lane]` over a series written as a list of times. The cue table
is already read by `eval` and by `events`, so this costs one load and one add a lane, the events
of a bounce stay solved without stepping, and moving one cue with `Cues.move` moves one lane.

The loops over lanes are plain `for` loops over contiguous `f64`, which the compiler vectorises
on its own. 100,000 lanes of a typical region evaluate in about 2.5 ms.

---

## 11. The Language: A Small Compiler

`src/lang/` turns text into the same node array a programmer could build by hand with the
`Builder`. It runs once, at load, so text costs nothing per frame. It is a conventional four-stage
compiler, with a few unconventional constraints.

```txt
 bytes ─▶ tokens ─▶ flat tree ─▶ checked declarations ─▶ Program
        token.zig   parse.zig      check.zig               graph.zig (the back end)
```

**It allocates nothing.** Every array every stage writes is a field of one struct,
`Compiled(limits)`, whose sizes are compile-time parameters. A file too big for a limit is an
ordinary error that names the limit. A `Compiled` is therefore large and must stay where it is,
because the program points into its tables.

**Tokens are spans.** A token is a tag plus a start and length into the source; no text is
copied. Units are part of a literal, so `500ms` is one token of kind "time".

**The tree is flat**, like the node array: items in one array referring to each other by index.
The grammar is about fifteen lines (it is printed at the top of `parse.zig`). After a syntax
error the parser skips to the next line and continues, so one mistake does not hide the others.

**The checker is driven by a table.** Neither the parser nor the checker contains the word
"spring". Every primitive is a row in `schema.zig`: its parameters in order, each one's kind, its
default, whether a signal may set it. The checker is one loop over any row. The same table drives
the formatter's argument order and `weft describe`'s output, which is why those three can never
disagree, and why a client can add its own nouns.

**Modules are expanded, not called.** A module is a macro with type checking: at each use, the
checker binds the parameters and checks the body in place, filling the same arrays the expanded
text would. The back end and the engine never see a module.

**Seeds come from names.** An unseeded `noise` takes the hash of its declaration's name, so
inserting a line never changes another line's randomness. Position-based seeds would reshuffle
the whole file on every edit.

**Diagnostics are data**: a code, a source span, a message, and a hint, in fixed arrays. A
misspelt name is matched against the candidates by edit distance.

### Recompiling a running program

When Play's editor changes the text, a new program is compiled and the reader must move to it.
For pure signals nothing needs moving. For simulated ones, restarting would replay every step
from zero. So (`src/lang/lang.zig`, section 5):

1. Each declaration gets a **fingerprint**: a hash of its tokens (ignoring comments and spacing)
   and of the fingerprints of the declarations it names.
2. Nodes of declarations with the same name and fingerprint in both programs are **twins**.
3. If every simulated node has a twin, the new reader **adopts** the old one's slab regions and
   checkpoints, copied to their new offsets.

Edit a colour and the wanderers keep their steps, so nothing replays. Edit a wanderer and the
reader restarts from step 0, which is right: its history is a different one now. Either way the
values are the ones a fresh reader would compute; the carry saves the replay, not a jump.

---

## 12. The Realtime Discipline

Weft is meant to be callable from an audio thread, where a missed deadline is an audible click.
The rules, which the codebase calls TigerStyle after the TigerBeetle database's conventions:

- **No allocation**, anywhere in `src/core` or `src/lang`. All memory is the caller's.
- **No locks, no threads, no I/O, no clock.**
- **Every loop is bounded**, and the bound is stated. A binary search is written as
  `for (0..33)` with an `unreachable` after it, not as `while (low < high)`.
- **Assertions are dense.** Preconditions and invariants are asserted in the code that relies on
  them.

These are checked, not merely intended. `test/rules.zig` reads every source file at each test run
and fails if any file in the core or the language names an allocator, a thread, a lock, a file,
or a clock. `zig build bench` runs a reader on its own thread at audio pace and reports the worst
block.

---

## 13. How It Is Tested

| Layer | What it checks |
|---|---|
| Unit tests (212) | Each mechanism, beside the code it tests; the graph's are in `src/core/graph_test/`, one file a topic |
| The golden (`zig build regress`) | 3,888 sampled values and events, bit for bit, on native and wasm |
| Equivalence tests (`test/`) | Text compiles to the same nodes as hand-built graphs; a vector spring equals two scalar springs; lane *i* of a thousand equals lane *i* built alone; a carried reader equals a fresh one |
| Fuzzing | 20,000 random and mutated inputs through compile and format: a program or a diagnostic, never a crash |
| The rules test | Section 12's rules, and that every file opens with a design guide |
| Command goldens | The `weft` command's exact output |
| The bench | What reads cost; no thresholds, since numbers depend on the machine |

A pattern worth noticing: many tests assert that *two ways of computing something give the same
bits*. With a cursor and without. From a checkpoint and from zero. Forward and after a seek. In
one range and in two halves. That is the requirement of section 1, tested directly.

Every source file opens with a "Deep Architectural Guide for Reviewers", a numbered explanation
of that file's design. They are the primary documentation, and this document is a map of them.

---

## 14. Topics for a Deeper Look

Each of these is a self-contained mechanism with real subtlety that this document only named.
They are ordered roughly from the most central to the most specialised.

| # | Topic | The question it answers | Where |
|---|---|---|---|
| 1 | **The cache rule** | How do a cursor, a checkpoint, and a generation counter each guarantee they cannot change an answer? What exactly makes "resume from cache" perform the same arithmetic as "from scratch"? | `motion.zig` §3, `graph.zig` §8–9, `state.zig` `run_to` |
| 2 | **The fixed step and its interpolation** | Why 1/480 s? What does linear interpolation between steps cost in accuracy? Why is the slab left one step *ahead* of the time read? | `simulation.zig` §1–2, `state.zig` `simulate_to` |
| 3 | **Events without storage** | How does `events(t0, t1)` avoid running ahead of its reader, so that consecutive ranges run each step once? What is the "read-only look" at the last step? | `graph.zig` §11, `state.zig` `events_simulated` |
| 4 | **Closed forms for springs and Newtonian moves** | The damped-spring solution, how overshoot maps to a damping ratio, the four-phase Newtonian plan, and how "goal reached" is found by a gallop and a bisection on integer flicks | `motion.zig` §4–6 |
| 5 | **Bit-exact elementary functions** | Range reduction in turns, the split of ln 2, why Taylor series and not a minimax fit, and what "the compiler must not fuse a multiply-add" means | `elementary.zig` |
| 6 | **Precision far from zero** | The whole-seconds-plus-remainder split in `turns` and `cycles`, and why it bounds a noise's frequency to 2¹⁹ Hz | `time.zig` §3 |
| 7 | **Hash noise and the B-spline** | The SplitMix64 finalizer, why index-then-seed, de Boor's algorithm, and the proof that smooth noise cannot leave `[-1, 1]` under rounding | `noise.zig` |
| 8 | **Sound ranges** | Interval arithmetic under IEEE rounding, when computed ends are exact, the spring bound `(1 + os) / (1 − os)` from the impulse response, and the fixed-point iteration for delay loops | `range.zig`, `graph.zig` `node_range` |
| 9 | **Tracks, the latch, and the floor** | How a write in the past truncates, how the ring of recent write times lets a reader drop only what it must, and what a "preview" undoes | `track.zig` |
| 10 | **Lanes** | Per-node lane counts, broadcast rules, `lane_first` and why lane *i* built alone equals lane *i* in a family, and how a staggered spring shares one cursor across lanes | `graph.zig` §16, `state.zig` `.motion` arm |
| 11 | **The checker and module expansion** | Frames, how a parameter used twice stays one signal, cycle detection by call chain, seeds inside instances, and shape and lane checking | `check.zig` §6, 8, 9 |
| 12 | **Recompile and carry** | Fingerprints, twins, `State.adopt`, why a file that feeds a delay never carries, and `carry_tracks` | `lang.zig` §5, `state.zig` `adopt` |
| 13 | **Recording live input** | Why passes are recorded rather than `set_input` calls, and why that makes playback bit-identical | `recording.zig` |
| 14 | **The bounce** | One definition of a hit time, `ceil(k × leg)`, shared by the signal and its events so they cannot disagree; exact for 148 days | `graph.zig` `BounceNode` |
| 15 | **Easing** | Solving a cubic Bezier for its parameter with a bracketed Newton method, and bounding the iteration for a realtime path | `ease.zig` |
| 16 | **OKLab and the gamut map** | Why interpolate in OKLab, compile-time matrix inversion, and chroma bisection for colours a screen cannot show | `colour.zig` |
| 17 | **The formatter and comments** | Canonical format from a tree that holds no comments, by reading them back from token gaps | `format.zig` |
| 18 | **The zero-allocation compiler** | How a tokenizer, parser, checker, and back end fit in fixed arrays, what each `Limits` field bounds, and how fuzzing covers the limits | `lang.zig` §2, 6 |
| 19 | **Threads and sharing** | What "one state per reader" requires of a client: copying the cue table, where a track write may happen, warming an audio reader | README Costs, `cue.zig` §3 |
| 20 | **The design that was not built** | What 0.1 deliberately leaves out (division, conditionals, signal-valued tween ends, events that start motions) and what each would cost the requirement of section 1 | The showcase feedback; README "What v0.1 Promises" |

A good first three, if the aim is to understand why Weft is shaped as it is: **1** (the cache
rule), **2** (the fixed step), and **3** (events). Together they are the whole answer to "how can
a simulation be a function of time?".
