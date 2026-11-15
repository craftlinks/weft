//! The signal graph back end: checked declarations to a `Program`, through the builder.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Two Passes
//! The builder reads its goal and region tables as slices taken at `Builder.init`, so the tables
//! are filled first: the cues, the tracks in declaration order, then every path and every list of
//! regions in text order. The checker already shared an inline run with an equal one, so Play's
//! five followers over `[0..1]` read one region. Then the declarations are built in order, so the
//! node array is the text order.
//!
//! ## 2. Expressions
//! An expression builds its operands left to right, then itself, so `a + b * c` is the nodes a, b,
//! c, product, sum: the order a hand-written builder call gives. A track's node is built where it
//! is first read, and shared after. A bound name builds nothing: it is its binding's ids.
//!
//! ## 3. Parameters From Signals
//! Where a signal sets a parameter, the node's fixed value is never read (`graph.zig`, section 14:
//! the step and `Program.ranges` both read the parameter's node). It is still validated, so it
//! must be a value the builder accepts. It is the signal's value before anything moves, where that
//! is known (a constant, a track's initial value, and sums and products of them), which keeps a
//! hand-built program's nodes, and otherwise 1 s, an overshoot of 0, or a limit of 1.
//!
//! ## 4. Refusals
//! A builder error becomes a diagnostic on the argument it is about, with the parameter's domain,
//! and stops the back end, since later nodes may read the one refused.
//!
//! ## 5. The Slab's Limit
//! The slab is a count, never an array the back end writes, so the builder is given the most a
//! program can hold and `Limits.slab` is compared once, after every declaration is built (step
//! 35). A file past it is refused on the name of the declaration whose nodes take the most of the
//! slab, with its values and its lanes, and the hint says fewer lanes, at what a lane costs, before
//! it gives the `Limits.slab` the file needs: a refusal at the call where the slab ran out named a
//! line that was only last, often a module's. When another error stops the build, the refusal
//! follows it and gives the least the slab needs, of the declarations built until then. The node
//! array is memory the builder writes, so its limit is still refused where it runs out.
//!
//! ## 6. Vectors
//! The core's vector nodes are only `pack` and `pick`, and its per-component arithmetic, map,
//! `apply`, `minimum`, and `maximum` (`graph.zig`, sections 15 and 17), so `abs`, `min`, and
//! `max` of a vector or a colour are one node each, as `+` is. A vector tween, spring, Newtonian
//! move, or chase is built as one scalar node a component, each from that component's ends,
//! goals, or target, then packed: two scalar springs side by side read exactly what a `vec2`
//! spring reads. A component of a vector
//! is the pack's own input where the vector is a pack, and a `pick` otherwise. An `srgb` colour is
//! converted to OKLab here, three constants packed. A vector motion records no goal source, so a
//! client draws no goal for it.
//!
//! ## 8. Lanes
//! Each expression records the count of the region it was checked in (`check.zig`, section 9), and
//! a call is built with the builder's region set to it, so a per-lane source takes the region's
//! lanes and everything else takes what the core gives it (`graph.zig`, section 16). `lane` is
//! the core's `lane`, and a `stagger:` goes to its source as it is. A region whose body has one
//! lane is spread to its count, a component at a time for a vector, so a binding of
//! `lanes(n, …)` always has n lanes.
//!
//! ## 9. Nouns That Only Describe
//! A `noun` declaration (step 27, `check.zig` section 6a) builds each signal among its call's
//! arguments, in parameter order, and nothing for the call: the client reads the values from
//! `Checked` and each signal's node from `expr_ids`. The nodes are the binding's, so a recompile
//! carries a simulated signal inside a noun as it carries any other.
//!
//! ## 7. TigerStyle Invariants
//! - Every table is the caller's and sized by `Limits`; the checker already refused what would
//!   not fit, except the node array and the slab, whose refusals are errors naming their limit,
//!   the slab's once the build is done (section 5).
//! - The recursion over expressions follows the tree, whose depth the parser bounds.

const std = @import("std");
const table = @import("table.zig");
const assert = std.debug.assert;
const weft = @import("weft");
const check_module = @import("jig").check;
const Checked = check_module.Checked;
const Value = check_module.Value;
const schema = @import("jig").schema;
const error_module = @import("jig").diagnostic;
const Diagnostics = error_module.List;
const parse_module = @import("jig").parse;
const Tree = parse_module.Tree;
const graph = weft.graph;
const Builder = graph.Builder;
const Id = graph.Id;
const cue_module = weft.cue;
const Cue = cue_module.Cue;
const Cues = cue_module.Cues;
const motion = weft.motion;
const simulation = weft.simulation;
const time_module = weft.time;
const Time = time_module.Time;
const track_module = weft.track;
const Sample = weft.recording.Sample;
const wave = weft.wave;
const noise = weft.noise;
const Ease = weft.ease.Ease;
const colour = weft.colour;

const flicks_per_second = time_module.flicks_per_second;

/// Where a signal's goal comes from, for a client drawing it (Play's goal traces).
pub const GoalSource = union(enum) {
    none,
    /// A spring's or a Newtonian move's goals, and its value before the first.
    path: struct { path: motion.Path, from: f64 },
    /// A chase's target.
    node: Id,
};

/// The nodes a declaration's expression built, `first` to `end`, in build order.
pub const NodeRange = struct { first: u32, end: u32 };

/// A binding's nodes: its first output, and a bounce's velocity.
pub const Ids = struct {
    first: Id,
    second: ?Id = null,
};

/// The tables a program reads, which must not move once built.
pub const Tables = struct {
    cues: Cues,
    goals: motion.Goals,
    regions: simulation.Regions,
    tracks: track_module.Tracks,
};

pub const Memory = struct {
    nodes: []graph.Node,
    slab_count_max: u32,
    cue_times: []Time,
    goal_entries: []motion.Goal,
    region_entries: []simulation.Region,
    track_entries: []track_module.Track,
    /// Each track's samples, `track_samples.len / track_entries.len` each.
    track_samples: []Sample,
    /// One for each checked path and each checked list of regions.
    paths: []motion.Path,
    runs: []simulation.Span,
    /// One for each binding.
    ids: []Ids,
    goal_sources: []GoalSource,
    /// One for each track.
    track_nodes: []?Id,
    /// One for each checked expression, so an expression the checker shares is built once: a
    /// module's parameter used twice is one signal (`check.zig`, section 6).
    expr_ids: []?Ids,
    /// One for each checked call, so a call two expressions share is built once: a module's local
    /// read as `b` and as `b.velocity` is one `bounce` (Jig's step 2).
    call_ids: []?Ids,
    /// One for each binding: the nodes its declaration built, for a recompile's carry (step 15).
    node_ranges: []NodeRange,
};

const Fail = error{Refused};

const Back = struct {
    checked: *const Checked,
    tree: *const Tree,
    memory: Memory,
    tables: *Tables,
    builder: Builder,
    diagnostics: *Diagnostics,
    /// The goal source of the last spring, Newtonian move, or chase built.
    goal: GoalSource = .none,

    fn fail(back: *Back, index: u32, code: error_module.Code, comptime format: []const u8, args: anytype) ?*error_module.Diagnostic {
        const span = check_module.item_bytes(back.tree, index);
        return back.diagnostics.add(code, span.start, @max(span.len, 1), format, args);
    }

    /// An expression's nodes, built the first time it is asked for.
    fn eval(back: *Back, expr_index: u32) Fail!Ids {
        assert(expr_index < back.checked.exprs.len);
        if (back.memory.expr_ids[expr_index]) |ids| return ids;
        const ids = try back.eval_uncached(expr_index);
        back.memory.expr_ids[expr_index] = ids;
        return ids;
    }

    /// A call's nodes, built the first time any expression of it asks, so two expressions of one
    /// call, a module local's outputs, share them.
    fn call_built(back: *Back, call: u32) Fail!Ids {
        assert(call < back.checked.calls.len);
        if (back.memory.call_ids[call]) |ids| return ids;
        const ids = try back.build_call(call);
        back.memory.call_ids[call] = ids;
        return ids;
    }

    fn eval_uncached(back: *Back, expr_index: u32) Fail!Ids {
        const expr = back.checked.exprs[expr_index];
        assert(back.memory.expr_ids[expr_index] == null);
        switch (expr.tag) {
            .call => {
                const saved = back.builder.lanes;
                defer back.builder.lanes = saved;
                back.builder.lanes = region_of(expr);
                const ids = try back.call_built(expr.a);
                if (expr.b == 0) return .{ .first = ids.first, .second = ids.second };
                assert(expr.b == 1);
                return .{ .first = ids.second.? };
            },
            .constant => return .{ .first = try back.attempt(back.builder.constant(expr.number), expr.item, null) },
            .add, .multiply => {
                const left = (try back.eval(expr.a)).first;
                const right = (try back.eval(expr.b)).first;
                const result = if (expr.tag == .add)
                    back.builder.add(left, right)
                else
                    back.builder.multiply(left, right);
                return .{ .first = try back.attempt(result, expr.item, null) };
            },
            .binding => {
                const ids = back.memory.ids[expr.a];
                if (expr.b == 0) return ids;
                return .{ .first = ids.second.? };
            },
            .pick => {
                const vector = (try back.eval(expr.a)).first;
                return .{ .first = try back.component(vector, @intCast(expr.b), expr.item) };
            },
            .track => {
                if (back.memory.track_nodes[expr.a]) |id| return .{ .first = id };
                const id = try back.attempt(back.builder.track(.{ .index = expr.a }), expr.item, null);
                back.memory.track_nodes[expr.a] = id;
                return .{ .first = id };
            },
            .lane => {
                const saved = back.builder.lanes;
                defer back.builder.lanes = saved;
                back.builder.lanes = region_of(expr);
                return .{ .first = try back.attempt(back.builder.lane(), expr.item, null) };
            },
        }
    }

    /// The signal's value before anything moves, where it is known (section 3).
    fn initial_of(back: *const Back, expr_index: u32, depth: u32) ?f64 {
        if (depth > parse_module.depth_max * 2) return null;
        const expr = back.checked.exprs[expr_index];
        return switch (expr.tag) {
            .constant => expr.number,
            .track => back.checked.tracks[expr.a].initial,
            .binding => if (expr.b == 0 and back.checked.bindings[expr.a].kind == .signal)
                back.initial_of(back.checked.bindings[expr.a].index, depth + 1)
            else
                null,
            .add, .multiply => {
                const a = back.initial_of(expr.a, depth + 1) orelse return null;
                const b = back.initial_of(expr.b, depth + 1) orelse return null;
                return if (expr.tag == .add) a + b else a * b;
            },
            .call, .pick, .lane => null,
        };
    }

    /// Component `k` of a vector node: a pack's own input, or a pick (section 6).
    fn component(back: *Back, id: Id, k: u8, item: u32) Fail!Id {
        switch (back.builder.nodes[id.index].op) {
            .pack => |packed_ids| {
                assert(k < packed_ids.count);
                return packed_ids.inputs[k];
            },
            else => return back.attempt(back.builder.pick(id, k), item, null),
        }
    }

    /// Packs one node a component, built by `each`, into a vector (section 6).
    fn pack(back: *Back, ids: []const Id, item: u32, call: u32) Fail!Ids {
        return .{ .first = try back.attempt(back.builder.pack(ids), item, call) };
    }

    const Param = struct { fixed: f64, from: ?Id };

    /// A number parameter that a signal may set: its fixed value and its node (section 3).
    fn live_number(back: *Back, value: Value, fallback: f64, valid: *const fn (f64) bool) Fail!Param {
        return switch (value) {
            .number => |number| .{ .fixed = number, .from = null },
            .signal => |expr| signal: {
                const id = (try back.eval(expr)).first;
                const initial = back.initial_of(expr, 0);
                const fixed = if (initial) |known| (if (valid(known)) known else fallback) else fallback;
                break :signal .{ .fixed = fixed, .from = id };
            },
            else => unreachable,
        };
    }

    const TimeParam = struct { fixed: Time, from: ?Id };

    fn live_time(back: *Back, value: Value) Fail!TimeParam {
        return switch (value) {
            .time => |flicks| .{ .fixed = .{ .flicks = flicks }, .from = null },
            .signal => |expr| signal: {
                const id = (try back.eval(expr)).first;
                var fixed: Time = .{ .flicks = flicks_per_second };
                if (back.initial_of(expr, 0)) |seconds| {
                    const flicks = seconds * @as(f64, @floatFromInt(flicks_per_second));
                    if (flicks >= 1 and flicks < 0x1p62) fixed = .{ .flicks = @intFromFloat(@round(flicks)) };
                }
                break :signal .{ .fixed = fixed, .from = id };
            },
            else => unreachable,
        };
    }

    fn signal_id(back: *Back, value: Value) Fail!Id {
        return (try back.eval(value.signal)).first;
    }

    fn build_call(back: *Back, call: u32) Fail!Ids {
        const checked = back.checked;
        const entry = checked.calls[call].entry;
        const v = checked.call_values(call);
        const item = checked.calls[call].item;
        const builder = &back.builder;
        switch (table.op_of(entry)) {
            // The checker binds a noun as a declaration, never as an expression.
            .noun => unreachable,
            .client => {
                const diagnostic = back.fail(item, .refused, "`{s}` has no back end in Weft", .{entry.name});
                error_module.hint(diagnostic, "a client builds its own nodes from `Checked.calls`, and checks such a file with `jig.File`", .{});
                return error.Refused;
            },
            .wave => {
                const source: wave.Wave = .{
                    .shape = schema.word_value(wave.Shape, v[0].word),
                    .hz = v[1].frequency,
                    .stagger = .{ .flicks = v[2].time },
                };
                return .{ .first = try back.attempt(builder.wave(source), item, call) };
            },
            .lanes => {
                const body = (try back.eval(v[1].signal)).first;
                const count: u32 = @intCast(v[0].integer);
                if (builder.nodes[body.index].extent.lanes == count) return .{ .first = body };
                assert(builder.nodes[body.index].extent.lanes == 1);
                builder.lanes = count;
                const components = builder.nodes[body.index].extent.components;
                if (components == 1) return .{ .first = try back.attempt(builder.spread(body), item, call) };
                var ids: [graph.components_max]Id = undefined;
                for (ids[0..components], 0..) |*id, k| {
                    const one = try back.component(body, @intCast(k), item);
                    id.* = try back.attempt(builder.spread(one), item, call);
                }
                return back.pack(ids[0..components], item, call);
            },
            .noise => {
                const source: noise.Noise = .{
                    .shape = schema.word_value(noise.Shape, v[0].word),
                    .hz = v[1].frequency,
                    .seed = v[2].seed,
                };
                return .{ .first = try back.attempt(builder.noise(source), item, call) };
            },
            .pack => {
                var ids: [graph.components_max]Id = undefined;
                for (v[0..entry.params.len], ids[0..entry.params.len]) |value, *id| id.* = try back.signal_id(value);
                return back.pack(ids[0..entry.params.len], item, call);
            },
            .srgb => {
                for (v[0..3], 0..) |value, at| if (!(value.number >= 0 and value.number <= 1)) {
                    const diagnostic = back.fail(checked.call_value_items(call)[at], .out_of_range, "an sRGB channel is in [0, 1]", .{});
                    error_module.hint(diagnostic, "write each of r, g, and b from 0 to 1", .{});
                    return error.Refused;
                };
                const lab = colour.from_srgb(.{ v[0].number, v[1].number, v[2].number });
                var ids: [3]Id = undefined;
                for (&ids, lab) |*id, value| id.* = try back.attempt(builder.constant(value), item, call);
                return back.pack(&ids, item, call);
            },
            .tween => {
                const components = @max(v[0].shape().components, v[1].shape().components);
                if (components > 1) {
                    const after: ?Id = if (v[5] == .signal) try back.signal_id(v[5]) else null;
                    var ids: [graph.components_max]Id = undefined;
                    for (ids[0..components], 0..) |*id, k| {
                        const source: graph.Tween = .{
                            .from = v[0].component(k),
                            .to = v[1].component(k),
                            .start = cue_start(v[2]),
                            .cue_by_lane = v[2] == .cue_by_lane,
                            .duration = .{ .flicks = v[3].time },
                            .ease = switch (v[4]) {
                                .cubic => |points| .{ .x1 = points[0], .y1 = points[1], .x2 = points[2], .y2 = points[3] },
                                else => ease_of(v[4].word),
                            },
                            .previous = if (after) |vector| try back.component(vector, @intCast(k), item) else null,
                            .stagger = .{ .flicks = v[6].time },
                        };
                        id.* = try back.attempt(builder.tween(source), item, call);
                    }
                    return back.pack(ids[0..components], item, call);
                }
                const previous: ?Id = if (v[5] == .signal) try back.signal_id(v[5]) else null;
                const source: graph.Tween = .{
                    .from = v[0].number,
                    .to = v[1].number,
                    .start = cue_start(v[2]),
                    .cue_by_lane = v[2] == .cue_by_lane,
                    .duration = .{ .flicks = v[3].time },
                    .ease = switch (v[4]) {
                        .cubic => |points| .{ .x1 = points[0], .y1 = points[1], .x2 = points[2], .y2 = points[3] },
                        else => ease_of(v[4].word),
                    },
                    .previous = previous,
                    .stagger = .{ .flicks = v[6].time },
                };
                return .{ .first = try back.attempt(builder.tween(source), item, call) };
            },
            .spring => {
                const components = checked.paths[v[0].path].shape.components;
                if (components > 1) {
                    var ids: [graph.components_max]Id = undefined;
                    for (ids[0..components], 0..) |*id, k| {
                        const source: motion.Spring = .{
                            .goals = back.memory.paths[v[0].path + k],
                            .from = v[1].component(k),
                            .time = .{ .flicks = v[2].time },
                            .overshoot = v[3].number,
                            .stagger = .{ .flicks = v[4].time },
                        };
                        id.* = try back.attempt(builder.spring(source), item, call);
                    }
                    back.goal = .none;
                    return back.pack(ids[0..components], item, call);
                }
                const source: motion.Spring = .{
                    .goals = back.memory.paths[v[0].path],
                    .from = v[1].number,
                    .time = .{ .flicks = v[2].time },
                    .overshoot = v[3].number,
                    .stagger = .{ .flicks = v[4].time },
                };
                back.goal = .{ .path = .{ .path = source.goals, .from = source.from } };
                return .{ .first = try back.attempt(builder.spring(source), item, call) };
            },
            .newtonian => {
                const components = checked.paths[v[0].path].shape.components;
                if (components > 1) {
                    var ids: [graph.components_max]Id = undefined;
                    for (ids[0..components], 0..) |*id, k| {
                        const source: motion.Newtonian = .{
                            .goals = back.memory.paths[v[0].path + k],
                            .from = v[1].component(k),
                            .speed = v[2].number,
                            .accel = v[3].number,
                            .decel = v[4].number,
                            .stagger = .{ .flicks = v[5].time },
                        };
                        id.* = try back.attempt(builder.newtonian(source), item, call);
                    }
                    back.goal = .none;
                    return back.pack(ids[0..components], item, call);
                }
                const source: motion.Newtonian = .{
                    .goals = back.memory.paths[v[0].path],
                    .from = v[1].number,
                    .speed = v[2].number,
                    .accel = v[3].number,
                    .decel = v[4].number,
                    .stagger = .{ .flicks = v[5].time },
                };
                back.goal = .{ .path = .{ .path = source.goals, .from = source.from } };
                return .{ .first = try back.attempt(builder.newtonian(source), item, call) };
            },
            .chase => {
                const target = try back.signal_id(v[0]);
                const time = try back.live_time(v[2]);
                const overshoot = try back.live_number(v[3], 0, valid_overshoot);
                const components = builder.nodes[target.index].extent.components;
                if (components > 1) {
                    var ids: [graph.components_max]Id = undefined;
                    for (ids[0..components], 0..) |*id, k| {
                        const source: graph.Chase = .{
                            .target = try back.component(target, @intCast(k), item),
                            .from = v[1].number,
                            .time = time.fixed,
                            .overshoot = overshoot.fixed,
                            .time_from = time.from,
                            .overshoot_from = overshoot.from,
                        };
                        id.* = try back.attempt(builder.chase(source), item, call);
                    }
                    back.goal = .none;
                    return back.pack(ids[0..components], item, call);
                }
                const source: graph.Chase = .{
                    .target = target,
                    .from = v[1].number,
                    .time = time.fixed,
                    .overshoot = overshoot.fixed,
                    .time_from = time.from,
                    .overshoot_from = overshoot.from,
                };
                back.goal = .{ .node = target };
                return .{ .first = try back.attempt(builder.chase(source), item, call) };
            },
            .oscillator => {
                const rate = try back.signal_id(v[1]);
                const source: graph.Oscillator = .{
                    .shape = schema.word_value(wave.Shape, v[0].word),
                    .rate = rate,
                    .phase = v[2].number,
                };
                return .{ .first = try back.attempt(builder.oscillator(source), item, call) };
            },
            .follow => {
                const mover_call = v[2].mover;
                const m = checked.call_values(mover_call);
                var mover: simulation.Mover = undefined;
                var from: graph.MoverFrom = .{};
                switch (table.op_of(checked.calls[mover_call].entry)) {
                    .spring_mover => {
                        const time = try back.live_time(m[0]);
                        const overshoot = try back.live_number(m[1], 0, valid_overshoot);
                        mover = .{ .spring = .{ .time = time.fixed, .overshoot = overshoot.fixed } };
                        from = .{ .time = time.from, .overshoot = overshoot.from };
                    },
                    .newtonian_mover => {
                        const speed = try back.live_number(m[0], 1, valid_limit);
                        const accel = try back.live_number(m[1], 1, valid_limit);
                        const decel = try back.live_number(m[2], 1, valid_limit);
                        mover = .{ .newtonian = .{ .speed = speed.fixed, .accel = accel.fixed, .decel = decel.fixed } };
                        from = .{ .speed = speed.from, .accel = accel.from, .decel = decel.from };
                    },
                    else => unreachable,
                }
                const source: graph.Follow = .{
                    .regions = back.memory.runs[v[0].regions],
                    .from = v[1].number,
                    .mover = mover,
                    .mover_from = from,
                    .pick = schema.word_value(simulation.Pick, v[3].word),
                    .tolerance = v[4].number,
                    .pause_min = .{ .flicks = v[5].time_range[0] },
                    .pause_max = .{ .flicks = v[5].time_range[1] },
                    .seed = v[6].seed,
                };
                return .{ .first = try back.attempt(builder.follow(source), item, call) };
            },
            .shift => {
                const buckets = std.math.cast(u32, v[1].integer) orelse std.math.maxInt(u32);
                const source: graph.Shift = .{
                    .low = v[0].number_range[0],
                    .high = v[0].number_range[1],
                    .buckets = buckets,
                    .period = .{ .flicks = v[2].time },
                    .odds = v[3].number,
                    .shape = schema.word_value(simulation.ShiftShape, v[4].word),
                    .seed = v[5].seed,
                };
                return .{ .first = try back.attempt(builder.shift(source), item, call) };
            },
            .delay => return .{ .first = try back.attempt(builder.delay(v[0].number), item, call) },
            .bounce => {
                const source: graph.Bounce = .{
                    .low = v[0].number_range[0],
                    .high = v[0].number_range[1],
                    .speed = v[1].number,
                    .start = cue_start(v[2]),
                    .stagger = .{ .flicks = v[3].time },
                    .cue_by_lane = v[2] == .cue_by_lane,
                };
                const ids = builder.bounce(source) catch |err| return back.refuse(err, item, call);
                return .{ .first = ids.position, .second = ids.velocity };
            },
            .crossing => {
                const input = try back.signal_id(v[0]);
                const source: graph.Crossing = .{
                    .input = input,
                    .level = v[1].number,
                    .direction = schema.word_value(graph.Crossing.Direction, v[2].word),
                };
                return .{ .first = try back.attempt(builder.crossing(source), item, call) };
            },
            .cues => {
                const span = v[0].span;
                const count: u32 = switch (v[1]) {
                    .integer => |integer| std.math.cast(u32, integer) orelse std.math.maxInt(u32),
                    else => span.count,
                };
                const source: graph.CueSpan = .{ .first = .{ .index = span.first }, .count = count };
                return .{ .first = try back.attempt(builder.cues(source), item, call) };
            },
            .input => {
                const source: graph.Input = .{
                    .low = v[0].number_range[0],
                    .high = v[0].number_range[1],
                    .initial = v[1].number,
                };
                return .{ .first = try back.attempt(builder.input(source), item, call) };
            },
            .map => {
                const input = try back.signal_id(v[0]);
                const source: graph.MapRange = .{
                    .input = input,
                    .input_low = v[1].number_range[0],
                    .input_high = v[1].number_range[1],
                    .output_low = v[2].number_range[0],
                    .output_high = v[2].number_range[1],
                };
                return .{ .first = try back.attempt(builder.map_range(source), item, call) };
            },
            .function => {
                const input = try back.signal_id(v[0]);
                const n = if (v.len == 2) v[1].integer else 0;
                const result = builder.apply(table.core_function(entry.function_of(n).?), input);
                return .{ .first = try back.attempt(result, item, call) };
            },
            .minimum, .maximum => {
                const a = try back.signal_id(v[0]);
                const b = try back.signal_id(v[1]);
                const result = switch (table.op_of(entry)) {
                    .minimum => builder.minimum(a, b),
                    else => builder.maximum(a, b),
                };
                return .{ .first = try back.attempt(result, item, call) };
            },
            .spring_mover, .newtonian_mover => unreachable,
        }
    }

    fn attempt(back: *Back, result: Builder.Error!Id, item: u32, call: ?u32) Fail!Id {
        return result catch |err| back.refuse(err, item, call);
    }

    /// A builder error as a diagnostic on the argument it is about (section 4).
    fn refuse(back: *Back, err: Builder.Error, item: u32, call: ?u32) Fail {
        const entry_name = if (call) |at| back.checked.calls[at].entry.name else "this";
        const op: ?table.Op = if (call) |at| table.op_of(back.checked.calls[at].entry) else null;
        const Code = error_module.Code;
        const At = struct { param: []const u8, message: []const u8, hint: []const u8 = "" };
        const at: At = switch (err) {
            error.NodeCapacityExceeded => {
                const diagnostic = back.fail(item, Code.limit, "the program needs more than {d} nodes", .{back.memory.nodes.len});
                error_module.hint(diagnostic, "raise `Limits.nodes`", .{});
                return error.Refused;
            },
            // Only past the most a program holds, since the limit is compared after the build
            // (section 5).
            error.SlabCapacityExceeded => {
                const diagnostic = back.fail(item, Code.limit, "the program needs a slab of more than {d} values, the most a program holds", .{back.builder.slab_count_max});
                error_module.hint(diagnostic, "use fewer lanes", .{});
                return error.Refused;
            },
            error.InvalidOvershoot => .{ .param = "overshoot", .message = "`overshoot` must be in [0, 1)", .hint = "0 settles without passing the goal; 0.5 is bouncy" },
            error.InvalidDuration => switch (op orelse .wave) {
                .tween => .{ .param = "over", .message = "`over` must be above 0s" },
                .shift => .{ .param = "period", .message = "`period` must be above 0s, at most 2^53 flicks, and at least one step of 1/480 s a bucket" },
                .bounce => .{ .param = "speed", .message = "a leg, `range` at `speed`, must last at least a flick and under 2^53 flicks" },
                else => .{ .param = "time", .message = "`time` must be above 0s" },
            },
            error.InvalidRate => .{ .param = "hz", .message = "`hz` must be above 0hz and at most 524288hz" },
            error.InvalidLimit => .{ .param = "speed", .message = "`speed`, `accel`, and `decel` must be above 0" },
            error.InvalidTolerance => .{ .param = "tolerance", .message = "`tolerance` must be at least 0" },
            error.InvalidPause => .{ .param = "pause", .message = "`pause` must run from at least 0s up to its high end, at most 2^32 - 1 steps" },
            error.InvalidOdds => .{ .param = "odds", .message = "`odds` must be in [0, 1]" },
            error.InvalidBuckets => .{ .param = "buckets", .message = "`buckets` must be from 1 to 64" },
            error.InvalidPhase => .{ .param = "phase", .message = "`phase` must be in [0, 1)" },
            error.InvalidPower => .{ .param = "n", .message = "`n` must be a whole number from 2 to 8" },
            error.InvalidRange => switch (op orelse .wave) {
                .input => .{ .param = "initial", .message = "`initial` must be inside the range, whose low end is at most its high" },
                .map => .{ .param = "from", .message = "`from` must have a width that fits a double" },
                else => .{ .param = "range", .message = "the range's low end must be below its high" },
            },
            error.UnknownCue => if (op == .cues)
                .{ .param = "count", .message = "the cues run past the last cue" }
            else
                .{ .param = "", .message = "this runs on the fixed step from a start cue, and the file has no cue", .hint = "declare one, such as `cue c0 = 0s`" },
            error.NotFinite => .{ .param = "", .message = "a value is infinite, not a number, or past 2^256 either way where it moves" },
            error.InvalidEase => .{ .param = "ease", .message = "a cubic ease's x1 and x2 must be in [0, 1]" },
            error.ShapeMismatch => .{ .param = "", .message = "the shapes of its values do not fit together" },
            error.LaneMismatch => .{ .param = "", .message = "the lanes of its values do not fit together" },
            else => .{ .param = "", .message = "the builder refused this call" },
        };
        const target = if (call) |index| back.param_item(index, at.param) else item;
        const diagnostic = back.fail(target, Code.refused, "{s}: {s}", .{ entry_name, at.message });
        if (at.hint.len > 0) error_module.hint(diagnostic, "{s}", .{at.hint});
        return error.Refused;
    }

    /// The item of parameter `name` of a call, the follower's `by` for its mover's, or the call.
    fn param_item(back: *const Back, call: u32, name: []const u8) u32 {
        const record = back.checked.calls[call];
        const items = back.checked.call_value_items(call);
        if (record.entry.param(name)) |index| return items[index];
        if (table.op_of(record.entry) == .follow) {
            const mover = back.checked.calls[back.checked.call_values(call)[2].mover];
            if (mover.entry.param(name)) |index| return back.checked.call_value_items(back.checked.call_values(call)[2].mover)[index];
            return items[2];
        }
        return record.item;
    }
};

/// The builder's region for an expression checked in `expr.region`, or null outside one.
fn region_of(expr: check_module.Expr) ?u32 {
    return if (expr.region == 0) null else expr.region;
}

fn valid_overshoot(value: f64) bool {
    return value >= 0 and value < 1;
}

fn valid_limit(value: f64) bool {
    return value > 0 and std.math.isFinite(value);
}

/// The cue a `tween`'s or a `bounce`'s `at` names: a cue, or the first of a series chosen by lane,
/// which the op's `cue_by_lane` then reads one cue a lane after (step 28).
fn cue_start(value: check_module.Value) Cue {
    return switch (value) {
        .cue => |index| .{ .index = index },
        .cue_by_lane => |index| .{ .index = index },
        else => unreachable,
    };
}

fn ease_of(word: u8) Ease {
    return switch (word) {
        0 => Ease.linear,
        1 => Ease.in,
        2 => Ease.out,
        3 => Ease.in_out,
        else => unreachable,
    };
}

/// Builds the program of `checked`, which has no error, into `memory` and `tables` (section 1),
/// or adds a diagnostic and returns null.
pub fn build(
    checked: *const Checked,
    tree: *const Tree,
    memory: Memory,
    tables: *Tables,
    diagnostics: *Diagnostics,
) ?graph.Program {
    assert(checked.ok);
    assert(memory.paths.len >= checked.paths.len);
    assert(memory.runs.len >= checked.region_runs.len);
    assert(memory.ids.len >= checked.bindings.len);
    assert(memory.track_nodes.len >= checked.tracks.len);
    assert(memory.cue_times.len >= checked.cue_times.len);
    assert(memory.expr_ids.len >= checked.exprs.len);
    assert(memory.call_ids.len >= checked.calls.len);
    assert(memory.node_ranges.len >= checked.bindings.len);
    @memset(memory.node_ranges[0..checked.bindings.len], .{ .first = 0, .end = 0 });
    @memset(memory.expr_ids[0..checked.exprs.len], null);
    @memset(memory.call_ids[0..checked.calls.len], null);
    tables.cues = Cues.init(memory.cue_times);
    for (checked.cue_times) |flicks| _ = tables.cues.add(.{ .flicks = flicks }) catch unreachable;
    tables.tracks = track_module.Tracks.init(memory.track_entries);
    const per_track = if (memory.track_entries.len == 0) 0 else memory.track_samples.len / memory.track_entries.len;
    for (checked.tracks, 0..) |track, index| {
        const samples = memory.track_samples[index * per_track ..][0..per_track];
        _ = tables.tracks.add(samples, track.low, track.high, track.initial) catch unreachable;
        memory.track_nodes[index] = null;
    }
    tables.goals = motion.Goals.init(memory.goal_entries);
    for (checked.paths, 0..) |run, index| {
        const goals = checked.goals[run.first..][0..run.count];
        var path: motion.Path = .{ .first = tables.goals.count, .count = run.count };
        var copied: usize = 0;
        while (copied < goals.len) {
            var entries: [64]motion.Goal = undefined;
            const chunk = @min(entries.len, goals.len - copied);
            for (entries[0..chunk], goals[copied..][0..chunk]) |*entry, goal| {
                entry.* = .{ .cue = .{ .index = goal.cue }, .value = goal.value, .cue_by_lane = goal.cue_by_lane };
            }
            const added = tables.goals.add(entries[0..chunk]) catch unreachable;
            if (copied == 0) path.first = added.first;
            copied += chunk;
        }
        memory.paths[index] = path;
    }
    tables.regions = simulation.Regions.init(memory.region_entries);
    for (checked.region_runs, 0..) |run, index| {
        const first = tables.regions.count;
        for (checked.regions[run.first..][0..run.count]) |region| {
            _ = tables.regions.add(&.{.{ .low = region.low, .high = region.high }}) catch unreachable;
        }
        memory.runs[index] = .{ .first = first, .count = run.count };
    }
    var back: Back = .{
        .checked = checked,
        .tree = tree,
        .memory = memory,
        .tables = tables,
        // The slab is only a count, so the builder takes the most a program can hold and the
        // limit is compared once every declaration is built (section 5).
        .builder = Builder.init(memory.nodes, .{
            .slab_count_max = std.math.maxInt(u32),
            .cues = &tables.cues,
            .goals = tables.goals.table(),
            .regions = tables.regions.table(),
            .tracks = &tables.tracks,
            .start = .{ .index = checked.start },
            .seed = checked.seed,
        }),
        .diagnostics = diagnostics,
    };
    var most: Most = .{};
    const built = build_declarations(&back, &most);
    // Past the limit, the slab's refusal names the declaration that needs the most, after the
    // error that stopped the build if one did, of the declarations built until then.
    if (back.builder.slab_count > memory.slab_count_max) {
        refuse_slab(&back, most, if (built) |_| true else |_| false);
        return null;
    }
    built catch return null;
    return back.builder.finish();
}

/// Builds every declaration in order (section 1), keeping in `most` the one whose nodes take the
/// most of the slab (section 5), the one an error stopped among them.
fn build_declarations(back: *Back, most: *Most) Fail!void {
    const checked = back.checked;
    assert(most.need == 0);
    for (checked.declarations) |declaration| {
        const first = back.builder.node_count;
        const slab_before = back.builder.slab_count;
        const built = build_declaration(back, declaration, first);
        const need = back.builder.slab_count - slab_before;
        if (need > most.need) {
            const nodes = back.builder.nodes[first..back.builder.node_count];
            const binding, const item = switch (declaration) {
                .signal => |signal| .{ signal.binding, checked.bindings[signal.binding].item },
                .noun => |noun| .{ noun.binding, checked.bindings[noun.binding].item },
                .feed => |feed| .{ feed.binding, feed.item },
            };
            most.* = .{ .need = need, .binding = binding, .item = item, .lanes = lanes_of(nodes), .per_lane = per_lane_of(nodes) };
        }
        try built;
    }
    assert(most.need <= back.builder.slab_count);
}

/// One declaration's nodes, from `first`.
fn build_declaration(back: *Back, declaration: check_module.Declaration, first: u32) Fail!void {
    const checked = back.checked;
    const memory = back.memory;
    assert(first == back.builder.node_count);
    switch (declaration) {
        .signal => |signal| {
            const ids = try back.eval(signal.expr);
            memory.node_ranges[signal.binding] = .{ .first = first, .end = back.builder.node_count };
            memory.ids[signal.binding] = ids;
            memory.goal_sources[signal.binding] = goal_source(back, signal.expr);
        },
        .noun => |noun| {
            for (checked.call_values(noun.call)) |value| {
                if (value == .signal) _ = try back.eval(value.signal);
            }
            memory.node_ranges[noun.binding] = .{ .first = first, .end = back.builder.node_count };
            memory.goal_sources[noun.binding] = .none;
        },
        .feed => |feed| {
            const input = (try back.eval(feed.expr)).first;
            const delay = memory.ids[feed.binding].first;
            back.builder.close(delay, input) catch unreachable;
        },
    }
    assert(back.builder.node_count >= first);
}

/// The declaration whose nodes take the most of the slab, for the slab's refusal (section 5).
const Most = struct {
    need: u32 = 0,
    binding: u32 = 0,
    /// Its declaration's item, whose token is its name.
    item: u32 = 0,
    /// The most lanes among its nodes.
    lanes: u32 = 1,
    /// What a lane of it adds to the slab, as `weft check` counts it.
    per_lane: u64 = 0,
};

/// The most lanes among `nodes`.
fn lanes_of(nodes: []const graph.Node) u32 {
    var lanes: u32 = 1;
    for (nodes) |node| lanes = @max(lanes, node.extent.lanes);
    assert(lanes >= 1);
    return lanes;
}

/// The f64 a lane adds to the slab among `nodes`: each node of many lanes' values and caches over
/// its lanes, rounded up, summed, as `weft check`'s `a lane costs` counts them. 0 for none.
fn per_lane_of(nodes: []const graph.Node) u64 {
    var total: u64 = 0;
    for (nodes) |node| {
        if (node.extent.lanes <= 1) continue;
        const count: u64 = node.extent.count();
        total += std.math.divCeil(u64, count + node.op.cache_count(count), node.extent.lanes) catch unreachable;
    }
    return total;
}

/// The slab's refusal (section 5): the slab the program needs, its limit, and the declaration that
/// needs the most, on its name, with its lanes; the hint says fewer lanes before `Limits.slab`.
/// `complete` is false when an error stopped the build, so the need is only a least.
fn refuse_slab(back: *Back, most: Most, complete: bool) void {
    const total = back.builder.slab_count;
    const limit = back.memory.slab_count_max;
    assert(total > limit);
    assert(most.need > 0);
    const name = back.checked.bindings[most.binding].name;
    const token = back.tree.tokens[back.tree.item(most.item).token];
    const least = if (complete) "" else "at least ";
    const diagnostic = if (most.lanes > 1)
        back.diagnostics.add(.limit, token.start, @max(token.len, 1), "the slab needs {s}{d} values, more than {d}; `{s}` needs {d} of them, at {d} lanes", .{ least, total, limit, name, most.need, most.lanes })
    else
        back.diagnostics.add(.limit, token.start, @max(token.len, 1), "the slab needs {s}{d} values, more than {d}; `{s}` needs {d} of them", .{ least, total, limit, name, most.need });
    if (most.lanes > 1 and complete) {
        error_module.hint(diagnostic, "give `{s}` fewer lanes, which cost {d} of the slab each, or raise `Limits.slab` to {d}", .{ name, most.per_lane, total });
    } else if (most.lanes > 1) {
        error_module.hint(diagnostic, "give `{s}` fewer lanes, which cost {d} of the slab each, or raise `Limits.slab`", .{ name, most.per_lane });
    } else if (complete) {
        error_module.hint(diagnostic, "raise `Limits.slab` to {d}", .{total});
    } else {
        error_module.hint(diagnostic, "raise `Limits.slab`", .{});
    }
}

/// The goal source of a declaration whose value is a call itself, which `build_call` recorded.
fn goal_source(back: *const Back, expr_index: u32) GoalSource {
    const expr = back.checked.exprs[expr_index];
    if (expr.tag != .call or expr.b != 0) return .none;
    return switch (table.op_of(back.checked.calls[expr.a].entry)) {
        .spring, .newtonian, .chase => back.goal,
        else => .none,
    };
}
