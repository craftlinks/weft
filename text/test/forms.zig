//! Where a number is written (step 41): a cue's form, a track's three numbers, and the reader
//! and writer of a time literal, each against the checker's own sums and folds.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. A Cue's Form
//! One test a form a cue can take (`check.zig`, section 4a): a literal, a cue alone, a cue of a
//! series alone, a cue and a literal after it, an item of a list, and a cue of a series spaced
//! `every` a step. Then every cue of a file with all of them is summed again from its form alone,
//! as a client would, and must give the checker's time, so a form that drifts from the sum fails.
//!
//! ## 2. A Track's Numbers
//! `1`, `1.00`, `-0.5`, and `1e3`, then the forms step 40 folds, `0..tau` and `2 * 0.25`, which
//! are `folded` and never `plain`, so no client rewrites an expression as a literal. A file that
//! does not check still gives its tracks' forms through `Syntax`, with `other` for what the
//! checker refuses.
//!
//! ## 3. The Reader and the Writer
//! `write_time` is the inverse of `read_time`: over a spread of flicks, every unit, and
//! Tapestry's literals, a written literal reads back to exactly its flicks, is the shortest that
//! does, and a time no literal holds is refused. Last, the whole loop of the README: a cue's
//! literal found by its form, rewritten by the writer, and the file loaded again.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const jig = @import("jig");
const weft_text = @import("weft_text");

const limits: weft_text.Limits = .{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 64,
    .slab = 256,
    .cues = 64,
    .goals = 16,
    .regions = 8,
    .tracks = 8,
    .track_samples = 4,
};
const Compiled = weft_text.Compiled(limits);
const Syntax = weft_text.Syntax(limits);

var compiled: Compiled = undefined;
var syntax: Syntax = undefined;

const second: i64 = weft.time.flicks_per_second;
const ms: i64 = @divExact(second, 1000);

fn compile(source: []const u8) !*const Compiled {
    compiled.compile(source) catch |err| {
        var buffer: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        for (compiled.errors()) |found| found.render(source, "test", &writer) catch {};
        std.debug.print("{s}", .{writer.buffered()});
        return err;
    };
    return &compiled;
}

fn cue_index(file: *const Compiled, name: []const u8) u32 {
    return file.cue(name).?.index;
}

/// Checks a literal's flicks, its unit, its minus, and its bytes in `source`.
fn expect_literal(source: []const u8, literal: jig.check.TimeLiteral, text: []const u8, flicks: i64, negative: bool) !void {
    try testing.expectEqualStrings(text, literal.text(source));
    try testing.expectEqual(flicks, literal.flicks);
    try testing.expectEqual(negative, literal.negative);
    const unit: jig.check.TimeUnit = if (std.mem.endsWith(u8, text, "ms")) .ms else .s;
    try testing.expectEqual(unit, literal.unit);
    try testing.expectEqual(jig.check.TimeRead{ .flicks = flicks }, jig.check.read_time(text));
}

// Locks a literal alone: `cue a = 2s` is 1,411,200,000 flicks in seconds, and `cue m = -1500ms`
// is the token `1500ms`, 1,058,400,000 flicks, after the parser's minus.
test "a cue written as a literal" {
    const source = "cue m = -1500ms\ncue a = 2s\n";
    const file = try compile(source);
    const a = file.cue_form(cue_index(file, "a")).?;
    try expect_literal(source, a.alone.literal, "2s", 2 * second, false);
    const m = file.cue_form(cue_index(file, "m")).?;
    try expect_literal(source, m.alone.literal, "1500ms", 1500 * ms, true);
    try testing.expectEqual(-1500 * ms, m.alone.literal.signed());
    try testing.expectEqual(@as(?jig.check.CueForm, null), file.cue_form(2));
}

// Locks a cue alone, `cue b = a`, and a cue of a series alone, `cue c = bar[2]`: each the
// cue it names, by its index in the table, 3 and 2.
test "a cue written as another cue" {
    const file = try compile("cue bar = 0s..4s every 2s\ncue a = 4s\ncue b = a\ncue c = bar[2]\n");
    try testing.expectEqual(@as(u32, 3), file.cue_form(cue_index(file, "b")).?.alone.cue);
    try testing.expectEqual(@as(u32, 2), file.cue_form(cue_index(file, "c")).?.alone.cue);
    try testing.expectEqual(@as(?jig.check.CueTime, .{ .cue = 2 }), file.cue_form(5).?.written());
}

// Locks a cue and a literal after it (step 29): `cue hit = a + 500ms` is cue 0 and 352,800,000
// flicks, and `cue d = s[1] + 2.08ms` is cue 3 and 1,467,648 flicks.
test "a cue written as a cue and a literal after it" {
    const source = "cue a = 1s\ncue hit = a + 500ms\ncue s = [2s, 3s]\ncue d = s[1] + 2.08ms\n";
    const file = try compile(source);
    const hit = file.cue_form(cue_index(file, "hit")).?.alone.after;
    try testing.expectEqual(@as(u32, 0), hit.base);
    try expect_literal(source, hit.offset, "500ms", 500 * ms, false);
    const d = file.cue_form(cue_index(file, "d")).?.alone.after;
    try testing.expectEqual(@as(u32, 3), d.base);
    try expect_literal(source, d.offset, "2.08ms", 1_467_648, false);
    try testing.expectEqual(3 * second + 1_467_648, file.checked.cue_times[cue_index(file, "d")]);
}

// Locks a series written as a list (step 28): `cue s = [a, 1s, a + 800ms]` is three cues,
// items 0 to 2, each written as its item is: cue 0, a literal, and cue 0 and 800 ms.
test "a cue written as an item of a list" {
    const source = "cue a = 500ms\ncue s = [a, 1s, a + 800ms]\n";
    const file = try compile(source);
    const first = file.cue_form(1).?.listed;
    try testing.expectEqual(@as(u32, 0), first.element);
    try testing.expectEqual(@as(u32, 0), first.time.cue);
    const middle = file.cue_form(2).?.listed;
    try testing.expectEqual(@as(u32, 1), middle.element);
    try expect_literal(source, middle.time.literal, "1s", second, false);
    const last = file.cue_form(3).?.listed;
    try testing.expectEqual(@as(u32, 2), last.element);
    try testing.expectEqual(@as(u32, 0), last.time.after.base);
    try expect_literal(source, last.time.after.offset, "800ms", 800 * ms, false);
}

// Locks a series spaced `every` a step: `cue bar = a..a + 6s every 2s` is four cues, 1 to 4,
// each with its place, from cue 0, to cue 0 and 6 s, and the step 2 s; none has a time of its
// own to write.
test "a cue written as a cue of a series spaced every a step" {
    const source = "cue a = 1s\ncue bar = a..a + 6s every 2s\n";
    const file = try compile(source);
    for (1..5) |cue| {
        const form = file.cue_form(@intCast(cue)).?;
        try testing.expectEqual(@as(?jig.check.CueTime, null), form.written());
        const every = form.every;
        try testing.expectEqual(@as(u32, @intCast(cue - 1)), every.element);
        try testing.expectEqual(@as(u32, 0), every.from.cue);
        try testing.expectEqual(@as(u32, 0), every.to.after.base);
        try expect_literal(source, every.to.after.offset, "6s", 6 * second, false);
        try expect_literal(source, every.step, "2s", 2 * second, false);
    }
}

/// A cue time summed from how it is written, as a client sums it, with `times` for its base.
fn sum(times: []const i64, time: jig.check.CueTime) i64 {
    return switch (time) {
        .literal => |literal| literal.signed(),
        .cue => |base| times[base],
        .after => |after| times[after.base] + after.offset.signed(),
    };
}

// Locks section 1's sum: every cue of a file with every form, summed from its form alone in the
// table's order, is the checker's time, flick for flick: 14 cues.
test "every cue's form sums to the checker's time" {
    const file = try compile(
        \\cue a = -250ms
        \\cue b = a
        \\cue c = b + 1.5s
        \\cue s0 = 1.5s
        \\cue s = [2s, c + 1s, c + 1.00001s, s0 + 1s]
        \\cue t = [s[3], s[3] + 2.08ms]
        \\cue bar = s[3] + 1s..t[1] + 2.99792s every 1s
        \\cue end = bar[2] + 6500ms
        \\
    );
    const times = file.checked.cue_times;
    try testing.expectEqual(@as(usize, 14), times.len);
    for (times, 0..) |time, cue| {
        const form = file.cue_form(@intCast(cue)).?;
        const summed = switch (form) {
            .alone => |written| sum(times, written),
            .listed => |listed| sum(times, listed.time),
            .every => |every| sum(times, every.from) + every.step.signed() * every.element,
        };
        try testing.expectEqual(time, summed);
        if (form == .every) {
            const span = sum(times, form.every.to) - sum(times, form.every.from);
            try testing.expectEqual(@as(i64, 0), @rem(span, form.every.step.signed()));
        }
    }
    try testing.expectEqual(12 * second, times[13]);
}

/// Checks a track's three forms: each kind, and its bytes in `source`.
fn expect_track(source: []const u8, form: jig.check.TrackForm, expected: [3]struct { jig.check.NumberForm.Kind, []const u8 }) !void {
    for ([_]jig.check.NumberForm{ form.value, form.low, form.high }, expected) |number, want| {
        try testing.expectEqual(want[0], number.kind);
        try testing.expectEqualStrings(want[1], number.bytes.of(source));
        if (want[0] == .plain) {
            try testing.expectEqual(number.bytes, number.plain().?);
        } else {
            try testing.expectEqual(@as(?jig.check.Bytes, null), number.plain());
        }
    }
}

// Locks section 2: `1`, `1.00`, `-0.5`, and `1e3` as written, a minus inside the bytes, a
// comment after the line outside them, and an exponent its own kind.
test "a track's literals are found as written" {
    const source =
        \\track a = 1 in 0.25..2 # a comment after it
        \\track b = 1.00 in -1..1e3
        \\track lean = -0.5 in -1..1.00
        \\
    ;
    const file = try compile(source);
    try expect_track(source, file.track_form("a").?, .{ .{ .plain, "1" }, .{ .plain, "0.25" }, .{ .plain, "2" } });
    try expect_track(source, file.track_form("b").?, .{ .{ .plain, "1.00" }, .{ .plain, "-1" }, .{ .exponent, "1e3" } });
    try expect_track(source, file.track_form("lean").?, .{ .{ .plain, "-0.5" }, .{ .plain, "-1" }, .{ .plain, "1.00" } });
    try testing.expectEqual(@as(?jig.check.TrackForm, null), file.track_form("missing"));
}

// Locks section 2 for step 40's folds: `0.5 in 0..tau`, `2 * 0.25 in -pi..(1)`, and
// `-tau / 4` are `folded`, with the expression's bytes, so none is a plain literal; the file's
// value of each is still the checker's, 0.5 and -tau / 4.
test "a track's folded numbers are not literals" {
    const source =
        \\track phase = 0.5 in 0..tau
        \\track half = 2 * 0.25 in -pi..(1)
        \\track turn = -tau / 4 in -tau..0
        \\
    ;
    const file = try compile(source);
    try expect_track(source, file.track_form("phase").?, .{ .{ .plain, "0.5" }, .{ .plain, "0" }, .{ .folded, "tau" } });
    try expect_track(source, file.track_form("half").?, .{ .{ .folded, "2 * 0.25" }, .{ .folded, "-pi" }, .{ .folded, "(1)" } });
    try expect_track(source, file.track_form("turn").?, .{ .{ .folded, "-tau / 4" }, .{ .folded, "-tau" }, .{ .plain, "0" } });
    try testing.expectEqual(@as(f64, 0.5), file.checked.tracks[1].initial);
    try testing.expectEqual(-std.math.tau / 4.0, file.checked.tracks[2].initial);
}

// Locks the tree alone: a file whose `bad` line the checker refuses still gives `a`'s forms,
// and a track bounded by a file's own `tau`, a signal, or by a name, is `other`, which only a
// file that does not check holds. The first of two lines of one name is the one given, and a
// track whose bounds are not a range, `r = 1 in 2`, has no form.
test "a track's forms are read while the file has an error" {
    const source =
        \\tau = wave(sine, 1hz)
        \\track a = 0.5 in 0..2
        \\bad = nothing(1)
        \\track b = 1 in 0..tau
        \\track c = k in 0..1
        \\track a = 9 in 0..9
        \\track r = 1 in 2
        \\
    ;
    try testing.expectError(error.Invalid, compiled.compile(source));
    _ = syntax.parse_source(source);
    try expect_track(source, syntax.track_form("a").?, .{ .{ .plain, "0.5" }, .{ .plain, "0" }, .{ .plain, "2" } });
    try expect_track(source, syntax.track_form("b").?, .{ .{ .plain, "1" }, .{ .plain, "0" }, .{ .other, "tau" } });
    try expect_track(source, syntax.track_form("c").?, .{ .{ .other, "k" }, .{ .plain, "0" }, .{ .plain, "1" } });
    try testing.expectEqual(@as(?jig.check.TrackForm, null), syntax.track_form("bad"));
    try testing.expectEqual(@as(?jig.check.TrackForm, null), syntax.track_form("r"));
}

/// Whether `text` is the shortest literal of its value: no zero ends a fraction, and no zero
/// starts a whole part of more than one digit.
fn shortest(text: []const u8) bool {
    const digits = text[0 .. text.len - @as(usize, if (std.mem.endsWith(u8, text, "ms")) 2 else 1)];
    if (digits.len > 1 and digits[0] == '0' and digits[1] != '.') return false;
    if (std.mem.indexOfScalar(u8, digits, '.') == null) return true;
    return digits[digits.len - 1] != '0';
}

// Locks section 3 on worked values: 7 s, 6.5 s, and 2.08 ms in both units, as Tapestry writes
// them (`7s`, `6500ms`, `2.08ms`), 1 flick and 440 flicks refused, 441 flicks, the finest a
// literal holds, written to 9 places of seconds, and the largest i64 of flicks refused, since
// 441 does not divide it, while the largest multiple of 441 is written.
test "the writer writes the shortest literal that reads back" {
    var buffer: [jig.check.time_text_max]u8 = undefined;
    const cases = [_]struct { i64, jig.check.TimeUnit, ?[]const u8 }{
        .{ 7 * second, .s, "7s" },
        .{ 7 * second, .ms, "7000ms" },
        .{ 6500 * ms, .ms, "6500ms" },
        .{ 6500 * ms, .s, "6.5s" },
        .{ 1_467_648, .ms, "2.08ms" },
        .{ 1_467_648, .s, "0.00208s" },
        .{ 0, .s, "0s" },
        .{ 0, .ms, "0ms" },
        .{ 1, .s, null },
        .{ 440, .ms, null },
        .{ 441, .s, "0.000000625s" },
        .{ 441, .ms, "0.000625ms" },
        .{ 3528, .s, "0.000005s" },
        .{ 3528, .ms, "0.005ms" },
        .{ -second, .s, null },
        .{ std.math.maxInt(i64), .s, null },
        .{ @divFloor(std.math.maxInt(i64), 441) * 441, .ms, "13071672387832.731875ms" },
        .{ @divFloor(std.math.maxInt(i64), 441) * 441, .s, "13071672387.832731875s" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {d} in {t}\n", .{ case[0], case[1] });
        const written = jig.check.write_time(&buffer, case[0], case[1]);
        if (case[2]) |expected| {
            try testing.expectEqualStrings(expected, written.?);
            try testing.expectEqual(jig.check.TimeRead{ .flicks = case[0] }, jig.check.read_time(expected));
        } else {
            try testing.expectEqual(@as(?[]const u8, null), written);
        }
    }
}

// Locks section 3 over a spread: 20,000 flicks from a seeded generator, small and large, in
// both units. A time is written exactly when 441 divides it (705,600,000 / 441 = 1,600,000, so
// the rest of the second's factors are 2s and 5s), and what is written reads back to it, is the
// shortest, and is what the writer gives for the literal it read.
test "the writer and the reader are inverses" {
    var prng: std.Random.DefaultPrng = .init(41);
    const random = prng.random();
    var buffer: [jig.check.time_text_max]u8 = undefined;
    var again: [jig.check.time_text_max]u8 = undefined;
    var written_count: u32 = 0;
    for (0..20_000) |at| {
        const magnitude: u6 = @intCast(at % 63);
        var flicks: i64 = @intCast(random.uintLessThan(u64, @as(u64, 1) << magnitude));
        if (at % 3 == 0) flicks = @divFloor(flicks, 441) * 441;
        for ([_]jig.check.TimeUnit{ .s, .ms }) |unit| {
            errdefer std.debug.print("case: {d} in {t}\n", .{ flicks, unit });
            const written = jig.check.write_time(&buffer, flicks, unit) orelse {
                try testing.expect(@rem(flicks, 441) != 0);
                continue;
            };
            written_count += 1;
            try testing.expectEqual(@as(i64, 0), @rem(flicks, 441));
            try testing.expectEqual(jig.check.TimeRead{ .flicks = flicks }, jig.check.read_time(written));
            try testing.expect(shortest(written));
            try testing.expectEqualStrings(written, jig.check.write_time(&again, jig.check.read_time(written).flicks, unit).?);
        }
    }
    try testing.expect(written_count > 10_000);
}

// Locks the loop a client follows (the README's "Writing a Number Back"): `cue b2` at `b1 +
// 6s` is retimed to 6.5 s by its offset's bytes, `6500ms` as Tapestry writes a fraction, and
// the file loaded again has the cue at 6.5 s after `b1`, with every other byte as it was.
test "a cue's literal rewritten by its form loads to the time written" {
    const source = "cue b1 = 1s\ncue b2 = b1 + 6s # the second beat\ncue b3 = b2 + 2s\n";
    const file = try compile(source);
    const b2 = cue_index(file, "b2");
    const offset = file.cue_form(b2).?.alone.after.offset;
    var literal: [jig.check.time_text_max]u8 = undefined;
    const written = jig.check.write_time(&literal, 6500 * ms, .ms).?;
    var text: [128]u8 = undefined;
    const edited = try std.fmt.bufPrint(&text, "{s}{s}{s}", .{ source[0..offset.start], written, source[offset.start + offset.len ..] });
    try testing.expectEqualStrings("cue b1 = 1s\ncue b2 = b1 + 6500ms # the second beat\ncue b3 = b2 + 2s\n", edited);
    const reloaded = try compile(edited);
    try testing.expectEqual(second + 6500 * ms, reloaded.checked.cue_times[b2]);
    try testing.expectEqual(second + 8500 * ms, reloaded.checked.cue_times[b2 + 1]);
}
