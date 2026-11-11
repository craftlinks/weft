//! The signal graph: a flat, sorted array of nodes, and one slab of values per reader.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. One Program, One State per Reader
//! A `Program` is the immutable node array. A `State` is one reader's slab of values, so the UI and
//! the audio thread each hold a state over the same program, or over a copy of it where they do not
//! share memory. A second reader costs one more slab, and reading never writes to the program.
//!
//! This file holds the program side: the op structs, `Op`, `Node`, `Program`, and `Builder`.
//! `state.zig` holds the reading side: `State`, the pass, the fixed step, and events. The tests are
//! in `graph_test/`, one file a topic. A section cited in either is a section of this guide.
//!
//! ## 2. The Slab
//! Every node's output lives in the slab at an offset, as `lanes * components` f64, lane after
//! lane. Each op loops over that extent, so many values cost no new layout: a thousand 2D values
//! are 2,000 f64 at one offset (sections 15 and 16). f64 is the one value type, because a
//! value and the time it came from must not differ in precision, and because a client converting
//! to f32 at its boundary pays less than Weft would pay for two kinds of slab.
//!
//! A motion node also keeps a cursor in the slab, right after its output: `cursor_count` f64 that
//! cache where it was at the last goal it reached. Section 8 explains why a cache cannot change a
//! value. A simulated node keeps its state there too, as section 9 explains. It is reader memory
//! like any other, so a copy of the slab still is a checkpoint.
//!
//! ## 3. No Pointers
//! Nodes refer to each other by `Id`, and neither a node nor the slab holds an address. So both can
//! move as bytes: a copy of the node array is the same program, and a copy of the slab is a
//! checkpoint. `Program` and `State` are only views of that memory, rebuilt wherever it lands.
//!
//! ## 4. Sorted Means No Cycles
//! A node can only refer to nodes built before it, which `Builder` enforces. So the array is
//! already in topological order, and eval is one pass over it. The one exception is a delay's
//! input, which section 10 explains: a cycle can only pass through a delay.
//!
//! ## 5. Ids and Names
//! An `Id` is a node's index, stable for the life of the program. The program stores no names: a
//! name belongs to whoever chose it, such as a text front end, which maps names to ids.
//!
//! ## 6. Tweens and Cues
//! A tween is one more pure node, so keyframes are not a second system. It refers to a cue and not
//! to a time, so moving the cue moves the tween, and it measures its progress as a difference of
//! integers, so it keeps every bit however far it is from zero. At and after its end it returns
//! `to` itself, not a computed value, so it lands exactly.
//!
//! The cue table is the one thing a program reads that can change, which `cue.zig` explains. A move
//! can change which tweens overlap at any time, long after building, so an overlap cannot be
//! refused. It has one defined answer instead: a tween's `previous` is what it follows until its
//! own start, and from then on the tween wins. A chain of tweens is a sequence, with no sequence
//! type, and a gap between two tweens holds the earlier one's `to`.
//!
//! ## 7. Seeds
//! A graph has one seed, from `Builder.Options`, and a noise node has a `seed` of its own, which is
//! a stable id the caller chooses and not the node's position. The builder stores the two hashed
//! together, so the graph's seed gives a new take of every noise at once, and inserting a node
//! does not reshuffle the others. Two noises with the same `seed` in one graph are one signal. A
//! follower and a shift register derive their seeds the same way.
//!
//! ## 8. Springs and Newtonian Moves
//! A motion node heads for goals at cues, from a `Goals` table that the program holds like the
//! cue table, and that is immutable once built. Reaching a time means folding over the goal
//! changes before it, which `motion.zig` explains, so each motion node keeps a cursor in the slab.
//! The cursor is a cache and not history: a sample from it performs the very operations a sample
//! from the first goal would, so `eval` still depends only on the time, bit for bit. The cursor
//! records the cue table's generation, and a cue move makes it stale.
//!
//! ## 9. Simulated Nodes
//! A chase, a follower, a shift register, and a delay have no closed form, so they run on the
//! fixed step of `simulation.zig`, from the cue `Program.start`. Each keeps its state in the slab
//! after its output: its values at the step before and the step after the time read, then its own
//! state. A crossing runs on the step too, for its events only, as section 11 explains: its output
//! is exact at any time, so it keeps no values to interpolate, only its input at the last step.
//!
//! One step is a pass over every node at the step's time, with each simulated node giving its
//! value there, then an update of each simulated node from that pass. A read at t between steps k
//! and k + 1 brings the slab to step k + 1, then a pass at t gives each simulated node
//! `before * (1 - w) + after * w`, where w is how far t is past step k. So a reader at any rate
//! sees the same value at the same time, and a step only reads inputs at times up to t.
//!
//! Reaching a step costs steps, so a reader keeps checkpoints: copies of its slab, one a second,
//! in memory it gives `State.init_with_checkpoints`. A read restores the nearest checkpoint before
//! it, or goes on from the slab's own step when that is nearer, and stores each checkpoint it
//! steps past. The checkpoints are a cache like a motion's cursor: a step is a function of the
//! step before and its index, so a value never depends on the memory a reader gave or the order
//! of its reads. A cue move drops them all, since a step can read cue times.
//!
//! A reader given room for it (`Program.reader_slab_count`) also keeps one more copy, of its
//! simulated nodes' regions only, after its slab: their state at the step before the slab's own,
//! saved before the last step of every call that steps. A read of the step the slab has just passed, which
//! `events(last, now)` after `eval(last)` makes, and so does a track written at the time just
//! read, restores that copy instead of a checkpoint, so it replays one step, not up to a second
//! of them. It is a cache in the same sense: pure nodes are refilled by the next pass, and a
//! motion's cursor is a cache of its own.
//!
//! ## 10. Cycles Through a Delay
//! Every op but a delay refers only to earlier nodes, so a pass has no cycle. A delay's input can
//! be any node, set by `close` after it is built, and is read only by the update after a pass,
//! never during one: a delay gives its input's value from one step before. So every cycle passes
//! through a delay, and a cycle without one cannot be expressed.
//!
//! ## 11. Events
//! A program has two readers' views. `eval(t)` gives every value at a moment, and `events(t0, t1)`
//! gives everything that happened in `[t0, t1)`, each at an exact flick, in the order `event.zig`
//! explains. One program answers both, each reader on its own `State`. The ranges are half open,
//! so however a reader splits its timeline, each event lands in exactly one range.
//!
//! An event's time is the first flick at which it has happened, so `eval(event.time)` already
//! shows it: the bounce is at the wall, the crossing's gate has flipped, the motion returns its
//! goal. An instant that is not a whole flick is rounded up, never down. Sources that know their
//! own times solve them: a bounce's hits, cues, a motion's goals reached, and a shift register's
//! bucket boundaries, which are integer flicks already. A crossing has no general solution for an
//! arbitrary input, so it compares its input at consecutive steps and interpolates inside the step,
//! for a pure input as for a simulated one. So a crossing that goes and comes back within one step,
//! 1/480 s, gives no event, though its gate flips, which is the one limit of the rule.
//!
//! Events are not stored. A simulated source finds its events from the slab at a step, after the
//! pass at that step's time and before the update that leaves it: at step j, a crossing compares
//! its input at the step before with the pass, a follower reads whether it arrived at step j, and
//! a shift register whether step j entered a bucket. Every event found at step j lies in
//! (t_{j-1}, t_j]. A step is a function of the step before and its index, so a past range re-runs
//! from a checkpoint and gives the same events, bit for bit.
//!
//! A range must not run ahead of its reader. `events(t0, t1)` commits steps only while every event
//! they can hold is before t1, which leaves the slab at step ceil((t1 - start) / step): the step
//! `eval(t1)` needs, or the one before when t1 is on a step. The events of that last step are
//! found by a read-only look: a pass at its time, which overwrites only node outputs, and each
//! source's check, which commits nothing. The next range starts from that very step, so
//! consecutive ranges run each step once and never restore a checkpoint, and an `eval(t1)` after
//! them runs at most the one step a t1 on a step leaves.
//!
//! A reader can ask for some sources only: `events_of(sources, t0, t1)` gives the events of the
//! listed nodes, in the order and with the overflow rule of `events` (step 23). The solved sources
//! are found apart from the step already, so a list steps only when it names a crossing, a
//! follower, or a shift register, and then it steps as `events` does and keeps only the listed
//! sources' events. A list of solved sources reads the cue table, the goals, and a motion's
//! cursor, and writes nothing, so it leaves the state, the slab, and the checkpoints as they were.
//!
//! ## 12. Ranges, Classes, and Live Input
//! `Program.ranges` gives each node a range its values never leave, and `Program.classes` the
//! class of each, as `range.zig` explains: both are worked out from the ops in a forward pass, with
//! a delay's loop solved as a fixed point, so a node pays nothing for them until a client asks.
//! `Program.report` says whether the program can be reached at any time, and which node is why.
//!
//! An input is the one live op. Its value lives in the slab as its output, set by `set_input`,
//! clamped into its declared range, and a pass leaves it as it is. It has no past, so a checkpoint
//! restore keeps it, and a backward read reads the value set last. A state can record what its
//! passes read of an input, as `recording.zig` explains, and a `recorded` node plays that back as a
//! pure signal. Only committed passes record: `eval`'s, and the passes of the steps. The read-only
//! look of section 11 does not, since a later commit at the same time can read a newer value.
//!
//! ## 14. Live Parameters
//! A knob that applies from now on is a track (`track.zig`): a table of timed values the client
//! writes between reads, which a program reads as the cue table, so a `track` node is pure and a
//! program that reads tracks stays seekable. A write changes the track only at and after its time,
//! so a state drops only what read the changed values: checkpoint k holds the passes of steps 0 to
//! `k * checkpoint_interval - 1` and survives while the last of them is before the earliest time
//! written since the state last looked, and the slab's own step likewise. Played forwards with a
//! write at each frame's time, a reader drops nothing it has run; a write at a time it has passed
//! costs at most one interval of steps.
//!
//! The parameters of a simulated node can come from nodes, read at each step: a chase's time and
//! overshoot, a follower's spring time and overshoot, or its Newtonian speed, accel, and decel. A
//! parameter's node is one of the node's inputs, built before it. Each value is clamped into its
//! domain (a time of at least a flick, an overshoot in [0, 0.99], a limit of at least 2^-20). A
//! spring's law needs a log, so it is cached in the node's slab with the values it came from and
//! worked out again only when they change. An oscillator is the wave whose rate is a node: its
//! phase is the rate summed over the steps, so it is simulated. A spring toward goals at cues and
//! a wave keep constant parameters, since a varying one would make them simulated too.
//!
//! Ranges stay sound. A Newtonian follower is bounded by the largest speed and the smallest decel
//! its parameter nodes' ranges allow. A spring follower whose overshoot alone comes from a node
//! keeps its omega, and `range.follower_damping` bounds it. A chase with a parameter from a node,
//! or a follower whose spring time does, has no bound, since a spring whose stiffness changes as it
//! moves can be pumped, so its range is unbounded.
//!
//! ## 15. Shapes: Vectors and Colour
//! A node's output is its own shape: 1 to `components_max` components a lane (step 16). Two pure
//! ops carry shapes and no op's maths changes: `pack` makes a value of 2 to 4 components from as
//! many scalar nodes, and `pick` takes one component out. `add`, `multiply`, `minimum`, and
//! `maximum` work per component on equal shapes, or broadcast a scalar operand across the other's
//! components; `map_range` and `apply` map each component (section 17). Every other op reads and
//! makes one value, so the builder refuses a vector where it reads one (`ShapeMismatch`), and a
//! moving vector is one scalar node per component, packed: each component of a spring is
//! independent, and a front end builds them. A colour is three components in OKLab (`colour.zig`),
//! so a tween or a spring between two colours is a straight line through OKLab. A pack's range is
//! the hull of its inputs', and a pick of a pack has the picked input's own range. Within a lane,
//! components are consecutive in the slab.
//!
//! ## 16. Lanes
//! One program evaluates many elements as lanes (step 17): each node has its own lane count, and
//! its values are lane after lane. A client opens a region with `Builder.lanes`, the count of the
//! family, and lane l of a node built in it is lane `g = lane_first + l` of the family, which
//! `Extent.laned` marks; `Options.lane_first` lets one program build a slice of a family, so lane
//! g built alone equals lane g built with the rest, bit for bit. A node has many lanes only when
//! its values differ by lane:
//! - Per-lane sources take the region's count: `lane`, each lane's g; a noise, a follower, and a
//!   shift register, whose lane g has its node's seed hashed with g; a delay; and a wave, tween,
//!   spring, Newtonian move, or bounce whose `stagger` is not 0, whose lane g reads the time
//!   `t - g * stagger`, which for a cued op is its cues moved `g * stagger` later.
//! - Arithmetic, a minimum, a maximum, a function of a value, a map, a pack, a pick, a chase, a
//!   crossing, an oscillator, and a tween with `previous` have the most lanes of their inputs, and
//!   an input of one lane is broadcast.
//! - A parameter from a node takes one lane, since a node has one law, and everything else is one
//!   lane, so a constant or a knob costs one value however many lanes read it.
//! Two counts above 1 in one op, or a parameter or a delay's feed of too many, are refused
//! (`LaneMismatch`), as is a stagger or a `lane` outside a region. A `spread` gives a one-lane node
//! n equal lanes, so a region's value has its count even where nothing in it varies. An event's
//! instance is its lane g, so `event.zig`'s order of time, source, then instance holds across
//! lanes. A staggered motion reads its lanes in time order, so its cursor folds forward.
//!
//! A tween or a bounce may choose its cue by lane (step 28): with `cue_by_lane`, lane g starts at
//! cue `start + g` (`lane_cue`, the one definition), then `g * stagger` later as before, so lanes
//! can start at uneven times a client writes in the cue table. Such a node takes the region's
//! lanes, outside a region it is `LaneMismatch`, and a last lane past the cue table is
//! `UnknownCue`. The pass, a bounce's events, and both of a bounce's outputs read the same cue, so
//! a lane's position, velocity, and hits agree, a by-lane bounce's events stay solved, and a cue
//! moved moves one lane. The field is a bool rather than a stride because the language writes
//! only cue g for lane g; a stride would replace it in `lane_cue` alone.
//!
//! ## 17. Functions of a Value
//! `apply` takes a `Function` of one value, and `minimum` and `maximum` the smaller and larger of
//! two (step 26). Each is pure and works per component and per lane as `add` does: `apply` keeps
//! its input's extent, and `minimum` and `maximum` take `add`'s shapes and lanes, a scalar or a
//! lane broadcast. Each has a range rule in `range.zig`, sound for any inputs in their ranges. A
//! function is one value of the union `Function`, its value in `Function.of`, and its range in
//! `function_range`, so a new function adds a line to each and no op. Signed zero has one answer
//! on every target, where `@min` and `@max` leave it to the instruction: |-0| is +0, the minimum
//! of -0 and +0 either way round is -0, and the maximum is +0. Equal inputs give that value.
//!
//! Step 33 adds `sin`, `cos`, `exp`, `ln`, `sqrt`, `floor`, `round`, and `pow` by a whole number
//! from 2 to 8, the one function with a payload, which the builder refuses outside that by
//! `InvalidPower`. Each is total (`elementary.zig`, section 4a): any value a signal holds gives a
//! finite value or the infinity it was given, so `sqrt` of a negative is 0 and `ln` of 0 is
//! held, and their range rules (`range.zig`, sections 2a and 2b) hold for any input, an unbounded
//! one included. abs, min, max, sqrt, floor, round, and pow round nothing out of order, so their
//! ranges are exact for independent inputs; exp, ln, sin, and cos are within a small margin.
//!
//! A function is pure, so its node has its input's class: `floor` of a wave is pure and
//! seekable, and `floor` of a chase is simulated. Of a simulated input it is the function of the
//! interpolated value (section 9), so a step of `floor` falls where the interpolation crosses a
//! whole number, between the fixed steps. A NaN reaches a pure node only after an overflow
//! upstream, such as `inf - inf`; every function passes it through, and min and max of one give
//! the same bits on every target, though which is not promised.
//!
//! ## 13. TigerStyle Invariants
//! - Capacities come from the caller, and the builder refuses what does not fit, by name.
//! - `eval` allocates nothing, takes no lock, and is one bounded pass over the node array. A motion
//!   node folds over at most its own goals. A simulated program first runs at most
//!   `checkpoint_interval - 1` steps once the checkpoints before the time are filled, and the
//!   steps since the last one filled otherwise.
//! - `events` allocates nothing and takes no lock. Its work is the seek `eval` would make to t0,
//!   the steps the range spans, one more pass, and for each event at most `out.len` moves of the
//!   events kept. A source that sorts after a full buffer only counts, by arithmetic for a bounce
//!   and cues, and a motion runs at most 131 closed forms per goal in the range. `events_of` does
//!   the same work for its listed sources, with no step when none of them needs one, and a binary
//!   search of the list for each event a step finds.
//! - `ranges` and `classes` allocate nothing and are bounded: at most `delay_rounds_max` plus
//!   `widen_rounds_max` plus one forward passes, and `3 * node_count + 1` passes.
//! - A recording appends at most one sample per committed pass, and never past its table.
//! - Offsets are consecutive from 0, so the slab has no gaps and no node overlaps another.

const std = @import("std");
const assert = std.debug.assert;
const Cue = @import("cue.zig").Cue;
const Cues = @import("cue.zig").Cues;
const Ease = @import("ease.zig").Ease;
const elementary = @import("elementary.zig");
const event_module = @import("event.zig");
pub const Collector = event_module.Collector;
pub const Event = event_module.Event;
pub const Events = event_module.Events;
const motion = @import("motion.zig");
const Goal = motion.Goal;
pub const Motion = motion.Motion;
const Noise = @import("noise.zig").Noise;
const range_module = @import("range.zig");
pub const Class = range_module.Class;
pub const Range = range_module.Range;
pub const Report = range_module.Report;
const recording_module = @import("recording.zig");
const Recording = recording_module.Recording;
const Sample = recording_module.Sample;
pub const noise_hash = @import("noise.zig").hash;
const simulation = @import("simulation.zig");
const time_module = @import("time.zig");
const Time = time_module.Time;
const track_module = @import("track.zig");
const Tracks = track_module.Tracks;
const TrackId = track_module.TrackId;
const wave_module = @import("wave.zig");
const Wave = wave_module.Wave;

/// A node, as its index in the program.
pub const Id = struct {
    index: u32,
};

/// The shape of a node's output: `lanes` elements of `components` values each.
pub const Extent = struct {
    lanes: u32,
    components: u32,
    /// Its lane l is lane `lane_first + l` of a family (section 16): it was built in a region, or
    /// reads a node that was.
    laned: bool = false,

    /// The number of f64 in the output. The builder refuses an extent where this overflows.
    pub fn count(extent: Extent) u32 {
        assert(extent.lanes > 0);
        assert(extent.components > 0);
        return extent.lanes * extent.components;
    }
};

pub const Binary = struct {
    left: Id,
    right: Id,
};

/// Moves `input` linearly from one range to another. The ends map exactly, it does not clamp, and
/// a high end below the low end reverses the direction.
pub const MapRange = struct {
    input: Id,
    input_low: f64,
    input_high: f64,
    output_low: f64,
    output_high: f64,
};

/// The components most a value has: a 2D or 3D vector, an OKLab colour, and room for one more.
pub const components_max = 4;

/// A value of 2 to `components_max` components from as many scalar nodes, in order (section 15).
pub const Pack = struct {
    inputs: [components_max]Id,
    count: u8,
};

/// Component `component` of `input`, a scalar (section 15).
pub const Pick = struct {
    input: Id,
    component: u8,
};

/// The most lanes a node has (section 16).
pub const lanes_max = 1 << 20;

/// The seed of lane `lane` of a seeded node whose seed is `seed` (section 16).
pub fn lane_seed(seed: u64, lane: u64) u64 {
    return noise_hash(seed, lane);
}

/// The time lane `lane` of a node staggered by `stagger` reads at `time` (section 16).
pub fn lane_time(time: Time, stagger: Time, lane: u64) Time {
    // Wrapping, as every time offset is: the builder refused a stagger whose offsets overflow.
    const offset = @as(i64, @bitCast(lane)) *% stagger.flicks;
    return .{ .flicks = time.flicks -% offset };
}

/// The cue lane `lane` of a family starts at when its op chooses a cue by lane (step 28): the
/// cue `lane` places after `start`, so lane g of a region reads cue `start.index + g`. The one
/// definition, which the builder, the pass, and the events read.
pub fn lane_cue(start: Cue, lane: u32) Cue {
    assert(@as(u64, start.index) + lane <= std.math.maxInt(u32));
    return .{ .index = start.index + lane };
}

/// A node whose cue is chosen by lane is laned, and its last lane's cue is in the table.
fn assert_cue_by_lane(program: Program, node: *const Node, start: Cue) void {
    assert(node.extent.laned);
    const last = @as(u64, start.index) + program.lane_first + node.extent.lanes - 1;
    assert(last < program.cues.count);
}

/// Moves from `from` to `to`, over `duration` from the time of the cue `start`.
pub const Tween = struct {
    from: f64,
    to: f64,
    /// How long the move takes, above zero. Measured from the cue, so it moves with the cue.
    duration: Time,
    ease: Ease,
    start: Cue,
    /// The signal to follow before `start`, or null to hold `from`.
    previous: ?Id,
    /// How much later each lane of a region starts (section 16).
    stagger: Time = .{ .flicks = 0 },
    /// Lane g of the region starts at cue `start.index + g` (`lane_cue`, step 28), so the op
    /// takes the region's lanes.
    cue_by_lane: bool = false,

    /// The value at or after `start_time`.
    pub fn value_after(tween: *const Tween, time: Time, start_time: Time) f64 {
        assert(time.flicks >= start_time.flicks);
        assert(tween.duration.flicks > 0);
        // Wrapping, because the distance between two i64 only fits in a u64.
        const elapsed: u64 = @bitCast(time.flicks -% start_time.flicks);
        const duration: u64 = @intCast(tween.duration.flicks);
        if (elapsed >= duration) return tween.to;
        const progress = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(duration));
        const eased = tween.ease.apply(progress);
        return tween.from * (1 - eased) + tween.to * eased;
    }
};

/// A spring whose goal is a signal, `target`, as a client describes it. Section 9 explains how it
/// runs: each step it heads for the target's value at that step.
pub const Chase = struct {
    target: Id,
    /// The value at the start, at rest.
    from: f64,
    /// The period of the undamped oscillation, above zero, as `motion.Spring.time`.
    time: Time,
    /// The peak overshoot of a move from rest, in [0, 1), as `motion.Spring.overshoot`.
    overshoot: f64,
    /// A node whose value, in seconds, is the time at each step instead (section 14).
    time_from: ?Id = null,
    /// A node whose value is the overshoot at each step instead (section 14).
    overshoot_from: ?Id = null,
};

/// A chase as a graph node holds it.
pub const ChaseNode = struct {
    target: Id,
    from: f64,
    law: motion.SpringLaw,
    /// The nodes of its time and overshoot, or `simulation.no_param` (section 14).
    params: [3]u32 = @splat(simulation.no_param),
};

/// The nodes a follower's law takes its parameters from, which must suit its mover: a spring's
/// time (in seconds) and overshoot, or a Newtonian move's speed, accel, and decel (section 14).
pub const MoverFrom = struct {
    time: ?Id = null,
    overshoot: ?Id = null,
    speed: ?Id = null,
    accel: ?Id = null,
    decel: ?Id = null,
};

/// A wave whose rate is a signal, as a client describes it: simulated, since its phase is the
/// rate summed over the steps (section 14).
pub const Oscillator = struct {
    shape: wave_module.Shape,
    /// A node whose value is the rate in cycles per second, read at each step. It may be negative.
    rate: Id,
    /// The phase at the start, in turns, in [0, 1).
    phase: f64 = 0,
};

/// A goal follower, as a client describes it. `simulation.zig`, section 4, explains it.
pub const Follow = struct {
    /// The value at the start, at rest.
    from: f64,
    /// The regions its goals are drawn from, in the table given in `Builder.Options`.
    regions: simulation.Span,
    pick: simulation.Pick,
    mover: simulation.Mover,
    /// Within this of the goal, and at most this fast in units per second, is arrived. At least 0.
    tolerance: f64,
    /// The shortest pause after arriving, at least 0. Rounded up to a whole step.
    pause_min: Time,
    /// The longest pause, at least `pause_min`. Rounded up to a whole step.
    pause_max: Time,
    /// Hashed with the graph's seed, as a noise's seed is.
    seed: u64,
    /// Nodes its mover's parameters come from instead of the constants (section 14).
    mover_from: MoverFrom = .{},
};

/// A shift register, as a client describes it. `simulation.zig`, section 5, explains it.
pub const Shift = struct {
    /// How many values it holds, from 1 to `simulation.buckets_max`.
    buckets: u32,
    /// One pass over every bucket. Above zero, and at least one step per bucket.
    period: Time,
    /// Bucket values are drawn between `low` and `high`.
    low: f64,
    high: f64,
    /// The chance, in [0, 1], that a bucket changes once per pass.
    odds: f64,
    shape: simulation.ShiftShape,
    /// Hashed with the graph's seed, as a noise's seed is.
    seed: u64,
};

/// A delay as a graph node holds it: its input's values from one step before.
pub const Delay = struct {
    /// Null until `Builder.close` gives the delay its input.
    input: ?Id,
    /// The value at the start, before a step has passed.
    initial: f64,
};

/// A value bouncing between two walls at a constant speed, as a client describes it. The builder
/// gives it two nodes: the position, which fires an event at each wall, and the velocity.
pub const Bounce = struct {
    low: f64,
    /// Above `low`.
    high: f64,
    /// Units per second, above zero.
    speed: f64,
    /// Before this cue it holds `low`, at rest. From it, it leaves `low` going up.
    start: Cue,
    /// How much later each lane of a region starts (section 16).
    stagger: Time = .{ .flicks = 0 },
    /// Lane g of the region starts at cue `start.index + g` (`lane_cue`, step 28).
    cue_by_lane: bool = false,
};

/// The two nodes of a bounce.
pub const BounceIds = struct {
    position: Id,
    velocity: Id,
};

/// The most flicks from its start at which a bounce's hit times stay exact: about 148 days.
const bounce_flicks_max: f64 = 0x1p53;

/// A bounce as a graph node holds it, one node per output. Its hits are the one definition of
/// where it is, so the signal and the events agree to the flick.
pub const BounceNode = struct {
    low: f64,
    high: f64,
    speed: f64,
    /// The flicks one leg lasts, `(high - low) * flicks_per_second / speed`, worked out once by
    /// the builder in exactly that order.
    leg_flicks: f64,
    start: Cue,
    output: Output,
    stagger: Time = .{ .flicks = 0 },
    /// As `Bounce.cue_by_lane`, the same on the position and the velocity.
    cue_by_lane: bool = false,

    pub const Output = enum { position, velocity };

    /// The flicks from the start of hit `k`, `ceil(k * leg_flicks)`, which is the one definition
    /// of a hit time. Hit 0 is the start, which is not a hit.
    pub fn hit(bounce: *const BounceNode, k: u64) u64 {
        assert(bounce.leg_flicks >= 1);
        const product = @as(f64, @floatFromInt(k)) * bounce.leg_flicks;
        // Past 2^53 flicks, k * leg_flicks no longer names a flick exactly.
        assert(product < bounce_flicks_max);
        return @intFromFloat(@ceil(product));
    }

    /// The legs completed at `elapsed` flicks from the start: the largest k whose hit is at or
    /// before it. The quotient is within one of it either way, so one correction each way finds it.
    pub fn legs(bounce: *const BounceNode, elapsed: u64) u64 {
        assert(@as(f64, @floatFromInt(elapsed)) < bounce_flicks_max);
        const quotient = @as(f64, @floatFromInt(elapsed)) / bounce.leg_flicks;
        var k: u64 = @intFromFloat(@floor(quotient));
        if (bounce.hit(k + 1) <= elapsed) k += 1;
        if (k > 0 and bounce.hit(k) > elapsed) k -= 1;
        assert(bounce.hit(k) <= elapsed);
        assert(bounce.hit(k + 1) > elapsed);
        return k;
    }

    /// The hits strictly before `time`, from the start at `start_time`.
    pub fn hits_before(bounce: *const BounceNode, time: Time, start_time: Time) u64 {
        if (time.flicks <= start_time.flicks) return 0;
        const elapsed: u64 = @bitCast(time.flicks -% start_time.flicks);
        return bounce.legs(elapsed - 1);
    }

    /// The output at `time`, from the start at `start_time`.
    pub fn sample(bounce: *const BounceNode, time: Time, start_time: Time) f64 {
        if (time.flicks < start_time.flicks) {
            return switch (bounce.output) {
                .position => bounce.low,
                .velocity => 0,
            };
        }
        // Wrapping, because the distance between two i64 only fits in a u64.
        const elapsed: u64 = @bitCast(time.flicks -% start_time.flicks);
        const k = bounce.legs(elapsed);
        const rising = k % 2 == 0;
        if (bounce.output == .velocity) return if (rising) bounce.speed else -bounce.speed;
        const leg_start = bounce.hit(k);
        const leg_end = bounce.hit(k + 1);
        assert(leg_start <= elapsed);
        assert(elapsed < leg_end);
        // Both below 2^53, so exact, and the quotient is below 1, so a hit lands on its wall.
        const into: f64 = @floatFromInt(elapsed - leg_start);
        const weight = into / @as(f64, @floatFromInt(leg_end - leg_start));
        assert(weight >= 0);
        assert(weight < 1);
        if (rising) return bounce.low * (1 - weight) + bounce.high * weight;
        return bounce.high * (1 - weight) + bounce.low * weight;
    }
};

/// A gate that is 1 while `input` is at or above `level`, and fires an event each time the input
/// crosses the level in `direction`, as section 11 explains. The gate is exact at any time; the
/// events come from the step grid, so they can differ from the gate by up to a step near a
/// crossing, and a crossing that comes back within one step flips the gate with no event.
pub const Crossing = struct {
    input: Id,
    level: f64,
    direction: Direction,

    pub const Direction = enum { rising, falling, both };

    /// Whether the input at two consecutive steps, `a` then `b`, crosses the level. At or above the
    /// level is above.
    pub fn crosses(crossing: *const Crossing, a: f64, b: f64) bool {
        const rising = a < crossing.level and b >= crossing.level;
        const falling = a >= crossing.level and b < crossing.level;
        assert(!(rising and falling));
        return switch (crossing.direction) {
            .rising => rising,
            .falling => falling,
            .both => rising or falling,
        };
    }
};

/// A run of `count` cues from `first`, which fires an event at each cue's time.
pub const CueSpan = struct {
    first: Cue,
    count: u32,
};

/// A live value, set by `State.set_input` each read and clamped into `[low, high]`, as section 12
/// explains. Either end can be infinite, which is the default.
pub const Input = struct {
    low: f64 = -std.math.inf(f64),
    high: f64 = std.math.inf(f64),
    /// The value before the first `set_input`, in `[low, high]`.
    initial: f64 = 0,
};

/// A recording played back, as a node holds it: its clip, and the hull of its values.
pub const Recorded = struct {
    clip: recording_module.Clip,
    low: f64,
    high: f64,
};

/// A function of one value, applied per component and per lane (section 17). Each is total, and
/// none is a composition of the others or of arithmetic, except as its doc says.
pub const Function = union(enum) {
    /// |x|, with its sign bit cleared, so |-0| is +0. `maximum(x, -x)` has the same values, but
    /// interval arithmetic takes x and -x as independent, so its range over [-1, 1] would be
    /// [-1, 1]; this one's is [0, 1].
    abs,
    /// The sine of x radians (`elementary.sine_radians`).
    sin,
    /// The cosine of x radians (`elementary.cosine_radians`).
    cos,
    /// e^x, held at e^709 above 709 (`elementary.exponential`).
    exp,
    /// The natural log of x, held at the log of 2^-1074 at and below 0 (`elementary.logarithm`).
    ln,
    /// The square root of x, and 0 at and below 0 (`elementary.square_root`).
    sqrt,
    /// The largest whole number at or below x: IEEE 754's `@floor`.
    floor,
    /// The nearest whole number, a half away from zero (`elementary.round_half_away`).
    round,
    /// x to a whole power from `elementary.power_min` to `power_max`, which the builder checks.
    /// `pow(x, 2)` is `x * x` bit for bit, with an exact range that knows both factors are x, so
    /// over [-1, 1] it is [0, 1] where the product's is [-1, 1].
    pow: u8,

    /// The function's value at `x`, the same bits on every target.
    pub fn of(function: Function, x: f64) f64 {
        return switch (function) {
            .abs => @abs(x),
            .sin => elementary.sine_radians(x),
            .cos => elementary.cosine_radians(x),
            .exp => elementary.exponential(x),
            .ln => elementary.logarithm(x),
            .sqrt => elementary.square_root(x),
            .floor => @floor(x),
            .round => elementary.round_half_away(x),
            .pow => |n| elementary.power(x, n),
        };
    }

    /// Whether the builder takes it: a power from 2 to 8.
    pub fn valid(function: Function) bool {
        return switch (function) {
            .pow => |n| n >= elementary.power_min and n <= elementary.power_max,
            else => true,
        };
    }
};

/// `function` of `input`, per component and per lane (section 17).
pub const Apply = struct {
    input: Id,
    function: Function,
};

/// The smaller of `a` and `b`, with -0 below +0 (section 17). Not `@min`, which leaves a signed
/// zero to the instruction: x86's `minsd` gives its second operand, and wasm's `f64.min` -0.
pub fn minimum(a: f64, b: f64) f64 {
    if (a < b) return a;
    if (b < a) return b;
    // Equal, or a NaN, which a signal never holds: -0 and +0 compare equal, so the sign decides.
    return if (std.math.signbit(a)) a else b;
}

/// The larger of `a` and `b`, with +0 above -0 (section 17).
pub fn maximum(a: f64, b: f64) f64 {
    if (a > b) return a;
    if (b > a) return b;
    return if (std.math.signbit(a)) b else a;
}

pub const Op = union(enum) {
    constant: f64,
    add: Binary,
    multiply: Binary,
    /// The smaller of two values per component, a scalar broadcast as `add` does (section 17).
    /// `-maximum(-a, -b)` has the same values in four nodes.
    minimum: Binary,
    /// The larger of two values per component, a scalar broadcast as `add` does (section 17).
    maximum: Binary,
    /// A function of one value (section 17).
    apply: Apply,
    map_range: MapRange,
    wave: Wave,
    tween: Tween,
    noise: Noise,
    motion: Motion,
    chase: ChaseNode,
    follow: simulation.Follower,
    shift: simulation.ShiftRegister,
    delay: Delay,
    bounce: BounceNode,
    crossing: Crossing,
    cues: CueSpan,
    input: Input,
    recorded: Recorded,
    oscillator: Oscillator,
    track: TrackId,
    pack: Pack,
    pick: Pick,
    /// Each lane's index in its family, `lane_first + l` (section 16).
    lane,
    /// A node of one lane as the node's lanes, each its value (section 16).
    spread: Id,

    /// The f64 a node of this op keeps in the slab after an output of `output_count` f64, for a
    /// cache or a simulation's state. Section 9 explains the layout of a simulated node.
    pub fn cache_count(op: *const Op, output_count: u64) u64 {
        assert(output_count > 0);
        return switch (op.*) {
            .motion => motion.cursor_count,
            .chase => |chase| 3 * output_count + law_cache_count(chase.params, true),
            .delay => 2 * output_count,
            // Its values at the steps before and after, then each lane's own slots.
            .follow => |follow| (2 + follower_slots) * output_count +
                law_cache_count(follow.params, follow.law == .spring),
            // Its values at the steps before and after, then its phase.
            .oscillator => 3 * output_count,
            .shift => |shift| 2 * output_count + (1 + @as(u64, shift.buckets)) * output_count,
            // The input at the last step, then whether there is one.
            .crossing => output_count + 1,
            .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .bounce, .cues => 0,
            .input, .recorded, .track, .pack, .pick, .lane, .spread => 0,
            .minimum, .maximum, .apply => 0,
        };
    }

    /// Whether a node of this op runs on the fixed step, as section 9 explains.
    pub fn simulated(op: *const Op) bool {
        return switch (op.*) {
            .chase, .follow, .shift, .delay, .crossing, .oscillator => true,
            .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .motion => false,
            .bounce, .cues, .input, .recorded, .track, .pack, .pick, .lane, .spread => false,
            .minimum, .maximum, .apply => false,
        };
    }

    /// The class of this op alone, before its inputs', as section 12 explains.
    pub fn class(op: *const Op) Class {
        return switch (op.*) {
            .constant, .add, .multiply, .map_range, .wave, .tween, .noise => .pure,
            .bounce, .cues, .recorded, .track, .pack, .pick, .lane, .spread => .pure,
            .minimum, .maximum, .apply => .pure,
            .motion => .exact,
            .chase, .follow, .shift, .delay, .crossing, .oscillator => .simulated,
            .input => .live,
        };
    }

    /// The nodes this op reads, at most four, null where there are fewer. A parameter's node is
    /// an input too (section 14).
    pub fn inputs(op: *const Op) [4]?Id {
        return switch (op.*) {
            .add, .multiply, .minimum, .maximum => |pair| .{ pair.left, pair.right, null, null },
            .apply => |apply| .{ apply.input, null, null, null },
            .map_range => |map| .{ map.input, null, null, null },
            .tween => |tween| .{ tween.previous, null, null, null },
            .chase => |chase| .{
                chase.target,
                param(chase.params, 0),
                param(chase.params, 1),
                null,
            },
            .follow => |follow| .{
                param(follow.params, 0),
                param(follow.params, 1),
                param(follow.params, 2),
                null,
            },
            .delay => |delay| .{ delay.input, null, null, null },
            .crossing => |crossing| .{ crossing.input, null, null, null },
            .oscillator => |oscillator| .{ oscillator.rate, null, null, null },
            .constant, .wave, .noise, .motion, .shift, .bounce, .cues => @splat(null),
            .input, .recorded, .track, .lane => @splat(null),
            .spread => |input| .{ input, null, null, null },
            .pack => |pack| ids: {
                var ids: [4]?Id = @splat(null);
                for (pack.inputs[0..pack.count], 0..) |id, at| ids[at] = id;
                break :ids ids;
            },
            .pick => |pick| .{ pick.input, null, null, null },
        };
    }
};

/// A follower's own state after its before and after values: velocity, goal, goals drawn, steps
/// of pause left, whether it arrived at this step, and the goal it last arrived at.
pub const follower_slots = 6;
pub const follower_slot_arrived = 4;
pub const follower_slot_arrived_goal = 5;

/// The f64 a spring with a parameter from a node keeps after its own state: the time and the
/// overshoot its law was last worked out from, then that law's omega, zeta, and damped hz.
const spring_cache_count = 5;

/// The least a Newtonian limit from a node can be; a smaller value is clamped up (section 14).
const limit_min: f64 = 0x1p-20;

/// The largest overshoot from a node; a larger value is clamped down (section 14).
const overshoot_max: f64 = 0.99;

/// The node of parameter `slot`, or null when it is constant.
pub fn param(params: [3]u32, slot: u32) ?Id {
    if (params[slot] == simulation.no_param) return null;
    return .{ .index = params[slot] };
}

pub fn any_param(params: [3]u32) bool {
    for (params) |id| if (id != simulation.no_param) return true;
    return false;
}

/// The f64 of a law cache after a node's own state: a spring with a parameter from a node keeps
/// one, and nothing else does.
fn law_cache_count(params: [3]u32, spring: bool) u64 {
    return if (spring and any_param(params)) spring_cache_count else 0;
}

/// The value of parameter node `id` at this pass: its first lane, bounded as a simulated node
/// reads every value (`simulation.zig`, section 7).
pub fn param_value(program: *const Program, slab: []const f64, id: Id) f64 {
    return simulation.bounded(node_values(program.nodes, slab, id)[0]);
}

/// The law of a spring at this step: `fixed`, with its omega from a time node and its damping from
/// an overshoot node where it has them, each clamped into its domain. Cached in `cache` with the
/// values it came from, so a parameter that holds costs two compares a step (section 14).
pub fn spring_law_at(
    program: *const Program,
    slab: []const f64,
    params: [3]u32,
    fixed: motion.SpringLaw,
    cache: []f64,
) motion.SpringLaw {
    assert(cache.len == spring_cache_count);
    const seconds_min = 1 / flicks_per_second_float;
    const seconds = if (param(params, 0)) |id|
        @max(param_value(program, slab, id), seconds_min)
    else
        0;
    const overshoot = if (param(params, 1)) |id|
        std.math.clamp(param_value(program, slab, id), 0, overshoot_max)
    else
        0;
    if (cache[0] == seconds and cache[1] == overshoot) {
        return .{ .omega = cache[2], .zeta = cache[3], .damped_hz = cache[4] };
    }
    const omega = if (param(params, 0) != null) std.math.tau / seconds else fixed.omega;
    const zeta = if (param(params, 1) != null) motion.SpringLaw.zeta_of(overshoot) else fixed.zeta;
    const law = motion.SpringLaw.from_omega_zeta(omega, zeta);
    cache[0..spring_cache_count].* = .{ seconds, overshoot, law.omega, law.zeta, law.damped_hz };
    return law;
}

/// The limits of a Newtonian move at this step: `fixed`, with each limit from a node where it has
/// one, clamped to at least `limit_min`.
pub fn newtonian_limits_at(
    program: *const Program,
    slab: []const f64,
    params: [3]u32,
    fixed: motion.Limits,
) motion.Limits {
    var limits = fixed;
    const fields = [3]*f64{ &limits.speed, &limits.accel, &limits.decel };
    for (fields, 0..) |field, slot| {
        const id = param(params, @intCast(slot)) orelse continue;
        field.* = @max(param_value(program, slab, id), limit_min);
    }
    return limits;
}

/// Marks a law cache stale, so the next step works its law out: no time is -1.
pub fn law_cache_reset(cache: []f64) void {
    assert(cache.len == spring_cache_count);
    @memset(cache, -1);
}

pub const Node = struct {
    op: Op,
    /// The index in the slab of this node's first value.
    offset: u32,
    extent: Extent,
};

comptime {
    // A follower is the largest op. The array is read in order, so this costs prefetch, not misses.
    assert(@sizeOf(Node) <= 128);
    assert(@sizeOf(Id) == @sizeOf(u32));
    assert(@alignOf(Node) == @alignOf(f64));
}

/// An immutable node array, the cue, goal, and region tables it reads, and the size of the slab
/// it needs. A view of memory that can move.
pub const Program = struct {
    nodes: []const Node,
    cues: *const Cues,
    goals: []const Goal,
    regions: []const simulation.Region,
    /// The recordings that `recorded` nodes play back.
    samples: []const Sample,
    /// The tracks that `track` nodes read, which the client writes between reads (section 14).
    tracks: *const Tracks,
    /// The cue simulated nodes start at, read only when `simulated`.
    start: Cue,
    /// Whether any node runs on the fixed step, so a read may cost steps.
    simulated: bool,
    /// The f64 of every node's values and caches: the least slab a reader takes.
    slab_count: u32,
    /// The f64 of a reader's copy of its simulated nodes' regions at the step before its own,
    /// packed in node order (section 9), which it keeps after `slab_count` when its slab has room
    /// for `reader_slab_count`. 0 for a program with no simulated node.
    recent_count: u32 = 0,
    /// The family index of lane 0 of a node built in a lane region (section 16).
    lane_first: u32 = 0,

    /// The slab a reader takes to keep the copy of section 9 as well: `slab_count` plus
    /// `recent_count`. A reader given only `slab_count` keeps none, and then a read of the step its
    /// slab has just passed restores a checkpoint instead.
    pub fn reader_slab_count(program: Program) u64 {
        return @as(u64, program.slab_count) + program.recent_count;
    }

    pub fn assert_valid(program: Program) void {
        var offset: u64 = 0;
        var simulated_count: u32 = 0;
        var simulated_regions: u64 = 0;
        for (program.nodes, 0..) |*node, index| {
            assert(node.offset == offset);
            assert(node.extent.lanes >= 1 and node.extent.lanes <= lanes_max);
            if (node.extent.lanes > 1) assert(node.extent.laned);
            for (node.op.inputs()) |maybe| {
                const input = maybe orelse continue;
                // A delay's input can come after it, which `close` checked.
                if (input.index >= index) continue;
                const lanes = program.nodes[input.index].extent.lanes;
                assert(lanes == 1 or lanes == node.extent.lanes);
            }
            const region = node.extent.count() + node.op.cache_count(node.extent.count());
            offset += region;
            if (node.op.simulated()) {
                simulated_count += 1;
                simulated_regions += region;
            }
            switch (node.op) {
                .constant, .wave, .noise, .shift => {},
                .lane => assert(node.extent.laned),
                .spread => |input| {
                    assert(input.index < index);
                    assert(program.nodes[input.index].extent.lanes == 1);
                    assert(node.extent.laned);
                },
                .chase => |op| {
                    assert(op.target.index < index);
                    for (op.params) |id| assert(id == simulation.no_param or id < index);
                },
                .delay => |op| if (op.input) |input| assert(input.index < program.nodes.len),
                .follow => |op| {
                    assert(op.regions.count > 0);
                    assert(op.regions.first + op.regions.count <= program.regions.len);
                    for (op.params) |id| assert(id == simulation.no_param or id < index);
                },
                .oscillator => |op| {
                    assert(op.rate.index < index);
                    assert(op.phase >= 0 and op.phase < 1);
                },
                .track => |id| assert(id.index < program.tracks.count),
                .add, .multiply, .minimum, .maximum => |op| {
                    assert(op.left.index < index);
                    assert(op.right.index < index);
                },
                .apply => |op| {
                    assert(op.input.index < index);
                    assert(op.function.valid());
                    const input = program.nodes[op.input.index].extent;
                    assert(input.lanes == node.extent.lanes);
                    assert(input.components == node.extent.components);
                },
                .map_range => |op| assert(op.input.index < index),
                .pack => |op| {
                    assert(op.count >= 2 and op.count <= components_max);
                    assert(node.extent.components == op.count);
                    for (op.inputs[0..op.count]) |id| {
                        assert(id.index < index);
                        assert(program.nodes[id.index].extent.components == 1);
                    }
                },
                .pick => |op| {
                    assert(op.input.index < index);
                    assert(op.component < program.nodes[op.input.index].extent.components);
                    assert(node.extent.components == 1);
                },
                .tween => |op| {
                    assert(op.start.index < program.cues.count);
                    if (op.cue_by_lane) assert_cue_by_lane(program, node, op.start);
                    if (op.previous) |previous| assert(previous.index < index);
                },
                .motion => |op| {
                    assert(op.goals.count > 0);
                    assert(op.goals.first + op.goals.count <= program.goals.len);
                    const path = program.goals[op.goals.first..][0..op.goals.count];
                    for (path) |goal| assert(goal.cue.index < program.cues.count);
                },
                .bounce => |op| {
                    assert(op.start.index < program.cues.count);
                    if (op.cue_by_lane) assert_cue_by_lane(program, node, op.start);
                    assert(op.leg_flicks >= 1);
                    assert(op.leg_flicks < bounce_flicks_max);
                },
                .crossing => |op| assert(op.input.index < index),
                .cues => |op| {
                    assert(op.count > 0);
                    assert(@as(u64, op.first.index) + op.count <= program.cues.count);
                },
                .input => |op| {
                    assert(op.low <= op.high);
                    assert(op.initial >= op.low and op.initial <= op.high);
                },
                .recorded => |op| {
                    assert(op.clip.count > 0);
                    assert(@as(u64, op.clip.first) + op.clip.count <= program.samples.len);
                    assert(op.low <= op.high);
                },
            }
        }
        assert(offset == program.slab_count);
        assert(program.recent_count == 0 or program.recent_count == simulated_regions);
        assert(program.simulated == (simulated_count > 0));
        if (program.simulated) assert(program.start.index < program.cues.count);
    }

    /// Fills `out[i]` with a range that node i's values never leave, at any time, for any cue
    /// placement and read order, as `range.zig` explains. `out.len` must be at least the node
    /// count. A delay's loop is solved as a fixed point: up to `delay_rounds_max` passes widening
    /// each delay to the hull of its initial value and its input, then up to `widen_rounds_max`
    /// passes trying ever wider ranges for the delays, accepting the first that the loop maps into
    /// itself, which is then a bound by induction over the steps. A loop that never settles has
    /// infinite ends. Not for the realtime path, though bounded and allocating nothing.
    pub fn ranges(program: *const Program, out: []Range) void {
        assert(out.len >= program.nodes.len);
        const result = out[0..program.nodes.len];
        for (program.nodes, result) |*node, *range| switch (node.op) {
            .delay => |op| range.* = Range.point(op.initial),
            else => range.* = Range.unbounded,
        };
        for (0..delay_rounds_max) |_| {
            program.ranges_pass(result);
            if (program.delays_settle(result)) return;
        }
        for (0..widen_rounds_max) |round| {
            for (program.nodes, result) |*node, *range| {
                if (node.op == .delay) range.* = widen_round(range.*, round);
            }
            program.ranges_pass(result);
            if (program.delays_cover(result)) return;
        }
        for (program.nodes, result) |*node, *range| {
            if (node.op == .delay) range.* = Range.unbounded;
        }
        program.ranges_pass(result);
        assert(program.delays_cover(result));
    }

    /// Fills `out[i]` with node i's class: the highest of its own op's and its inputs', as
    /// `range.zig` explains. A delay's input can come after it, so this repeats to a fixed point;
    /// a class only rises, at most three times a node, which bounds the passes.
    pub fn classes(program: *const Program, out: []Class) void {
        assert(out.len >= program.nodes.len);
        const result = out[0..program.nodes.len];
        for (program.nodes, result) |*node, *class| class.* = node.op.class();
        const rounds_max = 3 * program.nodes.len + 1;
        for (0..rounds_max) |_| {
            var changed = false;
            for (program.nodes, result) |*node, *class| {
                var highest = class.*;
                for (node.op.inputs()) |input| {
                    if (input) |id| highest = highest.max(result[id.index]);
                }
                if (highest != class.*) {
                    class.* = highest;
                    changed = true;
                }
            }
            if (!changed) return;
        } else unreachable;
    }

    /// Whether the program can be reached at any time, and the first node that keeps it from
    /// being, or that makes a read cost steps.
    pub fn report(program: *const Program) Report {
        var result: Report = .{
            .seekable = true,
            .live = null,
            .stepped = false,
            .first_simulated = null,
        };
        for (program.nodes, 0..) |*node, index| {
            const id: Id = .{ .index = @intCast(index) };
            switch (node.op.class()) {
                .live => if (result.live == null) {
                    result.live = id;
                    result.seekable = false;
                },
                .simulated => if (result.first_simulated == null) {
                    result.first_simulated = id;
                    result.stepped = true;
                },
                .pure, .exact => {},
            }
        }
        assert(result.stepped == program.simulated);
        return result;
    }

    /// One forward pass of `ranges`: every node but a delay, from the ranges before it and the
    /// delays' ranges as they stand.
    fn ranges_pass(program: *const Program, result: []Range) void {
        for (program.nodes, result) |*node, *range| {
            if (node.op != .delay) range.* = program.node_range(node, result);
            range.assert_valid();
        }
    }

    /// The range each delay needs for its input as `result` stands: the hull of its initial value
    /// and its input's range, and the margin of the interpolation between steps.
    fn delay_needs(program: *const Program, op: Delay, result: []const Range) Range {
        _ = program;
        const needed = Range.point(op.initial).hull(result[op.input.?.index]);
        return needed.widen(needed.scale(), range_module.margin_rounding);
    }

    /// Widens each delay to what it needs, and returns whether none had to.
    fn delays_settle(program: *const Program, result: []Range) bool {
        var settled = true;
        for (program.nodes, result) |*node, *range| switch (node.op) {
            .delay => |op| {
                const needed = program.delay_needs(op, result);
                if (!range.covers(needed)) {
                    range.* = range.hull(needed);
                    settled = false;
                }
            },
            else => {},
        };
        return settled;
    }

    /// Whether every delay's range holds what it needs.
    fn delays_cover(program: *const Program, result: []const Range) bool {
        for (program.nodes, result) |*node, range| switch (node.op) {
            .delay => |op| if (!range.covers(program.delay_needs(op, result))) return false,
            else => {},
        };
        return true;
    }

    /// The range of one node from the ranges of its inputs, by the rules of `range.zig`.
    fn node_range(program: *const Program, node: *const Node, result: []const Range) Range {
        return switch (node.op) {
            .constant => |constant| Range.point(constant),
            .add => |op| range_module.add(result[op.left.index], result[op.right.index]),
            .multiply => |op| range_module.multiply(result[op.left.index], result[op.right.index]),
            .minimum => |op| range_module.minimum(result[op.left.index], result[op.right.index]),
            .maximum => |op| range_module.maximum(result[op.left.index], result[op.right.index]),
            .apply => |op| function_range(op.function, result[op.input.index]),
            .map_range => |*op| map_range_range(op, result[op.input.index]),
            .wave, .noise => .{ .low = -1, .high = 1 },
            .tween => |*op| tween_range(op, if (op.previous) |id| result[id.index] else null),
            .motion => |*op| program.motion_range(op),
            .chase => |op| if (any_param(op.params))
                // A spring whose law changes as it moves has no bound (section 14).
                Range.unbounded
            else
                range_module.spring(
                    Range.point(op.from).hull(result[op.target.index]),
                    op.law.zeta,
                ),
            .follow => |*op| program.follow_range(op, result),
            .oscillator => hull_widened(-1, 1),
            .track => |id| Range.of(program.tracks.at(id).low, program.tracks.at(id).high),
            .shift => |op| hull_widened(op.low, op.high),
            .delay => unreachable,
            .bounce => |op| switch (op.output) {
                .position => hull_widened(op.low, op.high),
                .velocity => .{ .low = -op.speed, .high = op.speed },
            },
            .crossing => .{ .low = 0, .high = 1 },
            .cues => |span| .{ .low = 0, .high = @floatFromInt(span.count) },
            .input => |op| .{ .low = op.low, .high = op.high },
            .recorded => |op| .{ .low = op.low, .high = op.high },
            .pack => |op| hull: {
                var hull = result[op.inputs[0].index];
                for (op.inputs[1..op.count]) |id| hull = hull.hull(result[id.index]);
                break :hull hull;
            },
            .pick => |op| switch (program.nodes[op.input.index].op) {
                .pack => |pack| result[pack.inputs[op.component].index],
                else => result[op.input.index],
            },
            .lane => Range.of(
                @floatFromInt(program.lane_first),
                @floatFromInt(@as(u64, program.lane_first) + node.extent.lanes - 1),
            ),
            .spread => |input| result[input.index],
        };
    }

    /// A spring's or a Newtonian move's range, from its start and its goals.
    fn motion_range(program: *const Program, op: *const Motion) Range {
        const path = program.goals[op.goals.first..][0..op.goals.count];
        var inputs = Range.point(op.from);
        for (path) |goal| inputs = inputs.hull(Range.point(goal.value));
        return switch (op.law) {
            .spring => |law| if (path.len == 1)
                range_module.spring_one(op.from, path[0].value, law.zeta)
            else
                range_module.spring(inputs, law.zeta),
            .newtonian => |limits| range_module.newtonian(inputs, limits.speed, limits.decel),
        };
    }

    /// A follower's range, from its start and its regions, widened by what its mover overshoots.
    /// With parameters from nodes, as section 14 explains: a spring whose overshoot alone comes
    /// from a node keeps its omega, so `range.follower_damping` bounds it; one whose time comes
    /// from a node has no bound; a Newtonian move is bounded by its largest speed and smallest
    /// decel.
    fn follow_range(
        program: *const Program,
        op: *const simulation.Follower,
        result: []const Range,
    ) Range {
        var inputs = Range.point(op.from);
        for (program.regions[op.regions.first..][0..op.regions.count]) |region| {
            inputs = inputs.hull(Range.of(region.low, region.high));
        }
        return switch (op.law) {
            .spring => |law| if (param(op.params, 0) != null)
                Range.unbounded
            else if (param(op.params, 1) != null)
                range_module.follower_damping(inputs, op.tolerance, law.omega)
            else
                range_module.spring(inputs, law.zeta),
            .newtonian => |limits| {
                var speed = limits.speed;
                var decel = limits.decel;
                if (param(op.params, 0)) |id| speed = @max(result[id.index].high, limit_min);
                if (param(op.params, 2)) |id| decel = @max(result[id.index].low, limit_min);
                if (!std.math.isFinite(speed)) return Range.unbounded;
                return range_module.newtonian(inputs, speed, decel);
            },
        };
    }
};

/// Appends nodes to caller-owned memory, then hands over the finished `Program`.
pub const Builder = struct {
    nodes: []Node,
    node_count: u32,
    slab_count: u32,
    /// The f64 of the simulated nodes' regions built so far (`Program.recent_count`).
    recent_count: u32,
    slab_count_max: u32,
    /// The table of `Options.cues`. Not named `cues`, which is the op of section 11.
    cue_table: *const Cues,
    goals: []const Goal,
    regions: []const simulation.Region,
    samples: []const Sample,
    tracks: *const Tracks,
    start: Cue,
    seed: u64,
    /// The lane region open, as its count, or null outside one (section 16). A client sets it
    /// between nodes; a per-lane source built while it is set takes this many lanes.
    lanes: ?u32,
    /// The family index of a region's lane 0, from `Options.lane_first`.
    lane_first: u32,
    /// Whether a simulated node has been built.
    simulated: bool,
    /// Delays built and not yet closed, which `finish` requires to be none.
    delays_open: u32,
    finished: bool,

    pub const Error = error{
        /// The node array the caller gave `init` is full.
        NodeCapacityExceeded,
        /// The next node would pass `slab_count_max`.
        SlabCapacityExceeded,
        /// An id that no node built so far has, which also refuses a forward reference.
        UnknownNode,
        /// A constant or a parameter that is infinite or NaN, or an input end that is NaN. A
        /// constant that becomes a moving value or a goal must also be within
        /// `simulation.state_bound`, 2^256 (`simulation.zig`, section 7).
        NotFinite,
        /// Two vectors of different sizes in one op, a vector where an op reads one value, a pack
        /// of fewer than 2 or more than `components_max` inputs, or a component past the end
        /// (section 15).
        ShapeMismatch,
        /// Two inputs of different lane counts above 1, a parameter from a node of more than one
        /// lane, a delay fed more lanes than it has, a spread of a node of many lanes, or a
        /// stagger or a `lane` outside a lane region (section 16).
        LaneMismatch,
        /// A map whose input range has no width, or one too wide for a double, a bounce whose low
        /// is not below its high, or an input whose low is above its high or whose initial value
        /// is outside them.
        InvalidRange,
        /// A cue that the table given in `Options` does not have, including the start cue of a
        /// simulated node, and a cue span that is empty or runs past the table.
        UnknownCue,
        /// A tween or a spring time that is not above zero, or a shift register period that is not
        /// above zero, is longer than `simulation.period_flicks_max`, or gives a bucket less than
        /// one step, or a bounce leg shorter than a flick or too long to time exactly.
        InvalidDuration,
        /// A tween whose ease fails `Ease.valid`.
        InvalidEase,
        /// A noise whose frequency is not above 0 and at most `Noise.hz_max`.
        InvalidRate,
        /// A path that the goal table given in `Options` does not hold.
        UnknownGoals,
        /// A spring whose overshoot is not in [0, 1).
        InvalidOvershoot,
        /// A Newtonian move whose speed, accel, or decel is not above zero, or a bounce whose speed
        /// is not.
        InvalidLimit,
        /// A span that the region table given in `Options` does not hold.
        UnknownRegions,
        /// A follower whose tolerance is below zero.
        InvalidTolerance,
        /// A follower whose shortest pause is below zero or above its longest, or whose longest
        /// is above `simulation.pause_steps_max` steps.
        InvalidPause,
        /// A shift register whose odds are not in [0, 1].
        InvalidOdds,
        /// A shift register with no buckets, or more than `simulation.buckets_max`.
        InvalidBuckets,
        /// A `close` of a node that is not a delay.
        NotADelay,
        /// A `close` of a delay that already has its input.
        DelayClosed,
        /// A clip that the sample table given in `Options` does not hold.
        UnknownSamples,
        /// A track that the table given in `Options` does not have.
        UnknownTrack,
        /// A follower parameter from a node that its mover does not have: a spring's speed, or a
        /// Newtonian move's time.
        InvalidParameter,
        /// An oscillator's phase outside [0, 1).
        InvalidPhase,
        /// A `Function.pow` whose power is not a whole number from 2 to 8.
        InvalidPower,
    };

    pub const Options = struct {
        slab_count_max: u32,
        /// The cues that tweens and goals refer to. The program reads this table, so it sees
        /// later moves.
        cues: *const Cues = &Cues.empty,
        /// The goals that motions head for, from `Goals.table`.
        goals: []const Goal = &.{},
        /// The regions that followers draw goals from, from `Regions.table`.
        regions: []const simulation.Region = &.{},
        /// The recordings that `recorded` nodes play back, from `Samples.table`.
        samples: []const Sample = &.{},
        /// The tracks that `track` nodes read. The program reads this table, so it sees later
        /// writes, as section 14 explains.
        tracks: *const Tracks = &Tracks.empty,
        /// The cue every simulated node starts at, as section 9 explains.
        start: Cue = .{ .index = 0 },
        /// Hashed into the seed of every noise, follower, and shift register, as section 7
        /// explains.
        seed: u64 = 0,
        /// The family index of lane 0 of every lane region, so a program can build a slice of a
        /// family (section 16).
        lane_first: u32 = 0,
    };

    pub fn init(nodes: []Node, options: Options) Builder {
        assert(nodes.len <= std.math.maxInt(u32));
        return .{
            .nodes = nodes,
            .node_count = 0,
            .slab_count = 0,
            .recent_count = 0,
            .slab_count_max = options.slab_count_max,
            .cue_table = options.cues,
            .goals = options.goals,
            .regions = options.regions,
            .samples = options.samples,
            .tracks = options.tracks,
            .start = options.start,
            .seed = options.seed,
            .lanes = null,
            .lane_first = options.lane_first,
            .simulated = false,
            .delays_open = 0,
            .finished = false,
        };
    }

    pub fn constant(builder: *Builder, value: f64) Error!Id {
        if (!std.math.isFinite(value)) return error.NotFinite;
        return builder.push(.{ .constant = value });
    }

    /// Each lane's index in its family, in the region open (section 16).
    pub fn lane(builder: *Builder) Error!Id {
        return builder.push_shaped(.lane, try builder.region_extent());
    }

    /// The one-lane node `id` as the open region's lanes, each its value (section 16).
    pub fn spread(builder: *Builder, id: Id) Error!Id {
        try builder.check_scalar(id);
        if (builder.nodes[id.index].extent.lanes != 1) return error.LaneMismatch;
        return builder.push_shaped(.{ .spread = id }, try builder.region_extent());
    }

    /// `left + right`, per component; a scalar operand is added to every component of the other
    /// (section 15).
    pub fn add(builder: *Builder, left: Id, right: Id) Error!Id {
        const extent = try builder.binary_extent(left, right);
        return builder.push_shaped(.{ .add = .{ .left = left, .right = right } }, extent);
    }

    /// `left * right`, per component, with a scalar broadcast as `add` does.
    pub fn multiply(builder: *Builder, left: Id, right: Id) Error!Id {
        const extent = try builder.binary_extent(left, right);
        return builder.push_shaped(.{ .multiply = .{ .left = left, .right = right } }, extent);
    }

    /// The smaller of `left` and `right` per component, with a scalar broadcast as `add` does
    /// (section 17).
    pub fn minimum(builder: *Builder, left: Id, right: Id) Error!Id {
        const extent = try builder.binary_extent(left, right);
        return builder.push_shaped(.{ .minimum = .{ .left = left, .right = right } }, extent);
    }

    /// The larger of `left` and `right` per component, with a scalar broadcast as `add` does.
    pub fn maximum(builder: *Builder, left: Id, right: Id) Error!Id {
        const extent = try builder.binary_extent(left, right);
        return builder.push_shaped(.{ .maximum = .{ .left = left, .right = right } }, extent);
    }

    /// `function` of `of`, per component and per lane: the node has `of`'s extent (section 17).
    pub fn apply(builder: *Builder, function: Function, of: Id) Error!Id {
        try builder.check_known(of);
        if (!function.valid()) return error.InvalidPower;
        const extent = builder.nodes[of.index].extent;
        return builder.push_shaped(.{ .apply = .{ .input = of, .function = function } }, extent);
    }

    /// A value whose components are `ids`, each a scalar, 2 to `components_max` of them.
    pub fn pack(builder: *Builder, ids: []const Id) Error!Id {
        if (ids.len < 2 or ids.len > components_max) return error.ShapeMismatch;
        var op: Pack = .{ .inputs = undefined, .count = @intCast(ids.len) };
        var extents: [components_max]Extent = undefined;
        for (ids, 0..) |id, at| {
            try builder.check_scalar(id);
            op.inputs[at] = id;
            extents[at] = builder.nodes[id.index].extent;
        }
        var extent = try joined(extents[0..ids.len]);
        extent.components = op.count;
        return builder.push_shaped(.{ .pack = op }, extent);
    }

    /// Component `component` of `id`, a scalar.
    pub fn pick(builder: *Builder, id: Id, component: u8) Error!Id {
        try builder.check_known(id);
        const of = builder.nodes[id.index].extent;
        if (component >= of.components) return error.ShapeMismatch;
        const extent: Extent = .{ .lanes = of.lanes, .components = 1, .laned = of.laned };
        return builder.push_shaped(.{ .pick = .{ .input = id, .component = component } }, extent);
    }

    /// The shape of a binary op over `left` and `right`: theirs when equal, else the one that
    /// is not a scalar; two different vectors are refused.
    fn binary_extent(builder: *const Builder, left: Id, right: Id) Error!Extent {
        try builder.check_known(left);
        try builder.check_known(right);
        const a = builder.nodes[left.index].extent;
        const b = builder.nodes[right.index].extent;
        var extent = try joined(&.{ a, b });
        if (a.components == b.components or b.components == 1) {
            extent.components = a.components;
        } else if (a.components == 1) {
            extent.components = b.components;
        } else {
            return error.ShapeMismatch;
        }
        return extent;
    }

    pub fn map_range(builder: *Builder, map: MapRange) Error!Id {
        try builder.check_known(map.input);
        const extent = builder.nodes[map.input.index].extent;
        if (!std.math.isFinite(map.output_low)) return error.NotFinite;
        if (!std.math.isFinite(map.output_high)) return error.NotFinite;
        const input_width = map.input_high - map.input_low;
        if (input_width == 0) return error.InvalidRange;
        if (!std.math.isFinite(input_width)) return error.InvalidRange;
        return builder.push_shaped(.{ .map_range = map }, extent);
    }

    pub fn wave(builder: *Builder, source: Wave) Error!Id {
        if (!std.math.isFinite(source.hz)) return error.NotFinite;
        const extent = try builder.staggered_extent(source.stagger);
        return builder.push_shaped(.{ .wave = source }, extent);
    }

    pub fn tween(builder: *Builder, source: Tween) Error!Id {
        if (source.previous) |previous| try builder.check_scalar(previous);
        if (source.start.index >= builder.cue_table.count) return error.UnknownCue;
        if (!std.math.isFinite(source.from)) return error.NotFinite;
        if (!std.math.isFinite(source.to)) return error.NotFinite;
        if (source.duration.flicks <= 0) return error.InvalidDuration;
        if (!source.ease.valid()) return error.InvalidEase;
        var extent = try builder.cued_extent(source.start, source.cue_by_lane, source.stagger);
        if (source.previous) |previous| extent = try joined(&.{ extent, builder.nodes[previous.index].extent });
        return builder.push_shaped(.{ .tween = source }, extent);
    }

    /// A noise whose seed is `source.seed` hashed with the graph's seed.
    pub fn noise(builder: *Builder, source: Noise) Error!Id {
        if (!std.math.isFinite(source.hz)) return error.NotFinite;
        if (source.hz <= 0) return error.InvalidRate;
        if (source.hz > Noise.hz_max) return error.InvalidRate;
        return builder.push_shaped(.{ .noise = source.derive(builder.seed) }, builder.source_extent());
    }

    /// A spring toward the goals of `source.goals`, as `motion.zig` explains.
    pub fn spring(builder: *Builder, source: motion.Spring) Error!Id {
        try builder.check_goals(source.goals, source.from);
        const law = try spring_law(source.time, source.overshoot);
        const extent = try builder.staggered_extent(source.stagger);
        return builder.push_shaped(.{ .motion = .{
            .from = source.from,
            .goals = source.goals,
            .law = .{ .spring = law },
            .stagger = source.stagger,
        } }, extent);
    }

    /// A Newtonian move toward the goals of `source.goals`, as `motion.zig` explains.
    pub fn newtonian(builder: *Builder, source: motion.Newtonian) Error!Id {
        try builder.check_goals(source.goals, source.from);
        const limits = try newtonian_limits(source.speed, source.accel, source.decel);
        const extent = try builder.staggered_extent(source.stagger);
        return builder.push_shaped(.{ .motion = .{
            .from = source.from,
            .goals = source.goals,
            .law = .{ .newtonian = limits },
            .stagger = source.stagger,
        } }, extent);
    }

    /// A spring chasing the signal `source.target`, as section 9 explains.
    pub fn chase(builder: *Builder, source: Chase) Error!Id {
        try builder.check_scalar(source.target);
        try builder.check_start();
        if (!simulation.within_bound(source.from)) return error.NotFinite;
        const law = try spring_law(source.time, source.overshoot);
        const params = try builder.params_of(.{ source.time_from, source.overshoot_from, null });
        return builder.push_shaped(.{ .chase = .{
            .target = source.target,
            .from = source.from,
            .law = law,
            .params = params,
        } }, builder.nodes[source.target.index].extent);
    }

    /// A wave whose rate is the value of `source.rate` at each step, simulated (section 14).
    pub fn oscillator(builder: *Builder, source: Oscillator) Error!Id {
        try builder.check_scalar(source.rate);
        try builder.check_start();
        if (std.math.isNan(source.phase)) return error.NotFinite;
        if (!(source.phase >= 0 and source.phase < 1)) return error.InvalidPhase;
        return builder.push_shaped(.{ .oscillator = source }, builder.nodes[source.rate.index].extent);
    }

    /// The value of the track `id` at each time, held forward from each sample (section 14).
    pub fn track(builder: *Builder, id: TrackId) Error!Id {
        if (id.index >= builder.tracks.count) return error.UnknownTrack;
        return builder.push(.{ .track = id });
    }

    /// A goal follower, as `simulation.zig` explains, whose seed is `source.seed` hashed with the
    /// graph's seed.
    pub fn follow(builder: *Builder, source: Follow) Error!Id {
        try builder.check_start();
        if (!simulation.within_bound(source.from)) return error.NotFinite;
        const span = source.regions;
        if (span.count == 0) return error.UnknownRegions;
        if (span.first > builder.regions.len) return error.UnknownRegions;
        if (span.count > builder.regions.len - span.first) return error.UnknownRegions;
        const law: motion.Law = switch (source.mover) {
            .spring => |mover| .{ .spring = try spring_law(mover.time, mover.overshoot) },
            .newtonian => |mover| .{
                .newtonian = try newtonian_limits(mover.speed, mover.accel, mover.decel),
            },
        };
        const from = source.mover_from;
        const params = switch (source.mover) {
            .spring => spring: {
                if (from.speed != null or from.accel != null or from.decel != null) {
                    return error.InvalidParameter;
                }
                break :spring try builder.params_of(.{ from.time, from.overshoot, null });
            },
            .newtonian => newtonian: {
                if (from.time != null or from.overshoot != null) return error.InvalidParameter;
                break :newtonian try builder.params_of(.{ from.speed, from.accel, from.decel });
            },
        };
        if (!std.math.isFinite(source.tolerance)) return error.NotFinite;
        if (source.tolerance < 0) return error.InvalidTolerance;
        if (source.pause_min.flicks < 0) return error.InvalidPause;
        if (source.pause_max.flicks < source.pause_min.flicks) return error.InvalidPause;
        const pause_max_steps = steps_rounded_up(source.pause_max);
        if (pause_max_steps > simulation.pause_steps_max) return error.InvalidPause;
        return builder.push_shaped(.{ .follow = .{
            .from = source.from,
            .tolerance = source.tolerance,
            .seed = noise_hash(builder.seed, source.seed),
            .law = law,
            .regions = span,
            .pause_min_steps = @intCast(steps_rounded_up(source.pause_min)),
            .pause_max_steps = @intCast(pause_max_steps),
            .pick = source.pick,
            .params = params,
        } }, builder.source_extent());
    }

    /// A shift register, as `simulation.zig` explains, whose seed is `source.seed` hashed with
    /// the graph's seed.
    pub fn shift(builder: *Builder, source: Shift) Error!Id {
        try builder.check_start();
        if (source.buckets == 0) return error.InvalidBuckets;
        if (source.buckets > simulation.buckets_max) return error.InvalidBuckets;
        if (!std.math.isFinite(source.low)) return error.NotFinite;
        if (!std.math.isFinite(source.high)) return error.NotFinite;
        if (std.math.isNan(source.odds)) return error.NotFinite;
        if (!(source.odds >= 0 and source.odds <= 1)) return error.InvalidOdds;
        if (source.period.flicks <= 0) return error.InvalidDuration;
        const period_flicks: u64 = @intCast(source.period.flicks);
        if (period_flicks > simulation.period_flicks_max) return error.InvalidDuration;
        if (period_flicks < source.buckets * step_flicks) return error.InvalidDuration;
        return builder.push_shaped(.{ .shift = .{
            .low = source.low,
            .high = source.high,
            .odds = source.odds,
            .seed = noise_hash(builder.seed, source.seed),
            .period_flicks = period_flicks,
            .buckets = source.buckets,
            .shape = source.shape,
        } }, builder.source_extent());
    }

    /// A delay, open until `close` gives it its input, as section 10 explains.
    pub fn delay(builder: *Builder, initial: f64) Error!Id {
        try builder.check_start();
        if (!simulation.within_bound(initial)) return error.NotFinite;
        const op: Op = .{ .delay = .{ .input = null, .initial = initial } };
        const id = try builder.push_shaped(op, builder.source_extent());
        builder.delays_open += 1;
        return id;
    }

    /// Gives the delay `delay_id` its input, which can be any node built so far, before or after
    /// the delay, itself included.
    pub fn close(builder: *Builder, delay_id: Id, input_id: Id) Error!void {
        assert(!builder.finished);
        try builder.check_known(delay_id);
        try builder.check_scalar(input_id);
        const node = &builder.nodes[delay_id.index];
        switch (node.op) {
            .delay => |*op| {
                if (op.input != null) return error.DelayClosed;
                const lanes = builder.nodes[input_id.index].extent.lanes;
                if (lanes != 1 and lanes != node.extent.lanes) return error.LaneMismatch;
                assert(builder.delays_open > 0);
                op.input = input_id;
                builder.delays_open -= 1;
            },
            else => return error.NotADelay,
        }
    }

    /// A value bouncing between two walls, as two nodes: the position, which fires an event at
    /// each wall, and the velocity. Both or neither are built.
    pub fn bounce(builder: *Builder, source: Bounce) Error!BounceIds {
        for ([_]f64{ source.low, source.high, source.speed }) |parameter| {
            if (!std.math.isFinite(parameter)) return error.NotFinite;
        }
        if (source.low >= source.high) return error.InvalidRange;
        if (source.speed <= 0) return error.InvalidLimit;
        if (source.start.index >= builder.cue_table.count) return error.UnknownCue;
        const leg_flicks = (source.high - source.low) * flicks_per_second_float / source.speed;
        // A leg of at least a flick puts each hit on its own flick. NaN fails both.
        if (!(leg_flicks >= 1)) return error.InvalidDuration;
        if (!(leg_flicks < bounce_flicks_max)) return error.InvalidDuration;
        const extent = try builder.cued_extent(source.start, source.cue_by_lane, source.stagger);
        if (builder.nodes.len - builder.node_count < 2) return error.NodeCapacityExceeded;
        const output_count: u64 = extent.count();
        if (builder.slab_count + 2 * output_count > builder.slab_count_max) {
            return error.SlabCapacityExceeded;
        }
        var node: BounceNode = .{
            .low = source.low,
            .high = source.high,
            .speed = source.speed,
            .leg_flicks = leg_flicks,
            .start = source.start,
            .output = .position,
            .stagger = source.stagger,
            .cue_by_lane = source.cue_by_lane,
        };
        const position = builder.push_shaped(.{ .bounce = node }, extent) catch unreachable;
        node.output = .velocity;
        const velocity = builder.push_shaped(.{ .bounce = node }, extent) catch unreachable;
        assert(velocity.index == position.index + 1);
        return .{ .position = position, .velocity = velocity };
    }

    /// A gate on `source.input` at `source.level`, which fires an event at each crossing, as
    /// section 11 explains. It runs on the fixed step, so it needs the start cue.
    pub fn crossing(builder: *Builder, source: Crossing) Error!Id {
        try builder.check_scalar(source.input);
        try builder.check_start();
        if (!std.math.isFinite(source.level)) return error.NotFinite;
        return builder.push_shaped(.{ .crossing = source }, builder.nodes[source.input.index].extent);
    }

    /// The count of the span's cues at or before the time, which fires an event at each of them.
    pub fn cues(builder: *Builder, span: CueSpan) Error!Id {
        assert(builder.cue_table.count <= builder.cue_table.times.len);
        if (span.count == 0) return error.UnknownCue;
        if (span.first.index >= builder.cue_table.count) return error.UnknownCue;
        if (span.count > builder.cue_table.count - span.first.index) return error.UnknownCue;
        return builder.push(.{ .cues = span });
    }

    /// A live value, set by `State.set_input` each read, as section 12 explains. A program with
    /// one is not seekable.
    pub fn input(builder: *Builder, source: Input) Error!Id {
        if (std.math.isNan(source.low) or std.math.isNan(source.high)) return error.NotFinite;
        if (!std.math.isFinite(source.initial)) return error.NotFinite;
        if (source.low > source.high) return error.InvalidRange;
        if (source.initial < source.low or source.initial > source.high) return error.InvalidRange;
        return builder.push(.{ .input = source });
    }

    /// The clip `clip` of the sample table played back, a pure signal, as `recording.zig`
    /// explains.
    pub fn recorded(builder: *Builder, clip: recording_module.Clip) Error!Id {
        if (clip.count == 0) return error.UnknownSamples;
        if (clip.first > builder.samples.len) return error.UnknownSamples;
        if (clip.count > builder.samples.len - clip.first) return error.UnknownSamples;
        var hull = Range.point(builder.samples[clip.first].value);
        for (builder.samples[clip.first..][0..clip.count]) |sample| {
            hull = hull.hull(Range.point(sample.value));
        }
        return builder.push(.{ .recorded = .{ .clip = clip, .low = hull.low, .high = hull.high } });
    }

    fn check_goals(builder: *const Builder, path: motion.Path, from: f64) Error!void {
        if (!simulation.within_bound(from)) return error.NotFinite;
        if (path.count == 0) return error.UnknownGoals;
        if (path.first > builder.goals.len) return error.UnknownGoals;
        if (path.count > builder.goals.len - path.first) return error.UnknownGoals;
        for (builder.goals[path.first..][0..path.count]) |goal| {
            if (goal.cue.index >= builder.cue_table.count) return error.UnknownCue;
            if (!simulation.within_bound(goal.value)) return error.NotFinite;
        }
    }

    fn check_start(builder: *const Builder) Error!void {
        assert(builder.cue_table.count <= builder.cue_table.times.len);
        if (builder.start.index >= builder.cue_table.count) return error.UnknownCue;
    }

    /// The program built so far. Nothing can be added after this, and every delay must be closed.
    pub fn finish(builder: *Builder) Program {
        assert(!builder.finished);
        assert(builder.slab_count <= builder.slab_count_max);
        assert(builder.delays_open == 0);
        builder.finished = true;
        const program: Program = .{
            .nodes = builder.nodes[0..builder.node_count],
            .cues = builder.cue_table,
            .goals = builder.goals,
            .regions = builder.regions,
            .samples = builder.samples,
            .tracks = builder.tracks,
            .start = builder.start,
            .simulated = builder.simulated,
            .slab_count = builder.slab_count,
            .recent_count = builder.recent_count,
            .lane_first = builder.lane_first,
        };
        program.assert_valid();
        return program;
    }

    fn check_known(builder: *const Builder, id: Id) Error!void {
        assert(builder.node_count <= builder.nodes.len);
        if (id.index >= builder.node_count) return error.UnknownNode;
    }

    /// A node built so far whose output is one value, as every op but arithmetic, `minimum`,
    /// `maximum`, `apply`, `map_range`, and `pick` reads (sections 15 and 17).
    fn check_scalar(builder: *const Builder, id: Id) Error!void {
        try builder.check_known(id);
        if (builder.nodes[id.index].extent.components != 1) return error.ShapeMismatch;
    }

    /// The parameter slots of a node whose parameters may come from `ids`, each a node built
    /// already, as section 14 explains.
    fn params_of(builder: *const Builder, ids: [3]?Id) Error![3]u32 {
        var result: [3]u32 = @splat(simulation.no_param);
        for (&result, ids) |*slot, maybe| {
            const id = maybe orelse continue;
            try builder.check_scalar(id);
            // A node has one law, so its parameter has one lane (section 16).
            if (builder.nodes[id.index].extent.lanes != 1) return error.LaneMismatch;
            slot.* = id.index;
        }
        return result;
    }

    /// The extent of a node of one value in the open region's lanes, refused outside one.
    fn region_extent(builder: *const Builder) Error!Extent {
        const count = builder.lanes orelse return error.LaneMismatch;
        assert(count >= 1 and count <= lanes_max);
        assert(@as(u64, builder.lane_first) + count <= @as(u64, std.math.maxInt(u32)) + 1);
        return .{ .lanes = count, .components = 1, .laned = true };
    }

    /// A seeded source's or a delay's extent: the region's lanes, or one lane outside a region.
    fn source_extent(builder: *const Builder) Extent {
        if (builder.lanes == null) return one_lane;
        return builder.region_extent() catch unreachable;
    }

    /// The extent of a cued source, a tween or a bounce: with a cue by lane, the region's lanes,
    /// refused outside a region, and each lane's cue in the table; otherwise as staggered.
    fn cued_extent(builder: *const Builder, start: Cue, cue_by_lane: bool, stagger: Time) Error!Extent {
        if (!cue_by_lane) return builder.staggered_extent(stagger);
        const extent = try builder.region_extent();
        if (stagger.flicks != 0) _ = try builder.staggered_extent(stagger);
        const last = @as(u64, start.index) + builder.lane_first + extent.lanes - 1;
        if (last >= builder.cue_table.count) return error.UnknownCue;
        return extent;
    }

    /// A staggered source's extent: one lane when it is not staggered, the region's otherwise,
    /// refusing a stagger whose last lane's offset overflows (section 16).
    fn staggered_extent(builder: *const Builder, stagger: Time) Error!Extent {
        if (stagger.flicks == 0) return one_lane;
        const extent = try builder.region_extent();
        const last: i64 = @intCast(@as(u64, builder.lane_first) + extent.lanes - 1);
        _ = std.math.mul(i64, last, stagger.flicks) catch return error.InvalidDuration;
        return extent;
    }

    /// The extent of an op that reads nodes of `extents`, one value a lane: the most lanes of
    /// theirs, refusing two counts above 1 (section 16).
    fn joined(extents: []const Extent) Error!Extent {
        var result = one_lane;
        for (extents) |extent| {
            result.laned = result.laned or extent.laned;
            if (extent.lanes == 1) continue;
            if (result.lanes > 1 and result.lanes != extent.lanes) return error.LaneMismatch;
            result.lanes = extent.lanes;
        }
        return result;
    }

    /// A node of one value and one lane.
    pub fn push(builder: *Builder, op: Op) Error!Id {
        return builder.push_shaped(op, one_lane);
    }

    /// `push` with an output of `extent`.
    fn push_shaped(builder: *Builder, op: Op, extent: Extent) Error!Id {
        assert(!builder.finished);
        assert(builder.slab_count <= builder.slab_count_max);
        assert(extent.components >= 1 and extent.components <= components_max);
        assert(extent.lanes >= 1 and extent.lanes <= lanes_max);
        if (extent.lanes > 1) assert(extent.laned);
        if (builder.node_count == builder.nodes.len) return error.NodeCapacityExceeded;
        const output_count = @as(u64, extent.lanes) * extent.components;
        const count = output_count + op.cache_count(output_count);
        assert(count > 0);
        if (builder.slab_count + count > builder.slab_count_max) {
            return error.SlabCapacityExceeded;
        }
        // A reader may keep a simulated node's region twice: in place, and in its copy.
        const copy: u64 = if (op.simulated()) count else 0;
        const id: Id = .{ .index = builder.node_count };
        builder.nodes[id.index] = .{
            .op = op,
            .offset = builder.slab_count,
            .extent = extent,
        };
        builder.node_count += 1;
        builder.slab_count += @intCast(count);
        builder.recent_count += @intCast(copy);
        if (op.simulated()) builder.simulated = true;
        return id;
    }
};

const one_lane: Extent = .{ .lanes = 1, .components = 1 };

/// The law of a spring with this `time` and `overshoot`, or the refusal of either.
fn spring_law(time: Time, overshoot: f64) Builder.Error!motion.SpringLaw {
    if (time.flicks <= 0) return error.InvalidDuration;
    if (std.math.isNan(overshoot)) return error.NotFinite;
    if (!(overshoot >= 0 and overshoot < 1)) return error.InvalidOvershoot;
    return motion.SpringLaw.of(time, overshoot);
}

/// The limits of a Newtonian move, or the refusal of one of them.
fn newtonian_limits(speed: f64, accel: f64, decel: f64) Builder.Error!motion.Limits {
    for ([_]f64{ speed, accel, decel }) |limit| {
        if (!simulation.within_bound(limit)) return error.NotFinite;
        if (limit <= 0) return error.InvalidLimit;
    }
    return .{ .speed = speed, .accel = accel, .decel = decel };
}

/// Passes of `Program.ranges` that widen each delay to what it needs, before it tries wider ranges.
const delay_rounds_max = 16;

/// Passes of `Program.ranges` that try wider ranges for the delays: from 2^-40 of an end's
/// magnitude, doubling, which passes the largest f64 well within this many.
const widen_rounds_max = 1100;

/// A delay's range for widening round `round`: each finite end moved out by 2^(round - 40) of its
/// magnitude, or of 1 if it is smaller.
fn widen_round(range: Range, round: usize) Range {
    assert(round < widen_rounds_max);
    const factor = std.math.ldexp(@as(f64, 1), @as(i32, @intCast(round)) - 40);
    return .{
        .low = range.low - @max(@abs(range.low), 1) * factor,
        .high = range.high + @max(@abs(range.high), 1) * factor,
    };
}

/// The hull of two ends, with the margin of an interpolation between them.
fn hull_widened(a: f64, b: f64) Range {
    const hull = Range.of(a, b);
    return hull.widen(hull.scale(), range_module.margin_rounding);
}

/// The range of a map: its input's ends mapped, in order, with the margin of its form, relative to
/// the larger output end and to how far past the input range the ends reach.
fn map_range_range(map: *const MapRange, input: Range) Range {
    const width = map.input_high - map.input_low;
    const low = (input.low - map.input_low) / width;
    const high = (input.high - map.input_low) / width;
    const result = Range.of(
        map.output_low * (1 - low) + map.output_high * low,
        map.output_low * (1 - high) + map.output_high * high,
    );
    const outputs = @max(@abs(map.output_low), @abs(map.output_high));
    const reach = @max(1, @max(@abs(low), @abs(high)));
    return result.widen(@max(result.scale(), outputs * reach), range_module.margin_rounding);
}

/// The range of `function` over `input`, by the rules of `range.zig`, sections 2a and 2b.
fn function_range(function: Function, input: Range) Range {
    return switch (function) {
        .abs => range_module.abs(input),
        .sin => range_module.sine(input),
        .cos => range_module.cosine(input),
        .exp => range_module.exponential(input),
        .ln => range_module.logarithm(input),
        .sqrt => range_module.monotone(input, elementary.square_root),
        .floor => range_module.monotone(input, floor_of),
        .round => range_module.monotone(input, elementary.round_half_away),
        .pow => |n| range_module.power(input, n),
    };
}

fn floor_of(x: f64) f64 {
    return @floor(x);
}

/// The range of a tween: `from`, `to`, and the form at the eased progress's extremes, which the
/// cubic Bezier keeps within the hull of 0, its two y controls, and 1, then `previous` before it.
fn tween_range(tween: *const Tween, previous: ?Range) Range {
    const eased_low = @min(0, @min(tween.ease.y1, tween.ease.y2));
    const eased_high = @max(1, @max(tween.ease.y1, tween.ease.y2));
    const ends = Range.of(tween.from, tween.to);
    const result = ends.hull(Range.of(
        tween.from * (1 - eased_low) + tween.to * eased_low,
        tween.from * (1 - eased_high) + tween.to * eased_high,
    ));
    const reach = @max(@abs(eased_low), eased_high);
    const magnitude = @max(result.scale(), ends.scale() * reach);
    const widened = result.widen(magnitude, range_module.margin_rounding);
    return if (previous) |range| widened.hull(range) else widened;
}

/// The whole steps that `duration`, at least zero, lasts, rounded up.
pub fn steps_rounded_up(duration: Time) u64 {
    assert(duration.flicks >= 0);
    const flicks: u64 = @intCast(duration.flicks);
    return std.math.divCeil(u64, flicks, step_flicks) catch unreachable;
}

/// The reader of a program: its slab, its checkpoints, and `eval` and `events` (`state.zig`).
pub const State = @import("state.zig").State;

pub const step_flicks: u64 = @intCast(simulation.step.flicks);
pub const step_flicks_float: f64 = @floatFromInt(simulation.step.flicks);
pub const flicks_per_second_float: f64 = @floatFromInt(time_module.flicks_per_second);
/// Steps a second, exact, so a slope over a step in units per second is exact up to its rounding.
pub const steps_per_second: f64 = 480;

comptime {
    assert(step_flicks * 480 == time_module.flicks_per_second);
}

pub fn node_values(nodes: []const Node, slab: []const f64, id: Id) []const f64 {
    const node = &nodes[id.index];
    return slab[node.offset..][0..node.extent.count()];
}

test {
    _ = @import("state.zig");
    _ = @import("graph_test/ops.zig");
    _ = @import("graph_test/tween.zig");
    _ = @import("graph_test/readers.zig");
    _ = @import("graph_test/motion.zig");
    _ = @import("graph_test/simulated.zig");
    _ = @import("graph_test/events.zig");
    _ = @import("graph_test/ranges.zig");
    _ = @import("graph_test/tracks.zig");
    _ = @import("graph_test/lanes.zig");
    _ = @import("graph_test/functions.zig");
}
