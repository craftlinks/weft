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
//! (section 11), of every source or of the ones a caller lists, which step only when one of them
//! needs the step. The program side, the ops, and the builder stay in `graph.zig`, so this file
//! reads the op structs and never builds them. Every value a simulated node reads or stores
//! passes through `simulation.bounded`, so a loop that runs away saturates instead of
//! overflowing (`simulation.zig`, section 7), and `finite` tells a client when a pure node
//! downstream did.
//!
//! ## 2. TigerStyle Invariants
//! - `eval`, `events`, and `events_of` allocate nothing, take no lock, and are bounded, as
//!   `graph.zig` section 13 states.
//! - `events_of` over solved sources writes nothing in the state: `events_from` takes the step,
//!   and clears `evaluated`, only when a listed source needs the step.

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
const elementary = @import("elementary.zig");
const BounceNode = graph.BounceNode;
const Crossing = graph.Crossing;
const Cue = @import("cue.zig").Cue;
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
const lane_seed = graph.lane_seed;
const lane_cue = graph.lane_cue;
const lane_time = graph.lane_time;
const Extent = graph.Extent;
const newtonian_limits_at = graph.newtonian_limits_at;
const node_values = graph.node_values;
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
    /// The copy of the simulated nodes' regions at the step before the slab's own (`graph.zig`,
    /// section 9), empty when the caller gave no room for it, and the step it holds, or null.
    recent: []f64,
    recent_step: ?u64,
    /// The time of the last `eval`, which `events_since` reads on from.
    last_read: ?Time,
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

    /// `slab` needs at least `program.slab_count` values. With `program.reader_slab_count()`, the
    /// reader also keeps the copy of `graph.zig` section 9, so a read of the step its slab has
    /// just passed replays one step. A simulated program has no checkpoints this way, so each
    /// read further back runs every step from the start.
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
        const recent: []f64 = if (program.recent_count > 0 and slab.len >= program.reader_slab_count())
            slab[program.slab_count..][0..program.recent_count]
        else
            &.{};
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
            .recent = recent,
            .recent_step = null,
            .last_read = null,
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
        state.last_read = time;
    }

    /// The events since the last `eval`, then an `eval` at `now`: the call a client makes each
    /// frame. It reads `(last, now]`, which is `events(last + 1, now + 1)`, so it never replays a
    /// step the evals would not. With no `eval` before, it reads the events at exactly `now`; at
    /// or before the last one, a repeat or a seek back, it reads none. A jump forward reads every
    /// event between, so a client that seeks without wanting them calls `eval` first.
    pub fn events_since(state: *State, now: Time, out: []Event) Events {
        assert(now.flicks < std.math.maxInt(i64));
        var result: Events = .{ .count = 0, .dropped = 0 };
        if (state.last_read) |last| {
            if (now.flicks > last.flicks) {
                result = state.events(.{ .flicks = last.flicks + 1 }, .{ .flicks = now.flicks + 1 }, out);
            }
        } else {
            result = state.events(now, .{ .flicks = now.flicks + 1 }, out);
        }
        state.eval(now);
        return result;
    }

    /// The value of a node of one value, from the last `eval`.
    pub fn value(state: *const State, id: Id) f64 {
        const result = state.values(id);
        assert(result.len == 1);
        return result[0];
    }

    /// All the values of a node, from the last `eval`, lane after lane and each lane's
    /// components in order, which a client copies into an instance buffer as they are.
    pub fn values(state: *const State, id: Id) []const f64 {
        assert(state.evaluated);
        assert(id.index < state.program.nodes.len);
        return node_values(state.program.nodes, state.slab, id);
    }

    /// Whether every value of the last `eval` is finite. A loop that runs away saturates at
    /// `simulation.state_bound` (`simulation.zig`, section 7), but pure nodes downstream of it can
    /// still overflow, so a client checks this after an `eval` of a program with a loop, and
    /// shows a false rather than drawing it. It scans every node's values, so `eval` pays nothing.
    pub fn finite(state: *const State) bool {
        assert(state.evaluated);
        for (state.program.nodes, 0..) |_, index| {
            const id: Id = .{ .index = @intCast(index) };
            for (node_values(state.program.nodes, state.slab, id)) |read| {
                if (!std.math.isFinite(read)) return false;
            }
        }
        return true;
    }

    /// The lanes and components of a node's values (`graph.zig`, sections 15 and 16).
    pub fn extent(state: *const State, id: Id) Extent {
        assert(id.index < state.program.nodes.len);
        return state.program.nodes[id.index].extent;
    }

    /// Every event with a time in `[t0, t1)`, in order of time, then source index, then lane, as
    /// `event.zig` explains. The earliest `out.len` are written to `out`, and the rest are counted.
    /// It brings a simulated state no further than the step `eval(t1)` needs, as section 11
    /// explains, and leaves the outputs of the slab at no particular time, so `value` asserts
    /// until the next `eval`.
    pub fn events(state: *State, t0: Time, t1: Time, out: []Event) Events {
        return state.events_from(null, t0, t1, out);
    }

    /// The events of `sources` only, node ids as `Event.source` gives them, strictly ascending:
    /// what `events` gives, with every other source's events left out, in the same order and with
    /// the same overflow rule (step 23). A call steps only when a source is a crossing, a follower,
    /// or a shift register, the simulated ops that fire events, and then it leaves the state as
    /// `events` does. A call over solved sources, a bounce, cues, a spring, or a Newtonian move,
    /// changes nothing in the state, so the next `eval` and `value` read what the last `eval` left.
    /// A source that fires nothing, such as a chase or a wave, adds none and steps nothing.
    /// An invalid list (`sources_valid`) is an assert; where asserts are compiled out it reads as
    /// the empty list, so it can never read past the program.
    pub fn events_of(state: *State, sources: []const Id, t0: Time, t1: Time, out: []Event) Events {
        const valid = sources_valid(&state.program, sources);
        // Not a plain assert, which a build without safety may take as a promise and use to drop
        // the check below.
        if (std.debug.runtime_safety) assert(valid);
        return state.events_from(if (valid) sources else &.{}, t0, t1, out);
    }

    /// Whether `sources` is a list `events_of` takes: strictly ascending, so with no repeat, and
    /// each a node of `program`. A client that builds its list at run time can check it once with
    /// this.
    pub fn sources_valid(program: *const Program, sources: []const Id) bool {
        for (sources, 0..) |id, at| {
            if (id.index >= program.nodes.len) return false;
            if (at > 0 and sources[at - 1].index >= id.index) return false;
        }
        return true;
    }

    /// Whether a node fires events, as section 11 lists: a bounce's position, cues, a spring or
    /// a Newtonian move, a crossing, a follower, and a shift register.
    pub fn fires_events(node: *const Node) bool {
        return switch (node.op) {
            .bounce => |op| op.output == .position,
            .cues, .motion => true,
            .crossing, .follow, .shift => true,
            .constant, .add, .multiply, .minimum, .maximum, .apply, .map_range => false,
            .wave, .tween, .noise, .chase, .delay, .oscillator => false,
            .input, .recorded, .track, .pack, .pick, .lane, .spread => false,
        };
    }

    /// The body of `events` and `events_of`: every source's events when `sources` is null, else
    /// those of the listed ones, which step only when one of them must.
    fn events_from(state: *State, sources: ?[]const Id, t0: Time, t1: Time, out: []Event) Events {
        assert(state.slab.len == state.program.slab_count);
        assert(t0.flicks <= t1.flicks);
        const program = &state.program;
        if (sources) |list| assert(sources_valid(program, list));
        const steps = if (sources) |list| steps_for(program, list) else program.simulated;
        assert(!steps or program.simulated);
        var collector = Collector.init(out);
        // A call that steps nothing over a list of sources writes nothing in the state.
        if (sources == null or steps) state.evaluated = false;
        if (t0.flicks == t1.flicks) return collector.result();
        var report: Found = .{ .collector = &collector, .t0 = t0, .t1 = t1, .sources = sources };
        if (sources) |list| {
            // Ascending, so the solved sources are visited in node order, as below.
            for (list) |id| events_solved(program, state.slab, id, &report);
        } else {
            for (0..program.nodes.len) |index| {
                events_solved(program, state.slab, .{ .index = @intCast(index) }, &report);
            }
        }
        if (steps) state.events_simulated(&report);
        return collector.result();
    }

    /// Takes over `from`'s simulated state, a reader of another program, when every simulated or
    /// input node of this program has a twin there (`twins[i]`, the old node of node i) of the
    /// same op and size: its slab, its step, and its checkpoints, each node's region moved to
    /// its own offset. Other nodes are caches a pass refills, so they start as `init` leaves them.
    /// False, changing nothing, when a node has no twin, when the two programs start their steps
    /// at different times, or when `from` has not read since its program last changed, since its
    /// checkpoints could then be stale. A recompile uses this to keep a running program's state
    /// (step 15); the caller finds the twins.
    pub fn adopt(state: *State, from: *const State, twins: []const ?u32) bool {
        assert(twins.len == state.program.nodes.len);
        assert(state.slab.len == state.program.slab_count);
        if (!state.program.simulated or !from.program.simulated) return false;
        const step = from.step orelse return false;
        if (from.generation != from.program.cues.generation) return false;
        if (from.track_generation != from.program.tracks.generation) return false;
        const start = state.program.cues.at(state.program.start);
        if (start.flicks != from.program.cues.at(from.program.start).flicks) return false;
        for (state.program.nodes, twins) |*node, twin| {
            if (!node.op.simulated() and node.op != .input) continue;
            const old = twin orelse return false;
            if (old >= from.program.nodes.len) return false;
            const other = &from.program.nodes[old];
            if (std.meta.activeTag(node.op) != std.meta.activeTag(other.op)) return false;
            if (region_of(node) != region_of(other)) return false;
        }
        const filled = @min(from.checkpoints_filled, state.checkpoints_count());
        move_regions(state.program, state.slab, from.program, from.slab, twins);
        const size = state.slab.len;
        const from_size = from.slab.len;
        for (0..filled) |index| {
            const into = state.checkpoints[index * size ..][0..size];
            @memset(into, 0);
            const out_of = from.checkpoints[index * from_size ..][0..from_size];
            move_regions(state.program, into, from.program, out_of, twins);
        }
        state.step = step;
        state.recent_step = null;
        state.last_read = from.last_read;
        state.checkpoints_filled = filled;
        state.generation = state.program.cues.generation;
        state.track_generation = state.program.tracks.generation;
        state.evaluated = false;
        return true;
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
            state.recent_step = null;
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
            state.recent_step = null;
            return;
        };
        if (state.recent_step) |kept| {
            if (kept > 0 and step_time(start, kept - 1).flicks >= at.flicks) state.recent_step = null;
        }
        while (state.checkpoints_filled > 0) {
            const last_pass = @as(u64, state.checkpoints_filled) * interval - 1;
            if (step_time(start, last_pass).flicks < at.flicks) break;
            state.checkpoints_filled -= 1;
        }
        if (state.step) |live| {
            if (live > 0 and step_time(start, live - 1).flicks >= at.flicks) state.step = null;
        }
    }

    /// Brings the simulated state to step `target`, from the nearest of the slab's own step, the
    /// copy of the step before it, and the checkpoints before `target`.
    fn run_to(state: *State, target: u64, start: Time) void {
        const interval = simulation.checkpoint_interval;
        const nearest = @min(target / interval, state.checkpoints_filled);
        const live_usable = if (state.step) |live|
            live >= nearest * interval and live <= target
        else
            false;
        if (!live_usable) {
            const recent_usable = if (state.recent_step) |kept|
                kept >= nearest * interval and kept <= target
            else
                false;
            if (recent_usable) state.restore_recent() else state.restore(nearest);
        }
        state.advance_to(target, start, null);
    }

    /// Runs the steps from the slab's own step to `target`, storing each checkpoint it passes,
    /// and giving the events found at each step it leaves to `report`.
    fn advance_to(state: *State, target: u64, start: Time, report: ?*Found) void {
        const interval = simulation.checkpoint_interval;
        var live = state.step.?;
        assert(live <= target);
        while (live < target) {
            if (live + 1 == target) state.save_recent(live);
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

    /// Copies each simulated node's region, at step `step`, into `recent`, packed in node order
    /// (`graph.zig`, section 9). A reader with no room for it skips it.
    fn save_recent(state: *State, step: u64) void {
        const copy = state.recent;
        if (copy.len == 0) return;
        var at: usize = 0;
        for (state.program.nodes) |*node| {
            if (!node.op.simulated()) continue;
            const size: usize = @intCast(region_of(node));
            @memcpy(copy[at..][0..size], state.slab[node.offset..][0..size]);
            at += size;
        }
        assert(at == copy.len);
        state.recent_step = step;
    }

    /// Puts each simulated node's region back from the copy, at `recent_step`.
    fn restore_recent(state: *State) void {
        const copy = state.recent;
        assert(copy.len > 0);
        var at: usize = 0;
        for (state.program.nodes) |*node| {
            if (!node.op.simulated()) continue;
            const size: usize = @intCast(region_of(node));
            @memcpy(state.slab[node.offset..][0..size], copy[at..][0..size]);
            at += size;
        }
        assert(at == copy.len);
        state.step = state.recent_step.?;
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

/// The values and caches a node keeps in the slab.
fn region_of(node: *const Node) u64 {
    return node.extent.count() + node.op.cache_count(node.extent.count());
}

/// Copies each twinned simulated or input node's region from `from` into `into` (`adopt`).
fn move_regions(program: Program, into: []f64, from_program: Program, from: []const f64, twins: []const ?u32) void {
    for (program.nodes, twins) |*node, twin| {
        if (!node.op.simulated() and node.op != .input) continue;
        const other = &from_program.nodes[twin.?];
        const count: usize = @intCast(region_of(node));
        @memcpy(into[node.offset..][0..count], from[other.offset..][0..count]);
    }
}

/// Whether a list of sources needs the step: one of them is a simulated op that fires events.
fn steps_for(program: *const Program, sources: []const Id) bool {
    for (sources) |id| {
        assert(id.index < program.nodes.len);
        switch (program.nodes[id.index].op) {
            .crossing, .follow, .shift => return true,
            else => {},
        }
    }
    return false;
}

/// The events a solved source finds without the step: a bounce's position, cues, and each lane of
/// a motion. Other nodes find none here.
fn events_solved(program: *const Program, slab: []const f64, id: Id, report: *Found) void {
    assert(id.index < program.nodes.len);
    const node = &program.nodes[id.index];
    switch (node.op) {
        .bounce => |*op| if (op.output == .position) {
            for (0..node.extent.lanes) |lane| {
                events_bounce(program, op, id, family_lane(program, node, lane), report);
            }
        },
        .cues => |span| events_cues(program, span, id, report),
        .motion => |*op| for (0..node.extent.lanes) |lane| {
            events_motion(program, slab, node, op, id, family_lane(program, node, lane), report);
        },
        else => {},
    }
}

/// Where an events query puts what it finds: the collector, the range it keeps, and the sources
/// it keeps, all when null.
const Found = struct {
    collector: *Collector,
    t0: Time,
    t1: Time,
    sources: ?[]const Id = null,

    /// Keeps an event if its time is in the range and its source is wanted.
    fn add(report: *Found, time: Time, source: Id, instance: u32, value: f64) void {
        assert(report.t0.flicks < report.t1.flicks);
        if (time.flicks < report.t0.flicks) return;
        if (time.flicks >= report.t1.flicks) return;
        if (report.sources) |list| {
            if (!contains(list, source)) return;
        }
        report.collector.add(.{
            .time = time,
            .source = source,
            .instance = instance,
            .value = value,
        });
    }
};

/// Whether the ascending `sources` holds `id`, by binary search.
fn contains(sources: []const Id, id: Id) bool {
    assert(sources.len <= std.math.maxInt(u32));
    var low: usize = 0;
    var high: usize = sources.len;
    // Halving a u32 range ends within 33 rounds.
    for (0..33) |_| {
        if (low == high) break;
        const middle = low + (high - low) / 2;
        if (sources[middle].index == id.index) return true;
        if (sources[middle].index < id.index) low = middle + 1 else high = middle;
    } else unreachable;
    assert(low == high);
    return false;
}

/// The hits of one lane of a bounce's position in the range: at each wall, the velocity just
/// before it, `+speed` at `high` and `-speed` at `low`. Once the buffer is full, it counts the
/// rest. Lane g's start is `g * stagger` after its cue (`graph.zig`, section 16), which is cue
/// `start + g` when it is chosen by lane.
fn events_bounce(program: *const Program, op: *const BounceNode, id: Id, lane: u32, report: *Found) void {
    assert(op.output == .position);
    const start_time = lane_start(program, op.start, op.cue_by_lane, op.stagger, lane);
    const first = op.hits_before(report.t0, start_time) + 1;
    const last = op.hits_before(report.t1, start_time);
    var k = first;
    while (k <= last) : (k += 1) {
        const offset: i64 = @intCast(op.hit(k));
        const event: Event = .{
            .time = .{ .flicks = start_time.flicks +% offset },
            .source = id,
            .instance = lane,
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

/// The goals of one lane of a motion reached in the range, each with the goal as the value. Only
/// goals whose stretch, from their cue to the next goal's, meets the range can be reached in it,
/// and the fold to the first of them starts from the cursor when it can, as `motion.zig`
/// explains. Lane g reads its range `g * stagger` earlier, and moves its events that much later.
fn events_motion(
    program: *const Program,
    slab: []const f64,
    node: *const Node,
    op: *const Motion,
    id: Id,
    lane: u32,
    report_all: *Found,
) void {
    const path = program.goals[op.goals.first..][0..op.goals.count];
    const cues = program.cues;
    const shift = negated(op.stagger);
    // The range as the unstaggered motion sees it.
    var shifted: Found = .{
        .collector = report_all.collector,
        .t0 = lane_time(report_all.t0, op.stagger, lane),
        .t1 = lane_time(report_all.t1, op.stagger, lane),
    };
    const report = &shifted;
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
        if (reached) |time| report_all.add(lane_time(time, shift, lane), id, lane, path[index].value);
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
                const first = family_lane(program, node, 0);
                report_crossing(op, cache, inputs, step_time(start, index), id, first, report);
            },
            .follow => for (0..output_count) |lane| {
                const own = follower_own(cache, output_count, lane);
                if (own[follower_slot_arrived] == 1) {
                    const goal = own[follower_slot_arrived_goal];
                    report.add(step_time(start, index), id, family_lane(program, node, lane), goal);
                }
            },
            .shift => |*op| for (0..output_count) |lane| {
                const own = shift_own(cache, op, output_count, lane);
                report_shift(own, op, start, index, id, family_lane(program, node, lane), report);
            },
            else => {},
        }
    }
}

/// A crossing's events at step `index`: per lane, its input at the step before, kept in its slab,
/// against its input at this step, from the pass. The time is interpolated in the step and
/// rounded up, never past it nor onto the step before, and the value is the slope. Lane l's
/// instance is `first + l`, its lane in its family.
fn report_crossing(
    op: *const Crossing,
    cache: []const f64,
    inputs: []const f64,
    time: Time,
    id: Id,
    first: u32,
    report: *Found,
) void {
    assert(cache.len == inputs.len + 1);
    // Nothing to compare at step 0, before the first update has kept an input.
    if (cache[inputs.len] == 0) return;
    const step_before: Time = .{ .flicks = time.flicks -% simulation.step.flicks };
    for (cache[0..inputs.len], inputs, 0..) |a, b_read, lane| {
        // Read through the bound as the update reads it (`simulation.zig`, section 7).
        const b = simulation.bounded(b_read);
        if (!op.crosses(a, b)) continue;
        // In [0, 1], since a subtraction rounds monotonically: 0 only falling from on the level.
        const weight = (op.level - a) / (b - a);
        assert(weight >= 0);
        assert(weight <= 1);
        const into = std.math.clamp(@ceil(weight * step_flicks_float), 1, step_flicks_float);
        const offset: i64 = @intFromFloat(into);
        const at: Time = .{ .flicks = step_before.flicks +% offset };
        report.add(at, id, first + @as(u32, @intCast(lane)), (b - a) * steps_per_second);
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
    lane: u32,
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
    report.add(time, id, lane, own[1 + slot]);
}

/// The family lane of lane `lane` of `node`: `lane_first + lane` when it is laned, else 0
/// (`graph.zig`, section 16).
fn family_lane(program: *const Program, node: *const Node, lane: usize) u32 {
    assert(lane < node.extent.lanes);
    if (!node.extent.laned) return 0;
    return program.lane_first + @as(u32, @intCast(lane));
}

/// When lane `lane` of a family of a cued op starts: its cue, `start` or `lane_cue(start, lane)`
/// when chosen by lane, moved `lane * stagger` later.
fn lane_start(program: *const Program, start: Cue, cue_by_lane: bool, stagger: Time, lane: u32) Time {
    const cue = if (cue_by_lane) lane_cue(start, lane) else start;
    return lane_time(program.cues.at(cue), negated(stagger), lane);
}

/// `time` negated, so `lane_time` moves later instead of earlier.
fn negated(time: Time) Time {
    return .{ .flicks = 0 -% time.flicks };
}

/// The slots of lane `lane` of a follower, after its values at the steps before and after.
fn follower_own(cache: anytype, output_count: usize, lane: usize) @TypeOf(cache[0..follower_slots]) {
    assert(lane < output_count);
    return cache[2 * output_count + lane * follower_slots ..][0..follower_slots];
}

/// The bucket count and buckets of lane `lane` of a shift register.
fn shift_own(cache: anytype, op: *const simulation.ShiftRegister, output_count: usize, lane: usize) @TypeOf(cache[0..]) {
    assert(lane < output_count);
    const size = 1 + @as(usize, op.buckets);
    return cache[2 * output_count + lane * size ..][0..size];
}

/// The node `op` of lane `lane` of a seeded node: its seed hashed with the lane when laned.
fn seeded(comptime T: type, op: *const T, laned: bool, lane: u32) T {
    var result = op.*;
    if (laned) result.seed = lane_seed(op.seed, lane);
    return result;
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
    const first = family_lane(program, node, 0);
    switch (node.op) {
        .constant => |constant| @memset(out, constant),
        .add => |op| {
            const left = operand_of(nodes, slab, op.left);
            add_into(out, node.extent, left, operand_of(nodes, slab, op.right));
        },
        .multiply => |op| {
            const left = operand_of(nodes, slab, op.left);
            multiply_into(out, node.extent, left, operand_of(nodes, slab, op.right));
        },
        .minimum => |op| {
            const left = operand_of(nodes, slab, op.left);
            pairwise_into(out, node.extent, left, operand_of(nodes, slab, op.right), graph.minimum);
        },
        .maximum => |op| {
            const left = operand_of(nodes, slab, op.left);
            pairwise_into(out, node.extent, left, operand_of(nodes, slab, op.right), graph.maximum);
        },
        .apply => |op| apply_into(out, node_values(nodes, slab, op.input), op.function),
        .map_range => |*op| map_range_into(out, node_values(nodes, slab, op.input), op),
        .wave => |wave| if (node.extent.laned) {
            for (out, first..) |*value, lane| value.* = wave.sample(lane_time(time, wave.stagger, lane));
        } else {
            @memset(out, wave.sample(time));
        },
        .noise => |*noise| if (node.extent.laned) {
            for (out, first..) |*value, lane| {
                value.* = seeded(@TypeOf(noise.*), noise, true, @intCast(lane)).sample(time);
            }
        } else {
            @memset(out, noise.sample(time));
        },
        .motion => |*op| {
            const cursor = slab[node.offset + output_count ..][0..motion.cursor_count];
            if (!node.extent.laned) {
                @memset(out, motion.sample(op, program.goals, program.cues, cursor, time));
                return;
            }
            // In time order, so the cursor folds forward from lane to lane (section 16).
            for (0..out.len) |at| {
                const lane = if (op.stagger.flicks > 0) out.len - 1 - at else at;
                const lane_at = lane_time(time, op.stagger, first + lane);
                out[lane] = motion.sample(op, program.goals, program.cues, cursor, lane_at);
            }
        },
        .tween => |*tween| {
            const previous: ?[]const f64 = if (tween.previous) |id| node_values(nodes, slab, id) else null;
            const cue_time = program.cues.at(tween.start);
            for (out, 0..) |*value, lane| {
                const start_time = if (tween.stagger.flicks == 0 and !tween.cue_by_lane)
                    cue_time
                else
                    lane_start(program, tween.start, tween.cue_by_lane, tween.stagger, @intCast(first + lane));
                if (time.flicks >= start_time.flicks) {
                    value.* = tween.value_after(time, start_time);
                } else if (previous) |values| {
                    value.* = values[if (values.len == 1) 0 else lane];
                } else {
                    value.* = tween.from;
                }
            }
        },
        .chase, .follow, .shift, .delay, .oscillator => {
            const cache = slab[node.offset + output_count ..][0 .. 2 * output_count];
            sample_into(out, cache[0..output_count], cache[output_count..], sampling);
        },
        .track => |id| @memset(out, program.tracks.value(id, time)),
        .bounce => |*op| {
            const cue_time = program.cues.at(op.start);
            if (!node.extent.laned) {
                @memset(out, op.sample(time, cue_time));
                return;
            }
            for (out, first..) |*value, lane| {
                value.* = op.sample(time, lane_start(program, op.start, op.cue_by_lane, op.stagger, @intCast(lane)));
            }
        },
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
        .pack => |op| for (op.inputs[0..op.count], 0..) |id, component| {
            const values = node_values(nodes, slab, id);
            for (0..node.extent.lanes) |lane| {
                out[lane * op.count + component] = values[if (values.len == 1) 0 else lane];
            }
        },
        .pick => |op| {
            const values = node_values(nodes, slab, op.input);
            const components = nodes[op.input.index].extent.components;
            for (out, 0..) |*value, lane| value.* = values[lane * components + op.component];
        },
        .recorded => |op| {
            const clip = program.samples[op.clip.first..][0..op.clip.count];
            @memset(out, recording_module.play(clip, time));
        },
        .lane => for (out, first..) |*value, lane| {
            value.* = @floatFromInt(lane);
        },
        .spread => |input| @memset(out, node_values(nodes, slab, input)[0]),
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
        for (cache[0..output_count], inputs) |*kept, input| kept.* = simulation.bounded(input);
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
                const next = simulation.bounded_kinematics(
                    motion.advance(law, now, simulation.bounded(goal), simulation.step_seconds),
                );
                position.* = next.position;
                velocity.* = next.velocity;
            }
        },
        .delay => |op| if (op.input) |input| {
            const values = node_values(program.nodes, slab, input);
            // A one-lane feed is broadcast (`graph.zig`, section 16).
            if (values.len == 1) {
                @memset(after, simulation.bounded(values[0]));
            } else {
                for (after, values) |*kept, value| kept.* = simulation.bounded(value);
            }
        },
        .follow => |*op| {
            const law: motion.Law = switch (op.law) {
                .spring => |fixed| .{ .spring = if (any_param(op.params))
                    spring_law_at(program, slab, op.params, fixed, own[follower_slots * output_count ..])
                else
                    fixed },
                .newtonian => |fixed| .{
                    .newtonian = newtonian_limits_at(program, slab, op.params, fixed),
                },
            };
            for (after, 0..) |*position, lane| {
                const kept = follower_own(cache, output_count, lane);
                const lane_op = seeded(simulation.Follower, op, node.extent.laned, family_lane(program, node, lane));
                const state = follower_unpack(position.*, kept);
                const next = simulation.follower_step(&lane_op, program.regions, law, state);
                follower_pack(next.state, position, kept);
                kept[follower_slot_arrived] = @floatFromInt(@intFromBool(next.arrived));
                if (next.arrived) kept[follower_slot_arrived_goal] = state.goal;
            }
        },
        .shift => |*op| for (after, 0..) |*value, lane| {
            const kept = shift_own(cache, op, output_count, lane);
            const lane_op = seeded(simulation.ShiftRegister, op, node.extent.laned, family_lane(program, node, lane));
            const bucket: u64 = @intFromFloat(kept[0]);
            const next = simulation.shift_step(&lane_op, kept[1..], bucket, index);
            kept[0] = @floatFromInt(next.bucket);
            value.* = next.value;
        },
        .oscillator => |*op| {
            const rates = node_values(program.nodes, slab, op.rate);
            assert(rates.len == output_count);
            for (after, own[0..output_count], rates) |*value, *phase, rate_read| {
                const rate = simulation.bounded(rate_read);
                const turned = phase.* + rate * simulation.step_seconds;
                phase.* = turned - @floor(turned);
                // A sum one ulp below a whole turn can round up to 1 after the floor.
                if (phase.* >= 1) phase.* = 0;
                value.* = op.shape.at(phase.*);
            }
        },
        .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .motion => unreachable,
        .bounce, .cues, .crossing, .input, .recorded, .track, .pack, .pick, .lane, .spread => unreachable,
        .minimum, .maximum, .apply => unreachable,
    }
    for (after) |value| assert(@abs(value) <= simulation.state_bound);
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
            for (after, 0..) |*position, lane| {
                const kept = follower_own(cache, output_count, lane);
                const lane_op = seeded(simulation.Follower, op, node.extent.laned, family_lane(program, node, lane));
                follower_pack(simulation.follower_start(&lane_op, program.regions), position, kept);
                kept[follower_slot_arrived] = 0;
                kept[follower_slot_arrived_goal] = op.from;
            }
            if (own.len > follower_slots * output_count) law_cache_reset(own[follower_slots * output_count ..]);
        },
        .oscillator => |op| {
            @memset(own, op.phase);
            @memset(after, op.shape.at(op.phase));
        },
        .shift => |*op| for (after, 0..) |*value, lane| {
            const kept = shift_own(cache, op, output_count, lane);
            const lane_op = seeded(simulation.ShiftRegister, op, node.extent.laned, family_lane(program, node, lane));
            simulation.shift_fill(&lane_op, kept[1..]);
            kept[0] = 0;
            const position = simulation.shift_position(&lane_op, 0);
            value.* = simulation.shift_value(&lane_op, kept[1..], position);
        },
        .constant, .add, .multiply, .map_range, .wave, .tween, .noise, .motion => unreachable,
        .bounce, .cues, .crossing, .input, .recorded, .track, .pack, .pick, .lane, .spread => unreachable,
        .minimum, .maximum, .apply => unreachable,
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

fn follower_pack(state: simulation.FollowerState, position: *f64, own: []f64) void {
    assert(own.len == follower_slots);
    // Counters below 2^53, which section 6 of `simulation.zig` promises, are exact in an f64.
    assert(state.drawn < 1 << 53);
    position.* = state.kinematics.position;
    own[0] = state.kinematics.velocity;
    own[1] = state.goal;
    own[2] = @floatFromInt(state.drawn);
    own[3] = @floatFromInt(state.pause_left);
}

/// A node's values read as an operand, with its extent, for a broadcast.
const Operand = struct {
    values: []const f64,
    extent: Extent,

    /// Its value at `lane` and `component` of a larger extent: one lane or one component is
    /// broadcast (`graph.zig`, sections 15 and 16).
    fn at(operand: Operand, lane: usize, component: usize) f64 {
        const row = if (operand.extent.lanes == 1) 0 else lane;
        const column = if (operand.extent.components == 1) 0 else component;
        return operand.values[row * operand.extent.components + column];
    }
};

fn operand_of(nodes: []const Node, slab: []const f64, id: Id) Operand {
    return .{ .values = node_values(nodes, slab, id), .extent = nodes[id.index].extent };
}

/// `left + right` per lane and component, an operand of one lane or one component broadcast.
fn add_into(out: []f64, extent: Extent, left: Operand, right: Operand) void {
    // Operands of the output's own extent, the common case, as one loop.
    if (left.values.len == out.len and right.values.len == out.len) {
        for (out, left.values, right.values) |*value, a, b| value.* = a + b;
        return;
    }
    for (0..extent.lanes) |lane| for (0..extent.components) |component| {
        out[lane * extent.components + component] = left.at(lane, component) + right.at(lane, component);
    };
}

fn multiply_into(out: []f64, extent: Extent, left: Operand, right: Operand) void {
    if (left.values.len == out.len and right.values.len == out.len) {
        for (out, left.values, right.values) |*value, a, b| value.* = a * b;
        return;
    }
    for (0..extent.lanes) |lane| for (0..extent.components) |component| {
        out[lane * extent.components + component] = left.at(lane, component) * right.at(lane, component);
    };
}

/// `f(left, right)` per lane and component, an operand of one lane or one component broadcast, as
/// `add_into` does.
fn pairwise_into(
    out: []f64,
    extent: Extent,
    left: Operand,
    right: Operand,
    comptime f: fn (f64, f64) f64,
) void {
    assert(out.len == extent.count());
    if (left.values.len == out.len and right.values.len == out.len) {
        for (out, left.values, right.values) |*value, a, b| value.* = f(a, b);
        return;
    }
    for (0..extent.lanes) |lane| for (0..extent.components) |component| {
        const a = left.at(lane, component);
        out[lane * extent.components + component] = f(a, right.at(lane, component));
    };
}

/// `function` of each value of `input`, whose extent is the output's (`graph.zig`, section 17).
fn apply_into(out: []f64, input: []const f64, function: graph.Function) void {
    assert(input.len == out.len);
    assert(out.len > 0);
    // The function is known in each arm, so the loop has no switch in it; a power's n is not, and
    // it is a counted loop of products.
    switch (function) {
        .pow => |n| for (out, input) |*value, x| {
            value.* = elementary.power(x, n);
        },
        inline else => |_, tag| {
            const known = @unionInit(graph.Function, @tagName(tag), {});
            for (out, input) |*value, x| value.* = known.of(x);
        },
    }
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
