//! The signal graph: a flat, sorted array of nodes, and one slab of values per reader.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. One Program, One State per Reader
//! A `Program` is the immutable node array. A `State` is one reader's slab of values, so the UI and
//! the audio thread each hold a state over the same program, or over a copy of it where they do not
//! share memory. A second reader costs one more slab, and reading never writes to the program.
//!
//! ## 2. The Slab
//! Every node's output lives in the slab at an offset, as `lanes * components` f64. Each op loops
//! over that extent, so many values cost no new layout: lanes and components are both 1 today, and
//! a thousand 2D values would be 2,000 f64 at one offset. f64 is the one value type, because a
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
//! ## 13. TigerStyle Invariants
//! - Capacities come from the caller, and the builder refuses what does not fit, by name.
//! - `eval` allocates nothing, takes no lock, and is one bounded pass over the node array. A motion
//!   node folds over at most its own goals. A simulated program first runs at most
//!   `checkpoint_interval - 1` steps once the checkpoints before the time are filled, and the
//!   steps since the last one filled otherwise.
//! - `events` allocates nothing and takes no lock. Its work is the seek `eval` would make to t0,
//!   the steps the range spans, one more pass, and for each event at most `out.len` moves of the
//!   events kept. A source that sorts after a full buffer only counts, by arithmetic for a bounce
//!   and cues, and a motion runs at most 131 closed forms per goal in the range.
//! - `ranges` and `classes` allocate nothing and are bounded: at most `delay_rounds_max` plus
//!   `widen_rounds_max` plus one forward passes, and `3 * node_count + 1` passes.
//! - A recording appends at most one sample per committed pass, and never past its table.
//! - Offsets are consecutive from 0, so the slab has no gaps and no node overlaps another.

const std = @import("std");
const assert = std.debug.assert;
const Cue = @import("cue.zig").Cue;
const Cues = @import("cue.zig").Cues;
const Ease = @import("ease.zig").Ease;
const event_module = @import("event.zig");
const Collector = event_module.Collector;
pub const Event = event_module.Event;
pub const Events = event_module.Events;
const motion = @import("motion.zig");
const Goal = motion.Goal;
const Motion = motion.Motion;
const Noise = @import("noise.zig").Noise;
const range_module = @import("range.zig");
pub const Class = range_module.Class;
pub const Range = range_module.Range;
pub const Report = range_module.Report;
const recording_module = @import("recording.zig");
const Recording = recording_module.Recording;
const Sample = recording_module.Sample;
const noise_hash = @import("noise.zig").hash;
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

    /// The number of f64 in the output. The builder refuses an extent where this overflows.
    fn count(extent: Extent) u32 {
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

    /// The value at or after `start_time`.
    fn value_after(tween: *const Tween, time: Time, start_time: Time) f64 {
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

    pub const Output = enum { position, velocity };

    /// The flicks from the start of hit `k`, `ceil(k * leg_flicks)`, which is the one definition
    /// of a hit time. Hit 0 is the start, which is not a hit.
    fn hit(bounce: *const BounceNode, k: u64) u64 {
        assert(bounce.leg_flicks >= 1);
        const product = @as(f64, @floatFromInt(k)) * bounce.leg_flicks;
        // Past 2^53 flicks, k * leg_flicks no longer names a flick exactly.
        assert(product < bounce_flicks_max);
        return @intFromFloat(@ceil(product));
    }

    /// The legs completed at `elapsed` flicks from the start: the largest k whose hit is at or
    /// before it. The quotient is within one of it either way, so one correction each way finds it.
    fn legs(bounce: *const BounceNode, elapsed: u64) u64 {
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
    fn hits_before(bounce: *const BounceNode, time: Time, start_time: Time) u64 {
        if (time.flicks <= start_time.flicks) return 0;
        const elapsed: u64 = @bitCast(time.flicks -% start_time.flicks);
        return bounce.legs(elapsed - 1);
    }

    /// The output at `time`, from the start at `start_time`.
    fn sample(bounce: *const BounceNode, time: Time, start_time: Time) f64 {
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
    fn crosses(crossing: *const Crossing, a: f64, b: f64) bool {
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

pub const Op = union(enum) {
    constant: f64,
    add: Binary,
    multiply: Binary,
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

    /// The f64 a node of this op keeps in the slab after an output of `output_count` f64, for a
    /// cache or a simulation's state. Section 9 explains the layout of a simulated node.
    fn cache_count(op: *const Op, output_count: u64) u64 {
        assert(output_count > 0);
        return switch (op.*) {
            .motion => motion.cursor_count,
            .chase => |chase| 3 * output_count + law_cache_count(chase.params, true),
            .delay => 2 * output_count,
            .follow => |follow| 2 * output_count + follower_slots +
                law_cache_count(follow.params, follow.law == .spring),
            // Its values at the steps before and after, then its phase.
            .oscillator => 3 * output_count,
            .shift => |shift| 2 * output_count + 1 + shift.buckets,
            // The input at the last step, then whether there is one.
            .crossing => output_count + 1,
            .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .bounce, .cues => 0,
            .input, .recorded, .track => 0,
        };
    }

    /// Whether a node of this op runs on the fixed step, as section 9 explains.
    fn simulated(op: *const Op) bool {
        return switch (op.*) {
            .chase, .follow, .shift, .delay, .crossing, .oscillator => true,
            .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .motion => false,
            .bounce, .cues, .input, .recorded, .track => false,
        };
    }

    /// The class of this op alone, before its inputs', as section 12 explains.
    fn class(op: *const Op) Class {
        return switch (op.*) {
            .constant, .add, .multiply, .map_range, .wave, .tween, .noise => .pure,
            .bounce, .cues, .recorded, .track => .pure,
            .motion => .exact,
            .chase, .follow, .shift, .delay, .crossing, .oscillator => .simulated,
            .input => .live,
        };
    }

    /// The nodes this op reads, at most four, null where there are fewer. A parameter's node is
    /// an input too (section 14).
    fn inputs(op: *const Op) [4]?Id {
        return switch (op.*) {
            .add, .multiply => |binary| .{ binary.left, binary.right, null, null },
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
            .input, .recorded, .track => @splat(null),
        };
    }
};

/// A follower's own state after its before and after values: velocity, goal, goals drawn, steps
/// of pause left, whether it arrived at this step, and the goal it last arrived at.
const follower_slots = 6;
const follower_slot_arrived = 4;
const follower_slot_arrived_goal = 5;

/// The f64 a spring with a parameter from a node keeps after its own state: the time and the
/// overshoot its law was last worked out from, then that law's omega, zeta, and damped hz.
const spring_cache_count = 5;

/// The least a Newtonian limit from a node can be; a smaller value is clamped up (section 14).
const limit_min: f64 = 0x1p-20;

/// The largest overshoot from a node; a larger value is clamped down (section 14).
const overshoot_max: f64 = 0.99;

/// The node of parameter `slot`, or null when it is constant.
fn param(params: [3]u32, slot: u32) ?Id {
    if (params[slot] == simulation.no_param) return null;
    return .{ .index = params[slot] };
}

fn any_param(params: [3]u32) bool {
    for (params) |id| if (id != simulation.no_param) return true;
    return false;
}

/// The f64 of a law cache after a node's own state: a spring with a parameter from a node keeps
/// one, and nothing else does.
fn law_cache_count(params: [3]u32, spring: bool) u64 {
    return if (spring and any_param(params)) spring_cache_count else 0;
}

/// The value of parameter node `id` at this pass: its first lane.
fn param_value(program: *const Program, slab: []const f64, id: Id) f64 {
    const value = node_values(program.nodes, slab, id)[0];
    assert(std.math.isFinite(value));
    return value;
}

/// The law of a spring at this step: `fixed`, with its omega from a time node and its damping from
/// an overshoot node where it has them, each clamped into its domain. Cached in `cache` with the
/// values it came from, so a parameter that holds costs two compares a step (section 14).
fn spring_law_at(
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
fn newtonian_limits_at(
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
fn law_cache_reset(cache: []f64) void {
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
    slab_count: u32,

    fn assert_valid(program: Program) void {
        var offset: u64 = 0;
        var simulated_count: u32 = 0;
        for (program.nodes, 0..) |*node, index| {
            assert(node.offset == offset);
            offset += node.extent.count() + node.op.cache_count(node.extent.count());
            if (node.op.simulated()) simulated_count += 1;
            switch (node.op) {
                .constant, .wave, .noise, .shift => {},
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
                .add, .multiply => |op| {
                    assert(op.left.index < index);
                    assert(op.right.index < index);
                },
                .map_range => |op| assert(op.input.index < index),
                .tween => |op| {
                    assert(op.start.index < program.cues.count);
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
    slab_count_max: u32,
    /// The table of `Options.cues`. Not named `cues`, which is the op of section 11.
    cue_table: *const Cues,
    goals: []const Goal,
    regions: []const simulation.Region,
    samples: []const Sample,
    tracks: *const Tracks,
    start: Cue,
    seed: u64,
    /// The extent of every node built, 1 by 1 until a later step gives each node its own.
    extent: Extent,
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
        /// A constant or a parameter that is infinite or NaN, or an input end that is NaN.
        NotFinite,
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
    };

    pub fn init(nodes: []Node, options: Options) Builder {
        assert(nodes.len <= std.math.maxInt(u32));
        return .{
            .nodes = nodes,
            .node_count = 0,
            .slab_count = 0,
            .slab_count_max = options.slab_count_max,
            .cue_table = options.cues,
            .goals = options.goals,
            .regions = options.regions,
            .samples = options.samples,
            .tracks = options.tracks,
            .start = options.start,
            .seed = options.seed,
            .extent = .{ .lanes = 1, .components = 1 },
            .simulated = false,
            .delays_open = 0,
            .finished = false,
        };
    }

    pub fn constant(builder: *Builder, value: f64) Error!Id {
        if (!std.math.isFinite(value)) return error.NotFinite;
        return builder.push(.{ .constant = value });
    }

    pub fn add(builder: *Builder, left: Id, right: Id) Error!Id {
        try builder.check_known(left);
        try builder.check_known(right);
        return builder.push(.{ .add = .{ .left = left, .right = right } });
    }

    pub fn multiply(builder: *Builder, left: Id, right: Id) Error!Id {
        try builder.check_known(left);
        try builder.check_known(right);
        return builder.push(.{ .multiply = .{ .left = left, .right = right } });
    }

    pub fn map_range(builder: *Builder, map: MapRange) Error!Id {
        try builder.check_known(map.input);
        if (!std.math.isFinite(map.output_low)) return error.NotFinite;
        if (!std.math.isFinite(map.output_high)) return error.NotFinite;
        const input_width = map.input_high - map.input_low;
        if (input_width == 0) return error.InvalidRange;
        if (!std.math.isFinite(input_width)) return error.InvalidRange;
        return builder.push(.{ .map_range = map });
    }

    pub fn wave(builder: *Builder, source: Wave) Error!Id {
        if (!std.math.isFinite(source.hz)) return error.NotFinite;
        return builder.push(.{ .wave = source });
    }

    pub fn tween(builder: *Builder, source: Tween) Error!Id {
        if (source.previous) |previous| try builder.check_known(previous);
        if (source.start.index >= builder.cue_table.count) return error.UnknownCue;
        if (!std.math.isFinite(source.from)) return error.NotFinite;
        if (!std.math.isFinite(source.to)) return error.NotFinite;
        if (source.duration.flicks <= 0) return error.InvalidDuration;
        if (!source.ease.valid()) return error.InvalidEase;
        return builder.push(.{ .tween = source });
    }

    /// A noise whose seed is `source.seed` hashed with the graph's seed.
    pub fn noise(builder: *Builder, source: Noise) Error!Id {
        if (!std.math.isFinite(source.hz)) return error.NotFinite;
        if (source.hz <= 0) return error.InvalidRate;
        if (source.hz > Noise.hz_max) return error.InvalidRate;
        return builder.push(.{ .noise = source.derive(builder.seed) });
    }

    /// A spring toward the goals of `source.goals`, as `motion.zig` explains.
    pub fn spring(builder: *Builder, source: motion.Spring) Error!Id {
        try builder.check_goals(source.goals, source.from);
        const law = try spring_law(source.time, source.overshoot);
        return builder.push(.{ .motion = .{
            .from = source.from,
            .goals = source.goals,
            .law = .{ .spring = law },
        } });
    }

    /// A Newtonian move toward the goals of `source.goals`, as `motion.zig` explains.
    pub fn newtonian(builder: *Builder, source: motion.Newtonian) Error!Id {
        try builder.check_goals(source.goals, source.from);
        const limits = try newtonian_limits(source.speed, source.accel, source.decel);
        return builder.push(.{ .motion = .{
            .from = source.from,
            .goals = source.goals,
            .law = .{ .newtonian = limits },
        } });
    }

    /// A spring chasing the signal `source.target`, as section 9 explains.
    pub fn chase(builder: *Builder, source: Chase) Error!Id {
        try builder.check_known(source.target);
        try builder.check_start();
        if (!std.math.isFinite(source.from)) return error.NotFinite;
        const law = try spring_law(source.time, source.overshoot);
        const params = try builder.params_of(.{ source.time_from, source.overshoot_from, null });
        return builder.push(.{ .chase = .{
            .target = source.target,
            .from = source.from,
            .law = law,
            .params = params,
        } });
    }

    /// A wave whose rate is the value of `source.rate` at each step, simulated (section 14).
    pub fn oscillator(builder: *Builder, source: Oscillator) Error!Id {
        try builder.check_known(source.rate);
        try builder.check_start();
        if (std.math.isNan(source.phase)) return error.NotFinite;
        if (!(source.phase >= 0 and source.phase < 1)) return error.InvalidPhase;
        return builder.push(.{ .oscillator = source });
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
        if (!std.math.isFinite(source.from)) return error.NotFinite;
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
        return builder.push(.{ .follow = .{
            .from = source.from,
            .tolerance = source.tolerance,
            .seed = noise_hash(builder.seed, source.seed),
            .law = law,
            .regions = span,
            .pause_min_steps = @intCast(steps_rounded_up(source.pause_min)),
            .pause_max_steps = @intCast(pause_max_steps),
            .pick = source.pick,
            .params = params,
        } });
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
        return builder.push(.{ .shift = .{
            .low = source.low,
            .high = source.high,
            .odds = source.odds,
            .seed = noise_hash(builder.seed, source.seed),
            .period_flicks = period_flicks,
            .buckets = source.buckets,
            .shape = source.shape,
        } });
    }

    /// A delay, open until `close` gives it its input, as section 10 explains.
    pub fn delay(builder: *Builder, initial: f64) Error!Id {
        try builder.check_start();
        if (!std.math.isFinite(initial)) return error.NotFinite;
        const id = try builder.push(.{ .delay = .{ .input = null, .initial = initial } });
        builder.delays_open += 1;
        return id;
    }

    /// Gives the delay `delay_id` its input, which can be any node built so far, before or after
    /// the delay, itself included.
    pub fn close(builder: *Builder, delay_id: Id, input_id: Id) Error!void {
        assert(!builder.finished);
        try builder.check_known(delay_id);
        try builder.check_known(input_id);
        const node = &builder.nodes[delay_id.index];
        switch (node.op) {
            .delay => |*op| {
                if (op.input != null) return error.DelayClosed;
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
        if (builder.nodes.len - builder.node_count < 2) return error.NodeCapacityExceeded;
        const output_count = @as(u64, builder.extent.lanes) * builder.extent.components;
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
        };
        const position = builder.push(.{ .bounce = node }) catch unreachable;
        node.output = .velocity;
        const velocity = builder.push(.{ .bounce = node }) catch unreachable;
        assert(velocity.index == position.index + 1);
        return .{ .position = position, .velocity = velocity };
    }

    /// A gate on `source.input` at `source.level`, which fires an event at each crossing, as
    /// section 11 explains. It runs on the fixed step, so it needs the start cue.
    pub fn crossing(builder: *Builder, source: Crossing) Error!Id {
        try builder.check_known(source.input);
        try builder.check_start();
        if (!std.math.isFinite(source.level)) return error.NotFinite;
        return builder.push(.{ .crossing = source });
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
        if (!std.math.isFinite(from)) return error.NotFinite;
        if (path.count == 0) return error.UnknownGoals;
        if (path.first > builder.goals.len) return error.UnknownGoals;
        if (path.count > builder.goals.len - path.first) return error.UnknownGoals;
        for (builder.goals[path.first..][0..path.count]) |goal| {
            if (goal.cue.index >= builder.cue_table.count) return error.UnknownCue;
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
        };
        program.assert_valid();
        return program;
    }

    fn check_known(builder: *const Builder, id: Id) Error!void {
        assert(builder.node_count <= builder.nodes.len);
        if (id.index >= builder.node_count) return error.UnknownNode;
    }

    /// The parameter slots of a node whose parameters may come from `ids`, each a node built
    /// already, as section 14 explains.
    fn params_of(builder: *const Builder, ids: [3]?Id) Error![3]u32 {
        var result: [3]u32 = @splat(simulation.no_param);
        for (&result, ids) |*slot, maybe| {
            const id = maybe orelse continue;
            try builder.check_known(id);
            slot.* = id.index;
        }
        return result;
    }

    fn push(builder: *Builder, op: Op) Error!Id {
        assert(!builder.finished);
        assert(builder.slab_count <= builder.slab_count_max);
        if (builder.node_count == builder.nodes.len) return error.NodeCapacityExceeded;
        const output_count = @as(u64, builder.extent.lanes) * builder.extent.components;
        const count = output_count + op.cache_count(output_count);
        assert(count > 0);
        if (builder.slab_count + count > builder.slab_count_max) {
            return error.SlabCapacityExceeded;
        }
        const id: Id = .{ .index = builder.node_count };
        builder.nodes[id.index] = .{
            .op = op,
            .offset = builder.slab_count,
            .extent = builder.extent,
        };
        builder.node_count += 1;
        builder.slab_count += @intCast(count);
        if (op.simulated()) builder.simulated = true;
        return id;
    }
};

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
        if (!std.math.isFinite(limit)) return error.NotFinite;
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
fn steps_rounded_up(duration: Time) u64 {
    assert(duration.flicks >= 0);
    const flicks: u64 = @intCast(duration.flicks);
    return std.math.divCeil(u64, flicks, step_flicks) catch unreachable;
}

/// One reader's values, in a slab the reader owns, and its checkpoints of a simulation.
pub const State = struct {
    program: Program,
    slab: []f64,
    evaluated: bool,
    /// Copies of the slab at every `checkpoint_interval` steps, from the first interval on.
    checkpoints: []f64,
    /// How many of `checkpoints` hold a copy, always the first ones.
    checkpoints_filled: u32,
    /// The step the slab's simulated state is at, or null if it holds none.
    step: ?u64,
    /// The cue generation the simulated state and the checkpoints were worked out under.
    generation: u64,
    /// The track generation they were worked out under (section 14).
    track_generation: u64,
    /// Steps run since `init`, for measuring what reads cost.
    steps_run: u64,
    /// The recordings `record` attached, each of one input, as section 12 explains.
    recordings: [recordings_max]Attached,
    recordings_count: u32,

    /// The most recordings a state writes at once.
    pub const recordings_max = 8;

    const Attached = struct {
        input: Id,
        recording: *Recording,
    };

    /// `slab` needs at least `program.slab_count` values, and only those are used. A simulated
    /// program has no checkpoints this way, so each read before the slab's own step runs every
    /// step from the start.
    pub fn init(program: Program, slab: []f64) State {
        return init_with_checkpoints(program, slab, &.{});
    }

    /// As `init`, with room for `checkpoints.len / program.slab_count` checkpoints, which each
    /// cover a second of a simulated program, as section 9 explains.
    pub fn init_with_checkpoints(program: Program, slab: []f64, checkpoints: []f64) State {
        assert(slab.len >= program.slab_count);
        program.assert_valid();
        const slab_used = slab[0..program.slab_count];
        @memset(slab_used, 0);
        for (program.nodes) |*node| switch (node.op) {
            .input => |op| @memset(slab_used[node.offset..][0..node.extent.count()], op.initial),
            else => {},
        };
        var room: usize = 0;
        if (program.simulated) {
            room = @min(checkpoints.len / program.slab_count, std.math.maxInt(u32));
        }
        return .{
            .program = program,
            .slab = slab_used,
            .evaluated = false,
            .checkpoints = checkpoints[0 .. room * program.slab_count],
            .checkpoints_filled = 0,
            .step = null,
            .generation = program.cues.generation,
            .track_generation = program.tracks.generation,
            .steps_run = 0,
            .recordings = undefined,
            .recordings_count = 0,
        };
    }

    /// Sets every lane of the input `id` to `value`, clamped into its declared range, until set
    /// again, as section 12 explains.
    pub fn set_input(state: *State, id: Id, to: f64) void {
        assert(id.index < state.program.nodes.len);
        assert(!std.math.isNan(to));
        const node = &state.program.nodes[id.index];
        const op = node.op.input;
        const clamped = std.math.clamp(to, op.low, op.high);
        assert(std.math.isFinite(clamped));
        @memset(state.slab[node.offset..][0..node.extent.count()], clamped);
    }

    /// From now on, each committed pass that reads the input `id` notes its time and value in
    /// `recording`, as `recording.zig` explains.
    pub fn record(state: *State, id: Id, recording: *Recording) void {
        assert(id.index < state.program.nodes.len);
        assert(state.program.nodes[id.index].op == .input);
        assert(state.recordings_count < recordings_max);
        state.recordings[state.recordings_count] = .{ .input = id, .recording = recording };
        state.recordings_count += 1;
    }

    /// Notes what a committed pass at `time` read of each recorded input.
    fn record_pass(state: *State, time: Time) void {
        for (state.recordings[0..state.recordings_count]) |attached| {
            const node = &state.program.nodes[attached.input.index];
            attached.recording.add(time, state.slab[node.offset]);
        }
    }

    /// Fills the slab with every node's value at `time`. A reader can ask for any time in any
    /// order: what carries over from an earlier call is a cache that cannot change a value.
    pub fn eval(state: *State, time: Time) void {
        assert(state.slab.len == state.program.slab_count);
        var weight: f64 = 0;
        if (state.program.simulated) weight = state.simulate_to(time);
        pass(&state.program, state.slab, time, .{ .between = weight });
        state.record_pass(time);
        state.evaluated = true;
    }

    /// The value of a node of one value, from the last `eval`.
    pub fn value(state: *const State, id: Id) f64 {
        const result = state.values(id);
        assert(result.len == 1);
        return result[0];
    }

    /// All the values of a node, from the last `eval`, lane after lane.
    pub fn values(state: *const State, id: Id) []const f64 {
        assert(state.evaluated);
        assert(id.index < state.program.nodes.len);
        return node_values(state.program.nodes, state.slab, id);
    }

    /// Every event with a time in `[t0, t1)`, in order of time, then source index, then lane, as
    /// `event.zig` explains. The earliest `out.len` are written to `out`, and the rest are counted.
    /// It brings a simulated state no further than the step `eval(t1)` needs, as section 11
    /// explains, and leaves the outputs of the slab at no particular time, so `value` asserts
    /// until the next `eval`.
    pub fn events(state: *State, t0: Time, t1: Time, out: []Event) Events {
        assert(state.slab.len == state.program.slab_count);
        assert(t0.flicks <= t1.flicks);
        var collector = Collector.init(out);
        state.evaluated = false;
        if (t0.flicks == t1.flicks) return collector.result();
        var report: Found = .{ .collector = &collector, .t0 = t0, .t1 = t1 };
        for (state.program.nodes, 0..) |*node, index| {
            const id: Id = .{ .index = @intCast(index) };
            switch (node.op) {
                .bounce => |*op| if (op.output == .position) {
                    events_bounce(&state.program, op, id, &report);
                },
                .cues => |span| events_cues(&state.program, span, id, &report),
                .motion => |*op| events_motion(&state.program, state.slab, node, op, id, &report),
                else => {},
            }
        }
        if (state.program.simulated) state.events_simulated(&report);
        return collector.result();
    }

    /// How many checkpoints the state has room for.
    pub fn checkpoints_count(state: *const State) u32 {
        if (state.checkpoints.len == 0) return 0;
        return @intCast(state.checkpoints.len / state.program.slab_count);
    }

    /// Brings the simulated state to the step after `time`, and returns how far `time` is past
    /// the step before it, as a fraction of a step. Section 9 explains.
    fn simulate_to(state: *State, time: Time) f64 {
        assert(state.program.simulated);
        const start = state.simulation_start();
        var target: u64 = 0;
        var weight: f64 = 0;
        if (time.flicks >= start.flicks) {
            // Wrapping, because the distance between two i64 only fits in a u64.
            const elapsed: u64 = @bitCast(time.flicks -% start.flicks);
            target = elapsed / step_flicks + 1;
            weight = @as(f64, @floatFromInt(elapsed % step_flicks)) / step_flicks_float;
        }
        state.run_to(target, start);
        assert(state.step.? == target);
        assert(weight >= 0);
        assert(weight < 1);
        return weight;
    }

    /// The time of the start cue, after dropping the simulated state and the checkpoints if a cue
    /// has moved since they were worked out, or what a track write since then reaches.
    fn simulation_start(state: *State) Time {
        assert(state.program.simulated);
        const cues = state.program.cues;
        if (cues.generation != state.generation) {
            state.generation = cues.generation;
            state.checkpoints_filled = 0;
            state.step = null;
        }
        const start = cues.at(state.program.start);
        const tracks = state.program.tracks;
        if (tracks.generation != state.track_generation) {
            const floor = tracks.floor_since(state.track_generation);
            state.track_generation = tracks.generation;
            state.forget_from(start, floor);
        }
        return start;
    }

    /// Drops the checkpoints, and the slab's own step, that hold a pass at or after `floor`, or
    /// everything when `floor` is null, as section 14 explains. Checkpoint k holds the passes of
    /// steps 0 to `k * checkpoint_interval - 1`, and the slab at step n those of steps 0 to n - 1.
    fn forget_from(state: *State, start: Time, floor: ?Time) void {
        const interval = simulation.checkpoint_interval;
        const at = floor orelse {
            state.checkpoints_filled = 0;
            state.step = null;
            return;
        };
        while (state.checkpoints_filled > 0) {
            const last_pass = @as(u64, state.checkpoints_filled) * interval - 1;
            if (step_time(start, last_pass).flicks < at.flicks) break;
            state.checkpoints_filled -= 1;
        }
        if (state.step) |live| {
            if (live > 0 and step_time(start, live - 1).flicks >= at.flicks) state.step = null;
        }
    }

    /// Brings the simulated state to step `target`, from the nearest of the slab's own step and
    /// the checkpoints before `target`.
    fn run_to(state: *State, target: u64, start: Time) void {
        const interval = simulation.checkpoint_interval;
        const nearest = @min(target / interval, state.checkpoints_filled);
        const live_usable = if (state.step) |live|
            live >= nearest * interval and live <= target
        else
            false;
        if (!live_usable) state.restore(nearest);
        state.advance_to(target, start, null);
    }

    /// Runs the steps from the slab's own step to `target`, storing each checkpoint it passes,
    /// and giving the events found at each step it leaves to `report`.
    fn advance_to(state: *State, target: u64, start: Time, report: ?*Found) void {
        const interval = simulation.checkpoint_interval;
        var live = state.step.?;
        assert(live <= target);
        while (live < target) {
            step_once(&state.program, state.slab, start, live, report);
            state.record_pass(step_time(start, live));
            live += 1;
            state.steps_run += 1;
            if (live % interval == 0) state.store(live / interval);
        }
        state.step = live;
        assert(state.step.? == target);
    }

    /// The events of the simulated nodes in the range of `report`, as section 11 explains: a seek
    /// to the first step whose events can be in the range, the steps of the range, each giving
    /// its events, then a read-only look at the last step, which commits nothing.
    fn events_simulated(state: *State, report: *Found) void {
        const start = state.simulation_start();
        const first = step_ceiling(start, report.t0);
        const last = step_ceiling(start, report.t1);
        assert(first <= last);
        state.run_to(first, start);
        state.advance_to(last, start, report);
        pass(&state.program, state.slab, step_time(start, last), .at_step);
        report_step(&state.program, state.slab, start, last, report);
        assert(state.step.? == last);
    }

    /// Copies the slab into checkpoint `index`, at step `index * checkpoint_interval`, if it is
    /// the next one to fill and there is room.
    fn store(state: *State, index: u64) void {
        assert(index > 0);
        assert(state.checkpoints_filled <= state.checkpoints_count());
        if (index != @as(u64, state.checkpoints_filled) + 1) return;
        if (index > state.checkpoints_count()) return;
        const size = state.slab.len;
        const first: usize = @intCast((index - 1) * size);
        @memcpy(state.checkpoints[first..][0..size], state.slab);
        state.checkpoints_filled += 1;
    }

    /// Puts the slab at checkpoint `index`, where checkpoint 0 is the start, rebuilt. An input
    /// keeps the value set last, since it has no past, as section 12 explains.
    fn restore(state: *State, index: u64) void {
        assert(index <= state.checkpoints_filled);
        if (index == 0) {
            for (state.program.nodes) |*node| reset_node(&state.program, state.slab, node);
        } else {
            const size = state.slab.len;
            const checkpoint = state.checkpoints[@intCast((index - 1) * size)..][0..size];
            for (state.program.nodes) |*node| {
                if (node.op == .input) continue;
                const count = node.extent.count() + node.op.cache_count(node.extent.count());
                const region = state.slab[node.offset..][0..@intCast(count)];
                @memcpy(region, checkpoint[node.offset..][0..@intCast(count)]);
            }
        }
        state.step = index * simulation.checkpoint_interval;
    }
};

const step_flicks: u64 = @intCast(simulation.step.flicks);
const step_flicks_float: f64 = @floatFromInt(simulation.step.flicks);
const flicks_per_second_float: f64 = @floatFromInt(time_module.flicks_per_second);
/// Steps a second, exact, so a slope over a step in units per second is exact up to its rounding.
const steps_per_second: f64 = 480;

comptime {
    assert(step_flicks * 480 == time_module.flicks_per_second);
}

/// Where an events query puts what it finds: the collector, and the range it keeps.
const Found = struct {
    collector: *Collector,
    t0: Time,
    t1: Time,

    /// Keeps an event if its time is in the range.
    fn add(report: *Found, time: Time, source: Id, instance: u32, value: f64) void {
        assert(report.t0.flicks < report.t1.flicks);
        if (time.flicks < report.t0.flicks) return;
        if (time.flicks >= report.t1.flicks) return;
        report.collector.add(.{
            .time = time,
            .source = source,
            .instance = instance,
            .value = value,
        });
    }
};

/// The hits of a bounce's position in the range: at each wall, the velocity just before it,
/// `+speed` at `high` and `-speed` at `low`. Once the buffer is full, it counts the rest.
fn events_bounce(program: *const Program, op: *const BounceNode, id: Id, report: *Found) void {
    assert(op.output == .position);
    const start_time = program.cues.at(op.start);
    const first = op.hits_before(report.t0, start_time) + 1;
    const last = op.hits_before(report.t1, start_time);
    var k = first;
    while (k <= last) : (k += 1) {
        const offset: i64 = @intCast(op.hit(k));
        const event: Event = .{
            .time = .{ .flicks = start_time.flicks +% offset },
            .source = id,
            .instance = 0,
            .value = if (k % 2 == 1) op.speed else -op.speed,
        };
        assert(event.time.flicks >= report.t0.flicks);
        assert(event.time.flicks < report.t1.flicks);
        if (report.collector.counts_only(&event)) {
            report.collector.count_dropped(last - k + 1);
            return;
        }
        report.collector.add(event);
    }
}

/// The cues of a span in the range, each at its time with its index as the value, in cue order.
fn events_cues(program: *const Program, span: CueSpan, id: Id, report: *Found) void {
    const times = program.cues.times[span.first.index..][0..span.count];
    const first = times_before(times, report.t0, .exclusive);
    const last = times_before(times, report.t1, .exclusive);
    assert(first <= last);
    for (first..last) |index| {
        const event: Event = .{
            .time = times[index],
            .source = id,
            .instance = 0,
            .value = @floatFromInt(span.first.index + index),
        };
        if (report.collector.counts_only(&event)) {
            report.collector.count_dropped(last - index);
            return;
        }
        report.collector.add(event);
    }
}

/// The goals of a motion reached in the range, each with the goal as the value. Only goals whose
/// stretch, from their cue to the next goal's, meets the range can be reached in it, and the fold
/// to the first of them starts from the cursor when it can, as `motion.zig` explains.
fn events_motion(
    program: *const Program,
    slab: []const f64,
    node: *const Node,
    op: *const Motion,
    id: Id,
    report: *Found,
) void {
    const path = program.goals[op.goals.first..][0..op.goals.count];
    const cues = program.cues;
    // The first goal whose stretch ends after t0, and the goals after it whose cue is before t1.
    var first: u32 = 0;
    while (first + 1 < path.len) : (first += 1) {
        if (cues.at(path[first + 1].cue).flicks > report.t0.flicks) break;
    }
    if (cues.at(path[first].cue).flicks >= report.t1.flicks) return;
    const cursor = slab[node.offset + node.extent.count() ..][0..motion.cursor_count];
    var kinematics = motion.kinematics_at_goal(op, program.goals, cues, cursor, first);
    var index = first;
    while (index < path.len) : (index += 1) {
        const cue_time = cues.at(path[index].cue);
        if (cue_time.flicks >= report.t1.flicks) break;
        const reached = motion.reached_between(
            op,
            program.goals,
            cues,
            index,
            kinematics,
            report.t0,
            report.t1,
        );
        if (reached) |time| report.add(time, id, 0, path[index].value);
        if (index + 1 == path.len) break;
        const seconds = motion.seconds_between(cue_time, cues.at(path[index + 1].cue));
        kinematics = motion.advance(op.law, kinematics, path[index].value, seconds);
    }
}

/// The events found at step `index`, after the pass at its time and before the update that
/// leaves it, as section 11 explains. Each lies in (t_{index - 1}, t_index].
fn report_step(
    program: *const Program,
    slab: []const f64,
    start: Time,
    index: u64,
    report: *Found,
) void {
    for (program.nodes, 0..) |*node, node_index| {
        const id: Id = .{ .index = @intCast(node_index) };
        const output_count = node.extent.count();
        const cache_count: u32 = @intCast(node.op.cache_count(output_count));
        const cache = slab[node.offset + output_count ..][0..cache_count];
        switch (node.op) {
            .crossing => |*op| {
                const inputs = node_values(program.nodes, slab, op.input);
                report_crossing(op, cache, inputs, step_time(start, index), id, report);
            },
            .follow => {
                const own = cache[2 * output_count ..][0..follower_slots];
                if (own[follower_slot_arrived] == 1) {
                    const goal = own[follower_slot_arrived_goal];
                    report.add(step_time(start, index), id, 0, goal);
                }
            },
            .shift => |*op| report_shift(cache[2 * output_count ..], op, start, index, id, report),
            else => {},
        }
    }
}

/// A crossing's events at step `index`: per lane, its input at the step before, kept in its slab,
/// against its input at this step, from the pass. The time is interpolated in the step and
/// rounded up, never past it nor onto the step before, and the value is the slope.
fn report_crossing(
    op: *const Crossing,
    cache: []const f64,
    inputs: []const f64,
    time: Time,
    id: Id,
    report: *Found,
) void {
    assert(cache.len == inputs.len + 1);
    // Nothing to compare at step 0, before the first update has kept an input.
    if (cache[inputs.len] == 0) return;
    const step_before: Time = .{ .flicks = time.flicks -% simulation.step.flicks };
    for (cache[0..inputs.len], inputs, 0..) |a, b, lane| {
        if (!op.crosses(a, b)) continue;
        // In [0, 1], since a subtraction rounds monotonically: 0 only falling from on the level.
        const weight = (op.level - a) / (b - a);
        assert(weight >= 0);
        assert(weight <= 1);
        const into = std.math.clamp(@ceil(weight * step_flicks_float), 1, step_flicks_float);
        const offset: i64 = @intFromFloat(into);
        const at: Time = .{ .flicks = step_before.flicks +% offset };
        report.add(at, id, @intCast(lane), (b - a) * steps_per_second);
    }
}

/// A shift register's event at step `index`, if the update to it entered a bucket: at the
/// bucket's boundary, an exact integer of flicks, with the entered bucket's value after the
/// update's replacement.
fn report_shift(
    own: []const f64,
    op: *const simulation.ShiftRegister,
    start: Time,
    index: u64,
    id: Id,
    report: *Found,
) void {
    assert(own.len == 1 + op.buckets);
    if (index == 0) return;
    const entered: u64 = @intFromFloat(own[0]);
    const before = simulation.shift_position(op, index - 1).bucket;
    assert(entered >= before);
    assert(entered - before <= 1);
    if (entered == before) return;
    const boundary = simulation.shift_boundary(op, entered);
    assert(boundary > (index - 1) * step_flicks);
    assert(boundary <= index * step_flicks);
    const time: Time = .{ .flicks = start.flicks +% @as(i64, @bitCast(boundary)) };
    const slot: u32 = @intCast(entered % op.buckets);
    report.add(time, id, 0, own[1 + slot]);
}

/// How a pass gives a simulated node's value.
const Sampling = union(enum) {
    /// At a step: the value the slab's state holds.
    at_step,
    /// This fraction of a step past the step before, interpolated.
    between: f64,
};

fn node_values(nodes: []const Node, slab: []const f64, id: Id) []const f64 {
    const node = &nodes[id.index];
    return slab[node.offset..][0..node.extent.count()];
}

/// Evaluates every node at `time`, in order.
fn pass(program: *const Program, slab: []f64, time: Time, sampling: Sampling) void {
    assert(slab.len == program.slab_count);
    for (program.nodes) |*node| eval_node(program, slab, node, time, sampling);
}

fn eval_node(
    program: *const Program,
    slab: []f64,
    node: *const Node,
    time: Time,
    sampling: Sampling,
) void {
    const nodes = program.nodes;
    const output_count = node.extent.count();
    const out = slab[node.offset..][0..output_count];
    switch (node.op) {
        .constant => |constant| @memset(out, constant),
        .add => |op| {
            const left = node_values(nodes, slab, op.left);
            add_into(out, left, node_values(nodes, slab, op.right));
        },
        .multiply => |op| {
            const left = node_values(nodes, slab, op.left);
            multiply_into(out, left, node_values(nodes, slab, op.right));
        },
        .map_range => |*op| map_range_into(out, node_values(nodes, slab, op.input), op),
        .wave => |wave| @memset(out, wave.sample(time)),
        .noise => |noise| @memset(out, noise.sample(time)),
        .motion => |*op| {
            const cursor = slab[node.offset + output_count ..][0..motion.cursor_count];
            @memset(out, motion.sample(op, program.goals, program.cues, cursor, time));
        },
        .tween => |*tween| {
            const start_time = program.cues.at(tween.start);
            if (time.flicks >= start_time.flicks) {
                @memset(out, tween.value_after(time, start_time));
            } else if (tween.previous) |previous| {
                @memcpy(out, node_values(nodes, slab, previous));
            } else {
                @memset(out, tween.from);
            }
        },
        .chase, .follow, .shift, .delay, .oscillator => {
            const cache = slab[node.offset + output_count ..][0 .. 2 * output_count];
            sample_into(out, cache[0..output_count], cache[output_count..], sampling);
        },
        .track => |id| @memset(out, program.tracks.value(id, time)),
        .bounce => |*op| @memset(out, op.sample(time, program.cues.at(op.start))),
        .crossing => |*op| {
            const inputs = node_values(nodes, slab, op.input);
            assert(inputs.len == out.len);
            for (out, inputs) |*gate, input| gate.* = if (input >= op.level) 1 else 0;
        },
        .cues => |span| {
            const times = program.cues.times[span.first.index..][0..span.count];
            @memset(out, @floatFromInt(times_before(times, time, .inclusive)));
        },
        // Set by `State.set_input`, which a pass leaves as it is.
        .input => {},
        .recorded => |op| {
            const clip = program.samples[op.clip.first..][0..op.clip.count];
            @memset(out, recording_module.play(clip, time));
        },
    }
}

/// How many of the sorted `times` are before `time`, or at or before it, by binary search.
fn times_before(times: []const Time, time: Time, bound: enum { exclusive, inclusive }) u32 {
    assert(times.len <= std.math.maxInt(u32));
    var low: u32 = 0;
    var high: u32 = @intCast(times.len);
    // Halving a u32 range ends within 33 rounds.
    for (0..33) |_| {
        if (low == high) break;
        const middle = low + (high - low) / 2;
        const counted = switch (bound) {
            .exclusive => times[middle].flicks < time.flicks,
            .inclusive => times[middle].flicks <= time.flicks,
        };
        if (counted) low = middle + 1 else high = middle;
    } else unreachable;
    if (low > 0) assert(times[low - 1].flicks <= time.flicks);
    if (low < times.len) assert(times[low].flicks >= time.flicks);
    return low;
}

/// A simulated node's output from its values at the steps `before` and `after` the time.
fn sample_into(out: []f64, before: []const f64, after: []const f64, sampling: Sampling) void {
    assert(before.len == out.len);
    assert(after.len == out.len);
    switch (sampling) {
        .at_step => @memcpy(out, after),
        .between => |weight| {
            assert(weight >= 0);
            assert(weight < 1);
            for (out, before, after) |*value, a, b| value.* = a * (1 - weight) + b * weight;
        },
    }
}

/// The time of step `index`.
fn step_time(start: Time, index: u64) Time {
    // Wrapping, because the step's time fits an i64 even where its distance from start does not.
    const offset: i64 = @bitCast(index * step_flicks);
    const time: Time = .{ .flicks = start.flicks +% offset };
    assert(time.flicks >= start.flicks or offset < 0);
    return time;
}

/// The first step at or after `time`, which is 0 at or before the start: the step a range ending
/// at `time` commits, as section 11 explains.
fn step_ceiling(start: Time, time: Time) u64 {
    if (time.flicks <= start.flicks) return 0;
    // Wrapping, because the distance between two i64 only fits in a u64.
    const elapsed: u64 = @bitCast(time.flicks -% start.flicks);
    const result = std.math.divCeil(u64, elapsed, step_flicks) catch unreachable;
    assert(result > 0);
    assert((result - 1) * step_flicks < elapsed);
    return result;
}

/// Runs the step from step `index` to the next: a pass at its time, then an update of every
/// simulated node from that pass, as section 9 explains. Between the two, the events found at
/// step `index` go to `report`, as section 11 explains.
fn step_once(program: *const Program, slab: []f64, start: Time, index: u64, report: ?*Found) void {
    pass(program, slab, step_time(start, index), .at_step);
    if (report) |into| report_step(program, slab, start, index, into);
    for (program.nodes) |*node| {
        if (node.op.simulated()) update_node(program, slab, node, index + 1);
    }
}

/// Moves a simulated node's state to step `index`, from the pass at the step before.
fn update_node(program: *const Program, slab: []f64, node: *const Node, index: u64) void {
    assert(index > 0);
    const output_count = node.extent.count();
    const cache_count: u32 = @intCast(node.op.cache_count(output_count));
    const cache = slab[node.offset + output_count ..][0..cache_count];
    if (node.op == .crossing) {
        // It keeps no values to interpolate, only its input at this pass, for the next compare.
        const inputs = node_values(program.nodes, slab, node.op.crossing.input);
        assert(inputs.len == output_count);
        for (inputs) |input| assert(std.math.isFinite(input));
        @memcpy(cache[0..output_count], inputs);
        cache[output_count] = 1;
        return;
    }
    const before = cache[0..output_count];
    const after = cache[output_count..][0..output_count];
    const own = cache[2 * output_count ..];
    @memcpy(before, after);
    switch (node.op) {
        .chase => |*op| {
            const target = node_values(program.nodes, slab, op.target);
            assert(target.len == output_count);
            const velocities = own[0..output_count];
            const law: motion.Law = .{ .spring = if (any_param(op.params))
                spring_law_at(program, slab, op.params, op.law, own[output_count..])
            else
                op.law };
            for (after, velocities, target) |*position, *velocity, goal| {
                const now: motion.Kinematics = .{ .position = position.*, .velocity = velocity.* };
                const next = motion.advance(law, now, goal, simulation.step_seconds);
                position.* = next.position;
                velocity.* = next.velocity;
            }
        },
        .delay => |op| if (op.input) |input| {
            const values = node_values(program.nodes, slab, input);
            assert(values.len == output_count);
            @memcpy(after, values);
        },
        .follow => |*op| {
            const law: motion.Law = switch (op.law) {
                .spring => |fixed| .{ .spring = if (any_param(op.params))
                    spring_law_at(program, slab, op.params, fixed, own[follower_slots..])
                else
                    fixed },
                .newtonian => |fixed| .{
                    .newtonian = newtonian_limits_at(program, slab, op.params, fixed),
                },
            };
            const kept = own[0..follower_slots];
            const state = follower_unpack(after[0], kept);
            const next = simulation.follower_step(op, program.regions, law, state);
            follower_pack(next.state, after, kept);
            own[follower_slot_arrived] = @floatFromInt(@intFromBool(next.arrived));
            if (next.arrived) own[follower_slot_arrived_goal] = state.goal;
        },
        .shift => |*op| {
            const bucket: u64 = @intFromFloat(own[0]);
            const next = simulation.shift_step(op, own[1..], bucket, index);
            own[0] = @floatFromInt(next.bucket);
            @memset(after, next.value);
        },
        .oscillator => |*op| {
            const rate = param_value(program, slab, op.rate);
            for (after, own[0..output_count]) |*value, *phase| {
                const turned = phase.* + rate * simulation.step_seconds;
                phase.* = turned - @floor(turned);
                // A sum one ulp below a whole turn can round up to 1 after the floor.
                if (phase.* >= 1) phase.* = 0;
                value.* = op.shape.at(phase.*);
            }
        },
        .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .motion => unreachable,
        .bounce, .cues, .crossing, .input, .recorded, .track => unreachable,
    }
    for (after) |value| assert(std.math.isFinite(value));
}

/// Puts a node's simulated state at the start, step 0, as section 9 explains. Other nodes keep
/// nothing to reset.
fn reset_node(program: *const Program, slab: []f64, node: *const Node) void {
    if (!node.op.simulated()) return;
    const output_count = node.extent.count();
    const cache_count: u32 = @intCast(node.op.cache_count(output_count));
    const cache = slab[node.offset + output_count ..][0..cache_count];
    if (node.op == .crossing) {
        // No input yet, so the first update only stores, and nothing fires before step 1.
        @memset(cache, 0);
        return;
    }
    const before = cache[0..output_count];
    const after = cache[output_count..][0..output_count];
    const own = cache[2 * output_count ..];
    switch (node.op) {
        .chase => |op| {
            @memset(after, op.from);
            @memset(own[0..output_count], 0);
            if (any_param(op.params)) law_cache_reset(own[output_count..]);
        },
        .delay => |op| @memset(after, op.initial),
        .follow => |*op| {
            const kept = own[0..follower_slots];
            follower_pack(simulation.follower_start(op, program.regions), after, kept);
            kept[follower_slot_arrived] = 0;
            kept[follower_slot_arrived_goal] = op.from;
            if (own.len > follower_slots) law_cache_reset(own[follower_slots..]);
        },
        .oscillator => |op| {
            @memset(own, op.phase);
            @memset(after, op.shape.at(op.phase));
        },
        .shift => |*op| {
            simulation.shift_fill(op, own[1..]);
            own[0] = 0;
            const position = simulation.shift_position(op, 0);
            @memset(after, simulation.shift_value(op, own[1..], position));
        },
        .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .motion => unreachable,
        .bounce, .cues, .crossing, .input, .recorded, .track => unreachable,
    }
    @memcpy(before, after);
}

/// A follower's state from its slab: its position is its value after the step. The last two slots
/// are its event, which the state does not carry.
fn follower_unpack(position: f64, own: []const f64) simulation.FollowerState {
    assert(own.len == follower_slots);
    return .{
        .kinematics = .{ .position = position, .velocity = own[0] },
        .goal = own[1],
        .drawn = @intFromFloat(own[2]),
        .pause_left = @intFromFloat(own[3]),
    };
}

fn follower_pack(state: simulation.FollowerState, after: []f64, own: []f64) void {
    assert(own.len == follower_slots);
    // Counters below 2^53, which section 6 of `simulation.zig` promises, are exact in an f64.
    assert(state.drawn < 1 << 53);
    @memset(after, state.kinematics.position);
    own[0] = state.kinematics.velocity;
    own[1] = state.goal;
    own[2] = @floatFromInt(state.drawn);
    own[3] = @floatFromInt(state.pause_left);
}

fn add_into(out: []f64, left: []const f64, right: []const f64) void {
    assert(left.len == out.len);
    assert(right.len == out.len);
    for (out, left, right) |*value, a, b| value.* = a + b;
}

fn multiply_into(out: []f64, left: []const f64, right: []const f64) void {
    assert(left.len == out.len);
    assert(right.len == out.len);
    for (out, left, right) |*value, a, b| value.* = a * b;
}

fn map_range_into(out: []f64, input: []const f64, map: *const MapRange) void {
    assert(input.len == out.len);
    assert(map.input_high != map.input_low);
    const input_width = map.input_high - map.input_low;
    for (out, input) |*value, x| {
        const position = (x - map.input_low) / input_width;
        // Not `low + position * (high - low)`, which can miss the high end by rounding.
        value.* = map.output_low * (1 - position) + map.output_high * position;
    }
}

const testing = std.testing;
const Rate = @import("time.zig").Rate;

const carrier = Wave{ .shape = .sine, .hz = 440 };
const swell = Wave{ .shape = .triangle, .hz = 0.7 };

/// A wave of 440 Hz scaled by a slower wave moved into [0.25, 1], returning the output node.
fn build_tremolo(builder: *Builder) Builder.Error!Id {
    const fast = try builder.wave(carrier);
    const slow = try builder.wave(swell);
    const depth = try builder.map_range(.{
        .input = slow,
        .input_low = -1,
        .input_high = 1,
        .output_low = 0.25,
        .output_high = 1,
    });
    return builder.multiply(fast, depth);
}

/// The same signal as `build_tremolo`, by hand.
fn tremolo_formula(time: Time) f64 {
    const position = (swell.sample(time) + 1) / 2;
    return carrier.sample(time) * (0.25 * (1 - position) + 1 * position);
}

// Locks the demo of this step: a wave scaled by a slower wave equals its formula bit for bit, over
// four seconds of 48 kHz ticks stepped by 1009, and at its worked start: sine(0) is 0, so the
// output at time zero is 0, while the depth is 0.625, halfway through the map.
test "a wave scaled by a slower wave matches its formula" {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const output = try build_tremolo(&builder);
    var slab: [4]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 0), state.value(output));
    try testing.expectEqual(@as(f64, 0.625), state.value(.{ .index = 2 }));

    const rate = Rate.from_hz(48_000).?;
    var tick: i64 = 0;
    while (tick < 4 * 48_000) : (tick += 1009) {
        const time = Time.from_ticks(tick, rate).?;
        state.eval(time);
        try testing.expectEqual(tremolo_formula(time), state.value(output));
    }
}

// Locks each op on small numbers: 3 + 4 = 7, 7 * 2 = 14, and 14 moved from [10, 20] to [0, -1],
// a reversed output, is -0.4.
test "each op computes its value" {
    var nodes: [6]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 6 });
    const three = try builder.constant(3);
    const four = try builder.constant(4);
    const seven = try builder.add(three, four);
    const two = try builder.constant(2);
    const fourteen = try builder.multiply(seven, two);
    const mapped = try builder.map_range(.{
        .input = fourteen,
        .input_low = 10,
        .input_high = 20,
        .output_low = 0,
        .output_high = -1,
    });
    var slab: [6]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 7), state.value(seven));
    try testing.expectEqual(@as(f64, 14), state.value(fourteen));
    try testing.expectApproxEqAbs(@as(f64, -0.4), state.value(mapped), 1e-15);
}

// Locks the promise of `MapRange` on an output of [-0.3, 0.9], where `low + 1 * (high - low)` gives
// 0.8999999999999999: both ends land exactly, and an input outside the range is not clamped.
test "a map lands exactly on its ends and does not clamp" {
    var nodes: [6]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 6 });
    const map: MapRange = .{
        .input = undefined,
        .input_low = 0.1,
        .input_high = 0.7,
        .output_low = -0.3,
        .output_high = 0.9,
    };
    const inputs = [_]f64{ 0.1, 0.7, 1.3 };
    var outputs: [inputs.len]Id = undefined;
    for (inputs, &outputs) |input, *output| {
        var map_input = map;
        map_input.input = try builder.constant(input);
        output.* = try builder.map_range(map_input);
    }
    var slab: [6]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, -0.3), state.value(outputs[0]));
    try testing.expectEqual(@as(f64, 0.9), state.value(outputs[1]));
    try testing.expectApproxEqAbs(@as(f64, 2.1), state.value(outputs[2]), 1e-15);
}

// Locks each capacity refusal by name, at exactly one past the limit, and that a refused node
// leaves the builder as it was: the same counts, and a smaller node still fits.
test "the builder refuses a capacity overflow by name" {
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 8 });
    _ = try builder.constant(1);
    _ = try builder.constant(2);
    try testing.expectError(error.NodeCapacityExceeded, builder.constant(3));
    try testing.expectEqual(@as(u32, 2), builder.node_count);
    try testing.expectEqual(@as(u32, 2), builder.slab_count);

    builder = Builder.init(&nodes, .{ .slab_count_max = 5 });
    builder.extent = .{ .lanes = 3, .components = 2 };
    try testing.expectError(error.SlabCapacityExceeded, builder.constant(1));
    try testing.expectEqual(@as(u32, 0), builder.node_count);
    try testing.expectEqual(@as(u32, 0), builder.slab_count);
    builder.extent = .{ .lanes = 5, .components = 1 };
    _ = try builder.constant(1);
    try testing.expectEqual(@as(u32, 5), builder.slab_count);
    builder.extent = .{ .lanes = std.math.maxInt(u32), .components = std.math.maxInt(u32) };
    try testing.expectError(error.SlabCapacityExceeded, builder.constant(1));
}

// Locks that a cycle cannot be expressed: the only id a node could use to reach itself or a later
// node is one that does not exist yet.
test "a node cannot refer to itself or to a later node" {
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 3 });
    const first = try builder.constant(1);
    const next: Id = .{ .index = 1 };
    try testing.expectError(error.UnknownNode, builder.add(first, next));
    try testing.expectError(error.UnknownNode, builder.multiply(next, first));
    const map: MapRange = .{
        .input = next,
        .input_low = 0,
        .input_high = 1,
        .output_low = 0,
        .output_high = 1,
    };
    try testing.expectError(error.UnknownNode, builder.map_range(map));
    try testing.expectEqual(@as(u32, 1), builder.node_count);
}

// Locks the refusal of values that `eval` could not use, and that a reversed input range is fine.
test "the builder refuses parameters it cannot evaluate" {
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 3 });
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    try testing.expectError(error.NotFinite, builder.constant(nan));
    try testing.expectError(error.NotFinite, builder.constant(inf));
    try testing.expectError(error.NotFinite, builder.wave(.{ .shape = .saw, .hz = nan }));

    const input = try builder.constant(0.5);
    var map: MapRange = .{
        .input = input,
        .input_low = 1,
        .input_high = 1,
        .output_low = 0,
        .output_high = 1,
    };
    try testing.expectError(error.InvalidRange, builder.map_range(map));
    map.input_low = -std.math.floatMax(f64);
    map.input_high = std.math.floatMax(f64);
    try testing.expectError(error.InvalidRange, builder.map_range(map));
    map.input_low = 2;
    map.input_high = 0;
    map.output_high = inf;
    try testing.expectError(error.NotFinite, builder.map_range(map));
    map.output_high = 1;
    _ = try builder.map_range(map);
}

// Locks the rule of section 3. The node array and a slab are copied as bytes, the originals are
// overwritten, and the copies give the same bits: the moved program evaluates, and the moved slab
// reads back as a checkpoint without another eval.
test "moving the memory changes nothing" {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const output = try build_tremolo(&builder);
    const program = builder.finish();
    var slab: [4]f64 = undefined;
    var state = State.init(program, &slab);
    const time = Time{ .flicks = 1_234_567_890 };
    state.eval(time);
    const expected = state.value(output);

    var nodes_moved: [4]Node = undefined;
    var slab_moved: [4]f64 = undefined;
    @memcpy(std.mem.asBytes(&nodes_moved), std.mem.asBytes(&nodes));
    @memcpy(std.mem.asBytes(&slab_moved), std.mem.asBytes(&slab));
    @memset(std.mem.asBytes(&nodes), 0xaa);
    @memset(std.mem.asBytes(&slab), 0xaa);

    const program_moved: Program = .{
        .nodes = &nodes_moved,
        .cues = &Cues.empty,
        .goals = &.{},
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = program.slab_count,
    };
    var state_checkpoint: State = .{
        .program = program_moved,
        .slab = &slab_moved,
        .evaluated = true,
        .checkpoints = &.{},
        .checkpoints_filled = 0,
        .step = null,
        .generation = 0,
        .track_generation = 0,
        .steps_run = 0,
        .recordings = undefined,
        .recordings_count = 0,
    };
    try testing.expectEqual(expected, state_checkpoint.value(output));

    var slab_fresh: [4]f64 = undefined;
    var state_fresh = State.init(program_moved, &slab_fresh);
    state_fresh.eval(time);
    try testing.expectEqual(expected, state_fresh.value(output));
    state_checkpoint.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 0), state_checkpoint.value(output));
}

// Locks that a slab holds no history: an eval at a time gives the same bits whatever was evaluated
// before it, including a jump backwards.
test "eval depends only on the time" {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const output = try build_tremolo(&builder);
    var slab: [4]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    const time = Time{ .flicks = 987_654_321 };
    state.eval(time);
    const expected = state.value(output);
    state.eval(.{ .flicks = time.flicks * 3 });
    state.eval(.{ .flicks = -time.flicks });
    state.eval(time);
    try testing.expectEqual(expected, state.value(output));
}

// Locks the layout of section 2 with lanes and components above 1, which every op must loop over.
// 3 lanes of 2 components is 6 f64 per node, at offsets 0, 6, 12, 18, and 24, and a thousand 2D
// values is 2,000 f64 at one offset.
test "each op loops over the extent of its node" {
    var nodes: [5]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 30 });
    builder.extent = .{ .lanes = 3, .components = 2 };
    const two = try builder.constant(2);
    const three = try builder.constant(3);
    const sum = try builder.add(two, three);
    const product = try builder.multiply(sum, three);
    const mapped = try builder.map_range(.{
        .input = product,
        .input_low = 0,
        .input_high = 30,
        .output_low = 0,
        .output_high = 1,
    });
    const program = builder.finish();
    try testing.expectEqual(@as(u32, 30), program.slab_count);
    try testing.expectEqual(@as(u32, 24), program.nodes[mapped.index].offset);

    var slab: [30]f64 = undefined;
    var state = State.init(program, &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(5)), state.values(sum));
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(15)), state.values(product));
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(0.5)), state.values(mapped));

    var nodes_many: [2]Node = undefined;
    var builder_many = Builder.init(&nodes_many, .{ .slab_count_max = 4000 });
    builder_many.extent = .{ .lanes = 1000, .components = 2 };
    _ = try builder_many.wave(carrier);
    const second = try builder_many.wave(swell);
    try testing.expectEqual(@as(u32, 2000), builder_many.nodes[second.index].offset);
    try testing.expectEqual(@as(u32, 4000), builder_many.finish().slab_count);
}

// Locks the smallest program: no nodes, an empty slab, and an eval that does nothing.
test "an empty program evaluates" {
    var builder = Builder.init(&.{}, .{ .slab_count_max = 0 });
    var state = State.init(builder.finish(), &.{});
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(usize, 0), state.slab.len);
}

/// One tween of 1.5 s starting at `cue`, over a table the test owns.
fn tween_of(from: f64, to: f64, cue: Cue, ease: Ease) Tween {
    return .{
        .from = from,
        .to = to,
        .duration = .{ .flicks = 3 * 352_800_000 },
        .ease = ease,
        .start = cue,
        .previous = null,
    };
}

// Locks the demo of this step for 0.1 to 0.3, neither an exact f64, and for -0, whose sign only
// survives if the end value is returned and not computed: before and at the cue is `from`, and at
// the last flick's end and an hour later is `to`, bit for bit.
test "a tween ends on its target value, bit for bit" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 705_600_000 });

    for ([_]f64{ 0.3, -0.0 }) |target| {
        var nodes: [1]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &cues });
        const tween = try builder.tween(tween_of(0.1, target, cue, .in_out));
        var slab: [1]f64 = undefined;
        var state = State.init(builder.finish(), &slab);
        const end = cues.at(cue).flicks + 3 * 352_800_000;

        state.eval(.{ .flicks = 0 });
        try testing.expectEqual(@as(f64, 0.1), state.value(tween));
        state.eval(cues.at(cue));
        try testing.expectEqual(@as(f64, 0.1), state.value(tween));
        state.eval(.{ .flicks = end - 1 });
        try testing.expect(state.value(tween) != target);
        for ([_]i64{ end, end + 3600 * 705_600_000 }) |flicks| {
            state.eval(.{ .flicks = flicks });
            const bits: u64 = @bitCast(state.value(tween));
            try testing.expectEqual(@as(u64, @bitCast(target)), bits);
        }
    }
}

// Locks the worked middle of a tween from 10 to 20: halfway through, in-out has an eased progress
// of exactly a half, so the value is 15, and `in` at a half gives 10 + 10 * 0.3153568.
test "a tween follows its ease" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const symmetric = try builder.tween(tween_of(10, 20, cue, .in_out));
    const slow_start = try builder.tween(tween_of(10, 20, cue, .in));
    var slab: [2]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = 3 * 176_400_000 });
    try testing.expectApproxEqAbs(@as(f64, 15), state.value(symmetric), 1e-13);
    try testing.expectApproxEqAbs(@as(f64, 13.153568125725393), state.value(slow_start), 1e-13);
}

// Locks the demo of this step: after a move of `shift`, a reader sees the values it would have
// seen `shift` earlier, bit for bit, with no rebuild. That holds for one flick, for a shift
// backwards, and for a day, which would cost bits if the progress went through floating seconds.
test "moving a cue shifts its tween by exactly that time" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &cues });
    const tween = try builder.tween(tween_of(0.1, 0.7, cue, .in_out));
    var slab: [1]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    var expected: [64]f64 = undefined;
    for (&expected, 0..) |*value, index| {
        state.eval(.{ .flicks = @as(i64, @intCast(index)) * 23_456_789 - 7 });
        value.* = state.value(tween);
    }
    for ([_]i64{ 1, -12_345, 86_400 * 705_600_000 }) |shift| {
        try cues.move(cue, .{ .flicks = shift });
        for (expected, 0..) |value, index| {
            state.eval(.{ .flicks = @as(i64, @intCast(index)) * 23_456_789 - 7 + shift });
            try testing.expectEqual(value, state.value(tween));
        }
    }
}

// Locks a sequence of two tweens: 0 to 1 from t = 0 s for 1.5 s, then 5 to 2 from t = 2 s. The
// first holds 0 before it starts and 1 in the gap, and the second then jumps to its own `from` and
// holds its `to` afterwards.
test "a chain of tweens is a sequence, and a gap holds" {
    var times: [2]Time = undefined;
    var cues = Cues.init(&times);
    const first_cue = try cues.add(.{ .flicks = 0 });
    const second_cue = try cues.add(.{ .flicks = 2 * 705_600_000 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const first = try builder.tween(tween_of(0, 1, first_cue, .linear));
    var second_tween = tween_of(5, 2, second_cue, .linear);
    second_tween.previous = first;
    const second = try builder.tween(second_tween);
    var slab: [2]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    const rows = [_]struct { flicks: i64, value: f64 }{
        .{ .flicks = -1, .value = 0 },
        .{ .flicks = 352_800_000, .value = 1.0 / 3.0 },
        .{ .flicks = 3 * 352_800_000, .value = 1 },
        .{ .flicks = 2 * 705_600_000 - 1, .value = 1 },
        .{ .flicks = 2 * 705_600_000, .value = 5 },
        .{ .flicks = 7 * 352_800_000, .value = 2 },
    };
    for (rows) |row| {
        state.eval(.{ .flicks = row.flicks });
        try testing.expectEqual(row.value, state.value(second));
    }
}

// Locks the decision of section 6: a tween starting while an earlier one runs wins from its start,
// so at t = 0.75 s, a sixth of the way into a second tween from 10 to 20, the output is 11.667 and
// not the first's 0.5. Moving the second cue onto the first gives the second from time zero, and
// moving it past that time restores the first.
test "a later tween wins an overlap" {
    var times: [2]Time = undefined;
    var cues = Cues.init(&times);
    const first_cue = try cues.add(.{ .flicks = 0 });
    const second_cue = try cues.add(.{ .flicks = 352_800_000 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const first = try builder.tween(tween_of(0, 1, first_cue, .linear));
    var second_tween = tween_of(10, 20, second_cue, .linear);
    second_tween.previous = first;
    const second = try builder.tween(second_tween);
    var slab: [2]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    state.eval(.{ .flicks = 529_200_000 });
    try testing.expectEqual(@as(f64, 0.5), state.value(first));
    try testing.expectApproxEqAbs(@as(f64, 11.666666666666666), state.value(second), 1e-13);

    try cues.move(second_cue, .{ .flicks = 0 });
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 10), state.value(second));
    try cues.move(second_cue, .{ .flicks = 2 * 705_600_000 });
    state.eval(.{ .flicks = 529_200_000 });
    try testing.expectEqual(@as(f64, 0.5), state.value(second));
}

// Locks that `previous` can be any signal: a tween follows a wave until its cue, sample for
// sample, and leaves it at its own `from`.
test "a tween can follow any signal until its cue" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 705_600_000 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const wave = try builder.wave(swell);
    var source = tween_of(3, 4, cue, .linear);
    source.previous = wave;
    const tween = try builder.tween(source);
    var slab: [2]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    const time = Time{ .flicks = 123_456_789 };
    state.eval(time);
    try testing.expectEqual(swell.sample(time), state.value(tween));
    state.eval(cues.at(cue));
    try testing.expectEqual(@as(f64, 3), state.value(tween));
}

// Locks the far ends of an i64: a cue at the earliest time, read at the latest, is 2^64 - 1 flicks
// apart, which does not fit in an i64, and the tween must land and not wrap into its start. Its
// progress at 2^62 flicks in, half of a duration of 2^63 - 1, rounds to exactly a half.
test "a tween survives the full range of time" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = std.math.minInt(i64) });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &cues });
    var source = tween_of(1, 2, cue, .linear);
    source.duration = .{ .flicks = std.math.maxInt(i64) };
    const tween = try builder.tween(source);
    var slab: [1]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = std.math.maxInt(i64) });
    try testing.expectEqual(@as(f64, 2), state.value(tween));
    state.eval(.{ .flicks = -1 });
    try testing.expectEqual(@as(f64, 2), state.value(tween));
    state.eval(.{ .flicks = std.math.minInt(i64) + (1 << 62) });
    try testing.expectEqual(@as(f64, 1.5), state.value(tween));
}

// Locks each refusal of `tween` by name. The first is the case of a tween with no table at all.
test "the builder refuses a tween it cannot evaluate" {
    var nodes: [2]Node = undefined;
    var empty = Builder.init(&nodes, .{ .slab_count_max = 2 });
    const cue_none: Cue = .{ .index = 0 };
    try testing.expectError(error.UnknownCue, empty.tween(tween_of(0, 1, cue_none, .linear)));

    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const nan = std.math.nan(f64);
    try testing.expectError(error.NotFinite, builder.tween(tween_of(nan, 1, cue, .linear)));
    try testing.expectError(error.NotFinite, builder.tween(tween_of(0, nan, cue, .linear)));

    var source = tween_of(0, 1, cue, .linear);
    source.duration = .{ .flicks = 0 };
    try testing.expectError(error.InvalidDuration, builder.tween(source));
    source.duration = .{ .flicks = -1 };
    try testing.expectError(error.InvalidDuration, builder.tween(source));

    source = tween_of(0, 1, cue, .{ .x1 = 2, .y1 = 0, .x2 = 1, .y2 = 1 });
    try testing.expectError(error.InvalidEase, builder.tween(source));

    source = tween_of(0, 1, cue, .linear);
    source.previous = .{ .index = 0 };
    try testing.expectError(error.UnknownNode, builder.tween(source));
    try testing.expectEqual(@as(u32, 0), builder.node_count);
}

// Locks that a tween fills every lane of its extent, from itself and from `previous`.
test "a tween loops over the extent of its node" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 705_600_000 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 12, .cues = &cues });
    builder.extent = .{ .lanes = 3, .components = 2 };
    const before = try builder.constant(7);
    var source = tween_of(1, 9, cue, .linear);
    source.previous = before;
    const tween = try builder.tween(source);
    var slab: [12]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(7)), state.values(tween));
    state.eval(.{ .flicks = 3 * 705_600_000 });
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(9)), state.values(tween));
}

const Reader = struct {
    program: Program,
    output: Id,
    /// Frames of this reader's own clock, which the other reader's does not share.
    rate: Rate,
    epoch_ticks: i64,
    mismatches: u32,

    fn run(reader: *Reader) void {
        var slab: [4]f64 = undefined;
        var state = State.init(reader.program, &slab);
        for (0..200_000) |index| {
            const tick = reader.epoch_ticks + @as(i64, @intCast(index));
            const time = Time.from_ticks(tick, reader.rate).?;
            state.eval(time);
            if (state.value(reader.output) != tremolo_formula(time)) reader.mismatches += 1;
        }
    }
};

// Locks the rule of section 1: two states on one program, at different rates and far-apart times
// on two threads, each match the formula on all 200,000 evals.
test "two states on one program never disturb each other" {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const output = try build_tremolo(&builder);
    const program = builder.finish();

    var video: Reader = .{
        .program = program,
        .output = output,
        .rate = Rate.from_hz(60).?,
        .epoch_ticks = 0,
        .mismatches = 0,
    };
    var audio: Reader = .{
        .program = program,
        .output = output,
        .rate = Rate.from_hz(48_000).?,
        .epoch_ticks = 86_400 * 48_000,
        .mismatches = 0,
    };
    const thread_video = try std.Thread.spawn(.{}, Reader.run, .{&video});
    const thread_audio = try std.Thread.spawn(.{}, Reader.run, .{&audio});
    thread_video.join();
    thread_audio.join();
    try testing.expectEqual(@as(u32, 0), video.mismatches);
    try testing.expectEqual(@as(u32, 0), audio.mismatches);
}

/// Two noises keyed 1 and 2 and summed, with `inserted` nodes built before them, including a noise
/// keyed 3. Returns the two noises.
fn build_noises(builder: *Builder, inserted: bool) Builder.Error![2]Id {
    if (inserted) {
        _ = try builder.wave(carrier);
        _ = try builder.noise(.{ .shape = .smooth, .hz = 5, .seed = 3 });
    }
    const first = try builder.noise(.{ .shape = .smooth, .hz = 0.7, .seed = 1 });
    const second = try builder.noise(.{ .shape = .steps, .hz = 4, .seed = 2 });
    _ = try builder.add(first, second);
    return .{ first, second };
}

// Locks the demo of section 7: inserting a wave and a third noise before two noises moves their
// ids but not their values, which match `Noise.derive` sample for sample; and another graph seed
// changes both.
test "inserting a node does not reshuffle the noises" {
    var nodes_plain: [3]Node = undefined;
    var builder_plain = Builder.init(&nodes_plain, .{ .slab_count_max = 3, .seed = 77 });
    const plain = try build_noises(&builder_plain, false);
    var slab_plain: [3]f64 = undefined;
    var state_plain = State.init(builder_plain.finish(), &slab_plain);

    var nodes_inserted: [5]Node = undefined;
    var builder_inserted = Builder.init(&nodes_inserted, .{ .slab_count_max = 5, .seed = 77 });
    const inserted = try build_noises(&builder_inserted, true);
    var slab_inserted: [5]f64 = undefined;
    var state_inserted = State.init(builder_inserted.finish(), &slab_inserted);
    try testing.expect(inserted[0].index != plain[0].index);

    var nodes_other: [3]Node = undefined;
    var builder_other = Builder.init(&nodes_other, .{ .slab_count_max = 3, .seed = 78 });
    const other = try build_noises(&builder_other, false);
    var slab_other: [3]f64 = undefined;
    var state_other = State.init(builder_other.finish(), &slab_other);

    const first: Noise = .{ .shape = .smooth, .hz = 0.7, .seed = 1 };
    var tick: i64 = 0;
    var differences: u32 = 0;
    while (tick < 10 * 48_000) : (tick += 997) {
        const time = Time.from_ticks(tick, Rate.from_hz(48_000).?).?;
        state_plain.eval(time);
        state_inserted.eval(time);
        state_other.eval(time);
        for (plain, inserted) |id_plain, id_inserted| {
            try testing.expectEqual(state_plain.value(id_plain), state_inserted.value(id_inserted));
        }
        try testing.expectEqual(first.derive(77).sample(time), state_plain.value(plain[0]));
        if (state_other.value(other[0]) != state_plain.value(plain[0])) differences += 1;
    }
    try testing.expect(differences > 400);
}

// Locks each refusal of `noise` by name, and the edges that are accepted: `Noise.hz_max` itself,
// and the smallest positive double.
test "the builder refuses a noise it cannot evaluate" {
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2 });
    var source: Noise = .{ .shape = .steps, .hz = std.math.nan(f64), .seed = 0 };
    try testing.expectError(error.NotFinite, builder.noise(source));
    source.hz = std.math.inf(f64);
    try testing.expectError(error.NotFinite, builder.noise(source));
    for ([_]f64{ 0, -0.0, -1, Noise.hz_max * 2 }) |hz| {
        source.hz = hz;
        try testing.expectError(error.InvalidRate, builder.noise(source));
    }
    try testing.expectEqual(@as(u32, 0), builder.node_count);
    source.hz = Noise.hz_max;
    _ = try builder.noise(source);
    source.hz = std.math.floatTrueMin(f64);
    _ = try builder.noise(source);
}

// Locks that a noise fills every lane of its extent.
test "a noise loops over the extent of its node" {
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 6 });
    builder.extent = .{ .lanes = 3, .components = 2 };
    const source: Noise = .{ .shape = .smooth, .hz = 2, .seed = 4 };
    const noise = try builder.noise(source);
    var slab: [6]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    const time = Time{ .flicks = 444_444_444 };
    state.eval(time);
    const expected = source.derive(0).sample(time);
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(expected)), state.values(noise));
}

/// Cues at 0, 0.4, 1.1, and 1.5 s, and two paths over them: 1, 0, 3, -2 for a spring, and 10, 2,
/// 6 for a Newtonian move from the second cue.
const Track = struct {
    times: [4]Time,
    cues: Cues,
    entries: [7]Goal,
    goals: motion.Goals,
    spring_path: motion.Path,
    newtonian_path: motion.Path,

    fn init(track: *Track) !void {
        track.cues = Cues.init(&track.times);
        const seconds_tenths = [_]i64{ 0, 4, 11, 15 };
        var cues: [4]Cue = undefined;
        for (seconds_tenths, &cues) |tenths, *cue| {
            cue.* = try track.cues.add(.{ .flicks = tenths * 70_560_000 });
        }
        track.goals = motion.Goals.init(&track.entries);
        track.spring_path = try track.goals.add(&.{
            .{ .cue = cues[0], .value = 1 },
            .{ .cue = cues[1], .value = 0 },
            .{ .cue = cues[2], .value = 3 },
            .{ .cue = cues[3], .value = -2 },
        });
        track.newtonian_path = try track.goals.add(&.{
            .{ .cue = cues[1], .value = 10 },
            .{ .cue = cues[2], .value = 2 },
            .{ .cue = cues[3], .value = 6 },
        });
    }

    /// A spring of overshoot 0.2 and a Newtonian move, built in `nodes`.
    fn build(track: *const Track, nodes: []Node) ![2]Id {
        var builder = Builder.init(nodes, .{
            .slab_count_max = 2 * (1 + motion.cursor_count),
            .cues = &track.cues,
            .goals = track.goals.table(),
        });
        const bouncy = try builder.spring(.{
            .from = -1,
            .goals = track.spring_path,
            .time = .{ .flicks = 352_800_000 },
            .overshoot = 0.2,
        });
        const newtonian = try builder.newtonian(.{
            .from = 0,
            .goals = track.newtonian_path,
            .speed = 12,
            .accel = 40,
            .decel = 30,
        });
        _ = builder.finish();
        return .{ bouncy, newtonian };
    }
};

// Locks the rule of section 8: 2.5 s of a spring and a Newtonian move at 240 Hz, read forwards
// with the cursor, backwards, in a scattered order, and each from a fresh slab, give the same
// bits.
test "a motion's cursor never changes a value" {
    var track: Track = undefined;
    try track.init();
    var nodes: [2]Node = undefined;
    const ids = try track.build(&nodes);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &track.cues,
        .goals = track.goals.table(),
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2 * (1 + motion.cursor_count),
    };
    const rate = Rate.from_hz(240).?;
    const frames_count = 600;
    var slab: [10]f64 = undefined;
    var state = State.init(program, &slab);
    var forward: [frames_count][2]f64 = undefined;
    for (&forward, 0..) |*values, frame| {
        state.eval(Time.from_ticks(@intCast(frame), rate).?);
        values.* = .{ state.value(ids[0]), state.value(ids[1]) };
    }

    var frame: usize = frames_count;
    while (frame > 0) {
        frame -= 1;
        state.eval(Time.from_ticks(@intCast(frame), rate).?);
        try testing.expectEqual(forward[frame], [2]f64{ state.value(ids[0]), state.value(ids[1]) });
    }
    var hop: usize = 0;
    for (0..frames_count) |_| {
        hop = (hop + 389) % frames_count;
        state.eval(Time.from_ticks(@intCast(hop), rate).?);
        try testing.expectEqual(forward[hop], [2]f64{ state.value(ids[0]), state.value(ids[1]) });
        var slab_fresh: [10]f64 = undefined;
        var fresh = State.init(program, &slab_fresh);
        fresh.eval(Time.from_ticks(@intCast(hop), rate).?);
        try testing.expectEqual(forward[hop], [2]f64{ fresh.value(ids[0]), fresh.value(ids[1]) });
    }
    try testing.expectEqual(@as(f64, -1), forward[0][0]);
    try testing.expectEqual(@as(f64, 6), forward[frames_count - 1][1]);
}

// Locks the demo of this step: stepping at 24, 60, 240, and 960 Hz through 2.5 s of retargets gives
// the same value at every instant the rates share, every 1/12 s. The tolerance is zero: a value
// depends on the time and the goals, never on the frames before it.
test "springs ignore the frame rate" {
    var track: Track = undefined;
    try track.init();
    var nodes: [2]Node = undefined;
    const ids = try track.build(&nodes);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &track.cues,
        .goals = track.goals.table(),
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2 * (1 + motion.cursor_count),
    };
    const rates_hz = [_]u32{ 24, 60, 240, 960 };
    var shared: [rates_hz.len][31][2]f64 = undefined;
    for (rates_hz, &shared) |hz, *values| {
        var slab: [10]f64 = undefined;
        var state = State.init(program, &slab);
        const per_shared = hz / 12;
        for (0..31 * per_shared) |frame| {
            state.eval(Time.from_ticks(@intCast(frame), Rate.from_hz(hz).?).?);
            if (frame % per_shared == 0) {
                values[frame / per_shared] = .{ state.value(ids[0]), state.value(ids[1]) };
            }
        }
    }
    for (shared[1..]) |values| try testing.expectEqual(shared[0], values);
}

// Locks that a cue move makes a cursor stale: a reader that has played past the second goal sees
// the move at its next eval, with the value a fresh reader computes, which differs from before.
test "moving a cue reaches a motion's cursor" {
    var track: Track = undefined;
    try track.init();
    var nodes: [2]Node = undefined;
    const ids = try track.build(&nodes);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &track.cues,
        .goals = track.goals.table(),
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2 * (1 + motion.cursor_count),
    };
    var slab: [10]f64 = undefined;
    var state = State.init(program, &slab);
    const time: Time = .{ .flicks = 13 * 70_560_000 };
    for (0..14) |tenth| state.eval(.{ .flicks = @as(i64, @intCast(tenth)) * 70_560_000 });
    state.eval(time);
    const before = [2]f64{ state.value(ids[0]), state.value(ids[1]) };

    try track.cues.move(.{ .index = 1 }, .{ .flicks = 3 * 70_560_000 });
    state.eval(time);
    const after = [2]f64{ state.value(ids[0]), state.value(ids[1]) };
    var slab_fresh: [10]f64 = undefined;
    var fresh = State.init(program, &slab_fresh);
    fresh.eval(time);
    try testing.expectEqual([2]f64{ fresh.value(ids[0]), fresh.value(ids[1]) }, after);
    try testing.expect(before[0] != after[0]);
    try testing.expect(before[1] != after[1]);
}

// Locks the layout of section 2 for a motion: 3 lanes of output then 4 f64 of cursor, so the next
// node starts at 7, and every lane holds the value.
test "a motion keeps its cursor after its output" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var entries: [1]Goal = undefined;
    var goals = motion.Goals.init(&entries);
    const path = try goals.add(&.{.{ .cue = cue, .value = 2 }});
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 10,
        .cues = &cues,
        .goals = goals.table(),
    });
    builder.extent = .{ .lanes = 3, .components = 1 };
    const move = try builder.newtonian(.{
        .from = 0,
        .goals = path,
        .speed = 1,
        .accel = 1,
        .decel = 1,
    });
    const after = try builder.constant(5);
    const program = builder.finish();
    try testing.expectEqual(@as(u32, 7), program.nodes[after.index].offset);
    try testing.expectEqual(@as(u32, 10), program.slab_count);
    var slab: [10]f64 = undefined;
    var state = State.init(program, &slab);
    state.eval(.{ .flicks = 705_600_000 });
    try testing.expectEqualSlices(f64, &@as([3]f64, @splat(0.5)), state.values(move));
}

// Locks each refusal of `spring` and `newtonian` by name, and that nothing refused was built.
test "the builder refuses a motion it cannot evaluate" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var entries: [2]Goal = undefined;
    var goals = motion.Goals.init(&entries);
    const path = try goals.add(&.{.{ .cue = cue, .value = 1 }});
    const beyond = try goals.add(&.{.{ .cue = .{ .index = 1 }, .value = 1 }});
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 10,
        .cues = &cues,
        .goals = goals.table(),
    });
    const second: Time = .{ .flicks = 705_600_000 };
    var spring: motion.Spring = .{ .from = 0, .goals = path, .time = second, .overshoot = 0 };
    const unknowns = [_]motion.Path{
        .{ .first = 0, .count = 0 },
        .{ .first = 1, .count = 2 },
        .{ .first = 3, .count = 1 },
    };
    for (unknowns) |unknown| {
        spring.goals = unknown;
        try testing.expectError(error.UnknownGoals, builder.spring(spring));
    }
    spring.goals = beyond;
    try testing.expectError(error.UnknownCue, builder.spring(spring));
    spring.goals = path;
    spring.from = std.math.inf(f64);
    try testing.expectError(error.NotFinite, builder.spring(spring));
    spring.from = 0;
    spring.time = .{ .flicks = 0 };
    try testing.expectError(error.InvalidDuration, builder.spring(spring));
    spring.time = second;
    for ([_]f64{ -0.1, 1, 2 }) |overshoot| {
        spring.overshoot = overshoot;
        try testing.expectError(error.InvalidOvershoot, builder.spring(spring));
    }
    spring.overshoot = std.math.nan(f64);
    try testing.expectError(error.NotFinite, builder.spring(spring));

    var newtonian: motion.Newtonian = .{
        .from = 0,
        .goals = path,
        .speed = 1,
        .accel = 1,
        .decel = 1,
    };
    newtonian.decel = 0;
    try testing.expectError(error.InvalidLimit, builder.newtonian(newtonian));
    newtonian.decel = 1;
    newtonian.speed = -1;
    try testing.expectError(error.InvalidLimit, builder.newtonian(newtonian));
    newtonian.speed = std.math.inf(f64);
    try testing.expectError(error.NotFinite, builder.newtonian(newtonian));
    try testing.expectEqual(@as(u32, 0), builder.node_count);
    newtonian.speed = 1;
    _ = try builder.newtonian(newtonian);
    spring.overshoot = 0.999;
    _ = try builder.spring(spring);
}

const flicks_per_second = @import("time.zig").flicks_per_second;

/// A start cue half a step after 0.5 s, so a reader at a rate that divides 480 Hz lands halfway
/// between steps or on one, and a cue at 2 s. Two regions, and a graph of every simulated node: a
/// chase of a tween that rises at the second cue, a follower, a shift register, and a chase of
/// 1 - 0.8 times its own delay.
const Scene = struct {
    times: [2]Time,
    cues: Cues,
    region_entries: [2]simulation.Region,
    regions: simulation.Regions,
    nodes: [10]Node,
    outputs: [4]Id,
    program: Program,

    const slab_count = 37;

    fn init(scene: *Scene) !void {
        scene.cues = Cues.init(&scene.times);
        const start = try scene.cues.add(.{
            .flicks = flicks_per_second / 2 + simulation.step.flicks / 2,
        });
        const rise = try scene.cues.add(.{ .flicks = 2 * flicks_per_second });
        scene.regions = simulation.Regions.init(&scene.region_entries);
        const span = try scene.regions.add(&.{
            .{ .low = -1, .high = -0.5 },
            .{ .low = 0.5, .high = 1 },
        });
        var builder = Builder.init(&scene.nodes, .{
            .slab_count_max = slab_count,
            .cues = &scene.cues,
            .regions = scene.regions.table(),
            .start = start,
            .seed = 21,
        });
        const target = try builder.tween(tween_of(0, 1, rise, .in_out));
        scene.outputs[0] = try builder.chase(.{
            .target = target,
            .from = 0.5,
            .time = .{ .flicks = flicks_per_second * 2 / 5 },
            .overshoot = 0.1,
        });
        scene.outputs[1] = try builder.follow(.{
            .from = 0,
            .regions = span,
            .pick = .random,
            .mover = .{ .spring = .{
                .time = .{ .flicks = flicks_per_second / 4 },
                .overshoot = 0,
            } },
            .tolerance = 0.01,
            .pause_min = .{ .flicks = flicks_per_second / 10 },
            .pause_max = .{ .flicks = flicks_per_second * 3 / 10 },
            .seed = 3,
        });
        scene.outputs[2] = try builder.shift(.{
            .buckets = 8,
            .period = .{ .flicks = 2 * flicks_per_second },
            .low = -1,
            .high = 1,
            .odds = 0.5,
            .shape = .smooth,
            .seed = 4,
        });
        scene.outputs[3] = try build_feedback(&builder);
        scene.program = builder.finish();
        assert(scene.program.slab_count == slab_count);
    }

    /// Moves both cues by `shift`, the one ahead first, so neither passes the other.
    fn shift_cues(scene: *Scene, shift: i64) !void {
        const order = if (shift > 0) [2]u32{ 1, 0 } else [2]u32{ 0, 1 };
        for (order) |index| {
            const cue: Cue = .{ .index = index };
            try scene.cues.move(cue, .{ .flicks = scene.cues.at(cue).flicks + shift });
        }
    }

    fn read(scene: *const Scene, state: *State, time: Time) [4]f64 {
        assert(state.program.nodes.ptr == scene.program.nodes.ptr);
        state.eval(time);
        var result: [4]f64 = undefined;
        for (&result, scene.outputs) |*value, id| value.* = state.value(id);
        return result;
    }
};

/// A chase of 1 - 0.8 times its own delay, which settles where x = 1 - 0.8 x, at 1 / 1.8.
fn build_feedback(builder: *Builder) Builder.Error!Id {
    const echo = try builder.delay(0);
    const gain = try builder.constant(-0.8);
    const scaled = try builder.multiply(echo, gain);
    const one = try builder.constant(1);
    const target = try builder.add(one, scaled);
    const result = try builder.chase(.{
        .target = target,
        .from = 0,
        .time = .{ .flicks = flicks_per_second / 2 },
        .overshoot = 0.2,
    });
    try builder.close(echo, result);
    return result;
}

// Locks the page's first check: 10 s of every simulated node at 60 Hz, read forwards, backwards,
// in a scattered order with and without checkpoints, and from fresh readers, give the same bits.
// The feedback chase settles on 1 / 1.8 within 1e-9 by 10 s.
test "forward play and any seek give the same values" {
    var scene: Scene = undefined;
    try scene.init();
    const rate = Rate.from_hz(60).?;
    const frames_count = 600;
    var slab: [Scene.slab_count]f64 = undefined;
    var checkpoints: [12 * Scene.slab_count]f64 = undefined;
    var state = State.init_with_checkpoints(scene.program, &slab, &checkpoints);
    var forward: [frames_count][4]f64 = undefined;
    for (&forward, 0..) |*values, frame| {
        values.* = scene.read(&state, Time.from_ticks(@intCast(frame), rate).?);
    }
    try testing.expectEqual(@as(u32, 9), state.checkpoints_filled);

    var frame: usize = frames_count;
    while (frame > 0) {
        frame -= 1;
        const values = scene.read(&state, Time.from_ticks(@intCast(frame), rate).?);
        try testing.expectEqual(forward[frame], values);
    }
    var slab_plain: [Scene.slab_count]f64 = undefined;
    var plain = State.init(scene.program, &slab_plain);
    var hop: usize = 0;
    for (0..frames_count) |index| {
        hop = (hop + 389) % frames_count;
        const time = Time.from_ticks(@intCast(hop), rate).?;
        try testing.expectEqual(forward[hop], scene.read(&state, time));
        if (index % 5 != 0) continue;
        try testing.expectEqual(forward[hop], scene.read(&plain, time));
        var slab_fresh: [Scene.slab_count]f64 = undefined;
        var fresh = State.init(scene.program, &slab_fresh);
        try testing.expectEqual(forward[hop], scene.read(&fresh, time));
    }
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 1.8), forward[frames_count - 1][3], 1e-9);
}

// Locks the page's second check: readers at 24, 60, 240, and 960 Hz through 5 s give the same
// bits at every instant they share, every 1/12 s, each halfway between two steps. Readers at 25,
// 144, and 44,100 Hz, which 480 does not divide, give the same bits at each whole second.
test "simulated signals ignore the reader's rate" {
    var scene: Scene = undefined;
    try scene.init();
    const rates_hz = [_]u32{ 24, 60, 240, 960 };
    var shared: [rates_hz.len][61][4]f64 = undefined;
    for (rates_hz, &shared) |hz, *values| read_shared(&scene, hz, 12, values);
    for (shared[1..]) |values| try testing.expectEqual(shared[0], values);

    const rates_odd_hz = [_]u32{ 25, 144, 44_100, 960 };
    var seconds: [rates_odd_hz.len][6][4]f64 = undefined;
    for (rates_odd_hz, &seconds) |hz, *values| read_shared(&scene, hz, 1, values);
    for (seconds[1..]) |values| try testing.expectEqual(seconds[0], values);
}

/// Plays `scene` from time zero at `hz`, keeping the values at each of `values.len` instants
/// `shared_hz` apart.
fn read_shared(scene: *const Scene, hz: u32, shared_hz: u32, values: [][4]f64) void {
    assert(hz % shared_hz == 0);
    var slab: [Scene.slab_count]f64 = undefined;
    var state = State.init(scene.program, &slab);
    const per_shared = hz / shared_hz;
    for (0..values.len * per_shared - per_shared + 1) |frame| {
        const read = scene.read(&state, Time.from_ticks(@intCast(frame), Rate.from_hz(hz).?).?);
        if (frame % per_shared == 0) values[frame / per_shared] = read;
    }
}

// Locks the bound of section 11 for the page's third check. Without checkpoints, a read at 10 s
// runs all 4,800 steps, and a read back at 9.99 s runs them again. With room for ten, one read at
// 10.5 s fills them all, and from then on no read anywhere in 10.5 s runs more than 479 steps.
test "after a pre-roll no seek runs more than one interval of steps" {
    var scene: Scene = undefined;
    try scene.init();
    const start = scene.cues.at(scene.program.start).flicks;
    var slab_plain: [Scene.slab_count]f64 = undefined;
    var plain = State.init(scene.program, &slab_plain);
    _ = scene.read(&plain, .{ .flicks = start + 10 * flicks_per_second - 1 });
    try testing.expectEqual(@as(u64, 4800), plain.steps_run);
    _ = scene.read(&plain, .{ .flicks = start + 999 * flicks_per_second / 100 });
    try testing.expectEqual(@as(u64, 4800 + 4796), plain.steps_run);

    var slab: [Scene.slab_count]f64 = undefined;
    var checkpoints: [10 * Scene.slab_count]f64 = undefined;
    var state = State.init_with_checkpoints(scene.program, &slab, &checkpoints);
    try testing.expectEqual(@as(u32, 10), state.checkpoints_count());
    _ = scene.read(&state, .{ .flicks = start + 21 * flicks_per_second / 2 });
    try testing.expectEqual(@as(u32, 10), state.checkpoints_filled);
    var steps_max: u64 = 0;
    var hop: i64 = 0;
    for (0..2000) |_| {
        hop = @mod(hop + 3_708_281_731, 21 * flicks_per_second / 2);
        const steps_before = state.steps_run;
        _ = scene.read(&state, .{ .flicks = start + hop });
        steps_max = @max(steps_max, state.steps_run - steps_before);
    }
    try testing.expectEqual(simulation.checkpoint_interval - 1, steps_max);
}

// Locks section 10 on the smallest cycle: a delay fed by itself plus one counts steps. It is 0
// before the start, 480 at 1 s, 1.5 halfway through the second step, and the sum is one more.
test "a delay closes a cycle and gives the step before" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 5, .cues = &cues });
    const count = try builder.delay(0);
    const one = try builder.constant(1);
    const sum = try builder.add(count, one);
    try builder.close(count, sum);
    var slab: [5]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    const rows = [_]struct { flicks: i64, count: f64 }{
        .{ .flicks = -1, .count = 0 },
        .{ .flicks = 0, .count = 0 },
        .{ .flicks = 3 * simulation.step.flicks / 2, .count = 1.5 },
        .{ .flicks = flicks_per_second, .count = 480 },
        .{ .flicks = 3 * simulation.step.flicks, .count = 3 },
    };
    for (rows) |row| {
        state.eval(.{ .flicks = row.flicks });
        try testing.expectEqual(row.count, state.value(count));
        try testing.expectEqual(row.count + 1, state.value(sum));
    }
}

/// A program of one chase from 0 of the tween `target_source`.
fn chase_alone(
    nodes: []Node,
    cues: *const Cues,
    law_time: Time,
    overshoot: f64,
    target_source: Tween,
) !struct { program: Program, chase: Id } {
    var builder = Builder.init(nodes, .{ .slab_count_max = 5, .cues = cues });
    const target = try builder.tween(target_source);
    const chase = try builder.chase(.{
        .target = target,
        .from = 0,
        .time = law_time,
        .overshoot = overshoot,
    });
    return .{ .program = builder.finish(), .chase = chase };
}

// Locks step 5's deferred spring with a moving target on two worked cases. Chasing a constant 1
// (a tween that is already there) from 0, it is step 5's spring folded at every step: within
// 1e-12 at every step of 2 s, for omega 8 critical and for overshoot 0.163. Chasing a ramp of
// 1 per second, a critical spring of period 0.5 s lags 2 / omega + step / 2 = 0.160197 s at 10 s.
test "a chase follows a moving target" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var nodes: [2]Node = undefined;
    var slab: [5]f64 = undefined;
    const omega_8: Time = .{ .flicks = 554_176_944 };
    for ([_]f64{ 0, 0.163 }) |overshoot| {
        var constant_source = tween_of(1, 1, cue, .linear);
        constant_source.duration = .{ .flicks = 1 };
        const built = try chase_alone(&nodes, &cues, omega_8, overshoot, constant_source);
        var state = State.init(built.program, &slab);
        const law: motion.Law = .{ .spring = motion.SpringLaw.of(omega_8, overshoot) };
        for (0..961) |index| {
            state.eval(.{ .flicks = @as(i64, @intCast(index)) * simulation.step.flicks });
            const seconds = @as(f64, @floatFromInt(index)) / 480;
            const whole = motion.advance(law, .{ .position = 0, .velocity = 0 }, 1, seconds);
            try testing.expectApproxEqAbs(whole.position, state.value(built.chase), 1e-12);
        }
    }
    var ramp = tween_of(0, 100, cue, .linear);
    ramp.duration = .{ .flicks = 100 * flicks_per_second };
    const half_second: Time = .{ .flicks = flicks_per_second / 2 };
    const built = try chase_alone(&nodes, &cues, half_second, 0, ramp);
    var state = State.init(built.program, &slab);
    state.eval(.{ .flicks = 10 * flicks_per_second });
    const lag_expected: f64 = 2.0 / (std.math.tau / 0.5) + simulation.step_seconds / 2.0;
    try testing.expectApproxEqAbs(lag_expected, 10 - state.value(built.chase), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.160197), lag_expected, 5e-7);
}

// Locks a follower's timeline with a Newtonian mover (speed 4, accel 2, decel 4), regions fixed
// at 2 and 5 in turn, and a pause of exactly 0.5 s. From 0 to 2 takes sqrt 3 s, so it lands at
// step 832, the first step after 831.38; holds 2 for 240 steps; leaves at step 1073; takes
// 2.1213 s to 5, landing at step 2091; and holds 5 until step 2331.
test "a follower lands, pauses, and moves on" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    var region_entries: [2]simulation.Region = undefined;
    var regions = simulation.Regions.init(&region_entries);
    const span = try regions.add(&.{ .{ .low = 2, .high = 2 }, .{ .low = 5, .high = 5 } });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 9,
        .cues = &cues,
        .regions = regions.table(),
    });
    const half_second: Time = .{ .flicks = flicks_per_second / 2 };
    const follower = try builder.follow(.{
        .from = 0,
        .regions = span,
        .pick = .cycle,
        .mover = .{ .newtonian = .{ .speed = 4, .accel = 2, .decel = 4 } },
        .tolerance = 0,
        .pause_min = half_second,
        .pause_max = half_second,
        .seed = 0,
    });
    var slab: [9]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    const rows = [_]struct { step: i64, low: f64, high: f64 }{
        .{ .step = 1, .low = 0, .high = 0.001 },
        .{ .step = 831, .low = 1.999, .high = 2 - 1e-9 },
        .{ .step = 832, .low = 2, .high = 2 },
        .{ .step = 1072, .low = 2, .high = 2 },
        .{ .step = 1073, .low = 2 + 1e-9, .high = 2.001 },
        .{ .step = 2090, .low = 4.999, .high = 5 - 1e-9 },
        .{ .step = 2091, .low = 5, .high = 5 },
        .{ .step = 2331, .low = 5, .high = 5 },
        .{ .step = 2332, .low = 4.999, .high = 5 - 1e-9 },
    };
    for (rows) |row| {
        state.eval(.{ .flicks = row.step * simulation.step.flicks });
        const value = state.value(follower);
        try testing.expect(value >= row.low);
        try testing.expect(value <= row.high);
    }
}

// Locks that a cue move reaches a simulated reader: after moving the chase's target cue, a reader
// that has played past it gives what a fresh reader gives, which differs for the chase and not
// for the follower. Moving both cues by any amount, a flick or a day, shifts every simulated
// node by exactly that time.
test "moving a cue reaches a simulation" {
    var scene: Scene = undefined;
    try scene.init();
    var slab: [Scene.slab_count]f64 = undefined;
    var checkpoints: [4 * Scene.slab_count]f64 = undefined;
    var state = State.init_with_checkpoints(scene.program, &slab, &checkpoints);
    const time: Time = .{ .flicks = 3 * flicks_per_second };
    const before = scene.read(&state, time);
    try scene.cues.move(.{ .index = 1 }, .{ .flicks = 2 * flicks_per_second + 12_345_678 });
    const after = scene.read(&state, time);
    var slab_fresh: [Scene.slab_count]f64 = undefined;
    var fresh = State.init(scene.program, &slab_fresh);
    try testing.expectEqual(scene.read(&fresh, time), after);
    try testing.expect(before[0] != after[0]);
    try testing.expectEqual(before[1], after[1]);

    var expected: [64][4]f64 = undefined;
    for (&expected, 0..) |*values, index| {
        values.* = scene.read(&state, .{ .flicks = @as(i64, @intCast(index)) * 23_456_789 });
    }
    for ([_]i64{ 1, -7_777_777, 86_400 * flicks_per_second }) |shift| {
        try scene.shift_cues(shift);
        for (expected, 0..) |values, index| {
            const flicks = @as(i64, @intCast(index)) * 23_456_789 + shift;
            try testing.expectEqual(values, scene.read(&state, .{ .flicks = flicks }));
        }
        try scene.shift_cues(-shift);
    }
}

// Locks the layout of section 9 over 3 lanes: after a constant at 0, a chase at 3 keeps 3 lanes
// of before, after, and velocity, so a delay after it starts at 15, and the delay's 3 lanes of
// before and after end the slab at 24. Each chase lane follows its own lane of the target, and
// the delay holds its initial value in all three at the start.
test "a simulated node keeps its state after its output" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 30, .cues = &cues });
    builder.extent = .{ .lanes = 3, .components = 1 };
    const two = try builder.constant(2);
    const chase = try builder.chase(.{
        .target = two,
        .from = 0,
        .time = .{ .flicks = flicks_per_second },
        .overshoot = 0,
    });
    const echo = try builder.delay(-1);
    try builder.close(echo, chase);
    const program = builder.finish();
    try testing.expect(program.simulated);
    try testing.expectEqual(@as(u32, 15), program.nodes[echo.index].offset);
    try testing.expectEqual(@as(u32, 24), program.slab_count);
    var slab: [24]f64 = undefined;
    var state = State.init(program, &slab);
    state.eval(.{ .flicks = flicks_per_second });
    const value = state.values(chase)[0];
    try testing.expect(value > 1.9);
    try testing.expectEqualSlices(f64, &@as([3]f64, @splat(value)), state.values(chase));
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &@as([3]f64, @splat(-1)), state.values(echo));

    var nodes_pure: [1]Node = undefined;
    var builder_pure = Builder.init(&nodes_pure, .{ .slab_count_max = 1 });
    _ = try builder_pure.constant(1);
    try testing.expect(!builder_pure.finish().simulated);
}

/// One cue at 0 and one region, [0, 1], for the refusals of the simulated ops.
const Fixture = struct {
    times: [1]Time,
    cues: Cues,
    region_entries: [1]simulation.Region,
    regions: simulation.Regions,
    span: simulation.Span,

    fn init(fixture: *Fixture) !void {
        fixture.cues = Cues.init(&fixture.times);
        _ = try fixture.cues.add(.{ .flicks = 0 });
        fixture.regions = simulation.Regions.init(&fixture.region_entries);
        fixture.span = try fixture.regions.add(&.{.{ .low = 0, .high = 1 }});
    }

    fn builder(fixture: *const Fixture, nodes: []Node) Builder {
        return Builder.init(nodes, .{
            .slab_count_max = 64,
            .cues = &fixture.cues,
            .regions = fixture.regions.table(),
        });
    }
};

// Locks each refusal of `chase`, `delay`, and `close` by name, that nothing refused was built,
// and that a delay can be closed on itself. A simulated node needs a start cue to exist.
test "the builder refuses a chase or a delay it cannot evaluate" {
    var nodes: [4]Node = undefined;
    var empty = Builder.init(&nodes, .{ .slab_count_max = 64 });
    try testing.expectError(error.UnknownCue, empty.delay(0));

    var fixture: Fixture = undefined;
    try fixture.init();
    var builder = fixture.builder(&nodes);
    const second: Time = .{ .flicks = flicks_per_second };
    const nan = std.math.nan(f64);
    var chase: Chase = .{ .target = .{ .index = 0 }, .from = 0, .time = second, .overshoot = 0 };
    try testing.expectError(error.UnknownNode, builder.chase(chase));
    const target = try builder.constant(1);
    chase.target = target;
    chase.from = nan;
    try testing.expectError(error.NotFinite, builder.chase(chase));
    chase.from = 0;
    chase.time = .{ .flicks = 0 };
    try testing.expectError(error.InvalidDuration, builder.chase(chase));
    chase.time = second;
    chase.overshoot = 1;
    try testing.expectError(error.InvalidOvershoot, builder.chase(chase));
    try testing.expectError(error.NotFinite, builder.delay(nan));
    try testing.expectEqual(@as(u32, 1), builder.node_count);

    const echo = try builder.delay(0);
    try testing.expectError(error.NotADelay, builder.close(target, echo));
    try testing.expectError(error.UnknownNode, builder.close(echo, .{ .index = 2 }));
    try builder.close(echo, echo);
    try testing.expectError(error.DelayClosed, builder.close(echo, target));
    _ = builder.finish();
}

// Locks each refusal of `follow` and `shift` by name, that nothing refused was built, and the
// edges that are accepted: the longest pause, and a period of one step per bucket.
test "the builder refuses a follower or a shift register it cannot evaluate" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var nodes: [2]Node = undefined;
    var builder = fixture.builder(&nodes);
    const second: Time = .{ .flicks = flicks_per_second };
    const nan = std.math.nan(f64);
    var follow: Follow = .{
        .from = 0,
        .regions = fixture.span,
        .pick = .cycle,
        .mover = .{ .newtonian = .{ .speed = 1, .accel = 1, .decel = 0 } },
        .tolerance = 0,
        .pause_min = second,
        .pause_max = second,
        .seed = 0,
    };
    try testing.expectError(error.InvalidLimit, builder.follow(follow));
    follow.mover = .{ .spring = .{ .time = second, .overshoot = 0 } };
    const unknowns = [_]simulation.Span{
        .{ .first = 0, .count = 0 },
        .{ .first = 0, .count = 2 },
        .{ .first = 2, .count = 1 },
    };
    for (unknowns) |unknown| {
        follow.regions = unknown;
        try testing.expectError(error.UnknownRegions, builder.follow(follow));
    }
    follow.regions = fixture.span;
    follow.tolerance = -0.1;
    try testing.expectError(error.InvalidTolerance, builder.follow(follow));
    follow.tolerance = nan;
    try testing.expectError(error.NotFinite, builder.follow(follow));
    follow.tolerance = 0;
    const pause_steps_beyond: i64 = simulation.pause_steps_max + 1;
    const pauses = [_][2]i64{ .{ -1, 0 }, .{ 2, 1 }, .{ 0, pause_steps_beyond * step_flicks } };
    for (pauses) |pause| {
        follow.pause_min = .{ .flicks = pause[0] };
        follow.pause_max = .{ .flicks = pause[1] };
        try testing.expectError(error.InvalidPause, builder.follow(follow));
    }

    var shift: Shift = .{
        .buckets = 0,
        .period = second,
        .low = 0,
        .high = 1,
        .odds = 0.5,
        .shape = .steps,
        .seed = 0,
    };
    try testing.expectError(error.InvalidBuckets, builder.shift(shift));
    shift.buckets = simulation.buckets_max + 1;
    try testing.expectError(error.InvalidBuckets, builder.shift(shift));
    shift.buckets = 4;
    shift.odds = nan;
    try testing.expectError(error.NotFinite, builder.shift(shift));
    for ([_]f64{ -0.1, 1.1 }) |odds| {
        shift.odds = odds;
        try testing.expectError(error.InvalidOdds, builder.shift(shift));
    }
    shift.odds = 1;
    for ([_]i64{ 0, 4 * step_flicks - 1, (1 << 53) + 1 }) |period| {
        shift.period = .{ .flicks = period };
        try testing.expectError(error.InvalidDuration, builder.shift(shift));
    }
    try testing.expectEqual(@as(u32, 0), builder.node_count);

    shift.period = .{ .flicks = 4 * step_flicks };
    _ = try builder.shift(shift);
    follow.pause_min = .{ .flicks = 0 };
    follow.pause_max = .{ .flicks = simulation.pause_steps_max * step_flicks };
    _ = try builder.follow(follow);
}

/// One cue at 0, for the event tests of a single source.
fn cue_table_at_zero(times: *[1]Time) !Cues {
    var cues = Cues.init(times);
    _ = try cues.add(.{ .flicks = 0 });
    return cues;
}

/// A bounce between 0 and 1 at 0.7 units a second from the cue at 0, alone in a program.
fn bounce_alone(nodes: *[2]Node, cues: *const Cues) !BounceIds {
    var builder = Builder.init(nodes, .{ .slab_count_max = 2, .cues = cues });
    const ids = try builder.bounce(.{
        .low = 0,
        .high = 1,
        .speed = 0.7,
        .start = .{ .index = 0 },
    });
    _ = builder.finish();
    return ids;
}

// Locks the bounce worked on the page: 0.7 units a second between 0 and 1 is a leg of
// 1,008,000,000.0000001 flicks in an f64, so the hits are one flick after each 1/0.7 s, at
// 1,008,000,001, 2,016,000,001, 3,024,000,001, and 4,032,000,001. [0, 1 s) has none, [1, 2 s) the
// first at +0.7, and [2, 3 s) the second at -0.7. At each hit the position is on its wall exactly,
// and a flick before, it is not.
test "a bounce hits its walls at exact flicks" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [2]Node = undefined;
    const ids = try bounce_alone(&nodes, &cues);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &cues,
        .goals = &.{},
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2,
    };
    var slab: [2]f64 = undefined;
    var state = State.init(program, &slab);
    var out: [4]Event = undefined;
    const second = flicks_per_second;
    try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, state.events(
        .{ .flicks = 0 },
        .{ .flicks = second },
        &out,
    ));
    const first = state.events(.{ .flicks = second }, .{ .flicks = 2 * second }, &out);
    try testing.expectEqual(Events{ .count = 1, .dropped = 0 }, first);
    try testing.expectEqual(Event{
        .time = .{ .flicks = 1_008_000_001 },
        .source = ids.position,
        .instance = 0,
        .value = 0.7,
    }, out[0]);
    const next = state.events(.{ .flicks = 2 * second }, .{ .flicks = 3 * second }, &out);
    try testing.expectEqual(Events{ .count = 1, .dropped = 0 }, next);
    try testing.expectEqual(@as(i64, 2_016_000_001), out[0].time.flicks);
    try testing.expectEqual(@as(f64, -0.7), out[0].value);

    const all = state.events(.{ .flicks = 0 }, .{ .flicks = 6 * second }, &out);
    try testing.expectEqual(Events{ .count = 4, .dropped = 0 }, all);
    const hits = [_]i64{ 1_008_000_001, 2_016_000_001, 3_024_000_001, 4_032_000_001 };
    for (out, hits, 0..) |event, flicks, index| {
        try testing.expectEqual(flicks, event.time.flicks);
        const wall: f64 = if (index % 2 == 0) 1 else 0;
        state.eval(event.time);
        try testing.expectEqual(wall, state.value(ids.position));
        const velocity_after: f64 = if (index % 2 == 0) -0.7 else 0.7;
        try testing.expectEqual(velocity_after, state.value(ids.velocity));
        state.eval(.{ .flicks = flicks - 1 });
        try testing.expect(state.value(ids.position) != wall);
        try testing.expectEqual(event.value, state.value(ids.velocity));
    }
    state.eval(.{ .flicks = -1 });
    try testing.expectEqual(@as(f64, 0), state.value(ids.position));
    try testing.expectEqual(@as(f64, 0), state.value(ids.velocity));
    // Halfway through 0.5 s of real time is not halfway through the first leg, a flick longer.
    state.eval(.{ .flicks = 504_000_000 });
    try testing.expectEqual(@as(f64, 504_000_000.0 / 1_008_000_001.0), state.value(ids.position));
}

/// The event sources of the mixed graph, each of which can also be built alone.
const Source = enum { bounce, crossing, follow, shift, cues, spring };

/// A start cue half a step after 0.5 s, so no reader at a rate that divides 480 Hz lands on a
/// step, then cues at 2, 5, 5, and 9 s. A graph of every event source: a bounce, a crossing of 0
/// by a chase of a slow wave, a follower, a shift register, the cues, and a spring with a goal at
/// each cue but the start, or one of them alone.
const Mixed = struct {
    times: [5]Time,
    cues: Cues,
    region_entries: [2]simulation.Region,
    regions: simulation.Regions,
    goal_entries: [4]Goal,
    goals: motion.Goals,
    nodes: [12]Node,
    program: Program,

    const slab_count_max = 64;

    fn init(mixed: *Mixed, only: ?Source) !void {
        mixed.cues = Cues.init(&mixed.times);
        const start = try mixed.cues.add(.{
            .flicks = flicks_per_second / 2 + simulation.step.flicks / 2,
        });
        var cues: [4]Cue = undefined;
        for (&cues, [_]i64{ 2, 5, 5, 9 }) |*cue, seconds| {
            cue.* = try mixed.cues.add(.{ .flicks = seconds * flicks_per_second });
        }
        mixed.regions = simulation.Regions.init(&mixed.region_entries);
        const span = try mixed.regions.add(&.{
            .{ .low = -1, .high = -0.5 },
            .{ .low = 0.5, .high = 1 },
        });
        mixed.goals = motion.Goals.init(&mixed.goal_entries);
        const path = try mixed.goals.add(&.{
            .{ .cue = cues[0], .value = 1 },
            .{ .cue = cues[1], .value = -1 },
            .{ .cue = cues[2], .value = 0.5 },
            .{ .cue = cues[3], .value = 0.5 },
        });
        var builder = Builder.init(&mixed.nodes, .{
            .slab_count_max = slab_count_max,
            .cues = &mixed.cues,
            .goals = mixed.goals.table(),
            .regions = mixed.regions.table(),
            .start = start,
            .seed = 33,
        });
        for (std.enums.values(Source)) |source| {
            if (only) |alone| if (alone != source) continue;
            try build_source(&builder, source, start, span, path);
        }
        mixed.program = builder.finish();
    }

    fn build_source(
        builder: *Builder,
        source: Source,
        start: Cue,
        span: simulation.Span,
        path: motion.Path,
    ) !void {
        switch (source) {
            .bounce => _ = try builder.bounce(.{
                .low = -1,
                .high = 1,
                .speed = 1.4,
                .start = start,
            }),
            .crossing => {
                const wave = try builder.wave(.{ .shape = .triangle, .hz = 0.5 });
                const chase = try builder.chase(.{
                    .target = wave,
                    .from = 0,
                    .time = .{ .flicks = flicks_per_second / 3 },
                    .overshoot = 0.2,
                });
                _ = try builder.crossing(.{ .input = chase, .level = 0, .direction = .both });
            },
            .follow => _ = try builder.follow(.{
                .from = 0,
                .regions = span,
                .pick = .random,
                .mover = .{ .spring = .{
                    .time = .{ .flicks = flicks_per_second / 4 },
                    .overshoot = 0,
                } },
                .tolerance = 0.01,
                .pause_min = .{ .flicks = flicks_per_second / 10 },
                .pause_max = .{ .flicks = flicks_per_second * 3 / 10 },
                .seed = 3,
            }),
            .shift => _ = try builder.shift(.{
                .buckets = 8,
                .period = .{ .flicks = 2 * flicks_per_second },
                .low = -1,
                .high = 1,
                .odds = 0.5,
                .shape = .smooth,
                .seed = 4,
            }),
            .cues => _ = try builder.cues(.{ .first = start, .count = 5 }),
            .spring => _ = try builder.spring(.{
                .from = 0,
                .goals = path,
                .time = .{ .flicks = flicks_per_second / 2 },
                .overshoot = 0.1,
            }),
        }
    }
};

const events_max = 1 << 15;
var events_whole: [events_max]Event = undefined;
var events_joined: [events_max]Event = undefined;

/// The events of `[0, end)` on a fresh reader of `program`, in `out`, none dropped.
fn events_at_once(program: Program, end: Time, out: []Event) ![]const Event {
    var slab: [Mixed.slab_count_max]f64 = undefined;
    var state = State.init(program, &slab);
    const result = state.events(.{ .flicks = 0 }, end, out);
    try testing.expectEqual(@as(u64, 0), result.dropped);
    return out[0..result.count];
}

/// How a test splits `[0, end)`: into blocks of one length, or at drawn cut points.
const Split = union(enum) {
    block: i64,
    drawn: u64,
};

/// The events of `[0, end)` on a fresh reader of `program`, split as `split` says, each range's
/// events after the last's in `out`, none dropped. Between ranges it evaluates at `eval_seed`'s
/// drawn times, if given.
fn events_split(
    program: Program,
    end: Time,
    split: Split,
    eval_seed: ?u64,
    out: []Event,
) ![]const Event {
    var slab: [Mixed.slab_count_max]f64 = undefined;
    var checkpoints: [4 * Mixed.slab_count_max]f64 = undefined;
    var state = State.init_with_checkpoints(program, slab[0..program.slab_count], &checkpoints);
    var prng = std.Random.DefaultPrng.init(switch (split) {
        .block => 0,
        .drawn => |seed| seed,
    });
    var evals = std.Random.DefaultPrng.init(eval_seed orelse 0);
    var count: u32 = 0;
    var t0: Time = .{ .flicks = 0 };
    while (t0.flicks < end.flicks) {
        const length: i64 = switch (split) {
            .block => |block| block,
            // Empty ranges, a flick, and up to a second and a half.
            .drawn => prng.random().intRangeLessThan(i64, 0, 3 * flicks_per_second / 2),
        };
        const t1: Time = .{ .flicks = @min(t0.flicks + length, end.flicks) };
        const result = state.events(t0, t1, out[count..]);
        try testing.expectEqual(@as(u64, 0), result.dropped);
        count += result.count;
        if (eval_seed != null) {
            state.eval(.{ .flicks = evals.random().intRangeLessThan(i64, 0, end.flicks) });
        }
        t0 = t1;
    }
    return out[0..count];
}

const audio_block_flicks = 1_881_600;

// Locks the splitting promise of section 11: for each source alone and for the mixed graph, the
// events of [0, 60 s) equal, byte for byte, the events of every split into audio blocks, 1/60 s,
// 1 s, and 7 s, and at drawn cut points, empty ranges among them. Every source fires.
test "splitting a range never changes its events" {
    const minute: Time = .{ .flicks = 60 * flicks_per_second };
    const splits = [_]Split{
        .{ .block = audio_block_flicks },
        .{ .block = flicks_per_second / 60 },
        .{ .block = flicks_per_second },
        .{ .block = 7 * flicks_per_second },
        .{ .drawn = 1 },
        .{ .drawn = 2 },
    };
    var mixed: Mixed = undefined;
    for ([_]?Source{ null, .bounce, .crossing, .follow, .shift, .cues, .spring }) |only| {
        try mixed.init(only);
        const whole = try events_at_once(mixed.program, minute, &events_whole);
        try testing.expect(whole.len > 0);
        for (splits) |split| {
            const joined = try events_split(mixed.program, minute, split, null, &events_joined);
            try testing.expectEqualSlices(Event, whole, joined);
        }
        if (only == null) {
            var sources_firing: u32 = 0;
            for (mixed.program.nodes, 0..) |_, index| {
                for (whole) |event| {
                    if (event.source.index == index) {
                        sources_firing += 1;
                        break;
                    }
                }
            }
            try testing.expectEqual(@as(u32, 6), sources_firing);
        }
    }
}

// Locks the splitting promise over an hour of the mixed graph, against blocks of a second.
test "an hour of events equals its seconds" {
    var mixed: Mixed = undefined;
    try mixed.init(null);
    const hour: Time = .{ .flicks = 3600 * flicks_per_second };
    const whole = try events_at_once(mixed.program, hour, &events_whole);
    try testing.expect(whole.len > 10_000);
    const split: Split = .{ .block = flicks_per_second };
    const joined = try events_split(mixed.program, hour, split, null, &events_joined);
    try testing.expectEqualSlices(Event, whole, joined);
}

// Locks that event times do not depend on the reader: blocks at 44.1 kHz and 48 kHz of 128
// samples, and at 60 Hz, give the events of the whole 10 s, and so does any of them with evals at
// drawn times between its ranges.
test "events ignore the reader's rate and its evals" {
    var mixed: Mixed = undefined;
    try mixed.init(null);
    const end: Time = .{ .flicks = 10 * flicks_per_second };
    const whole = try events_at_once(mixed.program, end, &events_whole);
    const blocks = [_]i64{ 128 * 16_000, audio_block_flicks, flicks_per_second / 60 };
    for (blocks, 0..) |block, index| {
        for ([_]?u64{ null, index + 7 }) |eval_seed| {
            const split: Split = .{ .block = block };
            const joined = try events_split(mixed.program, end, split, eval_seed, &events_joined);
            try testing.expectEqualSlices(Event, whole, joined);
        }
    }
}

// Locks the first decision of the page: [30 s, 40 s), then [5 s, 10 s), then [30 s, 40 s) again
// give the same events each time, with and without checkpoints, and the same as a fresh reader.
test "a past range gives its events again" {
    var mixed: Mixed = undefined;
    try mixed.init(null);
    const ranges = [_][2]i64{ .{ 30, 40 }, .{ 5, 10 }, .{ 30, 40 } };
    var first: [3][256]Event = undefined;
    var counts: [3]u32 = undefined;
    for (ranges, &first, &counts) |range, *out, *count| {
        var slab: [Mixed.slab_count_max]f64 = undefined;
        var state = State.init(mixed.program, &slab);
        const t0: Time = .{ .flicks = range[0] * flicks_per_second };
        const t1: Time = .{ .flicks = range[1] * flicks_per_second };
        const result = state.events(t0, t1, out);
        try testing.expectEqual(@as(u64, 0), result.dropped);
        count.* = result.count;
    }
    for ([_]u32{ 0, 64 }) |checkpoints_count| {
        var slab: [Mixed.slab_count_max]f64 = undefined;
        var checkpoints: [64 * Mixed.slab_count_max]f64 = undefined;
        const room = checkpoints[0 .. checkpoints_count * mixed.program.slab_count];
        const slab_used = slab[0..mixed.program.slab_count];
        var state = State.init_with_checkpoints(mixed.program, slab_used, room);
        for (ranges, first, counts) |range, expected, count| {
            var out: [256]Event = undefined;
            const t0: Time = .{ .flicks = range[0] * flicks_per_second };
            const t1: Time = .{ .flicks = range[1] * flicks_per_second };
            const result = state.events(t0, t1, &out);
            try testing.expectEqual(Events{ .count = count, .dropped = 0 }, result);
            try testing.expectEqualSlices(Event, expected[0..count], out[0..count]);
        }
    }
    try testing.expect(counts[0] > 10);
    try testing.expectEqualSlices(Event, first[0][0..counts[0]], first[2][0..counts[2]]);
}

// Locks the bound of section 11: over 10 s of consecutive 1/60 s ranges, each runs exactly the
// steps it spans, from the step the last one left, and an eval at its end runs none, since the
// start cue keeps every end off a step.
test "events never run ahead of the reader" {
    var mixed: Mixed = undefined;
    try mixed.init(null);
    const start = mixed.cues.at(mixed.program.start);
    var slab: [Mixed.slab_count_max]f64 = undefined;
    var state = State.init(mixed.program, &slab);
    var out: [64]Event = undefined;
    const frame = flicks_per_second / 60;
    for (0..600) |index| {
        const t0: Time = .{ .flicks = @as(i64, @intCast(index)) * frame };
        const t1: Time = .{ .flicks = t0.flicks + frame };
        const steps_before = state.steps_run;
        _ = state.events(t0, t1, &out);
        const spanned = step_ceiling(start, t1) - step_ceiling(start, t0);
        try testing.expectEqual(steps_before + spanned, state.steps_run);
        state.eval(t1);
        try testing.expectEqual(steps_before + spanned, state.steps_run);
    }
    try testing.expectEqual(@as(u64, 4800 - 240), state.steps_run);
}

// Locks the overflow rule of `event.zig`: a buffer of 2 over the 4 hits of the worked bounce keeps
// the first 2 and counts 2, an empty one counts all 4, and a canary after the buffer is untouched.
// Over a minute of the mixed graph, 10 kept events are the head of the full list, and the rest
// are counted exactly.
test "overflow keeps the earliest events and counts the rest exactly" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [2]Node = undefined;
    _ = try bounce_alone(&nodes, &cues);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &cues,
        .goals = &.{},
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2,
    };
    var slab: [2]f64 = undefined;
    var state = State.init(program, &slab);
    const end: Time = .{ .flicks = 6 * flicks_per_second };
    var full: [4]Event = undefined;
    const zero: Time = .{ .flicks = 0 };
    try testing.expectEqual(Events{ .count = 4, .dropped = 0 }, state.events(zero, end, &full));
    var memory: [3]Event = undefined;
    const canary: Event = .{
        .time = .{ .flicks = -9 },
        .source = .{ .index = 9 },
        .instance = 9,
        .value = 9,
    };
    memory[2] = canary;
    const kept = state.events(zero, end, memory[0..2]);
    try testing.expectEqual(Events{ .count = 2, .dropped = 2 }, kept);
    try testing.expectEqualSlices(Event, full[0..2], memory[0..2]);
    try testing.expectEqual(canary, memory[2]);
    const counted = state.events(zero, end, memory[0..0]);
    try testing.expectEqual(Events{ .count = 0, .dropped = 4 }, counted);
    try testing.expectEqual(canary, memory[2]);

    var mixed: Mixed = undefined;
    try mixed.init(null);
    const minute: Time = .{ .flicks = 60 * flicks_per_second };
    const whole = try events_at_once(mixed.program, minute, &events_whole);
    var mixed_slab: [Mixed.slab_count_max]f64 = undefined;
    var mixed_state = State.init(mixed.program, &mixed_slab);
    var head: [10]Event = undefined;
    const result = mixed_state.events(.{ .flicks = 0 }, minute, &head);
    try testing.expectEqual(Events{ .count = 10, .dropped = whole.len - 10 }, result);
    try testing.expectEqualSlices(Event, whole[0..10], &head);
}

/// A program of one source over `input_build`'s input, a crossing of it at `level`, with the cue at
/// 0 as the start.
fn crossing_of_tween(nodes: *[2]Node, cues: *const Cues, level: f64) !Id {
    var builder = Builder.init(nodes, .{ .slab_count_max = 4, .cues = cues });
    var rise = tween_of(0, 1, .{ .index = 0 }, .linear);
    rise.duration = .{ .flicks = flicks_per_second };
    const input = try builder.tween(rise);
    const gate = try builder.crossing(.{ .input = input, .level = level, .direction = .rising });
    _ = builder.finish();
    return gate;
}

// Locks the crossing worked on the page: a linear tween from 0 to 1 over 1 s, crossed rising at
// 0.3, lands on the level at step 144, so its event is at exactly 0.3 s, 211,680,000 flicks, where
// the gate turns 1, and a flick before it is 0. At 0.301 the event is at 0.301 s, 212,385,600
// flicks, within a flick: the weight in the step is 0.48000000000000215, so it rounds up to
// 212,385,601. The value is the slope, 1 a second, and there is one event each.
test "a crossing fires where its input crosses, in the step" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    const rows = [_]struct { level: f64, flicks: i64 }{
        .{ .level = 0.3, .flicks = 211_680_000 },
        .{ .level = 0.301, .flicks = 212_385_601 },
    };
    for (rows) |row| {
        var nodes: [2]Node = undefined;
        const gate = try crossing_of_tween(&nodes, &cues, row.level);
        const program: Program = .{
            .nodes = &nodes,
            .cues = &cues,
            .goals = &.{},
            .regions = &.{},
            .samples = &.{},
            .tracks = &Tracks.empty,
            .start = .{ .index = 0 },
            .simulated = true,
            .slab_count = 4,
        };
        var slab: [4]f64 = undefined;
        var state = State.init(program, &slab);
        var out: [4]Event = undefined;
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = 2 * flicks_per_second }, &out);
        try testing.expectEqual(Events{ .count = 1, .dropped = 0 }, result);
        try testing.expectEqual(gate, out[0].source);
        try testing.expectApproxEqAbs(@as(f64, 1), out[0].value, 1e-12);
        try testing.expectEqual(row.flicks, out[0].time.flicks);
        if (row.level == 0.3) {
            state.eval(out[0].time);
            try testing.expectEqual(@as(f64, 1), state.value(gate));
            state.eval(.{ .flicks = row.flicks - 1 });
            try testing.expectEqual(@as(f64, 0), state.value(gate));
        }
    }
}

// Locks the limit of section 11. A 960 Hz sine is two whole cycles a step, so at every step it is
// within rounding of 0, and its crossings of 0.5 come and go inside each step: a second of it
// gives no event, though the gate, exact at any time, is 1 a quarter cycle in. (A 1,000 Hz sine
// would alias to 40 Hz on the step grid and fire at that rate instead.) Falling and both see
// nothing either.
test "a crossing that comes back within a step gives no event" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    for (std.enums.values(Crossing.Direction)) |direction| {
        var nodes: [2]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 4, .cues = &cues });
        const wave = try builder.wave(.{ .shape = .sine, .hz = 960 });
        const gate = try builder.crossing(.{ .input = wave, .level = 0.5, .direction = direction });
        var slab: [4]f64 = undefined;
        var state = State.init(builder.finish(), &slab);
        var out: [4]Event = undefined;
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = flicks_per_second }, &out);
        try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, result);
        state.eval(.{ .flicks = flicks_per_second / 3840 });
        try testing.expectEqual(@as(f64, 1), state.value(gate));
        state.eval(.{ .flicks = 0 });
        try testing.expectEqual(@as(f64, 0), state.value(gate));
    }
}

/// Cues at 1 s and 4 s, one path over them, and a motion of `law` from `from`, alone. The goals
/// are `first` and `second`.
const Reach = struct {
    times: [2]Time,
    cues: Cues,
    entries: [2]Goal,
    goals: motion.Goals,
    nodes: [1]Node,
    program: Program,
    motion: Id,

    fn init(reach: *Reach, law: motion.Law, from: f64, first: f64, second: f64) !void {
        reach.cues = Cues.init(&reach.times);
        const cue_first = try reach.cues.add(.{ .flicks = flicks_per_second });
        const cue_second = try reach.cues.add(.{ .flicks = 4 * flicks_per_second });
        reach.goals = motion.Goals.init(&reach.entries);
        const path = try reach.goals.add(&.{
            .{ .cue = cue_first, .value = first },
            .{ .cue = cue_second, .value = second },
        });
        var builder = Builder.init(&reach.nodes, .{
            .slab_count_max = 1 + motion.cursor_count,
            .cues = &reach.cues,
            .goals = reach.goals.table(),
        });
        reach.motion = switch (law) {
            .spring => |spring| try builder.push(.{ .motion = .{
                .from = from,
                .goals = path,
                .law = .{ .spring = spring },
            } }),
            .newtonian => |limits| try builder.newtonian(.{
                .from = from,
                .goals = path,
                .speed = limits.speed,
                .accel = limits.accel,
                .decel = limits.decel,
            }),
        };
        reach.program = builder.finish();
    }

    /// The events of the first minute.
    fn events(reach: *const Reach, out: []Event) ![]const Event {
        var slab: [1 + motion.cursor_count]f64 = undefined;
        var state = State.init(reach.program, &slab);
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = 60 * flicks_per_second }, out);
        try testing.expectEqual(@as(u64, 0), result.dropped);
        return out[0..result.count];
    }
};

// Locks a goal reached on the page's worked move: speed 4, accel 2, decel 4, from 0 to 2, takes
// sqrt 3 s, 1,222,135,049.8 flicks, so the event is 1,222,135,050 flicks after the cue at 1 s,
// the first flick where the closed form returns the goal at rest; the flick before does not. The
// next goal, 2 again, is already met at rest, so it fires at its own cue. Moving the first cue by
// 0.25 s moves its event by exactly that.
test "a Newtonian move fires when it lands, and a goal already met fires at its cue" {
    const limits: motion.Limits = .{ .speed = 4, .accel = 2, .decel = 4 };
    var reach: Reach = undefined;
    try reach.init(.{ .newtonian = limits }, 0, 2, 2);
    var out: [4]Event = undefined;
    const events = try reach.events(&out);
    try testing.expectEqual(@as(usize, 2), events.len);
    const landed = flicks_per_second + 1_222_135_050;
    try testing.expectEqual(Event{
        .time = .{ .flicks = landed },
        .source = reach.motion,
        .instance = 0,
        .value = 2,
    }, events[0]);
    try testing.expectEqual(@as(i64, 4 * flicks_per_second), events[1].time.flicks);
    const law: motion.Law = .{ .newtonian = limits };
    const rest: motion.Kinematics = .{ .position = 0, .velocity = 0 };
    const at: motion.Kinematics = .{ .position = 2, .velocity = 0 };
    const seconds_at = @as(f64, 1_222_135_050) / flicks_per_second_float;
    const seconds_before = @as(f64, 1_222_135_049) / flicks_per_second_float;
    try testing.expectEqual(at, motion.advance(law, rest, 2, seconds_at));
    try testing.expect(!std.meta.eql(at, motion.advance(law, rest, 2, seconds_before)));
    var slab: [1 + motion.cursor_count]f64 = undefined;
    var state = State.init(reach.program, &slab);
    state.eval(events[0].time);
    try testing.expectEqual(@as(f64, 2), state.value(reach.motion));

    try reach.cues.move(.{ .index = 0 }, .{ .flicks = flicks_per_second + flicks_per_second / 4 });
    const moved = try reach.events(&out);
    try testing.expectEqual(landed + flicks_per_second / 4, moved[0].time.flicks);
}

// Locks a spring's goal reached, and a goal cut short. A critical spring of omega 8 from 0 to 1
// settles after about 5.1 s, which is after the next cue at 4 s, so its first goal fires nothing;
// it settles on the second, -1, once, within a minute, where eval returns it exactly. A bouncy
// spring of overshoot 0.2 heading for 1 then back to 0 is the same: one event, the last goal.
test "a spring fires once when it settles, and a goal cut short fires nothing" {
    const critical = motion.SpringLaw.from_omega_zeta(8, 1);
    const bouncy = motion.SpringLaw.of(.{ .flicks = flicks_per_second / 2 }, 0.2);
    for ([_]motion.SpringLaw{ critical, bouncy }, [_]f64{ -1, 0 }) |law, second| {
        var reach: Reach = undefined;
        try reach.init(.{ .spring = law }, 0, 1, second);
        var out: [4]Event = undefined;
        const events = try reach.events(&out);
        try testing.expectEqual(@as(usize, 1), events.len);
        try testing.expectEqual(second, events[0].value);
        try testing.expect(events[0].time.flicks > 4 * flicks_per_second);
        var slab: [1 + motion.cursor_count]f64 = undefined;
        var state = State.init(reach.program, &slab);
        state.eval(events[0].time);
        try testing.expectEqual(second, state.value(reach.motion));
        // The flick before, the closed form from the second cue is not yet at rest on the goal.
        const op = &reach.program.nodes[0].op.motion;
        const cursor_none: [motion.cursor_count]f64 = @splat(0);
        const goals = reach.goals.table();
        const start = motion.kinematics_at_goal(op, goals, &reach.cues, &cursor_none, 1);
        const flicks_before = events[0].time.flicks - 1 - 4 * flicks_per_second;
        const seconds_before = @as(f64, @floatFromInt(flicks_before)) / flicks_per_second_float;
        const before = motion.advance(op.law, start, second, seconds_before);
        try testing.expect(before.position != second or before.velocity != 0);
    }
    // A Newtonian move too slow for its first goal before the next cue, then one that lands.
    var reach: Reach = undefined;
    try reach.init(.{ .newtonian = .{ .speed = 1, .accel = 1, .decel = 1 } }, 0, 10, 0);
    var out: [4]Event = undefined;
    const events = try reach.events(&out);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(f64, 0), events[0].value);
}

// Locks the follower worked on the page: a Newtonian follower (speed 4, accel 2, decel 4) from 0
// to a goal of 2 arrives at step 832, so its first event is at 832 steps, 1,223,040,000 flicks
// after the start, with the goal as the value, and the next at step 2091, at 5.
test "a follower fires at the step it arrives" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var region_entries: [2]simulation.Region = undefined;
    var regions = simulation.Regions.init(&region_entries);
    const span = try regions.add(&.{ .{ .low = 2, .high = 2 }, .{ .low = 5, .high = 5 } });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 9,
        .cues = &cues,
        .regions = regions.table(),
    });
    const half_second: Time = .{ .flicks = flicks_per_second / 2 };
    const follower = try builder.follow(.{
        .from = 0,
        .regions = span,
        .pick = .cycle,
        .mover = .{ .newtonian = .{ .speed = 4, .accel = 2, .decel = 4 } },
        .tolerance = 0,
        .pause_min = half_second,
        .pause_max = half_second,
        .seed = 0,
    });
    var slab: [9]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    var out: [4]Event = undefined;
    const result = state.events(.{ .flicks = 0 }, .{ .flicks = 5 * flicks_per_second }, &out);
    try testing.expectEqual(Events{ .count = 2, .dropped = 0 }, result);
    try testing.expectEqual(Event{
        .time = .{ .flicks = 1_223_040_000 },
        .source = follower,
        .instance = 0,
        .value = 2,
    }, out[0]);
    try testing.expectEqual(@as(i64, 2091 * simulation.step.flicks), out[1].time.flicks);
    try testing.expectEqual(@as(f64, 5), out[1].value);
    state.eval(out[0].time);
    try testing.expectEqual(@as(f64, 2), state.value(follower));
}

// Locks a shift register's events: entering bucket n is at its boundary, pass * period +
// ceil(within * period / buckets) flicks after the start, an exact integer even where the period
// does not divide, and the value is the entered bucket's, which a stepped shape returns there.
// Bucket 0 at the start fires nothing.
test "a shift register fires at each bucket boundary, exactly" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    for ([_]i64{ flicks_per_second, flicks_per_second + 1 }) |period| {
        var nodes: [1]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 16, .cues = &cues });
        const shift = try builder.shift(.{
            .buckets = 3,
            .period = .{ .flicks = period },
            .low = -1,
            .high = 1,
            .odds = 0.5,
            .shape = .steps,
            .seed = 8,
        });
        var slab: [16]f64 = undefined;
        var state = State.init(builder.finish(), &slab);
        var out: [16]Event = undefined;
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = 4 * flicks_per_second }, &out);
        try testing.expectEqual(Events{ .count = 11, .dropped = 0 }, result);
        for (out[0..result.count], 1..) |event, bucket| {
            const pass_index: i64 = @intCast(bucket / 3);
            const within: i64 = @intCast(bucket % 3);
            const within_flicks = std.math.divCeil(i64, within * period, 3) catch unreachable;
            const boundary = pass_index * period + within_flicks;
            try testing.expectEqual(boundary, event.time.flicks);
            state.eval(.{ .flicks = boundary + simulation.step.flicks });
            if (period == flicks_per_second) {
                state.eval(event.time);
                try testing.expectEqual(event.value, state.value(shift));
            }
        }
    }
}

// Locks the order of `event.zig` across sources: a follower arriving at 1,223,040,000 flicks and a
// cue at that flick come out by source index, whichever is built first, though the cue's event is
// found first.
test "events at one flick come out by source index" {
    var times: [2]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    const cue = try cues.add(.{ .flicks = 1_223_040_000 });
    var region_entries: [1]simulation.Region = undefined;
    var regions = simulation.Regions.init(&region_entries);
    const span = try regions.add(&.{.{ .low = 2, .high = 2 }});
    for ([_]bool{ true, false }) |follower_first| {
        var nodes: [2]Node = undefined;
        var builder = Builder.init(&nodes, .{
            .slab_count_max = 10,
            .cues = &cues,
            .regions = regions.table(),
        });
        var ids: [2]Id = undefined;
        for (0..2) |index| {
            const build_follower = (index == 0) == follower_first;
            ids[index] = if (build_follower) try builder.follow(.{
                .from = 0,
                .regions = span,
                .pick = .cycle,
                .mover = .{ .newtonian = .{ .speed = 4, .accel = 2, .decel = 4 } },
                .tolerance = 0,
                .pause_min = .{ .flicks = 2 * flicks_per_second },
                .pause_max = .{ .flicks = 2 * flicks_per_second },
                .seed = 0,
            }) else try builder.cues(.{ .first = cue, .count = 1 });
        }
        var slab: [10]f64 = undefined;
        var state = State.init(builder.finish(), &slab);
        var out: [4]Event = undefined;
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = 2 * flicks_per_second }, &out);
        try testing.expectEqual(Events{ .count = 2, .dropped = 0 }, result);
        for (out[0..2], ids) |event, id| {
            try testing.expectEqual(@as(i64, 1_223_040_000), event.time.flicks);
            try testing.expectEqual(id, event.source);
        }
    }
}

// Locks a cue span's events and signal: cues at 1, 1, and 2 s fire in cue order, the first two at
// one flick, each with its index; the count is 2 from 1 s and 3 from 2 s; and a cue move moves its
// event and its count.
test "cues fire in cue order, and a move moves them" {
    var times: [4]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    const first = try cues.add(.{ .flicks = flicks_per_second });
    _ = try cues.add(.{ .flicks = flicks_per_second });
    const last = try cues.add(.{ .flicks = 2 * flicks_per_second });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &cues });
    const span = try builder.cues(.{ .first = first, .count = 3 });
    var slab: [1]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    var out: [4]Event = undefined;
    const end: Time = .{ .flicks = 3 * flicks_per_second };
    const zero: Time = .{ .flicks = 0 };
    try testing.expectEqual(Events{ .count = 3, .dropped = 0 }, state.events(zero, end, &out));
    const expected = [_][2]i64{
        .{ flicks_per_second, 1 },
        .{ flicks_per_second, 2 },
        .{ 2 * flicks_per_second, 3 },
    };
    for (out[0..3], expected) |event, row| {
        try testing.expectEqual(row[0], event.time.flicks);
        try testing.expectEqual(@as(f64, @floatFromInt(row[1])), event.value);
    }
    const counts = [_][2]i64{
        .{ flicks_per_second - 1, 0 },
        .{ flicks_per_second, 2 },
        .{ 2 * flicks_per_second, 3 },
    };
    for (counts) |row| {
        state.eval(.{ .flicks = row[0] });
        try testing.expectEqual(@as(f64, @floatFromInt(row[1])), state.value(span));
    }
    try cues.move(last, .{ .flicks = 2 * flicks_per_second + 5 });
    try testing.expectEqual(Events{ .count = 3, .dropped = 0 }, state.events(zero, end, &out));
    try testing.expectEqual(2 * flicks_per_second + 5, out[2].time.flicks);
    state.eval(.{ .flicks = 2 * flicks_per_second });
    try testing.expectEqual(@as(f64, 2), state.value(span));
}

// Locks each refusal of `bounce`, `crossing`, and `cues` by name, that nothing refused was built,
// and that a bounce is built whole or not at all.
test "the builder refuses an event source it cannot evaluate" {
    var empty = Builder.init(&.{}, .{ .slab_count_max = 0 });
    const constant_source: Crossing = .{ .input = .{ .index = 0 }, .level = 0, .direction = .both };
    try testing.expectError(error.UnknownNode, empty.crossing(constant_source));

    var fixture: Fixture = undefined;
    try fixture.init();
    var nodes: [2]Node = undefined;
    var builder = fixture.builder(&nodes);
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    var bounce: Bounce = .{ .low = 0, .high = 1, .speed = 1, .start = .{ .index = 0 } };
    for ([_][3]f64{ .{ nan, 1, 1 }, .{ 0, inf, 1 }, .{ 0, 1, nan } }) |row| {
        bounce.low = row[0];
        bounce.high = row[1];
        bounce.speed = row[2];
        try testing.expectError(error.NotFinite, builder.bounce(bounce));
    }
    bounce = .{ .low = 1, .high = 1, .speed = 1, .start = .{ .index = 0 } };
    try testing.expectError(error.InvalidRange, builder.bounce(bounce));
    bounce.high = 0;
    try testing.expectError(error.InvalidRange, builder.bounce(bounce));
    bounce.high = 2;
    for ([_]f64{ 0, -1 }) |speed| {
        bounce.speed = speed;
        try testing.expectError(error.InvalidLimit, builder.bounce(bounce));
    }
    bounce.speed = 1;
    bounce.start = .{ .index = 1 };
    try testing.expectError(error.UnknownCue, builder.bounce(bounce));
    bounce.start = .{ .index = 0 };
    // A leg under a flick, and one of 2^53 flicks or more.
    for ([_]f64{ 2 * flicks_per_second_float, 1e-9 }) |speed| {
        bounce.speed = speed;
        try testing.expectError(error.InvalidDuration, builder.bounce(bounce));
    }
    bounce.low = -std.math.floatMax(f64);
    bounce.high = std.math.floatMax(f64);
    bounce.speed = 1;
    try testing.expectError(error.InvalidDuration, builder.bounce(bounce));
    bounce = .{ .low = 0, .high = 1, .speed = flicks_per_second_float, .start = .{ .index = 0 } };
    try testing.expectEqual(@as(u32, 0), builder.node_count);

    const input = try builder.constant(1);
    try testing.expectError(error.NodeCapacityExceeded, builder.bounce(bounce));
    try testing.expectEqual(@as(u32, 1), builder.node_count);
    var crossing: Crossing = .{ .input = .{ .index = 1 }, .level = 0, .direction = .rising };
    try testing.expectError(error.UnknownNode, builder.crossing(crossing));
    crossing.input = input;
    crossing.level = nan;
    try testing.expectError(error.NotFinite, builder.crossing(crossing));
    const spans = [_]CueSpan{
        .{ .first = .{ .index = 0 }, .count = 0 },
        .{ .first = .{ .index = 0 }, .count = 2 },
        .{ .first = .{ .index = 1 }, .count = 1 },
    };
    for (spans) |span| try testing.expectError(error.UnknownCue, builder.cues(span));
    try testing.expectEqual(@as(u32, 1), builder.node_count);
    crossing.level = 0;
    _ = try builder.crossing(crossing);

    var slab_small = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &fixture.cues });
    try testing.expectError(error.SlabCapacityExceeded, slab_small.bounce(bounce));
    try testing.expectEqual(@as(u32, 0), slab_small.node_count);
    var no_start = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const lonely = try no_start.constant(0);
    crossing.input = lonely;
    try testing.expectError(error.UnknownCue, no_start.crossing(crossing));
    var room = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &fixture.cues });
    const ids = try room.bounce(bounce);
    try testing.expectEqual(@as(u32, 1), ids.velocity.index);
}

/// The ranges of a finished program, for the tests of section 12.
fn ranges_of(program: *const Program, out: []Range) []const Range {
    program.ranges(out);
    return out[0..program.nodes.len];
}

// Locks the worked ranges: exact for a wave, a sum of two, and `x * x`, which interval arithmetic
// gives as [-1, 1]; a one-goal spring at 16.3% overshoot reaches 1.163 and not below its start; a
// critical spring with three goals is the hull of its goals; a Newtonian move is its hull widened
// by its stopping distance, speed^2 / (2 decel) = 2.
test "worked ranges are exact or within their margin" {
    var cue_times: [3]Time = undefined;
    var cues = Cues.init(&cue_times);
    for (0..3) |index| {
        _ = try cues.add(.{ .flicks = @as(i64, @intCast(index)) * flicks_per_second });
    }
    var goal_entries: [5]Goal = undefined;
    var goals = motion.Goals.init(&goal_entries);
    const one = try goals.add(&.{.{ .cue = .{ .index = 0 }, .value = 1 }});
    const three = try goals.add(&.{
        .{ .cue = .{ .index = 0 }, .value = 1 },
        .{ .cue = .{ .index = 1 }, .value = -0.5 },
        .{ .cue = .{ .index = 2 }, .value = 0.25 },
    });
    const glide = try goals.add(&.{.{ .cue = .{ .index = 0 }, .value = 2 }});
    var nodes: [8]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 64,
        .cues = &cues,
        .goals = goals.table(),
    });
    const wave = try builder.wave(carrier);
    const sum = try builder.add(wave, wave);
    const square = try builder.multiply(wave, wave);
    const os = range_module.overshoot(0.5);
    // The overshoot that gives a damping ratio of 0.5 exactly.
    const second: Time = .{ .flicks = flicks_per_second };
    const bouncy = try builder.spring(.{
        .from = 0,
        .goals = one,
        .time = second,
        .overshoot = os,
    });
    const critical = try builder.spring(.{
        .from = 0,
        .goals = three,
        .time = second,
        .overshoot = 0,
    });
    const newtonian = try builder.newtonian(.{
        .from = 0,
        .goals = glide,
        .speed = 4,
        .accel = 2,
        .decel = 4,
    });
    const program = builder.finish();
    var out: [8]Range = undefined;
    const result = ranges_of(&program, &out);
    try testing.expectEqual(Range{ .low = -1, .high = 1 }, result[wave.index]);
    try testing.expectEqual(Range{ .low = -2, .high = 2 }, result[sum.index]);
    try testing.expectEqual(Range{ .low = -1, .high = 1 }, result[square.index]);
    try testing.expectApproxEqAbs(@as(f64, 0.163), os, 0.0005);
    try testing.expect(result[bouncy.index].high >= 1 + os);
    try testing.expectApproxEqAbs(1 + os, result[bouncy.index].high, 1e-10);
    try testing.expect(result[bouncy.index].low <= 0);
    try testing.expectApproxEqAbs(@as(f64, 0), result[bouncy.index].low, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -0.5), result[critical.index].low, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1), result[critical.index].high, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -2), result[newtonian.index].low, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 4), result[newtonian.index].high, 1e-10);
}

/// A critical chase of `1 + gain * delay(chase)`, from 0, returning the chase.
fn build_loop(builder: *Builder, gain: f64, overshoot: f64) Builder.Error!Id {
    const echo = try builder.delay(0);
    const scaled = try builder.multiply(echo, try builder.constant(gain));
    const target = try builder.add(try builder.constant(1), scaled);
    const result = try builder.chase(.{
        .target = target,
        .from = 0,
        .time = .{ .flicks = flicks_per_second / 2 },
        .overshoot = overshoot,
    });
    try builder.close(echo, result);
    return result;
}

// Locks the fixed point of a delay's loop: a critical chase of 1 - 0.8 times its own delay has a
// finite range that holds [0, 1], and one of 1 + 1.25 times its delay, which grows without end,
// has an infinite one.
test "a loop through a delay has a finite range only when it settles" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [6]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 32, .cues = &cues });
    const settling = try build_loop(&builder, -0.8, 0);
    const program = builder.finish();
    var out: [6]Range = undefined;
    const result = ranges_of(&program, &out);
    try testing.expect(std.math.isFinite(result[settling.index].low));
    try testing.expect(std.math.isFinite(result[settling.index].high));
    try testing.expect(result[settling.index].covers(.{ .low = 0, .high = 1 }));
    try testing.expect(result[settling.index].high < 1 + 1e-9);

    var nodes_growing: [6]Node = undefined;
    var growing_builder = Builder.init(&nodes_growing, .{ .slab_count_max = 32, .cues = &cues });
    const growing = try build_loop(&growing_builder, 1.25, 0);
    const growing_program = growing_builder.finish();
    const growing_result = ranges_of(&growing_program, &out);
    try testing.expectEqual(std.math.inf(f64), growing_result[growing.index].high);
}

// Locks that classes rise through inputs, a delay's included: a wave plus a spring is exact, a
// chase plus an input is live, and a delay closed onto a live node is live, as is what reads it.
// The report names the first live node and the first simulated one.
test "classes rise through inputs, and the report names the live node" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var goal_entries: [1]Goal = undefined;
    var goals = motion.Goals.init(&goal_entries);
    const path = try goals.add(&.{.{ .cue = .{ .index = 0 }, .value = 1 }});
    var nodes: [10]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 64,
        .cues = &cues,
        .goals = goals.table(),
    });
    const wave = try builder.wave(carrier);
    const second: Time = .{ .flicks = flicks_per_second };
    const spring = try builder.spring(.{
        .from = 0,
        .goals = path,
        .time = second,
        .overshoot = 0,
    });
    const exact = try builder.add(wave, spring);
    const echo = try builder.delay(0);
    const after_echo = try builder.add(echo, wave);
    const chased = try builder.chase(.{
        .target = wave,
        .from = 0,
        .time = second,
        .overshoot = 0,
    });
    const live = try builder.input(.{ .low = -1, .high = 1 });
    const mixed = try builder.add(chased, live);
    try builder.close(echo, mixed);
    const program = builder.finish();
    var classes: [10]Class = undefined;
    program.classes(&classes);
    try testing.expectEqual(Class.pure, classes[wave.index]);
    try testing.expectEqual(Class.exact, classes[spring.index]);
    try testing.expectEqual(Class.exact, classes[exact.index]);
    try testing.expectEqual(Class.simulated, classes[chased.index]);
    try testing.expectEqual(Class.live, classes[mixed.index]);
    try testing.expectEqual(Class.live, classes[echo.index]);
    try testing.expectEqual(Class.live, classes[after_echo.index]);
    const report = program.report();
    try testing.expect(!report.seekable);
    try testing.expectEqual(live, report.live.?);
    try testing.expect(report.stepped);
    try testing.expectEqual(echo, report.first_simulated.?);

    var pure_nodes: [4]Node = undefined;
    var pure_builder = Builder.init(&pure_nodes, .{ .slab_count_max = 8 });
    _ = try build_tremolo(&pure_builder);
    const pure_report = pure_builder.finish().report();
    try testing.expect(pure_report.seekable);
    try testing.expect(!pure_report.stepped);
    try testing.expectEqual(@as(?Id, null), pure_report.live);
}

// Locks the input's contract: a value outside its range reads as the nearest end, it keeps the
// value set last through a checkpoint restore, since it has no past, and a backward read while
// recording counts a drop and keeps the table in order.
test "an input is clamped, keeps its value, and records forward only" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 8, .cues = &cues });
    const live = try builder.input(.{ .low = 0, .high = 1, .initial = 0.5 });
    const chased = try builder.chase(.{
        .target = live,
        .from = 0,
        .time = .{ .flicks = flicks_per_second },
        .overshoot = 0,
    });
    const program = builder.finish();
    var out: [2]Range = undefined;
    try testing.expectEqual(Range{ .low = 0, .high = 1 }, ranges_of(&program, &out)[live.index]);
    var slab: [8]f64 = undefined;
    var checkpoints: [4 * 8]f64 = undefined;
    var state = State.init_with_checkpoints(program, &slab, &checkpoints);
    var entries: [8]Sample = undefined;
    var recording = Recording.init(&entries);
    state.record(live, &recording);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 0.5), state.value(live));
    state.set_input(live, 2);
    state.eval(.{ .flicks = 3 * flicks_per_second });
    try testing.expectEqual(@as(f64, 1), state.value(live));
    try testing.expect(recording.complete());
    state.set_input(live, -3);
    state.eval(.{ .flicks = flicks_per_second + flicks_per_second / 3 });
    try testing.expectEqual(@as(f64, 0), state.value(live));
    try testing.expect(state.value(chased) > 0);
    try testing.expect(!recording.complete());
    const table = recording.table();
    for (table[1..], table[0 .. table.len - 1]) |later, earlier| {
        try testing.expect(later.time.flicks >= earlier.time.flicks);
    }
}

/// The value a recorded run sets for read `index`, a seeded draw in [-1.5, 1.5], so some are
/// clamped.
fn live_value(index: u64) f64 {
    const bits = noise_hash(0x11fe, index);
    return @as(f64, @floatFromInt(bits >> 11)) * 0x1p-53 * 3 - 1.5;
}

/// An input, or a recording of one, feeding a chase and a crossing, starting at a cue half a step
/// after 0.25 s. Returns the source, the chase, and the crossing.
fn build_listener(builder: *Builder, clip: ?recording_module.Clip) Builder.Error![3]Id {
    const source = if (clip) |played|
        try builder.recorded(played)
    else
        try builder.input(.{ .low = -1, .high = 1 });
    const chased = try builder.chase(.{
        .target = source,
        .from = 0,
        .time = .{ .flicks = flicks_per_second / 3 },
        .overshoot = 0.1,
    });
    const gate = try builder.crossing(.{ .input = chased, .level = 0.2, .direction = .both });
    return .{ source, chased, gate };
}

// Locks the page's third check: a live input set each read at 60 Hz for 10 s, recorded, then
// played back by a `recorded` node in its place and read at the same times, gives every value
// bit for bit. The recording is seekable: read in a drawn order it gives the same values, and its
// events are the same however the range is split.
test "a recorded run equals the live run, value for value" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = flicks_per_second / 4 + simulation.step.flicks / 2 });
    const reads = 600;
    var live_nodes: [3]Node = undefined;
    var live_builder = Builder.init(&live_nodes, .{ .slab_count_max = 16, .cues = &cues });
    const live_ids = try build_listener(&live_builder, null);
    const live_program = live_builder.finish();
    var slab: [16]f64 = undefined;
    var checkpoints: [12 * 16]f64 = undefined;
    var state = State.init_with_checkpoints(live_program, &slab, &checkpoints);
    var entries: [2 * reads]Sample = undefined;
    var recording = Recording.init(&entries);
    state.record(live_ids[0], &recording);
    var values: [reads][3]f64 = undefined;
    const rate = Rate.from_hz(60).?;
    for (&values, 0..) |*row, index| {
        state.set_input(live_ids[0], live_value(index));
        state.eval(Time.from_ticks(@intCast(index), rate).?);
        for (row, live_ids) |*value, id| value.* = state.value(id);
    }
    try testing.expect(recording.complete());

    var sample_entries: [2 * reads]Sample = undefined;
    var samples = recording_module.Samples.init(&sample_entries);
    const clip = try samples.add(recording.table());
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 16,
        .cues = &cues,
        .samples = samples.table(),
    });
    const ids = try build_listener(&builder, clip);
    const program = builder.finish();
    try testing.expect(program.report().seekable);
    var replay_slab: [16]f64 = undefined;
    var replay_checkpoints: [12 * 16]f64 = undefined;
    var replay = State.init_with_checkpoints(program, &replay_slab, &replay_checkpoints);
    for (values, 0..) |row, index| {
        replay.eval(Time.from_ticks(@intCast(index), rate).?);
        for (row, ids) |value, id| try testing.expectEqual(value, replay.value(id));
    }
    var prng = std.Random.DefaultPrng.init(8);
    var seek = State.init(program, &replay_slab);
    for (0..200) |_| {
        const index = prng.random().uintLessThan(usize, reads);
        seek.eval(Time.from_ticks(@intCast(index), rate).?);
        for (values[index], ids) |value, id| try testing.expectEqual(value, seek.value(id));
    }
    const end: Time = .{ .flicks = 10 * flicks_per_second };
    const whole = try events_at_once(program, end, &events_whole);
    try testing.expect(whole.len > 0);
    const joined = try events_split(program, end, .{ .drawn = 5 }, 6, &events_joined);
    try testing.expectEqualSlices(Event, whole, joined);
}

// Locks the refusals of an input and a recorded node by name, and that nothing is built.
test "the builder refuses an input or a recording it cannot evaluate" {
    var sample_entries: [1]Sample = .{.{ .time = .{ .flicks = 0 }, .value = 1 }};
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4, .samples = &sample_entries });
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try testing.expectError(error.NotFinite, builder.input(.{ .low = nan }));
    try testing.expectError(error.NotFinite, builder.input(.{ .high = nan }));
    try testing.expectError(error.NotFinite, builder.input(.{ .initial = inf }));
    const reversed: Input = .{ .low = 1, .high = 0, .initial = 0.5 };
    try testing.expectError(error.InvalidRange, builder.input(reversed));
    try testing.expectError(error.InvalidRange, builder.input(.{ .low = 1, .high = 2 }));
    try testing.expectError(error.UnknownSamples, builder.recorded(.{ .first = 0, .count = 0 }));
    try testing.expectError(error.UnknownSamples, builder.recorded(.{ .first = 0, .count = 2 }));
    try testing.expectError(error.UnknownSamples, builder.recorded(.{ .first = 2, .count = 1 }));
    try testing.expectEqual(@as(u32, 0), builder.node_count);
    const played = try builder.recorded(.{ .first = 0, .count = 1 });
    const program = builder.finish();
    var out: [1]Range = undefined;
    try testing.expectEqual(Range.point(1), ranges_of(&program, &out)[played.index]);
}

/// One graph drawn for the randomized range test: its tables, nodes, and the inputs to set.
const Drawn = struct {
    cue_times: [3]Time,
    cues: Cues,
    goal_entries: [24]Goal,
    goals: motion.Goals,
    region_entries: [16]simulation.Region,
    regions: simulation.Regions,
    sample_entries: [32]Sample,
    samples: recording_module.Samples,
    track_entries: [2]track_module.Track,
    track_samples: [2][64]Sample,
    tracks: Tracks,
    nodes: [nodes_max]Node,
    program: Program,

    const nodes_max = 12;
    const slab_count_max = 256;

    fn init(drawn: *Drawn, random: std.Random) !void {
        drawn.cues = Cues.init(&drawn.cue_times);
        inline for (.{ 1, 3, 6 }) |half_seconds| {
            _ = try drawn.cues.add(.{ .flicks = @divExact(half_seconds * flicks_per_second, 2) });
        }
        drawn.goals = motion.Goals.init(&drawn.goal_entries);
        drawn.regions = simulation.Regions.init(&drawn.region_entries);
        drawn.samples = recording_module.Samples.init(&drawn.sample_entries);
        // Tables first, since the builder holds them as slices.
        var paths: [8]motion.Path = undefined;
        for (&paths) |*path| {
            const count = random.intRangeAtMost(u32, 1, 3);
            var goals: [3]Goal = undefined;
            for (goals[0..count], 0..) |*goal, index| {
                goal.* = .{ .cue = .{ .index = @intCast(index) }, .value = between(random, -2, 2) };
            }
            path.* = try drawn.goals.add(goals[0..count]);
        }
        var spans: [8]simulation.Span = undefined;
        for (&spans) |*span| {
            const count = random.intRangeAtMost(u32, 1, 2);
            var regions: [2]simulation.Region = undefined;
            for (regions[0..count]) |*region| {
                region.* = .{ .low = between(random, -2, 2), .high = between(random, -2, 2) };
            }
            span.* = try drawn.regions.add(regions[0..count]);
        }
        var clips: [8]recording_module.Clip = undefined;
        for (&clips) |*clip| {
            const count = random.intRangeAtMost(u32, 1, 4);
            var samples: [4]Sample = undefined;
            var flicks: i64 = 0;
            for (samples[0..count]) |*sample| {
                flicks += random.intRangeLessThan(i64, 0, flicks_per_second);
                sample.* = .{ .time = .{ .flicks = flicks }, .value = between(random, -2, 2) };
            }
            clip.* = try drawn.samples.add(samples[0..count]);
        }
        drawn.tracks = Tracks.init(&drawn.track_entries);
        for (&drawn.track_samples) |*samples| {
            const low = between(random, -2, 1);
            const high = low + between(random, 0, 3);
            _ = try drawn.tracks.add(samples, low, high, between(random, low, high));
        }
        var builder = Builder.init(&drawn.nodes, .{
            .slab_count_max = slab_count_max,
            .cues = &drawn.cues,
            .goals = drawn.goals.table(),
            .regions = drawn.regions.table(),
            .samples = drawn.samples.table(),
            .tracks = &drawn.tracks,
            .seed = random.int(u64),
        });
        const count = random.intRangeAtMost(u32, 2, nodes_max - 1);
        while (builder.node_count < count) {
            try draw_node(&builder, random, &paths, &spans, &clips);
        }
        drawn.program = builder.finish();
    }

    /// Adds one drawn node, or two for a bounce. A delay is closed at once onto a node before it,
    /// or onto itself, so the randomized graphs have no loop that can grow without end; the loop
    /// test below covers loops.
    fn draw_node(
        builder: *Builder,
        random: std.Random,
        paths: []const motion.Path,
        spans: []const simulation.Span,
        clips: []const recording_module.Clip,
    ) !void {
        const any: Id = .{ .index = random.uintLessThan(u32, @max(builder.node_count, 1)) };
        const cue: Cue = .{ .index = random.uintLessThan(u32, 3) };
        const seconds = struct {
            fn of(r: std.Random, low: f64, high: f64) Time {
                const flicks = between(r, low, high) * flicks_per_second_float;
                return .{ .flicks = @intFromFloat(flicks) };
            }
        }.of;
        const other: Id = .{ .index = random.uintLessThan(u32, @max(builder.node_count, 1)) };
        const choice = if (builder.node_count == 0) 0 else random.uintLessThan(u32, 23);
        const from = struct {
            fn maybe(r: std.Random, id: Id) ?Id {
                return if (r.boolean()) id else null;
            }
        }.maybe;
        _ = switch (choice) {
            0 => try builder.constant(between(random, -2, 2)),
            1 => try builder.add(any, other),
            2 => try builder.multiply(any, other),
            3 => try builder.map_range(.{
                .input = any,
                .input_low = between(random, -1, 1),
                .input_high = between(random, 1.5, 3),
                .output_low = between(random, -3, 3),
                .output_high = between(random, -3, 3),
            }),
            4 => try builder.wave(.{
                .shape = random.enumValue(@import("wave.zig").Shape),
                .hz = between(random, 0.1, 5),
            }),
            5 => try builder.noise(.{
                .shape = random.enumValue(@import("noise.zig").Shape),
                .hz = between(random, 0.1, 5),
                .seed = random.int(u64),
            }),
            6 => try builder.tween(.{
                .from = between(random, -2, 2),
                .to = between(random, -2, 2),
                .duration = seconds(random, 0.1, 2),
                .ease = .{
                    .x1 = between(random, 0, 1),
                    .y1 = between(random, -0.5, 1.5),
                    .x2 = between(random, 0, 1),
                    .y2 = between(random, -0.5, 1.5),
                },
                .start = cue,
                .previous = if (random.boolean()) any else null,
            }),
            7 => try builder.spring(.{
                .from = between(random, -2, 2),
                .goals = paths[random.uintLessThan(usize, paths.len)],
                .time = seconds(random, 0.1, 1),
                .overshoot = between(random, 0, 0.6),
            }),
            8 => try builder.newtonian(.{
                .from = between(random, -2, 2),
                .goals = paths[random.uintLessThan(usize, paths.len)],
                .speed = between(random, 0.5, 4),
                .accel = between(random, 0.5, 8),
                .decel = between(random, 0.5, 8),
            }),
            9 => try builder.chase(.{
                .target = any,
                .from = between(random, -2, 2),
                .time = seconds(random, 0.1, 1),
                .overshoot = between(random, 0, 0.6),
            }),
            10 => try builder.follow(.{
                .from = between(random, -2, 2),
                .regions = spans[random.uintLessThan(usize, spans.len)],
                .pick = random.enumValue(simulation.Pick),
                .mover = if (random.boolean())
                    .{ .spring = .{
                        .time = seconds(random, 0.1, 1),
                        .overshoot = between(random, 0, 0.6),
                    } }
                else
                    .{ .newtonian = .{
                        .speed = between(random, 0.5, 4),
                        .accel = between(random, 0.5, 8),
                        .decel = between(random, 0.5, 8),
                    } },
                .tolerance = between(random, 0.01, 0.1),
                .pause_min = .{ .flicks = 0 },
                .pause_max = seconds(random, 0, 0.3),
                .seed = random.int(u64),
            }),
            11 => blk: {
                const buckets = random.intRangeAtMost(u32, 1, 8);
                const steps = buckets * random.intRangeAtMost(i64, 1, 200);
                break :blk try builder.shift(.{
                    .buckets = buckets,
                    .period = .{ .flicks = steps * simulation.step.flicks },
                    .low = between(random, -2, 2),
                    .high = between(random, -2, 2),
                    .odds = between(random, 0, 1),
                    .shape = random.enumValue(simulation.ShiftShape),
                    .seed = random.int(u64),
                });
            },
            12 => blk: {
                const echo = try builder.delay(between(random, -2, 2));
                const before: Id = if (echo.index == 0)
                    echo
                else
                    .{ .index = random.uintLessThan(u32, echo.index) };
                try builder.close(echo, before);
                break :blk echo;
            },
            13 => blk: {
                if (builder.nodes.len - builder.node_count < 2) break :blk try builder.constant(0);
                const low = between(random, -2, 1);
                const ids = try builder.bounce(.{
                    .low = low,
                    .high = low + between(random, 0.1, 2),
                    .speed = between(random, 0.2, 3),
                    .start = cue,
                });
                break :blk ids.position;
            },
            14 => try builder.crossing(.{
                .input = any,
                .level = between(random, -1, 1),
                .direction = random.enumValue(Crossing.Direction),
            }),
            15 => try builder.cues(.{
                .first = .{ .index = 0 },
                .count = random.intRangeAtMost(u32, 1, 3),
            }),
            16 => blk: {
                if (random.boolean()) break :blk try builder.input(.{});
                const low = between(random, -2, 0);
                const high = low + between(random, 0, 3);
                break :blk try builder.input(.{ .low = low, .high = high, .initial = low });
            },
            17 => try builder.recorded(clips[random.uintLessThan(usize, clips.len)]),
            18 => try builder.track(.{ .index = random.uintLessThan(u32, 2) }),
            19 => try builder.oscillator(.{
                .shape = random.enumValue(@import("wave.zig").Shape),
                .rate = any,
                .phase = between(random, 0, 0.99),
            }),
            20 => try builder.chase(.{
                .target = any,
                .from = between(random, -2, 2),
                .time = seconds(random, 0.1, 1),
                .overshoot = between(random, 0, 0.6),
                .time_from = from(random, other),
                .overshoot_from = from(random, other),
            }),
            21 => try builder.follow(.{
                .from = between(random, -2, 2),
                .regions = spans[random.uintLessThan(usize, spans.len)],
                .pick = random.enumValue(simulation.Pick),
                .mover = .{ .spring = .{
                    .time = seconds(random, 0.1, 1),
                    .overshoot = between(random, 0, 0.6),
                } },
                .tolerance = between(random, 0.01, 0.1),
                .pause_min = .{ .flicks = 0 },
                .pause_max = seconds(random, 0, 0.3),
                .seed = random.int(u64),
                .mover_from = .{ .time = from(random, any), .overshoot = from(random, other) },
            }),
            22 => try builder.follow(.{
                .from = between(random, -2, 2),
                .regions = spans[random.uintLessThan(usize, spans.len)],
                .pick = random.enumValue(simulation.Pick),
                .mover = .{ .newtonian = .{
                    .speed = between(random, 0.5, 4),
                    .accel = between(random, 0.5, 8),
                    .decel = between(random, 0.5, 8),
                } },
                .tolerance = between(random, 0.01, 0.1),
                .pause_min = .{ .flicks = 0 },
                .pause_max = seconds(random, 0, 0.3),
                .seed = random.int(u64),
                .mover_from = .{
                    .speed = from(random, any),
                    .accel = from(random, other),
                    .decel = from(random, any),
                },
            }),
            else => try builder.add(any, any),
        };
    }

    /// Writes each track at a drawn time in [-1 s, 4 s), past its bounds now and then, which a
    /// write clamps. A full track refuses, which changes nothing.
    fn write_tracks(drawn: *Drawn, random: std.Random) void {
        for (0..drawn.tracks.count) |index| {
            if (random.boolean()) continue;
            const track = drawn.tracks.at(.{ .index = @intCast(index) });
            const flicks = random.intRangeLessThan(i64, -flicks_per_second, 4 * flicks_per_second);
            const value = between(random, track.low - 1, track.high + 1);
            const id: TrackId = .{ .index = @intCast(index) };
            drawn.tracks.write(id, .{ .flicks = flicks }, value) catch |err| {
                assert(err == error.TrackFull);
            };
        }
    }

    /// Sets every input of `state` to a drawn value, past its range now and then.
    fn set_inputs(drawn: *const Drawn, state: *State, random: std.Random) void {
        for (drawn.program.nodes, 0..) |*node, index| switch (node.op) {
            .input => |op| {
                const low = if (std.math.isFinite(op.low)) op.low else -5;
                const high = if (std.math.isFinite(op.high)) op.high else 5;
                state.set_input(.{ .index = @intCast(index) }, between(random, low - 1, high + 1));
            },
            else => {},
        };
    }
};

fn between(random: std.Random, low: f64, high: f64) f64 {
    const weight = random.float(f64);
    return low * (1 - weight) + high * weight;
}

/// Checks that every value of every node of `state`'s last eval is in its range.
fn expect_in_ranges(state: *const State, ranges: []const Range, graph: usize, time: Time) !void {
    for (state.program.nodes, ranges, 0..) |*node, range, index| {
        for (state.values(.{ .index = @intCast(index) })) |value| {
            if (range.contains(value)) continue;
            std.debug.print("graph {d}, node {d} ({t}) at {d} flicks: {e} outside [{e}, {e}]\n", .{
                graph, index, node.op, time.flicks, value, range.low, range.high,
            });
            return error.TestUnexpectedResult;
        }
    }
}

// Locks the page's first check: in 2,000 drawn graphs over every op, each read forwards at 60 Hz,
// then backwards and at drawn times, with its inputs set to drawn values, some past their range,
// and its tracks written between reads (step 9.5), no value ever leaves its node's range.
test "no sampled value leaves its range" {
    var prng = std.Random.DefaultPrng.init(0x7a6e);
    const random = prng.random();
    var drawn: Drawn = undefined;
    var slab: [Drawn.slab_count_max]f64 = undefined;
    var checkpoints: [4 * Drawn.slab_count_max]f64 = undefined;
    var out: [Drawn.nodes_max]Range = undefined;
    const rate = Rate.from_hz(60).?;
    for (0..2000) |graph| {
        try drawn.init(random);
        const ranges = ranges_of(&drawn.program, &out);
        const used = drawn.program.slab_count;
        var state = State.init_with_checkpoints(
            drawn.program,
            slab[0..used],
            checkpoints[0 .. 4 * @as(usize, used)],
        );
        // Forwards over 4 s from just before zero, then backwards, then at drawn times.
        var tick: i64 = -6;
        while (tick < 240) : (tick += 7) {
            drawn.set_inputs(&state, random);
            drawn.write_tracks(random);
            const time = Time.from_ticks(tick, rate).?;
            state.eval(time);
            try expect_in_ranges(&state, ranges, graph, time);
        }
        for (0..12) |_| {
            drawn.set_inputs(&state, random);
            drawn.write_tracks(random);
            const flicks = random.intRangeLessThan(i64, -flicks_per_second, 4 * flicks_per_second);
            const time: Time = .{ .flicks = flicks };
            state.eval(time);
            try expect_in_ranges(&state, ranges, graph, time);
        }
    }
}

// Locks the loop half of the first check: 300 drawn loops, a chase of c + g times its own delay
// with |g| below 1 and any overshoot, read for 6 s, never leave their ranges, and when the chase
// is critical the range is finite.
test "a loop through a delay never leaves its range" {
    var prng = std.Random.DefaultPrng.init(0x100b);
    const random = prng.random();
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var out: [6]Range = undefined;
    for (0..300) |graph| {
        var nodes: [6]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 32, .cues = &cues });
        const overshoot = if (random.boolean()) 0 else between(random, 0, 0.5);
        const echo = try builder.delay(between(random, -1, 1));
        const gain = try builder.constant(between(random, -0.95, 0.95));
        const scaled = try builder.multiply(echo, gain);
        const target = try builder.add(try builder.constant(between(random, -1, 1)), scaled);
        const chased = try builder.chase(.{
            .target = target,
            .from = between(random, -1, 1),
            .time = .{ .flicks = @intFromFloat(between(random, 0.1, 1) * flicks_per_second_float) },
            .overshoot = overshoot,
        });
        try builder.close(echo, chased);
        const program = builder.finish();
        const ranges = ranges_of(&program, &out);
        if (overshoot == 0) {
            try testing.expect(std.math.isFinite(ranges[chased.index].low));
            try testing.expect(std.math.isFinite(ranges[chased.index].high));
        }
        var slab: [32]f64 = undefined;
        var state = State.init(program, &slab);
        var tick: i64 = 0;
        while (tick < 360) : (tick += 1) {
            const time = Time.from_ticks(tick, Rate.from_hz(60).?).?;
            state.eval(time);
            try expect_in_ranges(&state, ranges, graph, time);
        }
    }
}

/// A page of live parameters (step 9.5): an oscillator, a chase, and two followers whose rates,
/// times, overshoots, and limits come from tracks, as Play's knobs drive them.
const Live = struct {
    cue_times: [1]Time,
    cues: Cues,
    region_entries: [1]simulation.Region,
    regions: simulation.Regions,
    track_entries: [4]track_module.Track,
    track_samples: [4][2048]Sample,
    tracks: Tracks,
    ids: [4]TrackId,
    nodes: [12]Node,
    program: Program,
    outputs: [4]Id,

    const slab_count_max = 96;

    fn init(live: *Live) !void {
        live.cues = try cue_table_at_zero(&live.cue_times);
        live.regions = simulation.Regions.init(&live.region_entries);
        _ = try live.regions.add(&.{.{ .low = 0, .high = 1 }});
        live.tracks = Tracks.init(&live.track_entries);
        const bounds = [4][3]f64{
            .{ 0.1, 3, 0.5 },
            .{ 0.125, 2, 0.5 },
            .{ 0, 0.9, 0.3 },
            .{ 0.25, 4, 1 },
        };
        for (&live.ids, &live.track_samples, bounds) |*id, *samples, bound| {
            id.* = try live.tracks.add(samples, bound[0], bound[1], bound[2]);
        }
        var builder = Builder.init(&live.nodes, .{
            .slab_count_max = slab_count_max,
            .cues = &live.cues,
            .regions = live.regions.table(),
            .tracks = &live.tracks,
            .seed = 9,
        });
        const rate = try builder.track(live.ids[0]);
        const oscillator = try builder.oscillator(.{ .shape = .sine, .rate = rate });
        const time = try builder.track(live.ids[1]);
        const chase = try builder.chase(.{
            .target = oscillator,
            .from = 0,
            .time = .{ .flicks = @divExact(flicks_per_second, 2) },
            .overshoot = 0.1,
            .time_from = time,
        });
        const overshoot = try builder.track(live.ids[2]);
        const sway = try builder.follow(.{
            .from = 0.5,
            .regions = .{ .first = 0, .count = 1 },
            .pick = .random,
            .mover = .{ .spring = .{ .time = .{ .flicks = flicks_per_second }, .overshoot = 0.3 } },
            .tolerance = 0.01,
            .pause_min = .{ .flicks = 0 },
            .pause_max = .{ .flicks = flicks_per_second },
            .seed = 4,
            .mover_from = .{ .overshoot = overshoot },
        });
        const speed = try builder.track(live.ids[3]);
        const four = try builder.constant(4);
        const limit = try builder.multiply(speed, four);
        const glide = try builder.follow(.{
            .from = 0.5,
            .regions = .{ .first = 0, .count = 1 },
            .pick = .random,
            .mover = .{ .newtonian = .{ .speed = 1, .accel = 4, .decel = 4 } },
            .tolerance = 0.01,
            .pause_min = .{ .flicks = 0 },
            .pause_max = .{ .flicks = @divExact(flicks_per_second, 2) },
            .seed = 9,
            .mover_from = .{ .speed = speed, .accel = limit, .decel = limit },
        });
        live.outputs = .{ oscillator, chase, sway, glide };
        live.program = builder.finish();
    }

    fn values(live: *const Live, state: *const State) [4]f64 {
        var result: [4]f64 = undefined;
        for (&result, live.outputs) |*value, id| value.* = state.value(id);
        return result;
    }

    /// A fresh state's values at `time`, with no checkpoints, so from the start.
    fn fresh(live: *const Live, time: Time) [4]f64 {
        var slab: [slab_count_max]f64 = undefined;
        var state = State.init(live.program, slab[0..live.program.slab_count]);
        state.eval(time);
        return live.values(&state);
    }
};

fn whole_seconds(count: i64) Time {
    return .{ .flicks = count * flicks_per_second };
}

/// Static, since a page and its checkpoints are too large for the test's stack.
const live_fixture = struct {
    var live: Live = undefined;
    var slab: [Live.slab_count_max]f64 = undefined;
    var checkpoints: [70 * Live.slab_count_max]f64 = undefined;
};

// Locks section 14's floor: a reader played to 60 s, then writes at 30 s, keeps the 30
// checkpoints before 30 s, and its reads at 10, 30, 45, and 60 s equal a fresh state's, bit for
// bit; the read at 10 s runs at most one interval of steps, from a kept checkpoint.
test "a track write keeps the past and drops only what it reaches" {
    const live = &live_fixture.live;
    try live.init();
    const used = live.program.slab_count;
    var state = State.init_with_checkpoints(
        live.program,
        live_fixture.slab[0..used],
        live_fixture.checkpoints[0 .. 70 * @as(usize, used)],
    );
    const rate = Rate.from_hz(60).?;
    for (0..3601) |frame| state.eval(Time.from_ticks(@intCast(frame), rate).?);
    try testing.expectEqual(@as(u32, 60), state.checkpoints_filled);
    try live.tracks.write(live.ids[0], whole_seconds(30), 2);
    try live.tracks.write(live.ids[2], whole_seconds(30), 0.8);
    try live.tracks.write(live.ids[3], whole_seconds(30), 0.5);
    const before = state.steps_run;
    state.eval(whole_seconds(10));
    try testing.expectEqual(@as(u32, 30), state.checkpoints_filled);
    try testing.expect(state.steps_run - before <= simulation.checkpoint_interval);
    try testing.expectEqualSlices(f64, &live.fresh(whole_seconds(10)), &live.values(&state));
    for ([_]i64{ 30, 45, 60, 10 }) |at| {
        state.eval(whole_seconds(at));
        try testing.expectEqualSlices(f64, &live.fresh(whole_seconds(at)), &live.values(&state));
    }
}

// Locks the cost of a knob: playing at 60 Hz for 30 s with a write of every track at the playhead
// each frame, no frame runs more than its own steps and one interval, and the values are a fresh
// state's at the end, bit for bit.
test "a write at the playhead costs at most one interval" {
    const live = &live_fixture.live;
    try live.init();
    const used = live.program.slab_count;
    var state = State.init_with_checkpoints(
        live.program,
        live_fixture.slab[0..used],
        live_fixture.checkpoints[0 .. 70 * @as(usize, used)],
    );
    const rate = Rate.from_hz(60).?;
    var most: u64 = 0;
    for (0..1801) |frame| {
        const time = Time.from_ticks(@intCast(frame), rate).?;
        const swing: f64 = @floatFromInt(frame % 7);
        for (live.ids, 0..) |id, index| {
            const track = live.tracks.at(id);
            const share = (swing + @as(f64, @floatFromInt(index))) / 10;
            try live.tracks.write(id, time, track.low + (track.high - track.low) * share);
        }
        const before = state.steps_run;
        state.eval(time);
        most = @max(most, state.steps_run - before);
    }
    try testing.expect(most <= 8 + simulation.checkpoint_interval);
    try testing.expectEqualSlices(f64, &live.fresh(whole_seconds(30)), &live.values(&state));
}

// Locks parameters from nodes against constants: a chase, a spring follower, and a Newtonian
// follower whose parameters come from constant nodes equal the same nodes with constant
// parameters, at 60 Hz for 60 s, bit for bit.
test "parameters from constant nodes equal constant parameters" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var region_entries: [1]simulation.Region = undefined;
    var regions = simulation.Regions.init(&region_entries);
    _ = try regions.add(&.{.{ .low = -1, .high = 1 }});
    var nodes: [16]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 128,
        .cues = &cues,
        .regions = regions.table(),
        .seed = 3,
    });
    const target = try builder.wave(.{ .shape = .triangle, .hz = 0.7 });
    const time: Time = .{ .flicks = 282_240_000 };
    const seconds = try builder.constant(0.4);
    const overshoot = try builder.constant(0.15);
    const chase: Chase = .{ .target = target, .from = 0, .time = time, .overshoot = 0.15 };
    var chase_from = chase;
    chase_from.time_from = seconds;
    chase_from.overshoot_from = overshoot;
    const spring: Follow = .{
        .from = 0,
        .regions = .{ .first = 0, .count = 1 },
        .pick = .random,
        .mover = .{ .spring = .{ .time = time, .overshoot = 0.15 } },
        .tolerance = 0.02,
        .pause_min = .{ .flicks = 0 },
        .pause_max = .{ .flicks = 282_240_000 },
        .seed = 5,
    };
    var spring_from = spring;
    spring_from.mover_from = .{ .time = seconds, .overshoot = overshoot };
    var newtonian = spring;
    newtonian.mover = .{ .newtonian = .{ .speed = 1.5, .accel = 6, .decel = 4 } };
    var newtonian_from = newtonian;
    newtonian_from.mover_from = .{
        .speed = try builder.constant(1.5),
        .accel = try builder.constant(6),
        .decel = try builder.constant(4),
    };
    const pairs = [3][2]Id{
        .{ try builder.chase(chase), try builder.chase(chase_from) },
        .{ try builder.follow(spring), try builder.follow(spring_from) },
        .{ try builder.follow(newtonian), try builder.follow(newtonian_from) },
    };
    const program = builder.finish();
    var slab: [128]f64 = undefined;
    var state = State.init(program, slab[0..program.slab_count]);
    const rate = Rate.from_hz(60).?;
    for (0..3601) |frame| {
        state.eval(Time.from_ticks(@intCast(frame), rate).?);
        for (pairs) |pair| {
            const constant: u64 = @bitCast(state.value(pair[0]));
            try testing.expectEqual(constant, @as(u64, @bitCast(state.value(pair[1]))));
        }
    }
}

// Locks the oscillator: at a constant rate it is the wave at that rate, at every step for 10 s,
// within the rounding of its summed phase.
test "an oscillator at a constant rate is the wave" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 16, .cues = &cues });
    const rate = try builder.constant(1.25);
    const oscillator = try builder.oscillator(.{ .shape = .sine, .rate = rate });
    const program = builder.finish();
    var slab: [16]f64 = undefined;
    var state = State.init(program, slab[0..program.slab_count]);
    const wave: Wave = .{ .shape = .sine, .hz = 1.25 };
    for (0..4801) |step| {
        const time = step_time(.{ .flicks = 0 }, step);
        state.eval(time);
        try testing.expectApproxEqAbs(wave.sample(time), state.value(oscillator), 1e-9);
    }
    var out: [3]Range = undefined;
    const range = ranges_of(&program, &out)[oscillator.index];
    try testing.expect(range.low <= -1 and range.high >= 1);
}

// Locks the refusals of step 9.5, by name.
test "the builder refuses live parameters it cannot use" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var region_entries: [1]simulation.Region = undefined;
    var regions = simulation.Regions.init(&region_entries);
    _ = try regions.add(&.{.{ .low = 0, .high = 1 }});
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 64,
        .cues = &cues,
        .regions = regions.table(),
    });
    const one = try builder.constant(1);
    try testing.expectError(error.UnknownTrack, builder.track(.{ .index = 0 }));
    const late: Oscillator = .{ .shape = .sine, .rate = one, .phase = 1 };
    try testing.expectError(error.InvalidPhase, builder.oscillator(late));
    const unknown: Oscillator = .{ .shape = .sine, .rate = .{ .index = 5 } };
    try testing.expectError(error.UnknownNode, builder.oscillator(unknown));
    var follow: Follow = .{
        .from = 0,
        .regions = .{ .first = 0, .count = 1 },
        .pick = .cycle,
        .mover = .{ .spring = .{ .time = .{ .flicks = flicks_per_second }, .overshoot = 0 } },
        .tolerance = 0.01,
        .pause_min = .{ .flicks = 0 },
        .pause_max = .{ .flicks = 0 },
        .seed = 1,
        .mover_from = .{ .speed = one },
    };
    try testing.expectError(error.InvalidParameter, builder.follow(follow));
    follow.mover = .{ .newtonian = .{ .speed = 1, .accel = 1, .decel = 1 } };
    follow.mover_from = .{ .time = one };
    try testing.expectError(error.InvalidParameter, builder.follow(follow));
    follow.mover_from = .{ .decel = .{ .index = 7 } };
    try testing.expectError(error.UnknownNode, builder.follow(follow));
    try testing.expectEqual(@as(u32, 1), builder.node_count);
}
