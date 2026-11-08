//! The reader of a program: `State`, the pass over the node array, the fixed step and its
//! checkpoints, and events.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Where the Design Lives
//! `graph.zig` holds the guide for the whole graph, and this file is its reading half: a section
//! cited here is a section of `graph.zig`. A `State` is one reader's slab over a `Program` (section
//! 1); a pass evaluates every node at one time (section 9); a step runs the simulated nodes on the
//! fixed step, with checkpoints (section 9); and an events query finds what happened in a range
//! (section 11). The program side, the ops, and the builder stay in `graph.zig`, so this file reads
//! the op structs and never builds them.
//!
//! ## 2. TigerStyle Invariants
//! - `eval` and `events` allocate nothing, take no lock, and are bounded, as `graph.zig`
//!   section 13 states.

const std = @import("std");
const assert = std.debug.assert;
const event_module = @import("event.zig");
const Collector = event_module.Collector;
const Event = event_module.Event;
const Events = event_module.Events;
const motion = @import("motion.zig");
const Motion = motion.Motion;
const recording_module = @import("recording.zig");
const Recording = recording_module.Recording;
const simulation = @import("simulation.zig");
const time_module = @import("time.zig");
const Time = time_module.Time;
const graph = @import("graph.zig");
const BounceNode = graph.BounceNode;
const Crossing = graph.Crossing;
const CueSpan = graph.CueSpan;
const Id = graph.Id;
const MapRange = graph.MapRange;
const Node = graph.Node;
const Program = graph.Program;
const any_param = graph.any_param;
const follower_slot_arrived = graph.follower_slot_arrived;
const follower_slot_arrived_goal = graph.follower_slot_arrived_goal;
const follower_slots = graph.follower_slots;
const law_cache_reset = graph.law_cache_reset;
const newtonian_limits_at = graph.newtonian_limits_at;
const node_values = graph.node_values;
const param_value = graph.param_value;
const spring_law_at = graph.spring_law_at;
const step_flicks = graph.step_flicks;
const step_flicks_float = graph.step_flicks_float;
const steps_per_second = graph.steps_per_second;

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

/// Evaluates every node at `time`, in order.
pub fn pass(program: *const Program, slab: []f64, time: Time, sampling: Sampling) void {
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
pub fn step_time(start: Time, index: u64) Time {
    // Wrapping, because the step's time fits an i64 even where its distance from start does not.
    const offset: i64 = @bitCast(index * step_flicks);
    const time: Time = .{ .flicks = start.flicks +% offset };
    assert(time.flicks >= start.flicks or offset < 0);
    return time;
}

/// The first step at or after `time`, which is 0 at or before the start: the step a range ending
/// at `time` commits, as section 11 explains.
pub fn step_ceiling(start: Time, time: Time) u64 {
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
