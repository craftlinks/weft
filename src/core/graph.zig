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
//! state. One step is a pass over every node at the step's time, with each simulated node giving
//! its value there, then an update of each simulated node from that pass. A read at t between
//! steps k and k + 1 brings the slab to step k + 1, then a pass at t gives each simulated node
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
//! ## 11. TigerStyle Invariants
//! - Capacities come from the caller, and the builder refuses what does not fit, by name.
//! - `eval` allocates nothing, takes no lock, and is one bounded pass over the node array. A motion
//!   node folds over at most its own goals. A simulated program first runs at most
//!   `checkpoint_interval - 1` steps once the checkpoints before the time are filled, and the
//!   steps since the last one filled otherwise.
//! - Offsets are consecutive from 0, so the slab has no gaps and no node overlaps another.

const std = @import("std");
const assert = std.debug.assert;
const Cue = @import("cue.zig").Cue;
const Cues = @import("cue.zig").Cues;
const Ease = @import("ease.zig").Ease;
const motion = @import("motion.zig");
const Goal = motion.Goal;
const Motion = motion.Motion;
const Noise = @import("noise.zig").Noise;
const noise_hash = @import("noise.zig").hash;
const simulation = @import("simulation.zig");
const Time = @import("time.zig").Time;
const Wave = @import("wave.zig").Wave;

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
};

/// A chase as a graph node holds it.
pub const ChaseNode = struct {
    target: Id,
    from: f64,
    law: motion.SpringLaw,
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

    /// The f64 a node of this op keeps in the slab after an output of `output_count` f64, for a
    /// cache or a simulation's state. Section 9 explains the layout of a simulated node.
    fn cache_count(op: *const Op, output_count: u64) u64 {
        assert(output_count > 0);
        return switch (op.*) {
            .motion => motion.cursor_count,
            .chase => 3 * output_count,
            .delay => 2 * output_count,
            .follow => 2 * output_count + follower_slots,
            .shift => |shift| 2 * output_count + 1 + shift.buckets,
            .constant, .add, .multiply, .map_range, .wave, .tween, .noise => 0,
        };
    }

    /// Whether a node of this op runs on the fixed step, as section 9 explains.
    fn simulated(op: *const Op) bool {
        return switch (op.*) {
            .chase, .follow, .shift, .delay => true,
            .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .motion => false,
        };
    }
};

/// A follower's own state after its before and after values: velocity, goal, goals drawn, and
/// steps of pause left.
const follower_slots = 4;

pub const Node = struct {
    op: Op,
    /// The index in the slab of this node's first value.
    offset: u32,
    extent: Extent,
};

comptime {
    // A follower is the largest op. The array is read in order, so this costs prefetch, not misses.
    assert(@sizeOf(Node) <= 112);
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
                .chase => |op| assert(op.target.index < index),
                .delay => |op| if (op.input) |input| assert(input.index < program.nodes.len),
                .follow => |op| {
                    assert(op.regions.count > 0);
                    assert(op.regions.first + op.regions.count <= program.regions.len);
                },
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
            }
        }
        assert(offset == program.slab_count);
        assert(program.simulated == (simulated_count > 0));
        if (program.simulated) assert(program.start.index < program.cues.count);
    }
};

/// Appends nodes to caller-owned memory, then hands over the finished `Program`.
pub const Builder = struct {
    nodes: []Node,
    node_count: u32,
    slab_count: u32,
    slab_count_max: u32,
    cues: *const Cues,
    goals: []const Goal,
    regions: []const simulation.Region,
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
        /// A constant or a parameter that is infinite or NaN.
        NotFinite,
        /// A map whose input range has no width, or one too wide for a double.
        InvalidRange,
        /// A cue that the table given in `Options` does not have, including the start cue of a
        /// simulated node.
        UnknownCue,
        /// A tween or a spring time that is not above zero, or a shift register period that is not
        /// above zero, is longer than `simulation.period_flicks_max`, or gives a bucket less than
        /// one step.
        InvalidDuration,
        /// A tween whose ease fails `Ease.valid`.
        InvalidEase,
        /// A noise whose frequency is not above 0 and at most `Noise.hz_max`.
        InvalidRate,
        /// A path that the goal table given in `Options` does not hold.
        UnknownGoals,
        /// A spring whose overshoot is not in [0, 1).
        InvalidOvershoot,
        /// A Newtonian move whose speed, accel, or decel is not above zero.
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
            .cues = options.cues,
            .goals = options.goals,
            .regions = options.regions,
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
        if (source.start.index >= builder.cues.count) return error.UnknownCue;
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
        return builder.push(.{ .chase = .{
            .target = source.target,
            .from = source.from,
            .law = law,
        } });
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
    pub fn close(builder: *Builder, delay_id: Id, input: Id) Error!void {
        assert(!builder.finished);
        try builder.check_known(delay_id);
        try builder.check_known(input);
        const node = &builder.nodes[delay_id.index];
        switch (node.op) {
            .delay => |*op| {
                if (op.input != null) return error.DelayClosed;
                assert(builder.delays_open > 0);
                op.input = input;
                builder.delays_open -= 1;
            },
            else => return error.NotADelay,
        }
    }

    fn check_goals(builder: *const Builder, path: motion.Path, from: f64) Error!void {
        if (!std.math.isFinite(from)) return error.NotFinite;
        if (path.count == 0) return error.UnknownGoals;
        if (path.first > builder.goals.len) return error.UnknownGoals;
        if (path.count > builder.goals.len - path.first) return error.UnknownGoals;
        for (builder.goals[path.first..][0..path.count]) |goal| {
            if (goal.cue.index >= builder.cues.count) return error.UnknownCue;
        }
    }

    fn check_start(builder: *const Builder) Error!void {
        assert(builder.cues.count <= builder.cues.times.len);
        if (builder.start.index >= builder.cues.count) return error.UnknownCue;
    }

    /// The program built so far. Nothing can be added after this, and every delay must be closed.
    pub fn finish(builder: *Builder) Program {
        assert(!builder.finished);
        assert(builder.slab_count <= builder.slab_count_max);
        assert(builder.delays_open == 0);
        builder.finished = true;
        const program: Program = .{
            .nodes = builder.nodes[0..builder.node_count],
            .cues = builder.cues,
            .goals = builder.goals,
            .regions = builder.regions,
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
    /// Steps run since `init`, for measuring what reads cost.
    steps_run: u64,

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
            .steps_run = 0,
        };
    }

    /// Fills the slab with every node's value at `time`. A reader can ask for any time in any
    /// order: what carries over from an earlier call is a cache that cannot change a value.
    pub fn eval(state: *State, time: Time) void {
        assert(state.slab.len == state.program.slab_count);
        var weight: f64 = 0;
        if (state.program.simulated) weight = state.simulate_to(time);
        pass(&state.program, state.slab, time, .{ .between = weight });
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

    /// How many checkpoints the state has room for.
    pub fn checkpoints_count(state: *const State) u32 {
        if (state.checkpoints.len == 0) return 0;
        return @intCast(state.checkpoints.len / state.program.slab_count);
    }

    /// Brings the simulated state to the step after `time`, and returns how far `time` is past
    /// the step before it, as a fraction of a step. Section 9 explains.
    fn simulate_to(state: *State, time: Time) f64 {
        assert(state.program.simulated);
        const cues = state.program.cues;
        if (cues.generation != state.generation) {
            state.generation = cues.generation;
            state.checkpoints_filled = 0;
            state.step = null;
        }
        const start = cues.at(state.program.start);
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
        var live = state.step.?;
        assert(live <= target);
        while (live < target) {
            step_once(&state.program, state.slab, start, live);
            live += 1;
            state.steps_run += 1;
            if (live % interval == 0) state.store(live / interval);
        }
        state.step = live;
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

    /// Puts the slab at checkpoint `index`, where checkpoint 0 is the start, rebuilt.
    fn restore(state: *State, index: u64) void {
        assert(index <= state.checkpoints_filled);
        if (index == 0) {
            for (state.program.nodes) |*node| reset_node(&state.program, state.slab, node);
        } else {
            const size = state.slab.len;
            const first: usize = @intCast((index - 1) * size);
            @memcpy(state.slab, state.checkpoints[first..][0..size]);
        }
        state.step = index * simulation.checkpoint_interval;
    }
};

const step_flicks: u64 = @intCast(simulation.step.flicks);
const step_flicks_float: f64 = @floatFromInt(simulation.step.flicks);

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
        .chase, .follow, .shift, .delay => {
            const cache = slab[node.offset + output_count ..][0 .. 2 * output_count];
            sample_into(out, cache[0..output_count], cache[output_count..], sampling);
        },
    }
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

/// Runs the step from step `index` to the next: a pass at its time, then an update of every
/// simulated node from that pass, as section 9 explains.
fn step_once(program: *const Program, slab: []f64, start: Time, index: u64) void {
    // Wrapping, because the step's time fits an i64 even where its distance from start does not.
    const offset: i64 = @bitCast(index * step_flicks);
    const time: Time = .{ .flicks = start.flicks +% offset };
    assert(time.flicks >= start.flicks or offset < 0);
    pass(program, slab, time, .at_step);
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
    const before = cache[0..output_count];
    const after = cache[output_count..][0..output_count];
    const own = cache[2 * output_count ..];
    @memcpy(before, after);
    switch (node.op) {
        .chase => |*op| {
            const target = node_values(program.nodes, slab, op.target);
            assert(target.len == output_count);
            const velocities = own[0..output_count];
            const law: motion.Law = .{ .spring = op.law };
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
            const state = follower_unpack(after[0], own);
            const next = simulation.follower_step(op, program.regions, state);
            follower_pack(next, after, own);
        },
        .shift => |*op| {
            const bucket: u64 = @intFromFloat(own[0]);
            const next = simulation.shift_step(op, own[1..], bucket, index);
            own[0] = @floatFromInt(next.bucket);
            @memset(after, next.value);
        },
        .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .motion => unreachable,
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
    const before = cache[0..output_count];
    const after = cache[output_count..][0..output_count];
    const own = cache[2 * output_count ..];
    switch (node.op) {
        .chase => |op| {
            @memset(after, op.from);
            @memset(own, 0);
        },
        .delay => |op| @memset(after, op.initial),
        .follow => |*op| follower_pack(simulation.follower_start(op, program.regions), after, own),
        .shift => |*op| {
            simulation.shift_fill(op, own[1..]);
            own[0] = 0;
            const position = simulation.shift_position(op, 0);
            @memset(after, simulation.shift_value(op, own[1..], position));
        },
        .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .motion => unreachable,
    }
    @memcpy(before, after);
}

/// A follower's state from its slab: its position is its value after the step.
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
        .steps_run = 0,
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

    const slab_count = 35;

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
        .slab_count_max = 7,
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
    var slab: [7]f64 = undefined;
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
