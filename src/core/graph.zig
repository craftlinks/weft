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
//! ## 3. No Pointers
//! Nodes refer to each other by `Id`, and neither a node nor the slab holds an address. So both can
//! move as bytes: a copy of the node array is the same program, and a copy of the slab is a
//! checkpoint. `Program` and `State` are only views of that memory, rebuilt wherever it lands.
//!
//! ## 4. Sorted Means No Cycles
//! A node can only refer to nodes built before it, which `Builder` enforces. So the array is
//! already in topological order, eval is one pass over it, and a cycle cannot be expressed.
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
//! ## 7. TigerStyle Invariants
//! - Capacities come from the caller, and the builder refuses what does not fit, by name.
//! - `eval` allocates nothing, takes no lock, and is one bounded pass over the node array.
//! - Offsets are consecutive from 0, so the slab has no gaps and no node overlaps another.

const std = @import("std");
const assert = std.debug.assert;
const Cue = @import("cue.zig").Cue;
const Ease = @import("ease.zig").Ease;
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

pub const Op = union(enum) {
    constant: f64,
    add: Binary,
    multiply: Binary,
    map_range: MapRange,
    wave: Wave,
    tween: Tween,
};

pub const Node = struct {
    op: Op,
    /// The index in the slab of this node's first value.
    offset: u32,
    extent: Extent,
};

comptime {
    // A tween is the largest op. The array is read in order, so this costs prefetch, not misses.
    assert(@sizeOf(Node) <= 96);
    assert(@sizeOf(Id) == @sizeOf(u32));
    assert(@alignOf(Node) == @alignOf(f64));
}

/// An immutable node array, the cue times it reads, and the size of the slab it needs. A view of
/// memory that can move.
pub const Program = struct {
    nodes: []const Node,
    cues: []const Time,
    slab_count: u32,

    fn assert_valid(program: Program) void {
        var offset: u32 = 0;
        for (program.nodes, 0..) |*node, index| {
            assert(node.offset == offset);
            offset += node.extent.count();
            switch (node.op) {
                .constant, .wave => {},
                .add, .multiply => |op| {
                    assert(op.left.index < index);
                    assert(op.right.index < index);
                },
                .map_range => |op| assert(op.input.index < index),
                .tween => |op| {
                    assert(op.start.index < program.cues.len);
                    if (op.previous) |previous| assert(previous.index < index);
                },
            }
        }
        assert(offset == program.slab_count);
    }
};

/// Appends nodes to caller-owned memory, then hands over the finished `Program`.
pub const Builder = struct {
    nodes: []Node,
    node_count: u32,
    slab_count: u32,
    slab_count_max: u32,
    cues: []const Time,
    /// The extent of every node built, 1 by 1 until a later step gives each node its own.
    extent: Extent,
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
        /// A cue that the table given in `Options` does not have.
        UnknownCue,
        /// A tween whose duration is not above zero.
        InvalidDuration,
        /// A tween whose ease fails `Ease.valid`.
        InvalidEase,
    };

    pub const Options = struct {
        slab_count_max: u32,
        /// The cue times tweens can start from, from `Cues.table`.
        cues: []const Time = &.{},
    };

    pub fn init(nodes: []Node, options: Options) Builder {
        assert(nodes.len <= std.math.maxInt(u32));
        return .{
            .nodes = nodes,
            .node_count = 0,
            .slab_count = 0,
            .slab_count_max = options.slab_count_max,
            .cues = options.cues,
            .extent = .{ .lanes = 1, .components = 1 },
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
        if (source.start.index >= builder.cues.len) return error.UnknownCue;
        if (!std.math.isFinite(source.from)) return error.NotFinite;
        if (!std.math.isFinite(source.to)) return error.NotFinite;
        if (source.duration.flicks <= 0) return error.InvalidDuration;
        if (!source.ease.valid()) return error.InvalidEase;
        return builder.push(.{ .tween = source });
    }

    /// The program built so far. Nothing can be added after this.
    pub fn finish(builder: *Builder) Program {
        assert(!builder.finished);
        assert(builder.slab_count <= builder.slab_count_max);
        builder.finished = true;
        const program: Program = .{
            .nodes = builder.nodes[0..builder.node_count],
            .cues = builder.cues,
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
        const count = @as(u64, builder.extent.lanes) * builder.extent.components;
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
        return id;
    }
};

/// One reader's values, in a slab the reader owns.
pub const State = struct {
    program: Program,
    slab: []f64,
    evaluated: bool,

    /// `slab` needs at least `program.slab_count` values, and only those are used.
    pub fn init(program: Program, slab: []f64) State {
        assert(slab.len >= program.slab_count);
        program.assert_valid();
        const slab_used = slab[0..program.slab_count];
        @memset(slab_used, 0);
        return .{ .program = program, .slab = slab_used, .evaluated = false };
    }

    /// Fills the slab with every node's value at `time`. Nothing carries over from an earlier
    /// call, so a reader can ask for any time in any order.
    pub fn eval(state: *State, time: Time) void {
        assert(state.slab.len == state.program.slab_count);
        for (state.program.nodes) |*node| eval_node(&state.program, state.slab, node, time);
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
};

fn node_values(nodes: []const Node, slab: []const f64, id: Id) []const f64 {
    const node = &nodes[id.index];
    return slab[node.offset..][0..node.extent.count()];
}

fn eval_node(program: *const Program, slab: []f64, node: *const Node, time: Time) void {
    const nodes = program.nodes;
    const out = slab[node.offset..][0..node.extent.count()];
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
        .tween => |*tween| {
            const start_time = program.cues[tween.start.index];
            if (time.flicks >= start_time.flicks) {
                @memset(out, tween.value_after(time, start_time));
            } else if (tween.previous) |previous| {
                @memcpy(out, node_values(nodes, slab, previous));
            } else {
                @memset(out, tween.from);
            }
        },
    }
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
const Cues = @import("cue.zig").Cues;
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
        .cues = &.{},
        .slab_count = program.slab_count,
    };
    var state_checkpoint: State = .{
        .program = program_moved,
        .slab = &slab_moved,
        .evaluated = true,
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
        var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = cues.table() });
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
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = cues.table() });
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
    var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = cues.table() });
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
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = cues.table() });
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
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = cues.table() });
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
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = cues.table() });
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
    var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = cues.table() });
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
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = cues.table() });
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
    var builder = Builder.init(&nodes, .{ .slab_count_max = 12, .cues = cues.table() });
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
