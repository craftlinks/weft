//! Events: what happened in a range of time, each at an exact flick, kept in a caller's buffer.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. A Second Kind of Output
//! `State.eval` gives values at a moment. `State.events` gives everything that happened in a
//! half-open range `[t0, t1)`: a bounce hitting a wall, a crossing of a level, a goal reached, a
//! bucket entered, a cue. `graph.zig`, section 11, explains where each comes from. This file holds
//! the event itself and the one structure that collects them: a bounded, sorted insert.
//!
//! ## 2. One Total Order
//! Events are ordered by time, then by the index of the node that fired them, then by lane. The
//! sources give their own events in time order, and two events with the same key can only come
//! from one source at one time, such as two cues at one flick, which the source gives in cue
//! order. The insert is stable, so it keeps that order too. So two queries of the same range give
//! the same bytes, and splitting a range gives the same events in the same order.
//!
//! ## 3. Overflow
//! The caller's buffer bounds the memory. When it is full, an event that sorts before the last one
//! kept evicts it, and an event after it is only counted. So the buffer always holds the earliest
//! events of the range, in order, and `dropped` counts the rest exactly. Nothing is written past
//! the buffer, and nothing kept is reordered.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation and no locks. An insert moves at most `out.len` events.
//! - `out[0..count]` is sorted before and after every insert.

const std = @import("std");
const assert = std.debug.assert;
const Id = @import("graph.zig").Id;
const Time = @import("time.zig").Time;

pub const Event = struct {
    time: Time,
    /// The node that fired it.
    source: Id,
    /// The lane. Sources that set one value across the lanes fire on lane 0 only, until step 17
    /// gives lanes their own seeds.
    instance: u32,
    /// What the source's events carry, by op:
    /// - `bounce` position: the velocity just before the hit, `+speed` at `high`, `-speed` at
    ///   `low`.
    /// - `crossing`: the slope over the step of the crossing, in units per second, whose sign is
    ///   the direction.
    /// - `cues`: the index of the cue in its table.
    /// - a spring or a Newtonian move, and `follow`: the goal reached.
    /// - `shift`: the value of the bucket entered.
    value: f64,
};

comptime {
    assert(@sizeOf(Event) == 24);
    assert(@alignOf(Event) == @alignOf(i64));
}

pub const Events = struct {
    /// Events written to the front of `out`, in order.
    count: u32,
    /// Events in the range that did not fit. Exact, never an estimate.
    dropped: u64,
};

/// Whether `a` comes before `b` in the order of section 2. Equal keys are not before each other.
pub fn before(a: *const Event, b: *const Event) bool {
    if (a.time.flicks != b.time.flicks) return a.time.flicks < b.time.flicks;
    if (a.source.index != b.source.index) return a.source.index < b.source.index;
    return a.instance < b.instance;
}

/// Collects events into a caller's buffer, as section 3 explains.
pub const Collector = struct {
    out: []Event,
    count: u32,
    dropped: u64,

    pub fn init(out: []Event) Collector {
        assert(out.len <= std.math.maxInt(u32));
        return .{ .out = out, .count = 0, .dropped = 0 };
    }

    /// Whether `event` would only be counted: the buffer is full and it sorts after the last event
    /// kept, as would every later event of its source. A source can then count the rest of its
    /// events in a range without forming them.
    pub fn counts_only(collector: *const Collector, event: *const Event) bool {
        assert(collector.count <= collector.out.len);
        if (collector.count < collector.out.len) return false;
        if (collector.count == 0) return true;
        return !before(event, &collector.out[collector.count - 1]);
    }

    /// Counts `count` events that sort after the last one kept, without forming them.
    pub fn count_dropped(collector: *Collector, count: u64) void {
        assert(collector.count == collector.out.len);
        collector.dropped += count;
    }

    /// Keeps `event` in order if it is among the earliest `out.len` so far, and counts what falls
    /// out, as section 3 explains.
    pub fn add(collector: *Collector, event: Event) void {
        assert(collector.count <= collector.out.len);
        assert(std.math.isFinite(event.value));
        if (collector.counts_only(&event)) {
            collector.dropped += 1;
            return;
        }
        if (collector.count == collector.out.len) {
            // The last event kept sorts after this one, so it is the one to evict.
            collector.count -= 1;
            collector.dropped += 1;
        }
        // Stable: past every kept event that does not sort after this one.
        var index: u32 = collector.count;
        while (index > 0) : (index -= 1) {
            if (!before(&event, &collector.out[index - 1])) break;
            collector.out[index] = collector.out[index - 1];
        }
        collector.out[index] = event;
        collector.count += 1;
        assert(collector.count <= collector.out.len);
        if (index > 0) assert(!before(&event, &collector.out[index - 1]));
    }

    pub fn result(collector: *const Collector) Events {
        assert(collector.count <= collector.out.len);
        if (collector.count > 1) {
            for (collector.out[1..collector.count], 1..) |*event, index| {
                assert(!before(event, &collector.out[index - 1]));
            }
        }
        return .{ .count = collector.count, .dropped = collector.dropped };
    }
};

const testing = std.testing;

fn event_at(flicks: i64, source: u32, instance: u32, value: f64) Event {
    return .{
        .time = .{ .flicks = flicks },
        .source = .{ .index = source },
        .instance = instance,
        .value = value,
    };
}

// Locks the order of section 2: time first, then source, then lane, and that equal keys keep the
// order they came in, which the values tell apart.
test "events sort by time, source, and lane, and equal keys keep their order" {
    var out: [6]Event = undefined;
    var collector = Collector.init(&out);
    collector.add(event_at(5, 1, 0, 1));
    collector.add(event_at(5, 0, 2, 2));
    collector.add(event_at(5, 0, 1, 3));
    collector.add(event_at(2, 9, 0, 4));
    collector.add(event_at(5, 0, 1, 5));
    collector.add(event_at(9, 0, 0, 6));
    const events = collector.result();
    try testing.expectEqual(Events{ .count = 6, .dropped = 0 }, events);
    const values = [_]f64{ 4, 3, 5, 2, 1, 6 };
    for (out, values) |event, value| try testing.expectEqual(value, event.value);
}

// Locks section 3: a buffer of 2 given 5 events out of order keeps the earliest 2, in order, and
// counts 3; an empty buffer counts everything; and nothing past the buffer is written.
test "overflow keeps the earliest events and counts the rest" {
    var memory: [3]Event = undefined;
    const canary = event_at(-1, 77, 77, 77);
    memory[2] = canary;
    var collector = Collector.init(memory[0..2]);
    for ([_]i64{ 30, 10, 40, 20, 50 }) |flicks| collector.add(event_at(flicks, 0, 0, 0));
    try testing.expectEqual(Events{ .count = 2, .dropped = 3 }, collector.result());
    try testing.expectEqual(@as(i64, 10), memory[0].time.flicks);
    try testing.expectEqual(@as(i64, 20), memory[1].time.flicks);
    try testing.expectEqual(canary, memory[2]);
    try testing.expect(collector.counts_only(&event_at(20, 0, 0, 0)));
    try testing.expect(!collector.counts_only(&event_at(19, 0, 0, 0)));

    var none = Collector.init(memory[0..0]);
    for (0..4) |_| none.add(event_at(1, 0, 0, 0));
    none.count_dropped(6);
    try testing.expectEqual(Events{ .count = 0, .dropped = 10 }, none.result());
    try testing.expectEqual(canary, memory[2]);
}
