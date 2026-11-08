//! Tests of the graph: lanes (`graph.zig`, section 16).
//!
//! They read `graph.zig` and `state.zig` as a client would. The family below has one node of
//! every op that lanes change, so lane i of a thousand built together is checked against lane i
//! built alone, with `lane_first = i`.

const std = @import("std");
const Cues = @import("../cue.zig").Cues;
const event_module = @import("../event.zig");
const Event = event_module.Event;
const motion = @import("../motion.zig");
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const graph_module = @import("../graph.zig");
const testing = std.testing;
const flicks_per_second = time_module.flicks_per_second;
const State = graph_module.State;
const Builder = graph_module.Builder;
const Id = graph_module.Id;
const Node = graph_module.Node;
const Program = graph_module.Program;

/// The cues, goals, and regions the family reads.
const Tables = struct {
    times: [2]Time,
    cues: Cues,
    goal_entries: [2]motion.Goal,
    goals: motion.Goals,
    path: motion.Path,
    region_entries: [2]simulation.Region,
    regions: simulation.Regions,
    span: simulation.Span,

    fn init(tables: *Tables) !void {
        tables.cues = Cues.init(&tables.times);
        const c0 = try tables.cues.add(.{ .flicks = 0 });
        const c1 = try tables.cues.add(.{ .flicks = flicks_per_second });
        tables.goals = motion.Goals.init(&tables.goal_entries);
        tables.path = try tables.goals.add(&.{ .{ .cue = c0, .value = 1 }, .{ .cue = c1, .value = 0.2 } });
        tables.regions = simulation.Regions.init(&tables.region_entries);
        tables.span = try tables.regions.add(&.{ .{ .low = 0, .high = 1 }, .{ .low = 2, .high = 3 } });
    }

    fn options(tables: *const Tables, lane_first: u32) Builder.Options {
        return .{
            .slab_count_max = 1 << 20,
            .cues = &tables.cues,
            .goals = tables.goals.table(),
            .regions = tables.regions.table(),
            .seed = 41,
            .lane_first = lane_first,
        };
    }
};

fn ms(count: i64) Time {
    return .{ .flicks = @divExact(flicks_per_second, 1000) * count };
}

/// Every op that lanes change, in a region of `lanes`.
fn build_family(builder: *Builder, tables: *const Tables, lanes: u32) !void {
    builder.lanes = lanes;
    const index = try builder.lane();
    const noise = try builder.noise(.{ .shape = .smooth, .hz = 1.5, .seed = 9 });
    const wave = try builder.wave(.{ .shape = .sine, .hz = 0.7, .stagger = ms(3) });
    _ = try builder.tween(.{
        .from = 0,
        .to = 1,
        .duration = ms(500),
        .ease = .in_out,
        .start = .{ .index = 0 },
        .previous = null,
        .stagger = ms(2),
    });
    _ = try builder.spring(.{ .from = 0, .goals = tables.path, .time = ms(600), .overshoot = 0.3, .stagger = ms(2) });
    _ = try builder.newtonian(.{ .from = 0, .goals = tables.path, .speed = 2, .accel = 4, .decel = 4, .stagger = ms(1) });
    _ = try builder.bounce(.{ .low = 0, .high = 1, .speed = 0.9, .start = .{ .index = 0 }, .stagger = ms(1) });
    _ = try builder.follow(.{
        .from = 0,
        .regions = tables.span,
        .pick = .random,
        .mover = .{ .spring = .{ .time = ms(300), .overshoot = 0.2 } },
        .tolerance = 0.01,
        .pause_min = ms(0),
        .pause_max = ms(200),
        .seed = 3,
    });
    _ = try builder.shift(.{ .buckets = 8, .period = ms(1000), .low = 0, .high = 1, .odds = 0.5, .shape = .smooth, .seed = 5 });
    const target = try builder.add(try builder.multiply(index, try builder.constant(0.001)), noise);
    const chase = try builder.chase(.{ .target = target, .from = 0, .time = ms(400), .overshoot = 0.2 });
    _ = try builder.crossing(.{ .input = wave, .level = 0.5, .direction = .both });
    const rate = try builder.add(try builder.constant(1), try builder.multiply(index, try builder.constant(0.002)));
    _ = try builder.oscillator(.{ .shape = .sine, .rate = rate });
    const echo = try builder.delay(0);
    try builder.close(echo, chase);
    _ = try builder.spread(try builder.constant(7));
}

/// 50 times over 4 s, off the step grid.
fn time_at(k: usize) Time {
    return .{ .flicks = @as(i64, @intCast(k)) * 56_448_000 + 12_345 };
}

const family_lanes = 1000;
const node_max = 32;

// Locks section 16's promise: lane i of a family of a thousand, built together, equals lane i
// built alone with `lane_first = i`, bit for bit at 50 times, for every node, and the events of
// the family over a second are the events of the thousand programs merged in order.
test "a thousand lanes equal a thousand separate graphs" {
    var tables: Tables = undefined;
    try tables.init();
    var nodes: [node_max]Node = undefined;
    var builder = Builder.init(&nodes, tables.options(0));
    try build_family(&builder, &tables, family_lanes);
    const program = builder.finish();
    const slab = try testing.allocator.alloc(f64, program.slab_count);
    defer testing.allocator.free(slab);
    var state = State.init(program, slab);

    const values = try testing.allocator.alloc(f64, 50 * program.slab_count);
    defer testing.allocator.free(values);
    for (0..50) |k| {
        state.eval(time_at(k));
        @memcpy(values[k * program.slab_count ..][0..program.slab_count], state.slab);
    }
    var family_events: [16_384]Event = undefined;
    const found = state.events(.{ .flicks = 0 }, .{ .flicks = flicks_per_second }, &family_events);
    try testing.expectEqual(@as(u64, 0), found.dropped);
    try testing.expect(found.count > family_lanes);

    var merged = try testing.allocator.alloc(Event, family_events.len);
    defer testing.allocator.free(merged);
    var merged_count: usize = 0;
    var alone_nodes: [node_max]Node = undefined;
    var alone_slab: [256]f64 = undefined;
    for (0..family_lanes) |lane| {
        var alone = Builder.init(&alone_nodes, tables.options(@intCast(lane)));
        try build_family(&alone, &tables, 1);
        const one = alone.finish();
        try testing.expectEqual(program.nodes.len, one.nodes.len);
        var reader = State.init(one, &alone_slab);
        for (0..50) |k| {
            reader.eval(time_at(k));
            const all = values[k * program.slab_count ..][0..program.slab_count];
            for (program.nodes, one.nodes) |node, own| {
                const row = if (node.extent.lanes == 1) 0 else lane;
                try testing.expectEqual(all[node.offset + row], reader.slab[own.offset]);
            }
        }
        var events: [256]Event = undefined;
        const own_found = reader.events(.{ .flicks = 0 }, .{ .flicks = flicks_per_second }, &events);
        try testing.expectEqual(@as(u64, 0), own_found.dropped);
        for (events[0..own_found.count]) |event| try testing.expectEqual(@as(u32, @intCast(lane)), event.instance);
        @memcpy(merged[merged_count..][0..own_found.count], events[0..own_found.count]);
        merged_count += own_found.count;
    }
    std.sort.block(Event, merged[0..merged_count], {}, struct {
        fn less(_: void, a: Event, b: Event) bool {
            return event_module.before(&a, &b);
        }
    }.less);
    try testing.expectEqual(@as(usize, found.count), merged_count);
    try testing.expectEqualSlices(Event, merged[0..merged_count], family_events[0..found.count]);
}

/// A thousand bounces, each a millisecond after the one before, alone in a program.
fn build_bounces(builder: *Builder) !Id {
    builder.lanes = family_lanes;
    return (try builder.bounce(.{ .low = 0, .high = 1, .speed = 0.9, .start = .{ .index = 0 }, .stagger = ms(1) })).position;
}

// Locks section 16's events across lanes: a thousand staggered bounces over [0, 4 s) into
// buffers of 16 and 1,000 keep the first events of the full sorted list, count the rest exactly,
// and three consecutive ranges give the one range's events.
test "events from many lanes stay ordered, with drops counted" {
    var tables: Tables = undefined;
    try tables.init();
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, tables.options(0));
    _ = try build_bounces(&builder);
    const program = builder.finish();
    var slab: [2 * family_lanes]f64 = undefined;
    const end: Time = .{ .flicks = 4 * flicks_per_second };

    var all: [4_096]Event = undefined;
    var state = State.init(program, &slab);
    const full = state.events(.{ .flicks = 0 }, end, &all);
    try testing.expectEqual(@as(u64, 0), full.dropped);
    // A leg lasts 1/0.9 s, so lane g's third hit is at 3.33 s plus g ms: before 4 s for the
    // first 667 lanes, which hit 3 times, and the other 333 twice.
    try testing.expectEqual(@as(u32, 667 * 3 + 333 * 2), full.count);
    for (all[1..full.count], 1..) |*event, at| try testing.expect(!event_module.before(event, &all[at - 1]));

    for ([_]usize{ 16, 1_000 }) |size| {
        var some: [1_000]Event = undefined;
        var reader = State.init(program, &slab);
        const kept = reader.events(.{ .flicks = 0 }, end, some[0..size]);
        try testing.expectEqual(@as(u32, @intCast(size)), kept.count);
        try testing.expectEqual(@as(u64, full.count - size), kept.dropped);
        try testing.expectEqualSlices(Event, all[0..size], some[0..size]);
    }

    var joined: [4_096]Event = undefined;
    var count: usize = 0;
    var reader = State.init(program, &slab);
    const cuts = [_]Time{ .{ .flicks = 0 }, .{ .flicks = flicks_per_second }, .{ .flicks = 5 * flicks_per_second / 2 }, end };
    for (cuts[0..3], cuts[1..]) |t0, t1| {
        const part = reader.events(t0, t1, joined[count..]);
        try testing.expectEqual(@as(u64, 0), part.dropped);
        count += part.count;
    }
    try testing.expectEqualSlices(Event, all[0..full.count], joined[0..count]);
}

// Locks section 16's refusals: a stagger or a `lane` outside a region, two counts above 1 in one
// op, a parameter from a node of many lanes, a delay fed more lanes than it has, a spread of many
// lanes, and a stagger whose last offset overflows.
test "the builder refuses lanes that do not fit together" {
    var tables: Tables = undefined;
    try tables.init();
    var nodes: [16]Node = undefined;
    var builder = Builder.init(&nodes, tables.options(0));
    try testing.expectError(error.LaneMismatch, builder.lane());
    try testing.expectError(error.LaneMismatch, builder.wave(.{ .shape = .sine, .hz = 1, .stagger = ms(1) }));
    builder.lanes = 4;
    const four = try builder.lane();
    builder.lanes = 5;
    const five = try builder.lane();
    try testing.expectError(error.LaneMismatch, builder.add(four, five));
    try testing.expectError(error.LaneMismatch, builder.pack(&.{ four, five }));
    try testing.expectError(error.LaneMismatch, builder.chase(.{ .target = five, .from = 0, .time = ms(100), .overshoot = 0, .time_from = five }));
    try testing.expectError(error.LaneMismatch, builder.spread(five));
    builder.lanes = null;
    const one = try builder.delay(0);
    try testing.expectError(error.LaneMismatch, builder.close(one, five));
    try builder.close(one, try builder.constant(1));
    builder.lanes = 3;
    try testing.expectError(error.InvalidDuration, builder.wave(.{ .shape = .sine, .hz = 1, .stagger = .{ .flicks = std.math.maxInt(i64) / 2 + 1 } }));
    // A one-lane node broadcasts: four lanes plus one is four lanes.
    const sum = try builder.add(four, try builder.constant(1));
    try testing.expectEqual(@as(u32, 4), builder.nodes[sum.index].extent.lanes);
    _ = builder.finish();
}

// Locks the ranges of section 16: a lane's index runs over its family's lanes, from `lane_first`,
// and a spread has its input's range.
test "a lane's index has the range of its family" {
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 64, .lane_first = 10 });
    builder.lanes = 20;
    const index = try builder.lane();
    const seven = try builder.spread(try builder.constant(7));
    const program = builder.finish();
    var ranges: [3]graph_module.Range = undefined;
    program.ranges(&ranges);
    try testing.expectEqual(@as(f64, 10), ranges[index.index].low);
    try testing.expectEqual(@as(f64, 29), ranges[index.index].high);
    try testing.expectEqual(@as(f64, 7), ranges[seven.index].low);
    var slab: [64]f64 = undefined;
    var state = State.init(program, &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 29), state.values(index)[19]);
    try testing.expectEqualSlices(f64, &@as([20]f64, @splat(7)), state.values(seven));
    try testing.expectEqual(@as(u32, 20), state.extent(seven).lanes);
}
