//! Cues: a sorted, bounded table of times that other things attach to.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What a Cue Is
//! A cue is a time with an identity. A client decides what it means, such as a beat of narration.
//! Whatever refers to a cue refers to the time it holds now, so moving one cue moves everything
//! attached to it. Names belong to the client, as they do for graph nodes: a `Cue` is an index.
//!
//! ## 2. Why the Table Stays in Order
//! The table is one array of times, always sorted, and a cue's id is its position. A cue can be
//! added only at the end, and a move that would pass a neighbour is refused. Equal times are fine.
//!
//! This one rule pays three times. Lookup by id is an array read, on a reader's hot path. Sorted
//! order needs no second array, so a search for the cues in a range is a binary search. And
//! anything kept in cue order stays in time order after a move, so a table of goals never needs
//! sorting again. A client that wants to reorder cues has changed the score, not moved a cue, and
//! builds a new table.
//!
//! ## 3. Moving and Readers
//! A `Program` sees the table as a slice, so a move reaches its readers at their next eval with no
//! rebuild. The table is the one thing a program reads that can change. A move must not overlap an
//! eval: a reader on another thread takes its own copy of the table, as it would of the nodes.
//!
//! ## 4. TigerStyle Invariants
//! - The caller owns the memory, and the table holds no pointers.
//! - `times[0..count]` is sorted before and after every call, and a refused call changes nothing.

const std = @import("std");
const assert = std.debug.assert;
const Time = @import("time.zig").Time;

/// A cue, as its position in the table.
pub const Cue = struct {
    index: u32,
};

pub const Cues = struct {
    times: []Time,
    count: u32,

    pub const Error = error{
        /// The array the caller gave `init` is full.
        CueCapacityExceeded,
        /// The time would put the cue before an earlier cue or after a later one.
        CueOutOfOrder,
        /// An id that no cue in this table has.
        UnknownCue,
    };

    pub fn init(times: []Time) Cues {
        assert(times.len <= std.math.maxInt(u32));
        return .{ .times = times, .count = 0 };
    }

    /// A new cue at `time`, which must not be before the last cue.
    pub fn add(cues: *Cues, time: Time) Error!Cue {
        assert(cues.count <= cues.times.len);
        if (cues.count == cues.times.len) return error.CueCapacityExceeded;
        if (cues.count > 0) {
            if (time.flicks < cues.times[cues.count - 1].flicks) return error.CueOutOfOrder;
        }
        const cue: Cue = .{ .index = cues.count };
        cues.times[cue.index] = time;
        cues.count += 1;
        cues.assert_sorted();
        return cue;
    }

    /// Moves a cue to `time`, which may equal a neighbour's but not pass it.
    pub fn move(cues: *Cues, cue: Cue, time: Time) Error!void {
        cues.assert_sorted();
        if (cue.index >= cues.count) return error.UnknownCue;
        if (cue.index > 0) {
            if (time.flicks < cues.times[cue.index - 1].flicks) return error.CueOutOfOrder;
        }
        if (cue.index + 1 < cues.count) {
            if (time.flicks > cues.times[cue.index + 1].flicks) return error.CueOutOfOrder;
        }
        cues.times[cue.index] = time;
        cues.assert_sorted();
    }

    /// The time of a cue.
    pub fn at(cues: *const Cues, cue: Cue) Time {
        assert(cue.index < cues.count);
        return cues.times[cue.index];
    }

    /// The cues so far, in order. A `Program` reads this slice, so it sees later moves.
    pub fn table(cues: *const Cues) []const Time {
        cues.assert_sorted();
        return cues.times[0..cues.count];
    }

    fn assert_sorted(cues: *const Cues) void {
        assert(cues.count <= cues.times.len);
        if (cues.count == 0) return;
        for (cues.times[0 .. cues.count - 1], cues.times[1..cues.count]) |earlier, later| {
            assert(earlier.flicks <= later.flicks);
        }
    }
};

const testing = std.testing;

// Locks that cues are added in order, ids are positions, and two cues can share a time.
test "cues are added in order and looked up by id" {
    var times: [3]Time = undefined;
    var cues = Cues.init(&times);
    const first = try cues.add(.{ .flicks = 100 });
    const second = try cues.add(.{ .flicks = 200 });
    const same = try cues.add(.{ .flicks = 200 });
    try testing.expectEqual(@as(u32, 0), first.index);
    try testing.expectEqual(@as(u32, 2), same.index);
    try testing.expectEqual(@as(i64, 200), cues.at(second).flicks);
    try testing.expectEqual(@as(usize, 3), cues.table().len);
}

// Locks both refusals of `add` by name, and that a refused cue leaves the table as it was.
test "adding refuses a full table and a time out of order" {
    var times: [2]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 100 });
    try testing.expectError(error.CueOutOfOrder, cues.add(.{ .flicks = 99 }));
    try testing.expectEqual(@as(u32, 1), cues.count);
    _ = try cues.add(.{ .flicks = 100 });
    try testing.expectError(error.CueCapacityExceeded, cues.add(.{ .flicks = 300 }));
    try testing.expectEqual(@as(u32, 2), cues.count);
}

// Locks the edges of a move among cues at 100, 200, and 300: the middle cue can reach exactly 100
// or 300 but not 99 or 301, a refused move changes nothing, and the end cues are only bounded on
// their inner side.
test "a move can reach a neighbour but not pass it" {
    var times: [3]Time = undefined;
    var cues = Cues.init(&times);
    const first = try cues.add(.{ .flicks = 100 });
    const middle = try cues.add(.{ .flicks = 200 });
    const last = try cues.add(.{ .flicks = 300 });

    try cues.move(middle, .{ .flicks = 100 });
    try cues.move(middle, .{ .flicks = 300 });
    try testing.expectEqual(@as(i64, 300), cues.at(middle).flicks);
    try cues.move(middle, .{ .flicks = 200 });

    try testing.expectError(error.CueOutOfOrder, cues.move(middle, .{ .flicks = 99 }));
    try testing.expectError(error.CueOutOfOrder, cues.move(middle, .{ .flicks = 301 }));
    try testing.expectEqual(@as(i64, 200), cues.at(middle).flicks);

    try cues.move(first, .{ .flicks = std.math.minInt(i64) });
    try cues.move(last, .{ .flicks = std.math.maxInt(i64) });
    try testing.expectError(error.CueOutOfOrder, cues.move(first, .{ .flicks = 201 }));
    try testing.expectError(error.CueOutOfOrder, cues.move(last, .{ .flicks = 199 }));
}

// Locks that an id past the table is refused, including the id of a slot not yet filled.
test "a move refuses an unknown cue" {
    var times: [2]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 100 });
    try testing.expectError(error.UnknownCue, cues.move(.{ .index = 1 }, .{ .flicks = 200 }));
    try testing.expectError(error.UnknownCue, cues.move(.{ .index = 9 }, .{ .flicks = 200 }));
}

// Locks that a table with one cue moves freely, and an empty table reads as empty.
test "a lone cue has no neighbours" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    try testing.expectEqual(@as(usize, 0), cues.table().len);
    const only = try cues.add(.{ .flicks = 5 });
    try cues.move(only, .{ .flicks = -5 });
    try testing.expectEqual(@as(i64, -5), cues.at(only).flicks);
}
