//! Tracks: timed values a client writes while a program runs, which a program reads as signals.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What a Track Is For
//! A knob that applies from now on is a value that changes at the times it was turned. A track
//! holds those changes: a bounded run of samples in time order, each value held forward until the
//! next, and `initial` before the first. A `track` node reads it at the pass's time, so a program
//! that reads tracks is still a function of t: it can be read at any time, in any order, and the
//! past shows what was played. The client owns the table and writes it between reads, as it owns
//! and moves the cue table.
//!
//! ## 2. The Latch
//! `write(track, t, v)` removes every sample at or after t and appends `(t, v)`, so v holds from t
//! on, until a later write. Writing again at an earlier time replaces what was played after it, as
//! a latch automation lane does. A value is clamped into the track's `[low, high]`, so its declared
//! range is never left. A write that changes nothing (the same bits as the value held at t, and no
//! sample after t) is not a write: it keeps the generation, so a held knob costs no reader
//! anything.
//!
//! ## 3. The Floor
//! A write changes the track's values only at and after its time. A reader keeps checkpoints of a
//! simulation whose passes read tracks, and must drop exactly the checkpoints that read a changed
//! value. So the table counts writes in `generation` and keeps the time of each of the last
//! `log_len` in a ring. A reader that last saw generation g asks `floor_since(g)`: the earliest
//! time written since g, or null when the ring no longer reaches back to g, which means drop
//! everything.
//!
//! ## 4. A Preview Undone
//! A client may let a control write a track as a preview, then take the writes back: Play's text
//! knob writes from now on while it is dragged, and on release rewrites the track's declaration
//! instead (step 15). `restore` puts back the samples the client saved before the preview, and
//! logs the preview's start as one write's time, since every change the preview made is at or
//! after it: a reader drops what it worked out from that time on, and nothing before.
//!
//! ## 5. TigerStyle Invariants
//! - The caller owns every sample array; a refused write or add changes nothing.
//! - Samples are in time order, finite, and inside their track's bounds.
//! - `value` is a binary search: at most 33 rounds over a track's samples.

const std = @import("std");
const assert = std.debug.assert;
const Sample = @import("recording.zig").Sample;
const Time = @import("time.zig").Time;

/// Writes whose times the table remembers (section 3).
pub const log_len = 64;

pub const Track = struct {
    samples: []Sample,
    count: u32,
    low: f64,
    high: f64,
    /// The value before the first sample, in `[low, high]`.
    initial: f64,

    /// The samples so far, in time order.
    pub fn table(track: *const Track) []const Sample {
        assert(track.count <= track.samples.len);
        return track.samples[0..track.count];
    }

    /// The value at `time`: the last sample at or before it, or `initial` (section 1).
    pub fn value(track: *const Track, time: Time) f64 {
        const index = samples_at_or_before(track.table(), time);
        if (index == 0) return track.initial;
        return track.samples[index - 1].value;
    }
};

/// A track, as its position in the table.
pub const TrackId = struct {
    index: u32,
};

pub const Tracks = struct {
    entries: []Track,
    count: u32,
    /// Writes since `init` (section 3).
    generation: u64,
    /// The time of write number g at `log[g % log_len]`.
    log: [log_len]Time,

    /// A table with no tracks, for a program that reads none.
    pub const empty: Tracks = .{
        .entries = &.{},
        .count = 0,
        .generation = 0,
        .log = @splat(.{ .flicks = 0 }),
    };

    pub const Error = error{
        /// The array the caller gave `init` is full.
        TrackCapacityExceeded,
        /// A track whose low is above its high, or whose initial value is outside them.
        InvalidRange,
        /// An end, an initial value, or a written value that is infinite or NaN.
        NotFinite,
        /// A track with no room for a sample.
        NoSamples,
        /// An id that no track in this table has.
        UnknownTrack,
        /// A write that needs one more sample than the track holds. Nothing changes.
        TrackFull,
    };

    pub fn init(entries: []Track) Tracks {
        assert(entries.len <= std.math.maxInt(u32));
        var tracks = empty;
        tracks.entries = entries;
        return tracks;
    }

    /// A new track over `samples`, empty, holding `initial` until its first write.
    pub fn add(
        tracks: *Tracks,
        samples: []Sample,
        low: f64,
        high: f64,
        initial: f64,
    ) Error!TrackId {
        assert(tracks.count <= tracks.entries.len);
        if (tracks.count == tracks.entries.len) return error.TrackCapacityExceeded;
        for ([_]f64{ low, high, initial }) |end| {
            if (!std.math.isFinite(end)) return error.NotFinite;
        }
        if (low > high) return error.InvalidRange;
        if (initial < low or initial > high) return error.InvalidRange;
        if (samples.len == 0) return error.NoSamples;
        assert(samples.len <= std.math.maxInt(u32));
        const id: TrackId = .{ .index = tracks.count };
        tracks.entries[id.index] = .{
            .samples = samples,
            .count = 0,
            .low = low,
            .high = high,
            .initial = initial,
        };
        tracks.count += 1;
        return id;
    }

    /// The track `id`, which must exist.
    pub fn at(tracks: *const Tracks, id: TrackId) *const Track {
        assert(id.index < tracks.count);
        return &tracks.entries[id.index];
    }

    pub fn value(tracks: *const Tracks, id: TrackId, time: Time) f64 {
        return tracks.at(id).value(time);
    }

    /// Latches `value`, clamped into the track's bounds, from `time` on (section 2).
    pub fn write(tracks: *Tracks, id: TrackId, time: Time, value_written: f64) Error!void {
        if (id.index >= tracks.count) return error.UnknownTrack;
        if (!std.math.isFinite(value_written)) return error.NotFinite;
        const track = &tracks.entries[id.index];
        const clamped = std.math.clamp(value_written, track.low, track.high);
        const kept = samples_before(track.table(), time);
        if (writes_nothing(track, kept, time, clamped)) return;
        if (kept == track.samples.len) return error.TrackFull;
        track.samples[kept] = .{ .time = time, .value = clamped };
        track.count = kept + 1;
        tracks.generation += 1;
        tracks.log[@intCast(tracks.generation % log_len)] = time;
        assert(track.value(time) == clamped);
    }

    /// Puts back `samples`, which the client saved from this track's `table()`, as the track's
    /// writes (section 4). Every change since they were saved is at or after `since`. Restoring
    /// what the track already holds is not a write, so it keeps the generation.
    pub fn restore(tracks: *Tracks, id: TrackId, samples: []const Sample, since: Time) Error!void {
        if (id.index >= tracks.count) return error.UnknownTrack;
        const track = &tracks.entries[id.index];
        if (samples.len > track.samples.len) return error.TrackFull;
        for (samples, 0..) |sample, index| {
            assert(std.math.isFinite(sample.value));
            assert(sample.value >= track.low and sample.value <= track.high);
            if (index > 0) assert(samples[index - 1].time.flicks < sample.time.flicks);
        }
        const same = samples.len == track.count and for (samples, track.table()) |a, b| {
            if (a.time.flicks != b.time.flicks or @as(u64, @bitCast(a.value)) != @as(u64, @bitCast(b.value))) break false;
        } else true;
        if (same) return;
        @memcpy(track.samples[0..samples.len], samples);
        track.count = @intCast(samples.len);
        tracks.generation += 1;
        tracks.log[@intCast(tracks.generation % log_len)] = since;
        assert(track.table().len == samples.len);
    }

    /// The earliest time written since generation `seen`, or null if the log no longer reaches
    /// back to it (section 3). `seen` is below the current generation.
    pub fn floor_since(tracks: *const Tracks, seen: u64) ?Time {
        assert(seen < tracks.generation);
        if (tracks.generation - seen > log_len) return null;
        var floor: Time = .{ .flicks = std.math.maxInt(i64) };
        var write_index = seen + 1;
        while (write_index <= tracks.generation) : (write_index += 1) {
            const written = tracks.log[@intCast(write_index % log_len)];
            if (written.flicks < floor.flicks) floor = written;
        }
        return floor;
    }
};

/// Whether latching `value` at `time`, keeping the first `kept` samples, leaves the track's
/// values as they are: nothing after it and the value already held, or its own sample again.
fn writes_nothing(track: *const Track, kept: u32, time: Time, value: f64) bool {
    const bits: u64 = @bitCast(value);
    if (kept == track.count) {
        const held = if (kept == 0) track.initial else track.samples[kept - 1].value;
        return @as(u64, @bitCast(held)) == bits;
    }
    if (kept + 1 != track.count) return false;
    const last = track.samples[kept];
    return last.time.flicks == time.flicks and @as(u64, @bitCast(last.value)) == bits;
}

/// How many of the sorted `samples` are at or before `time`.
fn samples_at_or_before(samples: []const Sample, time: Time) u32 {
    return search(samples, time, .inclusive);
}

/// How many of the sorted `samples` are before `time`.
fn samples_before(samples: []const Sample, time: Time) u32 {
    return search(samples, time, .exclusive);
}

fn search(samples: []const Sample, time: Time, bound: enum { exclusive, inclusive }) u32 {
    assert(samples.len <= std.math.maxInt(u32));
    var low: u32 = 0;
    var high: u32 = @intCast(samples.len);
    // Halving a u32 range ends within 33 rounds.
    for (0..33) |_| {
        if (low == high) break;
        const middle = low + (high - low) / 2;
        const counted = switch (bound) {
            .exclusive => samples[middle].time.flicks < time.flicks,
            .inclusive => samples[middle].time.flicks <= time.flicks,
        };
        if (counted) low = middle + 1 else high = middle;
    } else unreachable;
    return low;
}

const testing = std.testing;

fn at(flicks: i64) Time {
    return .{ .flicks = flicks };
}

// Locks the latch: values hold forward from each write, a write removes the samples at and after
// its time, a write at the same time replaces, values are clamped, and a full track refuses and
// keeps what it had.
test "a write latches its value from its time on" {
    var entries: [1]Track = undefined;
    var samples: [3]Sample = undefined;
    var tracks = Tracks.init(&entries);
    const id = try tracks.add(&samples, 0, 1, 0.5);
    try testing.expectEqual(@as(f64, 0.5), tracks.value(id, at(100)));
    try tracks.write(id, at(10), 0.25);
    try tracks.write(id, at(20), 0.75);
    try tracks.write(id, at(30), 2);
    try testing.expectEqual(@as(f64, 0.5), tracks.value(id, at(9)));
    try testing.expectEqual(@as(f64, 0.25), tracks.value(id, at(10)));
    try testing.expectEqual(@as(f64, 0.75), tracks.value(id, at(29)));
    try testing.expectEqual(@as(f64, 1), tracks.value(id, at(30)));
    try testing.expectError(error.TrackFull, tracks.write(id, at(40), 0));
    try testing.expectEqual(@as(u32, 3), tracks.at(id).count);
    try tracks.write(id, at(15), 0.125);
    try testing.expectEqual(@as(u32, 2), tracks.at(id).count);
    try testing.expectEqual(@as(f64, 0.125), tracks.value(id, at(100)));
    try tracks.write(id, at(15), 0.375);
    try testing.expectEqual(@as(u32, 2), tracks.at(id).count);
    try testing.expectEqual(@as(f64, 0.375), tracks.value(id, at(15)));
    try testing.expectError(error.NotFinite, tracks.write(id, at(15), std.math.nan(f64)));
    try testing.expectError(error.UnknownTrack, tracks.write(.{ .index = 1 }, at(1), 0));
}

// Locks the floor: the earliest write since a generation, a write that changes nothing (its own
// sample again, or the value already held with nothing after) is not counted, and a reader behind
// by more than the log learns nothing, so it drops everything.
test "the floor is the earliest write since a generation" {
    var entries: [1]Track = undefined;
    var samples: [128]Sample = undefined;
    var tracks = Tracks.init(&entries);
    const id = try tracks.add(&samples, 0, 1, 0);
    try tracks.write(id, at(50), 1);
    try tracks.write(id, at(20), 1);
    try tracks.write(id, at(70), 0);
    try testing.expectEqual(@as(u64, 3), tracks.generation);
    try testing.expectEqual(at(20), tracks.floor_since(0).?);
    try testing.expectEqual(at(20), tracks.floor_since(1).?);
    try testing.expectEqual(at(70), tracks.floor_since(2).?);
    try tracks.write(id, at(70), 0);
    try testing.expectEqual(@as(u64, 3), tracks.generation);
    for (0..log_len) |index| {
        try tracks.write(id, at(@intCast(80 + index)), @floatFromInt((index + 1) % 2));
    }
    try testing.expectEqual(@as(?Time, null), tracks.floor_since(2));
    try testing.expectEqual(at(80), tracks.floor_since(3).?);
}

// Locks the refusals of `add`, by name.
test "a track is refused by name" {
    var entries: [1]Track = undefined;
    var samples: [1]Sample = undefined;
    var tracks = Tracks.init(&entries);
    try testing.expectError(error.InvalidRange, tracks.add(&samples, 1, 0, 0));
    try testing.expectError(error.InvalidRange, tracks.add(&samples, 0, 1, 2));
    try testing.expectError(error.NotFinite, tracks.add(&samples, 0, std.math.inf(f64), 0));
    try testing.expectError(error.NoSamples, tracks.add(samples[0..0], 0, 1, 0));
    _ = try tracks.add(&samples, 0, 1, 0);
    try testing.expectError(error.TrackCapacityExceeded, tracks.add(&samples, 0, 1, 0));
}

// Locks section 4: a preview's writes, one of which latched over a later sample, are taken back
// whole, the floor is the preview's start, and restoring what is there already is no write.
test "a preview is taken back by restoring the samples saved before it" {
    var entries: [1]Track = undefined;
    var samples: [8]Sample = undefined;
    var tracks = Tracks.init(&entries);
    const id = try tracks.add(&samples, 0, 2, 0.5);
    try tracks.write(id, .{ .flicks = 100 }, 1);
    try tracks.write(id, .{ .flicks = 300 }, 1.5);
    var saved: [8]Sample = undefined;
    const kept = tracks.at(id).table();
    @memcpy(saved[0..kept.len], kept);
    const saved_count = kept.len;
    const before = tracks.generation;
    try tracks.write(id, .{ .flicks = 200 }, 0.25);
    try tracks.write(id, .{ .flicks = 250 }, 0.75);
    try testing.expectEqual(@as(f64, 0.75), tracks.value(id, .{ .flicks = 400 }));
    try tracks.restore(id, saved[0..saved_count], .{ .flicks = 200 });
    try testing.expectEqual(@as(f64, 1.5), tracks.value(id, .{ .flicks = 400 }));
    try testing.expectEqual(@as(f64, 1), tracks.value(id, .{ .flicks = 250 }));
    try testing.expectEqual(Time{ .flicks = 200 }, tracks.floor_since(before).?);
    const restored = tracks.generation;
    try tracks.restore(id, saved[0..saved_count], .{ .flicks = 200 });
    try testing.expectEqual(restored, tracks.generation);
}
