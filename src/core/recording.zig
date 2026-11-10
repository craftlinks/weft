//! Recordings: live input written down as it is read, and played back as a seekable signal.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Record Passes, Not Calls
//! A live input has no past: every pass reads whatever the client set last. A reader that sets the
//! input once per read cannot reproduce its run from those calls alone, because the steps a read
//! runs before its own time read the input too. So a `State` records what its passes read: each
//! committed pass that reads an attached input appends its time and the value, when the value
//! changed. Playback holds each value forward from its time, which is exactly what the live passes
//! read, so a recorded program read at the same times gives the same values, bit for bit, and it
//! can be read at any time, in any order.
//!
//! ## 2. Only Forward
//! A recording is in time order. A pass at a time before the latest pass noted, which only a
//! backward read makes, is not appended: it is counted in `dropped`, and the recording is
//! incomplete from then on. A full recording counts too. Neither ever corrupts what was kept.
//! One backward pass is no loss: one that reads the very value the recording already plays at
//! its time, because the last sample kept is at or before it and holds the same bits. A reader
//! that replays the step its slab has just passed, as a track write at the time just read makes
//! it, reads that, so its recording stays complete while the input holds still.
//!
//! ## 3. Samples in a Program
//! A program reads recordings from a `Samples` table, as it reads goals and regions, and a
//! `recorded` node refers to a `Clip` of it. Two samples may share a time, when a read is repeated
//! at one time with a new value; playback takes the later one.
//!
//! ## 4. TigerStyle Invariants
//! - The caller owns the memory, and a refused or dropped sample changes nothing kept.
//! - Every table is in time order, and holds only finite values.

const std = @import("std");
const assert = std.debug.assert;
const Time = @import("time.zig").Time;

/// A value read at a time.
pub const Sample = struct {
    time: Time,
    value: f64,
};

/// A run of samples in a `Samples` table.
pub const Clip = struct {
    first: u32,
    count: u32,
};

/// A bounded table of samples that `recorded` nodes refer to by `Clip`.
pub const Samples = struct {
    entries: []Sample,
    count: u32,

    pub const Error = error{
        /// The array the caller gave `init` is full.
        SampleCapacityExceeded,
        /// A clip with no samples.
        NoSamples,
        /// A sample before the sample before it.
        SampleOutOfOrder,
        /// A value that is infinite or NaN.
        NotFinite,
    };

    pub fn init(entries: []Sample) Samples {
        assert(entries.len <= std.math.maxInt(u32));
        return .{ .entries = entries, .count = 0 };
    }

    /// Copies `run` to the end of the table, as one clip.
    pub fn add(samples: *Samples, run: []const Sample) Error!Clip {
        assert(samples.count <= samples.entries.len);
        if (run.len == 0) return error.NoSamples;
        if (run.len > samples.entries.len - samples.count) return error.SampleCapacityExceeded;
        for (run, 0..) |sample, index| {
            if (!std.math.isFinite(sample.value)) return error.NotFinite;
            if (index > 0 and sample.time.flicks < run[index - 1].time.flicks) {
                return error.SampleOutOfOrder;
            }
        }
        const clip: Clip = .{ .first = samples.count, .count = @intCast(run.len) };
        @memcpy(samples.entries[clip.first..][0..clip.count], run);
        samples.count += clip.count;
        return clip;
    }

    /// The samples so far.
    pub fn table(samples: *const Samples) []const Sample {
        assert(samples.count <= samples.entries.len);
        return samples.entries[0..samples.count];
    }
};

/// What a `State` writes as it reads one input, as section 1 explains.
pub const Recording = struct {
    entries: []Sample,
    count: u32,
    /// Passes not written: backward, or past the end of `entries`.
    dropped: u64,
    /// The time of the latest pass noted, which a sample only keeps when the value changed.
    latest: ?Time,

    pub fn init(entries: []Sample) Recording {
        assert(entries.len <= std.math.maxInt(u32));
        return .{ .entries = entries, .count = 0, .dropped = 0, .latest = null };
    }

    /// Whether every pass since `init` is in the table.
    pub fn complete(recording: *const Recording) bool {
        return recording.dropped == 0;
    }

    /// Notes that a pass at `time` read `value`: appended when it changed, or as the first sample.
    pub fn add(recording: *Recording, time: Time, value: f64) void {
        assert(recording.count <= recording.entries.len);
        assert(std.math.isFinite(value));
        if (recording.latest) |latest| {
            if (time.flicks < latest.flicks) {
                // No loss when playback already gives this value at this time (section 2).
                if (recording.count > 0) {
                    const last = recording.entries[recording.count - 1];
                    const same = @as(u64, @bitCast(last.value)) == @as(u64, @bitCast(value));
                    if (last.time.flicks <= time.flicks and same) return;
                }
                recording.dropped += 1;
                return;
            }
        }
        recording.latest = time;
        if (recording.count > 0) {
            const last = recording.entries[recording.count - 1];
            assert(last.time.flicks <= time.flicks);
            // Bit equality, so a change of sign of a zero is kept too.
            const same: u64 = @bitCast(last.value);
            if (same == @as(u64, @bitCast(value))) return;
        }
        if (recording.count == recording.entries.len) {
            recording.dropped += 1;
            return;
        }
        recording.entries[recording.count] = .{ .time = time, .value = value };
        recording.count += 1;
    }

    /// The samples so far, in time order, ready for `Samples.add`.
    pub fn table(recording: *const Recording) []const Sample {
        assert(recording.count <= recording.entries.len);
        return recording.entries[0..recording.count];
    }
};

/// The value a clip plays at `time`: its last sample at or before it, the later one of two at one
/// time, or before the first sample, the first sample's value.
pub fn play(samples: []const Sample, time: Time) f64 {
    assert(samples.len > 0);
    assert(samples.len <= std.math.maxInt(u32));
    var low: u32 = 0;
    var high: u32 = @intCast(samples.len);
    // Halving a u32 range ends within 33 rounds.
    for (0..33) |_| {
        if (low == high) break;
        const middle = low + (high - low) / 2;
        if (samples[middle].time.flicks <= time.flicks) low = middle + 1 else high = middle;
    } else unreachable;
    if (low == 0) return samples[0].value;
    assert(samples[low - 1].time.flicks <= time.flicks);
    return samples[low - 1].value;
}

const testing = std.testing;

fn at(seconds: i64) Time {
    return .{ .flicks = seconds * @import("time.zig").flicks_per_second };
}

// Locks the table's refusals by name, and that a refused clip leaves the table as it was.
test "the sample table refuses a clip it cannot hold" {
    var entries: [3]Sample = undefined;
    var samples = Samples.init(&entries);
    try testing.expectError(error.NoSamples, samples.add(&.{}));
    const nan = std.math.nan(f64);
    try testing.expectError(error.NotFinite, samples.add(&.{.{ .time = at(0), .value = nan }}));
    try testing.expectError(error.SampleOutOfOrder, samples.add(&.{
        .{ .time = at(1), .value = 0 }, .{ .time = at(0), .value = 0 },
    }));
    const clip = try samples.add(&.{
        .{ .time = at(0), .value = 1 },
        .{ .time = at(0), .value = 2 },
    });
    try testing.expectEqual(Clip{ .first = 0, .count = 2 }, clip);
    try testing.expectError(error.SampleCapacityExceeded, samples.add(&.{
        .{ .time = at(2), .value = 0 }, .{ .time = at(3), .value = 0 },
    }));
    try testing.expectEqual(@as(usize, 2), samples.table().len);
}

// Locks that a recording keeps changes only, counts a backward pass and a full table without
// touching what it kept, and that playback holds forward and takes the later of two at one time.
test "a recording keeps changes in order and plays them held forward" {
    var entries: [3]Sample = undefined;
    var recording = Recording.init(&entries);
    recording.add(at(1), 0.5);
    recording.add(at(2), 0.5);
    recording.add(at(3), -0.25);
    try testing.expect(recording.complete());
    try testing.expectEqual(@as(usize, 2), recording.table().len);
    recording.add(at(2), 0.75);
    try testing.expectEqual(@as(u64, 1), recording.dropped);
    try testing.expect(!recording.complete());
    recording.add(at(3), 0.125);
    recording.add(at(4), 1);
    try testing.expectEqual(@as(u64, 2), recording.dropped);
    const table = recording.table();
    try testing.expectEqual(@as(usize, 3), table.len);
    try testing.expectEqual(@as(f64, 0.5), play(table, at(0)));
    try testing.expectEqual(@as(f64, 0.5), play(table, at(2)));
    try testing.expectEqual(@as(f64, 0.125), play(table, at(3)));
    try testing.expectEqual(@as(f64, 0.125), play(table, at(100)));
}

// Locks section 2's exception: a backward pass that reads what playback already gives at its time
// is no loss, and any other backward pass is.
test "a backward pass is no loss only when playback already gives its value" {
    var entries: [4]Sample = undefined;
    var recording = Recording.init(&entries);
    const second = @import("time.zig").flicks_per_second;
    recording.add(.{ .flicks = second }, 0.5);
    recording.add(.{ .flicks = 2 * second }, 0.5);
    recording.add(.{ .flicks = 3 * second / 2 }, 0.5);
    try std.testing.expect(recording.complete());
    try std.testing.expectEqual(@as(u32, 1), recording.count);
    recording.add(.{ .flicks = 3 * second / 2 }, 0.75);
    try std.testing.expect(!recording.complete());
    var again = Recording.init(&entries);
    again.add(.{ .flicks = second }, 0.5);
    again.add(.{ .flicks = 2 * second }, 0.5);
    again.add(.{ .flicks = second / 2 }, 0.5);
    try std.testing.expect(!again.complete());
}
