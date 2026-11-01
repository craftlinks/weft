# Weft

A Zig library for composable motion: motion as an object of its own, separate from whatever it
moves. It has no dependencies and knows nothing about pixels. So far it has a clock and four waves.

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

## Regress

`zig build regress` renders `test/catalog.zig` on native and on wasm and compares both with
`test/golden/signals.txt`, byte for byte. There is one sample per line, as a hex float, so any
changed bit fails and the report names the sample:

```txt
regress: native differs from golden at line 700
  golden: triangle 440hz hour 3 0x1.c28f5c28f5c28p-1
  native: triangle 440hz hour 3 0x1.c28f5c28f5c29p-1
```

Bless only for a change the step means to make, in that step's commit.
