# Weft 0.1: A Tutorial

A step-by-step walk through the ideas behind Weft and its public interface, for a person or an
agent who has never used it. Every listing here was compiled and run against Weft 0.1.0; the
outputs shown are real.

Read it top to bottom once. After that, sections 3 and 15 are the ones to keep open.

| If you want | Read |
|---|---|
| The idea in one page | 1, 2 |
| To write motion as text and look at it with no window | 3 to 11 |
| To read that motion from Zig | 12 to 14 |
| To draw it | 15 |
| The limits, costs, and mistakes people make | 16, 17 |
| Why it is built this way | `docs/internals.md`, then the README |

---

## 1. What Weft Is

A button sliding in, a knob wobbling, a ball bouncing between two walls: each is a number that
changes over time. **Weft computes those numbers and nothing else.** It has no idea what a pixel,
a window, or a sound is. Your code asks for a number and applies it to whatever it likes.

That makes Weft the middle of three parts. Only the middle one is Weft:

```txt
   a clock            Weft                    a destination
  (yours)   ─ t ─▶  program  ─ numbers ─▶  (yours: pixels, sound, a robot arm)
```

The library is plain Zig with no dependencies. It allocates nothing, takes no lock, and gives
the same bits on a desktop and in a browser.

## 2. The One Idea: Ask, Don't Accumulate

Most animation code keeps a value and nudges it every frame:

```zig
position += velocity * dt;   // the value now depends on every frame before it
```

The result then depends on history. A late frame changes it, you cannot jump to minute five
without replaying minutes zero to five, and two machines drift apart.

Weft asks a different question: **what is the value at time `t`?**

```zig
state.eval(t);               // any t, in any order
const position = state.value(dot);
```

Everything else in Weft follows from keeping that one promise, even for motion that has no
formula. Four things fall out of it for free:

- **Scrubbing and rewinding.** Going back is just another question.
- **Frame-rate independence.** A 60 Hz reader and a 240 Hz reader agree at every shared moment.
- **Several readers.** A UI thread and an audio thread read one program without coordinating.
- **Tests without a screen.** A motion can be checked as numbers, which is how this tutorial
  works until section 15.

A useful picture is a **spreadsheet whose only input is a clock**. Each cell is a formula over
the cells above it. You set the clock and read the cells.

### The words

| Word | Meaning |
|---|---|
| **signal** | A value defined at every time. Everything in Weft is one. |
| **node** | One operation in a program: a wave, an add, a spring. Each node is a signal. |
| **program** | An immutable list of nodes. Shared and read-only. |
| **state** (a reader) | One reader's memory: every node's value at the time it last asked about. |
| **cue** | A named moment on the timeline. Motion starts at cues, not at raw times. |
| **event** | Something that happened at an exact moment: a bounce hit a wall. |
| **flick** | Weft's unit of time: 1/705,600,000 of a second, a whole number. |
| **lane** | One of many elements evaluated by the same program: one dot of a thousand. |

---

## 3. Setup, and the Loop You Will Use

You need Zig 0.17.0. From the root of the Weft repository:

```bash
zig build                                 # builds zig-out/bin/weft, the command-line tool
```

Motion is written in a small text language, in a `.weft` file. Save this as `first.weft`:

```txt
# first.weft: a dot that slides in, then breathes.
cue go = 1s

slide = tween(from: 0, to: 1, at: go, over: 800ms, ease: out)
breath = wave(sine, 0.5hz) * 0.05
x = slide + breath
```

Three commands are the whole working loop. You do not need a window to see motion.

**`check`** says whether the file is valid, and how big its program is:

```txt
$ zig-out/bin/weft check first.weft
ok: 5 nodes, a slab of 5, 1 cues, 0 goals, 0 regions, 0 tracks, seekable, closed form
```

**`sample`** prints every signal's values on a time grid, as JSON:

```txt
$ zig-out/bin/weft sample first.weft --to 2 --step 0.5
{"from":0,"to":1411200000,"step":352800000,"signals":[
 {"name":"slide","range":[-0.0000000000000009,1.0000000000000009],"values":[0,0,0,0.8079780514132684,1]},
 {"name":"breath","range":[-0.05,0.05],"values":[0,0.05,0,-0.05,0]},
 {"name":"x","range":[-0.05000000000000089,1.050000000000001],"values":[0,0.05,0,0.7579780514132683,1]}],
 "events":[]}
```

Read it like this: five samples at 0, 0.5, 1, 1.5, and 2 seconds. `slide` holds 0 until the cue
at 1 s, is 81% of the way half a second later, and has landed on exactly 1 by 2 s. Command-line
times are **seconds**; times in the output are **flicks** (705,600,000 a second). `range` is a
bound the signal never leaves, worked out without sampling (section 13).

**`describe`** lists every call the language has, with its parameters, defaults, and kinds:

```bash
zig-out/bin/weft describe --use std=src/lang/std.weft
```

Ask `describe` rather than guessing a parameter's name. It is the reference; this tutorial is the
tour.

**Errors** come with a line, a column, a reason, and usually the fix:

```txt
bad.weft:2:39: error: tween has no parameter `ovr`
    slide = tween(from: 0, to: 1, at: go, ovr: 800ms)
                                          ^^^
    hint: did you mean `over`?
```

Exit codes: 0 for success, 1 when the file has errors, 2 for bad arguments.

### The shape of a file

- One declaration a line: `name = expression`. `#` starts a comment.
- **A name is declared above its use.** The file's order is the program's order.
- Times carry units, `2s` or `500ms`; frequencies carry `hz`. A bare number is not a time.
- Arithmetic is `+`, `-`, `*`, `/`, and parentheses. **A divisor is a number**, fixed when the
  program is built: `x / 4`, `lane / 16 - 3`. To scale by a signal, multiply by it.
- Up to two leading arguments go by position; the rest are named.
- A few words are reserved: `cue`, `track`, `seed`, `start`, `use`, `module`, `lane`.

---

## 4. Time

Time is a whole number of **flicks**. One second is 705,600,000 flicks, a number chosen because
it divides evenly by every common frame rate (24, 30, 60, 120, 144) and audio rate (44,100,
48,000, 96,000). So a frame time or a sample time is exact, and whole numbers do not drift: the
ten-thousandth frame is exactly ten thousand frames after the first.

In a file, a time is exact to five decimal places of a second or two of a millisecond. Anything
finer is refused, with the nearest flick named.

In Zig:

```zig
const weft = @import("weft");

const rate = weft.Rate.from_hz(60).?;          // null if a tick is not a whole number of flicks
const t = weft.Time.from_ticks(90, rate).?;    // frame 90: exactly 1.5 s
const t2: weft.Time = .{ .flicks = 3 * weft.time.flicks_per_second };   // 3 s
const seconds: f64 = t.seconds();              // for display only
```

Keep your clock as a `weft.Time`. Convert to seconds only to print.

---

## 5. Pure Signals: Functions of Time

The simplest signals are plain formulas. Ask for any time and the answer is computed directly.

```txt
hum = wave(sine, 0.5hz)                     # sine, triangle, saw, or square; in [-1, 1]
jitter = noise(smooth, 3hz)                 # smooth or steps; in [-1, 1]
level = map(jitter, -1..1, to: 0.2..1)      # move a signal from one range to another
mix = hum * 0.5 + level - 1                 # arithmetic on signals and numbers
```

**Noise is not random.** Weft has no random number generator. A noise is a formula of a seed and
the time, so it has the same value at the same moment on every machine, forwards or backwards.
`smooth` is a curve with no kinks; `steps` holds one value per cycle.

**Seeds.** Each noise gets a seed from its declaration's *name*, so adding a line never reshuffles
another. `seed 7` at the top of a file gives a new take of every noise at once. `seed: 1` on a
call pins one.

`map` does not clamp. A reversed output range, `to: 1..0`, flips the direction.

---

## 6. Cues and Tweens

A **cue** is a named moment. A **tween** moves from one value to another, starting at a cue.

```txt
cue intro = 0s
cue drop = 2s
cue beat = 4s..12s every 500ms              # a series: beat[0], beat[1], ... beat[16]

rise = tween(from: 0, to: 1, at: intro, over: 1s, ease: in_out)
fall = tween(to: 0.25, at: drop, over: 500ms, ease: out, after: rise)
```

- Before its cue, a tween holds `from`. After its end it returns `to` exactly, bit for bit.
- `ease` is `linear` (the default), `in`, `out`, or `in_out`.
- **`after:` chains tweens into a sequence.** `fall` follows `rise` until `drop`, then takes over.
  Sampled at 0, 1, 2, and 3 s, `fall` reads `0, 1, 1, 0.25`.
- **A tween after a tween may leave out `from`**: it starts from the `to` of the tween `after`
  names, so a chain says each value once. `after` must then be a name bound to a tween (directly,
  in `lanes(n, …)`, or passed through a module); otherwise `from` is required. Writing `from`
  anyway is allowed, and a different value is a jump at the cue.
- **`from` and `to` are numbers, not signals.** To scale a tween by a signal, multiply:
  `tween(from: 0, to: 1, …) * height`.

Why cues and not times? Because a client can **move a cue** while the program runs, and
everything attached to it moves with it, with no rebuild (section 12).

Cues are kept in time order, which gives the file three rules:

- **Declare cues in time order.** A cue earlier than the one above it is an error, and a series
  counts: `cue beat = 4s..12s every 500ms` must come after every cue before 4 s and before every
  cue after 12 s. Two cues may share a time.
- **A series' step divides its span exactly**, and every cue of a series counts toward
  `Limits.cues` (512 by default): ten minutes at `every 2s` is 301 cues.
- **A move cannot pass a neighbour.** It is refused whole, not clamped, so a drag handle clamps
  for itself.

A cue may also be written **after another cue**: `cue hit = drop + 500ms`, or a series from one,
`cue tick = drop + 1s..drop + 3s every 500ms`. Then the parts of a beat follow the beat when its
one literal is edited. There is no minus, since a cue comes at or after the cue it names. The sum
is worked out when the file compiles, so `Cues.move` on `drop` does not move `hit`: move both, or
edit the text and recompile.

The first cue is also where simulated signals start (section 8). If you plan to move cues, begin
the file with a cue at 0 that you never move.

---

## 7. Springs and Newtonian Moves

A tween is a fixed trip. A **spring** or a **Newtonian move** heads for a goal, and when the goal
changes, it carries on from wherever it is, at whatever speed it has. That is what makes motion
feel alive rather than scripted.

Goals are listed as a **path**: values at cues.

```txt
stops = [intro: 1, drop: -0.5, beat[0]: 0.25]             # a path

settle = spring(stops, time: 0.5s, overshoot: 0.2)        # springy
glide = newtonian(stops, speed: 2, accel: 8, decel: 4)    # speed up, cruise, brake
```

- `spring`: `time` is how fast it is (the period of its swing), and `overshoot` is how far past
  the goal a move from rest goes, as a fraction: 0 never overshoots, 0.2 goes 20% past.
- `newtonian`: a top `speed` in units a second, an `accel`, and a `decel`. It stops exactly on
  the goal.
- `from:` is the value before the first goal (0 by default).

These are **exact**: between two goal changes there is a formula, so any time is computed, not
stepped. A spring that has settled returns its goal exactly from then on.

---

## 8. Simulated Signals

Some motion has no formula: a value chasing a moving target, a wanderer that picks a place, goes
there, rests, and picks another. Weft still answers "what is the value at `t`?" for these, by
running them on **one fixed step of 1/480 s**, the same for every program and every reader,
whatever the frame rate. A read between two steps interpolates. So the promise of section 2
holds; what changes is the *cost* (section 16).

```txt
lag = chase(jitter, time: 0.5s, overshoot: 0.1)           # a spring whose goal is a signal

roam = follow(                                            # a wanderer
    [-1..-0.5, 0.5..1],                                   # regions it draws goals from
    by: spring(time: 0.25s),                              # how it moves: spring or newtonian
    pause: 100ms..500ms,                                  # how long it rests on arrival
)

steps = shift(-1..1, buckets: 8, period: 2s, odds: 0.25, shape: smooth)   # a slowly mutating loop

siren = oscillator(sine, rate: map(hum, -1..1, to: 0.5..4))   # a wave whose rate is a signal
```

A simulated signal starts at the file's **start cue**: the first cue, unless a line `start c`
names another. So a file with one needs at least one cue.

### Feedback goes through a delay

A name is declared above its use, so a loop cannot be written directly. The one way to close a
loop is a **delay**, which gives its input from one step (1/480 s) earlier:

```txt
echo = delay(0)                             # 0 is its value before the first step
ring = chase(1 + echo * -0.8, time: 0.5s)
echo <- ring                                # feed it, below
```

A delay holds one number: a 2D loop is two delays and two feeds. Inside `lanes(n, …)` a delay has
n lanes and is fed once.

**Keep a loop's gain below 1.** A loop that grows, such as `echo * 1.5`, passes `check` and runs
away. Since 0.1.1 it saturates near 2^256 and holds there, the same in every build mode, and comes
back down if a knob turns its gain back. Values computed from it can still overflow, so after
`state.eval(now)` on a program with a loop, check `state.finite()` and show a false rather than
drawing it (section 16).

### Parameters from signals

Most parameters are fixed numbers. The ones `describe` marks `"live": true` also take a signal,
read at each step: a chase's `time` and `overshoot`, and a follower's mover. This is how a knob
reaches into a motion (section 10). A signal given to a `time` is read in **seconds**.

| A signal can set | A signal cannot set |
|---|---|
| `chase`: `target`, `time`, `overshoot` | `tween`: `from`, `to`, `over`, `at` |
| `follow`: its mover's `time`, `overshoot`, `speed`, `accel`, `decel` | `spring`, `newtonian` toward goals: every parameter, and the goals |
| `oscillator`: `rate` | `wave`, `noise`: `hz` |
| any `signal` parameter: `map`'s input, `crossing`'s input, `vec2`'s parts | `bounce`: its walls and `speed`; `shift`: all; `crossing`: `level` |
| | any range, region, pause, lane count, or cue time |

So a knob cannot set a wave's frequency; an `oscillator` can stand in, at the cost of becoming
simulated. A knob cannot move a goal; `chase(knob, …)` can stand in.

---

## 9. Events

`sample` and `eval` give values at a moment. **Events** answer a second question: *what happened
between two moments?* A ball hit a wall. A level was crossed. A beat passed.

```txt
ball = bounce(0..1, speed: 0.7, at: drop)                 # hits fire at both walls
up = ball.velocity                                        # a call's second output
loud = crossing(lag, level: 0.5, direction: rising)       # a gate: 1 at or above the level
ticks = cues(beat)                                        # how many beats have passed
```

Each event has an **exact time** in flicks, the node that fired it, its lane, and a value:

| Source | Fires when | `value` |
|---|---|---|
| `bounce` | it hits a wall | the velocity just before: `+speed` at the top, `-speed` at the bottom |
| `crossing` | its input crosses the level | the slope at the crossing; its sign is the direction |
| `cues` | a cue passes | the cue's index among all the file's cues, counted from 0 |
| `spring`, `newtonian` | it has **settled** on a goal | the goal |
| `follow` | it arrives | the goal |
| `shift` | it enters a bucket | the bucket's value |

`sample` lists them under `"events"`. This is the ball's first hit on the top wall, 1/0.7 s after
the cue at 2 s (`source` is the node's index, `instance` its lane):

```txt
{"t":2419200001,"source":17,"instance":0,"name":"ball","value":0.7}
```

That time is one flick after the decimal answer, 2,419,200,000. It is not an off-by-one: 0.7 has
no exact binary form, so the true instant falls a hair after a whole flick and is rounded up to
the first flick at which the hit has happened. Speeds that are exact in binary (1, 1.5, 2.5) hit
on the flick that arithmetic predicts.

**A spring's event is late by design.** It fires when the spring has settled so far that it
returns its goal exactly, which for `time: 0.5s` is about 3.2 s after the goal with no overshoot
and about 6.5 s with `overshoot: 0.2`. If the next goal comes first, that goal never fires. For
"it got there, near enough", use a `newtonian` move, whose plan ends at a definite time, or a
`crossing` on the spring.

Three rules make events dependable:

1. **Ranges are half-open**, `[t0, t1)`. However you cut your timeline into ranges, each event
   lands in exactly one. Nothing is reported twice or lost at a seam.
2. **Events are not stored.** Asking about a past range works them out again and gives the same
   answer, bit for bit. Scrub back and the hits are where they were.
3. **An event's time is the first flick at which it has happened**, so evaluating at
   `event.time` already shows it: the ball is on the wall.

A `crossing` is the one approximate source: it looks at its input every 1/480 s, so an input that
crosses and comes back inside one step flips the gate with no event. Its events can be up to a
step away from the true crossing, they exist only from the start cue on, and a gate has no dead
band, so an input hovering at the level fires many times.

**An event cannot start a motion.** A tween starts at a cue, and a cue is a time in a table, not
something that happens. To chain one thing off another, either make the second a `chase` of a
`crossing` gate, or have the client read the event and write a track at `event.time`
(section 12).

**Events ahead of the playhead** are as available as events behind it: on a program with no
simulated node, `events(t - 2 s, t + 4 s)` is a cheap way to draw what is about to happen.

---

## 10. Knobs and Live Input

There are two ways for the outside world to reach into a program, and they mean different things.

### A track: a knob that applies *from now on*

```txt
track tension = 0.5 in 0.125..2             # its value before any write, then its bounds
lag = chase(jitter, time: tension, overshoot: 0.1)
```

A client writes a track at a time: "from `t` on, the value is `v`". The past keeps its values, so
scrubbing back shows the knob as it was turned, like an automation lane in a music program. The
program **stays seekable**. A track is read like any signal.

Three things to know before building a knob on one:

- **A write at `t` removes every write after `t`.** "From now on" means it: turn a knob at 4 s and
  what was played at 12 s is gone. That is what an overdub is. To undo one, save the track's
  samples first and put them back with `Tracks.restore`.
- **A track holds 1,024 writes** by default (`Limits.track_samples`), and a knob dragged at 60 Hz
  writes 60 a second, so it fills in 17 s. The next write is `error.TrackFull`. A write of the
  value the track already holds is free, so write on change, and thin a drag.
- **Draw the knob from the track**, `tracks.value(id, t)`, not from the widget. Then a refused
  write and a scrub both show the truth.

### An input: a value with no past

```txt
mic = input(0..1)                           # set by the client before each read
smooth_mic = chase(mic, time: 200ms)
```

An input is whatever the client last set. It has no history, so `check` reports the program as
`live` rather than `seekable`. A reader can **record** an input while it plays, and the recording
plays back later as an ordinary seekable signal (section 14). `input(0..1, initial: 0.5)` sets its
value before the first write.

A live program gives up more than seeking:

- **An input belongs to a reader**, not to the program. A second reader sees `initial` until it
  is set there too.
- **Anything that makes a reader redo its steps redoes them with today's input.** A cue move, or
  a track write at a time the reader has already passed, replays from the last checkpoint with
  the input's present value held throughout, so the motion jumps. Give a live reader checkpoints
  even though it never seeks, and do not move cues during a take.

The third way is not a mechanism at all: **edit the text and recompile**. That rewrites history,
which suits a document. Section 12 shows how a running reader survives it.

---

## 11. More Than One Number

### Vectors and colour

A value has a shape: a number, a `vec2`, a `vec3`, or a colour.

```txt
place = vec2(roam, settle) * 0.5            # pack two signals; arithmetic works per component
height = place.y                            # .x .y .z take one component out

tint = tween(from: srgb(0.95, 0.35, 0.2), to: srgb(0.2, 0.45, 0.95), at: intro, over: 4s)
bright = tint.l                             # a colour's components are .l .a .b
warm = oklab(0.75, noise(smooth, 0.2hz) * 0.14, 0.05)
dot = spring([intro: vec2(0.2, 0.8), drop: vec2(0.9, 0.3)], from: vec2(0, 0), time: 0.6s)
```

Colours are kept in **OKLab**, a colour space in which a straight line between two colours looks
even to the eye: it does not go grey or dark in the middle as a line through RGB does. `srgb(…)`
converts in; your code converts out with `weft.colour.to_srgb`, which also pulls a colour that a
spring overshot back into what a screen can show.

A vector and a colour never mix in arithmetic, and the checker says so (`wrong_shape`). Two holes
in 0.1: a tween from a colour to a plain number compiles, and so does a product of two colours.
Neither means anything, so check your shapes with `sample`, which prints `"components"`.

There is no fourth component: alpha is a signal of its own.

### Lanes: many elements, one program

To move a thousand dots you do not write a thousand signals. `lanes(n, body)` evaluates its body
`n` times, each with its own `lane` index, its own seeds, and its own delay:

```txt
bars = lanes(16, tween(from: 0, to: 1, at: intro, over: 0.6s, ease: out, stagger: 50ms))
own = lanes(16, map(noise(smooth, 0.25hz), -1..1, to: 0.2..1))
height = bars * own                         # 16 lanes: each bar rises to a height of its own
across = lanes(16, lane / 16)               # each lane's index, here scaled to 0..1
```

What makes lanes differ from one another:

- **`lane`** is each lane's index, 0 to n − 1.
- **Seeded calls** (`noise`, `follow`, `shift`) get a different seed per lane.
- **`stagger:`** on `wave`, `tween`, `spring`, `newtonian`, and `bounce` starts lane *i* that much
  later than lane *i* − 1.
- Everything else has as many lanes as what it reads. A constant, a knob, or a name declared
  outside the region is one shared value.

Two lane counts meet only when equal, or when one side has one lane. An event carries its lane as
`instance`, so a thousand bounces read as one stream.

**Lanes are independent.** A lane cannot read its neighbour, and there is no sum or average over
lanes. So a chain where each link follows the one before is one declaration a link, and a flock
cannot be written. What a lane can differ by is what the list above gives it: `lane` in
arithmetic, a seed, and a uniform `stagger:`. A number parameter stays one number for every lane,
so `bounce(…, speed: 1 + lane * 0.5)` is refused, and so is a cue chosen by lane, `beat[lane]`.

### Modules: your own vocabulary

A module is a named expression with parameters. It expands in place, like a macro with type
checks:

```txt
use std                                     # snappy, heavy, breathe, bob

module wobble(t: 0.3s) = spring(time: t)
module pulse(base, amount: 0.1) = base + amount * wave(sine, 1hz)

out = snappy(stops)                         # spring(stops, time: 0.25s)
soft = pulse(out, amount: 0.02)
```

A file that says `use std` is checked with `--use std=src/lang/std.weft`. From Zig the library is
the string `weft.lang.std_library`.

A parameter's kind is whatever the body uses it as, so a module can take a signal, a number, a
time, a cue, a path, a colour written as `srgb(…)`, a lane count, or a whole expression to
evaluate in lanes. That last one lets a file say "one lane a letter" once:

```txt
module chars(body) = lanes(4, body)
module arrive(at, gap: 60ms) = tween(from: 0, to: 1, at: at, over: 0.5s, ease: out, stagger: gap)

lift = chars(arrive(intro))                 # `stagger:` is legal here: it expands inside the region
```

What a module cannot do: see the file's names (pass them in), or stand where a number literal is
needed. `module ember() = srgb(0.96, 0.45, 0.25)` is a signal, so it cannot be a tween's `from`.

---

## 12. From Zig: Text In, Numbers Out

This is the whole of the reading interface. The listing compiles a file, reads values, events, a
track, and a cue.

```zig
const std = @import("std");
const weft = @import("weft");

const source = @embedFile("motion.weft");

/// The sizes of every table the compile fills. `weft check` prints the counts they must hold.
const Motion = weft.lang.Compiled(.{ .nodes = 32, .slab = 64, .cues = 4, .tracks = 1 });

// A Compiled holds every table and the program points into it, so it is large and must not
// move. Keep it in static memory or in a struct that stays put, never in a returned value.
var motion: Motion = undefined;
var slab: [64]f64 = undefined;                 // one reader's memory

pub fn example(writer: *std.Io.Writer) !void {
    // 1. Compile, once. Nothing here runs again per frame.
    motion.compile(source) catch {
        for (motion.errors()) |found| try found.render(source, "motion.weft", writer);
        return error.Invalid;
    };
    const program = motion.program;

    // 2. Resolve names to node ids, once.
    const x = motion.signal("x").?;
    const tint = motion.signal("tint").?;
    const dots = motion.signal("dots").?;

    // 3. Make a reader. The program is shared; each reader owns a slab.
    var state = weft.State.init(program, slab[0..program.slab_count]);

    // 4. Ask. Any time, in any order.
    const second = weft.time.flicks_per_second;
    state.eval(.{ .flicks = 30 * second });
    state.eval(.{ .flicks = 1 * second + second / 2 });
    const now: f64 = state.value(x);           // a node of one value

    // A vector, a colour, or lanes: a slice, lane after lane, components in order.
    const lab = state.values(tint);            // 3 f64: OKLab
    const rgb = weft.colour.to_srgb(lab[0..3].*);
    const all = state.values(dots);            // 8 f64 for lanes(8, …)
    const extent = state.extent(dots);         // .lanes = 8, .components = 1
    _ = .{ now, rgb, all, extent };
}
```

Values are always `f64`. Convert to `f32` at your own edge.

**Events** take the caller's buffer, which bounds the memory:

```zig
var found: [64]weft.Event = undefined;
const result = state.events(t0, t1, &found);   // everything in [t0, t1)
for (found[0..result.count]) |event| {
    // event.time, event.source (a node id), event.instance (the lane), event.value
    if (event.source.index == ball.index) flash();
}
// result.dropped counts, exactly, the events that did not fit.
```

After `events`, the slab is at no particular time, so call `eval` before the next `value`.

**Each frame, call `events_since`.** It reads the events since the last `eval`, `(last, now]`,
then evaluates at `now`:

```zig
const result = state.events_since(now, &found);   // events in (last eval, now], then eval(now)
```

By hand it is `events(last + 1, now + 1)` then `eval(now)`: one flick added to both ends. On a
program with no simulated node any order costs the same. On a simulated one, an `eval` at a time
that falls exactly on a step, as every 60 Hz frame does, leaves the reader one step ahead of where
`[last, now)` wants to begin. Since 0.1.1 a reader whose slab has `program.reader_slab_count()`
values keeps a copy of that step and replays it; one with only `slab_count` restores a
checkpoint. Measured on a four-node file over 600 frames at 60 Hz: 4,801 steps with
`events_since`, which is what the frames need; 5,400 with `[last, now)` and the copy; 147,000
without it.

**A full buffer keeps the earliest events and counts the rest.** For "flash what just happened"
that is the wrong end: with a window of the last 200 ms and a buffer too small, the hits you keep
are the ones that have nearly faded. Size the buffer for the window, or keep the window short.

`events` returns every node's events. To pick one source, compare `event.source.index` with the id
you resolved. And every call runs every simulated node across its whole range, so on a simulated
program a wide window, behind the playhead or ahead of it, costs steps each frame. If you want
both a timeline of events and simulated motion, put them in two programs.

**A track** is written between reads. The table lives in the `Compiled`:

```zig
const tension = motion.track("tension").?;
try motion.tables.tracks.write(tension, now_time, 1.25);   // from now_time on
```

**A cue** is moved the same way, and every tween and goal attached moves with it:

```zig
const go = motion.cue("go").?;
try motion.tables.cues.move(go, .{ .flicks = 3 * second });
```

Neither write may overlap an `eval` on another thread: write between reads.

### A reader for a simulated program

A program with a simulated node (`program.simulated`, or `stepped` in `check`'s output) has to run
steps to reach a time. So a reader keeps **checkpoints**, one a second, in memory you provide:

```zig
var checkpoints: [601 * 64]f64 = undefined;    // (1 + seconds of timeline) * slab_count
var state = weft.State.init_with_checkpoints(program, slab[0..program.slab_count], &checkpoints);
```

Checkpoints change what a read costs, never what it returns. Without them, each backward read
replays from the start.

- **A shorter array covers only the first seconds.** With room for 100 checkpoints, a read at
  599 s still runs the steps from 100 s. Nothing reports partial cover.
- **A cue move drops every checkpoint**, whichever cue it is. So does a burst of more than 64
  track writes between two reads. One write drops only the checkpoints after its time.
- **An event the client turns into a track write** is how one thing starts another at an exact
  flick: read the event, then `tracks.write(id, event.time, 1)`. It costs writes from the track's
  budget, and `check` and `sample` cannot see the link.

### Recompiling a running program

To change a running program, compile the new text into a second `Compiled` and move the reader
across:

```zig
try motion_new.compile(edited_source);
motion_new.carry_tracks(&motion);                           // a knob's history survives
var new_state = weft.State.init_with_checkpoints(motion_new.program, &slab_new, &checkpoints_new);
const carried = motion_new.carry(&new_state, &motion, &old_state);
```

**`carry` saves time; it never changes a value.** A fresh reader of the new program gives the same
bits as a carried one, because every value is a function of `t`. What a fresh reader of a
simulated program costs is the replay of every step from the start: 174 ms at 600 s for a small
score, against 0.6 ms carried.

- It returns `true` when every simulated signal is unchanged, and the new reader then has the old
  one's steps and checkpoints.
- It returns `false` when any simulated signal changed, and the whole reader starts fresh, not
  only the changed signal. A changed `seed`, `start`, `use`, or `module` line, a changed library,
  or a file that feeds a delay also start fresh.
- It returns `false` for a program with no simulated signal. There is nothing to carry.

An edit that changes a simulated signal does make it jump, since it has a new history. To change
a motion's character *without* a jump, use a track.

After a compile that fails, `compiled.program` is not valid. Compile into a second `Compiled` and
swap on success, so the last good program keeps running.

---

## 13. Questions Besides "What Is the Value?"

A program can be asked about itself, with no sampling:

```zig
var ranges: [32]weft.Range = undefined;
program.ranges(ranges[0..program.nodes.len]);  // .low and .high: a bound each node never leaves
var classes: [32]weft.Class = undefined;
program.classes(classes[0..program.nodes.len]); // .pure, .exact, .simulated, or .live
const report = program.report();               // .seekable, .stepped, and which node is why
```

**Ranges** let a destination map a signal safely: a signal with range `[-1, 1]` can drive a
slider without a clamp. A range is never wrong, but it may be wider than the truth: `x * x` over
`[-1, 1]` is reported as `[-1, 1]`, and a signal whose spring stiffness comes from a knob is
reported as unbounded.

**Classes** say what a read costs:

| Class | Made by | A read costs |
|---|---|---|
| `pure` | wave, noise, tween, bounce, map, arithmetic, track, cues | one formula |
| `exact` | spring, newtonian | one formula per goal change passed |
| `simulated` | chase, follow, shift, oscillator, delay, crossing | steps from the nearest checkpoint |
| `live` | input | nothing, but it has no past |

---

## 14. The Builder: A Program Without Text

The language is a front end. Underneath, a program is assembled by `weft.Builder`, and you can use
it directly: for a program made by code, or for the two things the language does not reach,
recording and playback.

```zig
var times: [2]weft.Time = undefined;
var cues = weft.Cues.init(&times);
const c0 = try cues.add(.{ .flicks = 0 });

var nodes: [4]weft.Node = undefined;           // capacities come from the caller
var builder = weft.Builder.init(&nodes, .{ .slab_count_max = 16, .cues = &cues, .start = c0 });
const mic = try builder.input(.{ .low = 0, .high = 1 });
const fifth: weft.Time = .{ .flicks = weft.time.flicks_per_second / 5 };
const smooth = try builder.chase(.{ .target = mic, .from = 0, .time = fifth, .overshoot = 0 });
const program = builder.finish();              // immutable from here

var slab: [16]f64 = undefined;
var state = weft.State.init(program, slab[0..program.slab_count]);

var entries: [256]weft.Sample = undefined;
var recording = weft.Recording.init(&entries);
state.record(mic, &recording);                 // write down what each read sees of the input

state.set_input(mic, level);                   // before each eval
state.eval(t);
```

Later, the recording becomes a clip that a second program plays back as a pure signal:

```zig
var samples = weft.Samples.init(&sample_entries);
const clip = try samples.add(recording.table());
var replay = weft.Builder.init(&nodes_b, .{ .slab_count_max = 16, .cues = &cues, .start = c0,
    .samples = samples.table() });
const tape = try replay.recorded(clip);        // seekable: read at the same times, the same bits
```

What a recording is, precisely:

- It holds one sample each time the value **changed**, so a hand held still for a minute is one
  sample. Sixty seconds of two inputs moving at 60 Hz is about 112 KiB.
- It records what the reader's *steps* read, not your `set_input` calls. That is why playback is
  bit-identical at the times that were read. Between them it holds the earlier value.
- It only goes forwards. A backward read while recording, or a full table, marks it incomplete
  (`recording.complete()` is false) and keeps what it had.
- A reader records at most 8 inputs. A ninth is an assert, not an error.
- **The language has no `recorded` call.** A program written as text cannot name a clip, so
  replaying a text program's input means building the program again with the `Builder`.

The builder's calls match the language's, one for one: `constant`, `add`, `multiply`,
`map_range`, `wave`, `noise`, `tween`, `spring`, `newtonian`, `chase`, `follow`, `shift`,
`delay` and `close`, `bounce`, `crossing`, `cues`, `input`, `recorded`, `oscillator`, `track`,
`pack`, `pick`, and `lane`. A lane region is a field: set `builder.lanes = 1000`, build the
per-lane nodes, then set it back to `null`.

The builder refuses, **by a named error**, anything it cannot evaluate: `error.UnknownCue`,
`error.InvalidOvershoot`, `error.SlabCapacityExceeded`, and so on. Nothing invalid reaches a
reader. Cues, goals, regions, and tracks are small tables you create first and pass in
`Builder.Options`; the README shows each.

---

## 15. Drawing It: A Complete Client

`examples/starter` is the smallest complete client: a Patchwork app of about 200 lines. Patchwork
is a separate UI library; Weft does not know it exists, and the app is the bridge.

```bash
cd examples/starter
zig build test                              # compiles the file, replays the scenarios; no GPU
zig build run                               # a window: space plays, left and right step
zig build && ./zig-out/bin/starter --render play --out frames   # PNG frames, no window
```

The bridge is three steps, and they are the same in any client:

**1. Compile once, at init, and resolve names to ids.**

```zig
pub fn init(app: *App, textures: *quads.Textures) void {
    app.motion.compile(source) catch { … print app.motion.errors() and stop … };
    app.reader = .init(app.motion.program, &app.slab);
    app.height = app.motion.signal("height").?;
    app.t = .{ .flicks = 0 };
}
```

**2. Own a clock.** The app's only state about the motion is a time.

```zig
.frame => |dt_ms| {
    if (!app.playing) return;
    app.t.flicks += @as(i64, @intFromFloat(@round(dt_ms))) * flicks_per_ms;
    cx.redraw();
    cx.keep_animating();
},
```

**3. Each frame, ask and draw.** Events first, then values.

```zig
pub fn draw(app: *App, cx: *Context) void {
    var found: [8]weft.Event = undefined;
    const window = app.reader.events(since, .{ .flicks = app.t.flicks + 1 }, &found);
    // … turn each hit's exact time into a flash that fades …

    app.reader.eval(app.t);
    const heights = app.reader.values(app.height);          // 24 lanes
    const tints = app.reader.values(app.tint);              // 24 lanes of OKLab
    for (heights, 0..) |height, lane| {
        const rgb = weft.colour.to_srgb(tints[3 * lane ..][0..3].*);
        // … draw one bar of that height in that colour …
    }
}
```

Stepping backwards with the Left key needs no code beyond changing `app.t`. That is section 2's
promise, visible.

Wiring the two libraries together is `build.zig.zon` naming both by path and one `imports` line
in `build.zig`; copy the starter's.

---

## 16. Costs and Limits of 0.1

What a read costs, measured on an i5-13600K **with `-Doptimize=ReleaseFast`**. A Debug build is
several times slower (the showcases saw 2× to 12×), so measure an optimized build before deciding
something is too slow.

| What | Cost |
|---|---|
| A pure node, a frame | 2 to 27 ns |
| A simulated node, a frame at 60 Hz (8 steps) | 40 to 235 ns |
| 1,000 lanes of a pure region, one eval | about 44 µs |
| 100,000 lanes of the same, one eval | about 2.5 ms |
| A 21-node simulated file, first read at 600 s, cold | 34 ms |
| The same, a seek once checkpoints are filled | 151 µs |
| Compiling that file | 15 µs |

Lanes cost lanes × nodes: about 5 ns for each lane of each node, so the 2.5 ms above is one node
over 100,000 lanes, and a 44-node file over 112,896 lanes took 22 ms. `eval` computes every node,
read or not. A simulated lane costs about 35 times a wave lane.

A cold read costs steps × nodes. Ten minutes is 288,000 steps, and a step costs roughly 0.1 to
0.4 µs for a few dozen simulated nodes, so scale from that rather than from the node count alone:
showcases measured 113 ms for 41 nodes, 560 ms for 115 nodes, and 22 s for a chain of 2,000
chases, each cold to 600 s.

The limits worth knowing before you design around Weft:

- **A cold read far into a simulated program is slow**, because it runs every step from the start.
  It happens once; then checkpoints cover it. Warm a reader while loading, or start it at the
  playhead.
- **Checkpoints cost memory**: (1 + seconds) × slab × 8 bytes for each reader. A 115-node pond is
  3 MB for ten minutes; a 2,000-link chain is 92 MB.
- **One simulated node makes every `events` call step**, including for the pure nodes beside it.
  A six-second events window cost 2 µs on a pure program and 1.6 ms once a chase was added. Keep
  event timelines and simulated motion in separate programs, and on a simulated program read
  events with `events_since` (section 12).
- **A feedback loop that grows is not caught.** `check` passes it, and its range is reported as
  unbounded (as every loop's is, stable or not). Since 0.1.1 its state saturates near 2^256 in
  every build mode, and `state.finite()` says when a value computed from it has overflowed.
- **A `Compiled` is about 1 MB at the default `Limits`**, however small the file, because the
  token and tree tables default to 4,096 entries. Since 0.1.1 `check` prints the least `Limits`
  the file compiles with, every field, ready to paste, so size a `Compiled` from that line. A
  library is parsed under the same limits as the file, and the line accounts for it.
- **Lane counts are fixed at compile.** Data that changes size means a recompile.
- **Lanes cannot read each other**, and a number parameter or a cue cannot vary by lane
  (section 11). A region is a line, with no rows and columns, and the client cannot hand it a
  table of per-lane values.
- **The `weft` command's own slab limit is 262,144 values** and cannot be raised, so a file with
  a large region is checked at a smaller lane count. A `stagger:` cannot be finer than 10 µs.
- **A `bounce` asserts beyond 148 days** (2⁵³ flicks) from its cue.
- **`colour.to_srgb` costs 0.1 to 0.4 µs a call**, which is 30 ms for 100,000 colours. At that
  scale send OKLab to the GPU and convert in the shader.
- **Most parameters are constants.** Only those marked `live` take a signal. A tween's ends, a
  spring's goals, and a bounce's walls are fixed when the program is built.
- **Division by a number only, no comparison, no `if`.** `x / 4` is `x * 0.25`, so a divisor is
  a number other than 0 that is fixed when the program is built, never a signal, whose range
  could hold 0. The product is the quotient exactly when the divisor is a power of two, and
  otherwise within one unit in the last place, the same on every target. A `crossing` is the one
  way to make a gate; a `map` is the one way to rescale. Since 0.2, `abs(x)`, `min(a, b)`, and
  `max(a, b)` exist, per component and per lane like `+`, with exact ranges, and `use std` gives
  `clamp(x, low, high)`; there is still no `floor`, `sin` of a value, `sqrt`, or `exp`.
- **No strings in a signal.** A value is one to four numbers. Since step 27 a string literal,
  `"text"`, exists for one use: a parameter of a client's noun (README, A Client's Nouns).
- **A track holds a bounded number of writes** (`Limits.track_samples`, 1,024 by default).
- **`crossing` events** can miss a there-and-back inside 1/480 s.
- **Ranges are conservative.** A declared module range such as `in -1..1` can be refused because
  the proven bound is a hair wider (`-1.0000000000000018..1.0000000000000018`).
- **Everything is sized up front.** A full table is an error that names its `Limits` field, never
  a crash. Render `compiled.errors()` to see which.

What 0.1 promises to keep stable: the exports of `src/weft.zig`, the language `describe` lists,
the command's JSON fields, and the rules (a function of `t`, no allocation, the same bits on every
target).

---

## 17. Mistakes People Make

| Symptom | Cause | Fix |
|---|---|---|
| `tween's 'from' is fixed when it is built` | A signal given to a number parameter | Multiply the tween by the signal instead |
| `a divisor is a number, fixed when the program is built` | Division by a signal, a track, or `lane` | Multiply by the signal, or by its reciprocal if you have one |
| `cues are in time order, and this one is before the cue above it` | Cues declared out of time order | Reorder the cue lines; a series counts |
| `'x' is used before it is declared` | A name below its use, **or the line that declares it has an error of its own** | Fix the first error first; for a loop, use a `delay` |
| `` `start` is a keyword `` | A reserved word as a name | Rename it |
| `'hz' takes a frequency` | A bare number | Write `2hz`, `500ms`, `1.5s` |
| `not a whole number of flicks` | A time finer than the grid | Round to 5 places of a second |
| `4 lanes and 5 lanes do not go together` | Two regions of different sizes | Make the counts equal |
| ``there is no call `clamp` `` | `clamp` is a module of `std`, not a primitive | Add `use std`, and pass `--use std=src/lang/std.weft` to `weft` |
| `` `min` is a primitive, not a module's name ``, or ``the module `clamp` is declared twice`` | A module of your own from before 0.2 named `abs`, `min`, or `max`, or `clamp` beside `use std` | Rename it, or delete it and use the call |
| `error.Invalid` with no message | `compile(...) catch unreachable` | Render `compiled.errors()`; it names the `Limits` field to raise |
| An assert in `value` | Reading after `events` with no `eval` between | Call `eval` first |
| An assert in `value` | A node with lanes or components | Use `values` |
| A crash on a moved `Compiled` | It was returned by value or copied | Compile in place, in memory that stays put |
| A freeze on pressing End | A cold seek on a simulated program | Give the reader checkpoints, and warm it |
| Every lane's `crossing` fires at the first flick | The inputs start at or above the level | Move the level, or start below it |
| A `seekable` program reads as `live` | It has an `input` | Use a `track`, or record and play back |
| Frames get slower the longer a simulated program plays | `events(last, now)` each frame rewinds the reader | Call `events_since(now)`, and give the reader `reader_slab_count()` of slab |
| A knob stops responding after a while | `error.TrackFull`: 1,024 writes | Write on change, thin a drag, raise `Limits.track_samples` |
| A knob turned while scrubbed back erases later turns | A write removes every later write | Save the samples and `restore` them to undo |
| A puppet on a live `input` jumps when a cue is dragged | The reader replays its steps with today's input | Give it checkpoints; do not move cues during a take |
| Values stuck near 1.16e77, or `state.finite()` false | A feedback loop with gain above 1 | Keep loop gain below 1; bound a knob that sets it |
| A spring's arrival event never fires | The next goal came before it settled | Use `newtonian`, or a `crossing` on the spring |

---

## 18. Where to Go Next

- `weft describe` for every parameter of every call.
- `play/*.weft` for five real files, and `play/` for a client with seven pages.
- `docs/agents.md` for how Play's pages are assembled and how to add a primitive.
- `docs/internals.md` for how Weft works underneath.
- The README for each part in depth, and the guide at the top of every source file for why it is
  the way it is.
