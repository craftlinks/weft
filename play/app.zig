//! Play: Weft's own Modulator Play, a scope of eight signals around a playhead on Patchwork.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Two-File Rule
//! Only `signals.zig` and `glue.zig` import `weft`. This file and `scope.zig` see time as a
//! `glue.Clock` and everything else as `f32` arrays and plain structs, so the app is the only glue
//! between Weft and Patchwork, and neither library knows the other exists.
//!
//! ## 2. Screen
//! ```text
//! 1280 x 720 at scale 1
//! y 0..48     transport: play button (8, 8, 88 x 32), scrub slider (104, 8, 720 x 32), label
//! y 48..688   eight rows of 80 px: a 200 px label column, then the plot (`scope.zig`)
//! ```
//! Each plot is a window from `t - 1 s` to `t + 3 s`, so the playhead sits at a quarter of its
//! width and a viewer sees where each signal is going, which only a seekable program can show.
//!
//! ## 3. Transport
//! Time follows frames: the timer is off, `t` advances on the `frame` event by its delta, clamped
//! at `dt_max_ms` so a stall loses time, and the app asks for the next frame only while playing.
//! Stopped, it sleeps. Space or the button plays and pauses; playing stops at 12 s, and play at the
//! end starts again from 0. The slider shows `t / 12 s` each frame, and a press or drag on it seeks
//! there and pauses. Home goes to 0; Left and Right step `step_ms`, clamped to the timeline.
//!
//! ## 4. Scenarios
//! `still` is three frames at 0. `play` presses Space and lets 150 frames run on the regress
//! clock. `scrub` clicks the slider where it maps to 6 s exactly. `scrub_back` clicks at about
//! 10 s, waits 30 frames, and clicks the same point as `scrub`, so its golden equals `scrub`'s:
//! scrubbing back draws the same picture.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: the program, both readers' slabs and checkpoints, and the sampled frame live
//!   in `App`, which the host keeps in static memory and which never moves.
//! - The tests assert that no draw is refused, in every scenario.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const glue = @import("glue.zig");
const scope = @import("scope.zig");
const input = patchwork.input;
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const Rect = quads.Rect;
const Clip = quads.Clip;

const Context = patchwork.app.Context(App);

pub const transport_height: f32 = 48;
pub const row_height: f32 = 80;
pub const button_rect: Rect = .{ .x = 8, .y = 8, .width = 88, .height = 32 };
pub const scrub_rect: Rect = .{ .x = 104, .y = 8, .width = 720, .height = 32 };
const label_rect: Rect = .{ .x = 840, .y = 0, .width = 424, .height = transport_height };
/// The longest frame delta the clock takes, so a stall loses time.
pub const dt_max_ms: f32 = 100;
pub const step_ms = 100;
/// Where the playhead sits in a plot's window.
const head_at: f32 = @as(f32, glue.before_ms) / @as(f32, glue.before_ms + glue.after_ms);
const line_cap = 96;

const ink = theme.dark.colors.text;
const label_style: text.Style = .{ .face = .sans, .size = 14, .color = ink };
const button_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = ink };
const button_paint: widgets.Paint = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = 8 };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

/// The x of slider value `value` from the slider's left edge, as a scenario's `click_at` takes it.
pub fn scrub_x(value: f32) f32 {
    return widgets.knob_radius + value * (scrub_rect.width - 2 * widgets.knob_radius);
}

const Step = patchwork.bench.Step;
const space: Step = .{ .key = .{ .key = .other, .text = " " } };
const scrub_target = patchwork.bench.area("scrub", 0);
/// 6 s exactly: the slider's value is 0.5 there.
const click_6s: Step = .{ .click_at = .{ .target = scrub_target, .x = scrub_x(0.5), .y = 16 } };
/// About 10 s: 592 px along a 696 px travel, a value of 580 / 696 in f32.
const click_10s: Step = .{ .click_at = .{ .target = scrub_target, .x = 592, .y = 16 } };

pub const App = struct {
    clock: glue.Clock,
    playing: bool,
    motion: glue.Motion,
    frame: glue.Frame,
    play: widgets.Button,
    scrub: widgets.Slider,

    pub const config: patchwork.app.Config = .{
        .title = "play",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 160 },
            .{ .type = quads.Path, .cap = 1024 },
            .{ .type = quads.Glyph, .cap = 1024 },
        },
        .batch_order = .registered,
        .batch_cap = 32,
        .area_cap = 8,
        .point_cap = 8192,
    };

    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 2 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 1 },
        .{ .name = "play", .setup = &.{space}, .cycle = &.{}, .frames = 150 },
        .{
            .name = "scrub",
            .setup = &.{ click_6s, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "scrub_back",
            .setup = &.{ click_10s, .{ .wait = 30 }, click_6s, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.clock = .{};
        app.playing = false;
        app.motion.init();
        app.play = .{
            .id = ui.id("play", 0),
            .label = "play",
            .style = button_style,
            .padding = .xy(8, 0),
            .paint = button_paint,
            .hover = .init(widgets.hover_rate_per_ms),
            .down = .init(widgets.down_rate_per_ms),
        };
        app.scrub = .{
            .id = ui.id("scrub", 0),
            .hover = .init(widgets.hover_rate_per_ms),
            .value = 0,
            .track = widgets.paint_of(theme.dark.colors.track, widgets.track_radius),
            .fill = widgets.paint_of(theme.dark.colors.value, widgets.track_radius),
            .knob = widgets.paint_of(theme.dark.colors.control, widgets.knob_radius),
        };
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        if (app.play.handle(cx, event_value) == .clicked) app.toggle(cx);
        switch (app.scrub.handle(cx, event_value)) {
            .changed => |value| {
                app.playing = false;
                app.clock.seek(value);
                cx.redraw();
            },
            .none, .released => {},
        }
        switch (event_value) {
            .frame => |dt_ms| {
                if (!app.playing) return;
                app.clock.advance(@min(dt_ms, dt_max_ms));
                if (app.at_end()) app.playing = false else cx.keep_animating();
                cx.redraw();
            },
            .key_down => |press| app.key(cx, press),
            else => {},
        }
    }

    fn key(app: *App, cx: *Context, press: input.KeyPress) void {
        switch (press.key) {
            .home => app.clock.seek(0),
            .left => app.clock.step(-step_ms),
            .right => app.clock.step(step_ms),
            .other => {
                if (!std.mem.eql(u8, press.typed(), " ")) return;
                app.toggle(cx);
            },
            else => return,
        }
        cx.redraw();
    }

    /// Plays or pauses; play at the end starts again from 0.
    fn toggle(app: *App, cx: *Context) void {
        if (!app.playing and app.at_end()) app.clock.seek(0);
        app.playing = !app.playing;
        cx.redraw();
    }

    fn at_end(app: *const App) bool {
        return app.clock.millis() == glue.timeline_ms;
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const clip: Clip = .{ .x0 = 0, .y0 = 0, .x1 = cx.window.width, .y1 = cx.window.height };
        app.draw_transport(cx, clip);
        app.motion.sample(app.clock, &app.frame);
        for (0..glue.row_count) |index| {
            const rect: Rect = .{
                .x = 0,
                .y = transport_height + row_height * @as(f32, @floatFromInt(index)),
                .width = cx.window.width,
                .height = row_height,
            };
            scope.draw(cx, app.row(index), rect, clip);
        }
    }

    fn draw_transport(app: *App, cx: *Context, clip: Clip) void {
        app.play.label = if (app.playing) "pause" else "play";
        app.scrub.value = app.clock.fraction();
        _ = cx.begin_at(button_rect, .{ .flow = .down });
        app.play.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        _ = cx.begin_at(scrub_rect, .{ .flow = .down });
        app.scrub.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        var buffer: [line_cap]u8 = undefined;
        text.place(cx.drawing(), label_style, app.label(&buffer), label_rect, clip, left);
    }

    /// The transport label: `t` to the millisecond, then the report.
    pub fn label(app: *const App, out: *[line_cap]u8) []const u8 {
        const ms: u64 = @intCast(app.clock.millis());
        const report = app.motion.report;
        const seekable = if (report.seekable) "seekable" else "not seekable";
        const name = if (report.first) |index| app.motion.signals.rows[index].name else "";
        const stepped = if (report.stepped) ", stepped from " else "";
        const args = .{ @divFloor(ms, 1000), @mod(ms, 1000), seekable, stepped, name };
        return std.fmt.bufPrint(out, "t {d}.{d:0>3} s   {s}{s}{s}", args) catch unreachable;
    }

    /// Row `index` of the scope, from the last sampled frame.
    fn row(app: *const App, index: usize) scope.Row {
        const frame = &app.frame;
        const signal = &app.motion.signals.rows[index];
        const goal: ?[]const f32 = if (signal.goal == .node) &frame.goals[index] else null;
        const count = frame.step_counts[index];
        const steps: ?[]const [2]f32 = if (count > 0) frame.steps[index][0..count] else null;
        const range = app.motion.ranges[index];
        return .{
            .name = signal.name,
            .class = app.motion.classes[index],
            .range = range,
            .axis = scope.axis(range, &frame.samples[index], goal, steps),
            .samples = &frame.samples[index],
            .goal = goal,
            .steps = steps,
            .cues = &frame.cues,
            .head_at = head_at,
            .head = frame.heads[index],
            .color = accent(signal.accent),
        };
    }
};

fn accent(index: u8) [4]f32 {
    const paint = widgets.accents[index % widgets.accents.len];
    return .{ paint.r, paint.g, paint.b, paint.a };
}

comptime {
    assert(glue.sample_count == quads.path.plot_samples_max);
    const Steps = @typeInfo(@FieldType(glue.Frame, "steps")).array.child;
    assert(@typeInfo(Steps).array.len <= scope.steps_max);
    assert(scrub_rect.x + scrub_rect.width < label_rect.x);
    assert(transport_height + glue.row_count * row_height <= 720);
    patchwork.app.check(App);
}

const fixture = struct {
    var context: Context = undefined;
    var app: App = undefined;
};

fn new_app() *App {
    fixture.context.init();
    patchwork.app.start(App, &fixture.context);
    var textures: quads.Textures = undefined;
    App.init(&fixture.app, &textures);
    return &fixture.app;
}

fn frame_at(app: *App) *Context {
    const cx = &fixture.context;
    cx.redraw();
    assert(ui.draw_frame(App, app, cx, 1280, 720, 120));
    return cx;
}

fn send(app: *App, event_value: input.Event) void {
    ui.dispatch(App, app, &fixture.context, event_value);
}

fn key_down(key_value: input.Key, typed: []const u8) input.Event {
    return .{ .key_down = input.key_press(key_value, .none, false, typed) };
}

test {
    _ = glue;
    _ = scope;
}

// Locks the transport's ends: playing stops at 12 s and play from there restarts at 0, and a
// paused frame asks for no redraw and no further frame.
test "playing stops at the end and starts again from zero" {
    const app = new_app();
    const cx = frame_at(app);
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    try std.testing.expect(!cx.dirty);
    send(app, key_down(.other, " "));
    try std.testing.expect(app.playing);
    var frames: u32 = 0;
    while (ui.animate(App, app, cx, 50)) : (frames += 1) {
        try std.testing.expect(frames < 1000);
        _ = frame_at(app);
    }
    try std.testing.expect(!app.playing);
    try std.testing.expectEqual(@as(i64, glue.timeline_ms), app.clock.millis());
    try std.testing.expectEqual(@as(u32, 239), frames);
    _ = frame_at(app);
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    try std.testing.expect(!cx.dirty);
    send(app, key_down(.other, " "));
    try std.testing.expect(app.playing);
    try std.testing.expectEqual(@as(i64, 0), app.clock.millis());
    try std.testing.expect(ui.animate(App, app, cx, 250));
    try std.testing.expectEqual(@as(i64, 100), app.clock.millis());
}

// Locks the keys: Home goes to 0, the arrows step 100 ms, and both ends clamp.
test "home and the arrows clamp to the timeline" {
    const app = new_app();
    send(app, key_down(.left, ""));
    try std.testing.expectEqual(@as(i64, 0), app.clock.millis());
    send(app, key_down(.right, ""));
    send(app, key_down(.right, ""));
    try std.testing.expectEqual(@as(i64, 200), app.clock.millis());
    send(app, key_down(.home, ""));
    try std.testing.expectEqual(@as(i64, 0), app.clock.millis());
    app.clock.seek(1);
    send(app, key_down(.right, ""));
    try std.testing.expectEqual(@as(i64, glue.timeline_ms), app.clock.millis());
    send(app, key_down(.left, ""));
    try std.testing.expectEqual(@as(i64, glue.timeline_ms - step_ms), app.clock.millis());
}

// Locks the label and the report: seekable, stepped, and the chase named as the first simulated.
test "the label shows the time and the report" {
    const app = new_app();
    app.clock.seek(0.5);
    var buffer: [line_cap]u8 = undefined;
    const expected = "t 6.000 s   seekable, stepped from chase";
    try std.testing.expectEqualStrings(expected, app.label(&buffer));
}

// Locks the scrub clicks: `scrub` lands on 6 s exactly and pauses, `scrub_back` near 10 s first.
test "the scrub scenarios land where their clicks map" {
    const bench = patchwork.bench;
    const cx = &fixture.context;
    var app = new_app();
    send(app, key_down(.other, " "));
    _ = try bench.replay_headless_paced(App, app, cx, &App.scenarios[2], .{ 1280, 720 }, 1, 16);
    try std.testing.expectEqual(@as(i64, 6000), app.clock.millis());
    try std.testing.expect(!app.playing);
    app = new_app();
    _ = try bench.replay_headless_paced(App, app, cx, &App.scenarios[3], .{ 1280, 720 }, 1, 16);
    try std.testing.expectEqual(@as(i64, 9999), app.clock.millis());
}

/// Copies of two frames' Path instances and point pools, static for their size.
const frozen = struct {
    var copies: [2][2][128 * 1024]u8 = undefined;
};

// Locks the picture after a scrub back: `scrub_back` ends with the very Path instances and point
// pool `scrub` does, byte for byte, though its scope reader came from 10 s and its checkpoints.
test "scrubbing back draws the same picture" {
    const bench = patchwork.bench;
    const cx = &fixture.context;
    var paths: [2][]const u8 = undefined;
    var points: [2][]const u8 = undefined;
    const copies = &frozen.copies;
    for (App.scenarios[2..4], 0..) |*scenario, index| {
        const app = new_app();
        _ = try bench.replay_headless_paced(App, app, cx, scenario, .{ 1280, 720 }, 64, 16);
        _ = frame_at(app);
        try std.testing.expectEqual(@as(i64, 6000), app.clock.millis());
        const path_bytes = std.mem.sliceAsBytes(cx.draw.items(quads.Path));
        const point_bytes = std.mem.sliceAsBytes(cx.draw.points[0..cx.draw.point_count]);
        @memcpy(copies[index][0][0..path_bytes.len], path_bytes);
        @memcpy(copies[index][1][0..point_bytes.len], point_bytes);
        paths[index] = copies[index][0][0..path_bytes.len];
        points[index] = copies[index][1][0..point_bytes.len];
    }
    try std.testing.expect(paths[0].len > 0);
    try std.testing.expectEqualSlices(u8, paths[0], paths[1]);
    try std.testing.expectEqualSlices(u8, points[0], points[1]);
}

// Locks the scenarios without a GPU (`patchwork.bench`, section 2a): none refuses a draw.
test "the scenarios replay headless" {
    const bench = patchwork.bench;
    const cx = &fixture.context;
    for (App.scenarios) |*scenario| {
        const app = new_app();
        _ = try bench.replay_headless_paced(App, app, cx, scenario, .{ 1280, 720 }, 200, 16);
        try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    }
}
