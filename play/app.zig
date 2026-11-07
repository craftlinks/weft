//! Play: Weft's own Modulator Play on Patchwork: a scope of signals around a playhead, a page of
//! shapes whose parameters any signal can drive, and a page of bouncers whose hits are events.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Two-File Rule
//! Only `signals.zig` and `glue.zig` import `weft`. This file, `scope.zig`, `patch.zig`,
//! `shapes.zig`, and `bouncers.zig` see time as a `glue.Clock` and everything else as `f32`
//! arrays and plain structs, so the app is the only glue between Weft and Patchwork, and neither
//! library knows the other exists. The app reads each row's name, accent, and goal kind from the
//! signal table through `motion.signals`, and each lane's from `motion.bouncers`, which names no
//! Weft type.
//!
//! ## 2. Screen
//! ```text
//! 1280 x 720 at scale 1
//! y 0..48    transport: play (8, 8, 88 x 32), page (104, 8, 88 x 32), scrub (200, 8, 640 x 32),
//!            then the label
//! scope      eight rows of 80 px from y 48: a 200 px label column, then the plot (`scope.zig`)
//! shapes     left column x 16..352: four knobs of 160 x 72 in two rows from y 56, then eleven
//!            patch rows of 32 px from y 224 (name, source button, bar); the canvas x 368..1272,
//!            y 56..712 (`shapes.zig`)
//! bouncers   seven lanes of 80 px from y 48: a 200 px label column with the small bouncer, then
//!            the lane (`bouncers.zig`); the log of six lines from y 616
//! ```
//! Each scope plot and each lane is a window from `t - 1 s` to `t + 3 s`, so the playhead sits at
//! a quarter of its width. The shapes page reads only the playhead reader, so it never samples
//! that window, and the bouncers page reads only the bouncer program's reader.
//!
//! ## 3. Transport
//! Time follows frames: the timer is off, `t` advances on the `frame` event by its delta, clamped
//! at `dt_max_ms` so a stall loses time, and the app asks for the next frame only while playing.
//! Stopped, it sleeps. Space or the play button plays and pauses; playing stops at 600 s, and play
//! at the end starts again from 0. The slider shows `t / 600 s` each frame, and a press or drag on
//! it seeks there and pauses. Home goes to 0 and End to 600 s; Left and Right step `step_ms`, and
//! Page Up and Page Down `page_ms` back and forth, all clamped. The page button cycles the pages
//! and names the next; the keys 1, 2, and 3 go to each.
//!
//! ## 4. Knobs Apply From Now On
//! A knob's value v in [0, 1] maps to a parameter so that 0.5 is the default exactly
//! (`knob_param`), and each parameter is a track (Weft's step 9.5). Turning a knob writes its
//! parameter at t, latched from t on: the program is never rebuilt, the past keeps what was
//! played, and a write costs the readers at most a second of steps. When not turned, a knob shows
//! its track's value at t, so scrubbing back or replaying shows the knob move as it was played. A
//! right press resets a knob to its default, from now on. A full track refuses the write, which
//! changes nothing.
//!
//! ## 5. Re-Pointing Costs Nothing in Weft
//! `patch` holds the row each destination reads. A source button moves its destination to the next
//! row with a finite range, wrapping, and the program is not touched. A destination's value is its
//! source's value at t through the source's declared range (`patch.zig`, section 2), so it never
//! leaves its range. The chase, whose spring time comes from a knob, has no finite range, so it is
//! never a source.
//!
//! ## 6. Scenarios
//! `still` is frames at 0. `play` presses Space and lets 150 frames run on the regress clock.
//! `scrub` clicks the slider where it maps to 300 s exactly; `scrub_back` clicks near 500 s,
//! waits 30 frames, and clicks the same point as `scrub`, so its golden equals `scrub`'s.
//! `shapes` and `shapes_play` are the shapes page still and playing. `repoint` moves lines.width
//! two rows on. `knob` moves to 2 s, drags `chase s` to 1 s there, and shows the scope: the chase
//! slows from 2 s on and not before. `knob_600` drags `pulse hz` up and down at 600 s, a write each
//! frame: the bench scenario. `bouncers` and `bouncers_play` are the bouncers page still and
//! playing, and `bouncers_300` scrubs to 300 s, where six lanes hit at once. `play_590` and
//! `bouncers_590` play from 590 s on the scope and the bouncers: the benches for the events.
//!
//! ## 7. Events Are Read, Never Kept
//! Each frame reads its events as a window around the playhead (`glue.zig`, section 6): the
//! scope's dots, the lanes' hits and bars, and each lane's last hit, whose flash fades over a
//! quarter second (`bouncers.zig`, section 3). The app keeps none of them between frames, so a
//! scrub, a pause, or a frame rate never changes what a time shows.
//!
//! ## 8. TigerStyle Invariants
//! - No allocation: the program, both readers' slabs and checkpoints, and the sampled frame live
//!   in `App`, which the host keeps in static memory and which never moves.
//! - A knob change is one track write; `writes` counts them for the tests.
//! - The tests assert that no draw is refused, in every scenario.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const glue = @import("glue.zig");
const patch = @import("patch.zig");
const scope = @import("scope.zig");
const shapes = @import("shapes.zig");
const bouncers = @import("bouncers.zig");
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
pub const play_rect: Rect = .{ .x = 8, .y = 8, .width = 88, .height = 32 };
pub const page_rect: Rect = .{ .x = 104, .y = 8, .width = 88, .height = 32 };
pub const scrub_rect: Rect = .{ .x = 200, .y = 8, .width = 640, .height = 32 };
const label_rect: Rect = .{ .x = 856, .y = 0, .width = 408, .height = transport_height };
/// The longest frame delta the clock takes, so a stall loses time.
pub const dt_max_ms: f32 = 100;
pub const step_ms = 100;
pub const page_ms = 10_000;
/// Where the playhead sits in a plot's window.
const head_at: f32 = @as(f32, glue.before_ms) / @as(f32, glue.before_ms + glue.after_ms);
const line_cap = 96;

pub const knob_count = 4;
/// The knobs sit in two rows of two: the default skin draws the name and value beside the ring.
pub const knob_y: f32 = 56;
pub const knob_pitch: [2]f32 = .{ 168, 80 };
pub const patch_y: f32 = 224;
pub const patch_pitch: f32 = 32;
const knob_names = [knob_count][]const u8{ "pulse hz", "chase s", "sway os", "glide v" };
/// Each knob's parameter at its middle, the default: pulse hz, chase s, sway os, glide v.
const knob_middles = [knob_count]f64{ 0.3, 0.5, 0.45, 1 };

const ink = theme.dark.colors.text;
const label_style: text.Style = .{ .face = .sans, .size = 14, .color = ink };
const name_style: text.Style = .{ .face = .sans, .size = 13, .color = ink };
const button_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = ink };
const source_style: text.Style = .{ .face = .sans, .size = 12, .color = ink };
const button_paint: widgets.Paint = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = 8 };
const source_paint: widgets.Paint = .{ .r = 0.22, .g = 0.25, .b = 0.32, .a = 1, .radius = 6 };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

pub const Page = enum {
    scope,
    shapes,
    bouncers,

    /// The page the page button goes to.
    pub fn next(page: Page) Page {
        return switch (page) {
            .scope => .shapes,
            .shapes => .bouncers,
            .bouncers => .scope,
        };
    }
};

/// The x of slider value `value` from the slider's left edge, as a scenario's `click_at` takes it.
pub fn scrub_x(value: f32) f32 {
    return widgets.knob_radius + value * (scrub_rect.width - 2 * widgets.knob_radius);
}

/// The rect of knob `index`.
pub fn knob_rect(index: usize) Rect {
    const column: f32 = @floatFromInt(index % 2);
    const row: f32 = @floatFromInt(index / 2);
    const x = 16 + knob_pitch[0] * column;
    const y = knob_y + knob_pitch[1] * row;
    return .{ .x = x, .y = y, .width = 160, .height = widgets.knob_height };
}

/// The rect of patch row `index`.
pub fn patch_rect(index: usize) Rect {
    const y = patch_y + patch_pitch * @as(f32, @floatFromInt(index));
    return .{ .x = 16, .y = y, .width = 336, .height = patch_pitch };
}

/// Knob `index`'s parameter at value `value` (section 4): `sway os` is linear, `0.9 v`, and the
/// rest are their middle times `4^(2v - 1)`, so each is its default at 0.5 exactly.
pub fn knob_param(index: usize, value: f32) f64 {
    assert(value >= 0 and value <= 1);
    const v: f64 = value;
    if (index == 2) return 2 * knob_middles[2] * v;
    return knob_middles[index] * std.math.pow(f64, 4, 2 * v - 1);
}

/// The knob value whose parameter is `param`, the inverse of `knob_param`, clamped into [0, 1].
pub fn knob_value(index: usize, param: f64) f32 {
    assert(param >= 0);
    const v = if (index == 2)
        param / (2 * knob_middles[2])
    else
        (std.math.log2(param / knob_middles[index]) / 2 + 1) / 2;
    return @floatCast(std.math.clamp(v, 0, 1));
}

const Step = patchwork.bench.Step;
const space: Step = .{ .key = .{ .key = .other, .text = " " } };
const page_1: Step = .{ .key = .{ .key = .other, .text = "1" } };
const page_2: Step = .{ .key = .{ .key = .other, .text = "2" } };
const page_3: Step = .{ .key = .{ .key = .other, .text = "3" } };
const page_up: Step = .{ .key = .{ .key = .page_up, .text = "" } };
const end: Step = .{ .key = .{ .key = .end, .text = "" } };
const scrub_target = patchwork.bench.area("scrub", 0);
/// 300 s exactly: the slider's value is 0.5 there.
const click_300s: Step = .{ .click_at = .{ .target = scrub_target, .x = scrub_x(0.5), .y = 16 } };
/// Near 500 s: 513 px along a 616 px travel.
const click_500s: Step = .{ .click_at = .{ .target = scrub_target, .x = 525, .y = 16 } };
const repoint_width: Step = .{ .click = patchwork.bench.area("source", 1) };
const right: Step = .{ .key = .{ .key = .right, .text = "" } };

/// A drag of `dy` px on knob `index` from its centre: up is positive v, 120 px for the whole range.
fn knob_drag(comptime index: u32, dy: f32) Step {
    return .{ .drag = .{
        .target = patchwork.bench.area("knob", index),
        .from_x = 40,
        .from_y = 36,
        .dx = 0,
        .dy = dy,
    } };
}

pub const App = struct {
    clock: glue.Clock,
    playing: bool,
    page: Page,
    motion: glue.Motion,
    frame: glue.Frame,
    play: widgets.Button,
    page_button: widgets.Button,
    scrub: widgets.Slider,
    knobs: [knob_count]widgets.Knob,
    /// Track writes made by the knobs (section 4).
    writes: u32,
    /// The row each destination reads (section 5).
    patch: [patch.count]u8,
    sources: [patch.count]widgets.Button,
    /// The bouncers page as last read, and the scope's dots sorted by row (section 7).
    hits: glue.Hits,
    row_dots: [glue.scope_row_count][glue.dots_max][2]f32,
    row_dot_counts: [glue.scope_row_count]u32,

    pub const config: patchwork.app.Config = .{
        .title = "play",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 320 },
            .{ .type = quads.Arc, .cap = 16 },
            .{ .type = quads.Fill, .cap = 32 },
            .{ .type = quads.Path, .cap = 1024 },
            .{ .type = quads.Glyph, .cap = 1536 },
        },
        .batch_order = .registered,
        .batch_cap = 32,
        .area_cap = 32,
        .point_cap = 8192,
    };

    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 2 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 1 },
        .{ .name = "play", .setup = &.{space}, .cycle = &.{}, .frames = 150 },
        .{
            .name = "scrub",
            .setup = &.{ click_300s, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "scrub_back",
            .setup = &.{ click_500s, .{ .wait = 30 }, click_300s, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "shapes",
            .setup = &.{ page_2, .{ .wait = 2 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 1,
        },
        .{ .name = "shapes_play", .setup = &.{ page_2, space }, .cycle = &.{}, .frames = 150 },
        .{
            .name = "repoint",
            .setup = &.{ page_2, repoint_width, repoint_width, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 1,
        },
        .{
            .name = "knob",
            .setup = &([_]Step{page_2} ++ @as([20]Step, @splat(right)) ++ [_]Step{
                knob_drag(1, -30),
                page_1,
                .{ .wait = 3 },
            }),
            .cycle = &.{.{ .wait = 1 }},
            .frames = 1,
        },
        .{
            .name = "knob_600",
            .setup = &.{ end, page_2, .{ .wait = 2 } },
            .cycle = &.{ knob_drag(0, -1), knob_drag(0, 1) },
            .frames = 20,
        },
        .{
            .name = "bouncers",
            .setup = &.{ page_3, .{ .wait = 2 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 1,
        },
        .{ .name = "bouncers_play", .setup = &.{ page_3, space }, .cycle = &.{}, .frames = 150 },
        .{
            .name = "bouncers_300",
            .setup = &.{ page_3, click_300s, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 1,
        },
        .{
            .name = "play_590",
            .setup = &.{ end, page_up, space },
            .cycle = &.{},
            .frames = 120,
        },
        .{
            .name = "bouncers_590",
            .setup = &.{ end, page_up, page_3, space },
            .cycle = &.{},
            .frames = 120,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.clock = .{};
        app.playing = false;
        app.page = .scope;
        app.motion.build();
        app.play = button(ui.id("play", 0), "play", button_style, button_paint);
        app.page_button = button(ui.id("page", 0), "shapes", button_style, button_paint);
        app.scrub = .{
            .id = ui.id("scrub", 0),
            .hover = .init(widgets.hover_rate_per_ms),
            .value = 0,
            .track = widgets.paint_of(theme.dark.colors.track, widgets.track_radius),
            .fill = widgets.paint_of(theme.dark.colors.value, widgets.track_radius),
            .knob = widgets.paint_of(theme.dark.colors.control, widgets.knob_radius),
        };
        for (&app.knobs, knob_names, 0..) |*knob, name, index| {
            const id = ui.id("knob", @intCast(index));
            knob.* = widgets.Knob.init(id, name, 0.5, widgets.accents[index % widgets.accents.len]);
        }
        app.writes = 0;
        for (&app.patch, &app.sources, 0..) |*row, *source, index| {
            row.* = app.row_named(patch.destinations[index].source);
            const id = ui.id("source", @intCast(index));
            source.* = button(id, app.motion.signals.rows[row.*].name, source_style, source_paint);
        }
    }

    /// The index of the row named `name`, which must exist.
    pub fn row_named(app: *const App, name: []const u8) u8 {
        for (app.motion.signals.rows, 0..) |row, index| {
            if (std.mem.eql(u8, row.name, name)) return @intCast(index);
        }
        unreachable;
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        if (app.play.handle(cx, event_value) == .clicked) app.toggle(cx);
        if (app.page_button.handle(cx, event_value) == .clicked) app.show(cx, app.page.next());
        switch (app.scrub.handle(cx, event_value)) {
            .changed => |value| {
                app.playing = false;
                app.clock.seek(value);
                cx.redraw();
            },
            .none, .released => {},
        }
        for (&app.knobs, 0..) |*knob, index| switch (knob.handle(cx, event_value)) {
            .changed, .reset => |value| {
                if (app.motion.write(index, app.clock, knob_param(index, value))) app.writes += 1;
                cx.redraw();
            },
            .none, .released => {},
        };
        for (&app.patch, &app.sources) |*row, *source| {
            if (source.handle(cx, event_value) != .clicked) continue;
            row.* = app.next_source(row.*);
            source.label = app.motion.signals.rows[row.*].name;
            cx.redraw();
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
            .end => app.clock.seek(1),
            .left => app.clock.step(-step_ms),
            .right => app.clock.step(step_ms),
            .page_up => app.clock.step(-page_ms),
            .page_down => app.clock.step(page_ms),
            .other => {
                const typed = press.typed();
                if (std.mem.eql(u8, typed, " ")) return app.toggle(cx);
                if (std.mem.eql(u8, typed, "1")) return app.show(cx, .scope);
                if (std.mem.eql(u8, typed, "2")) return app.show(cx, .shapes);
                if (std.mem.eql(u8, typed, "3")) return app.show(cx, .bouncers);
                return;
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

    fn show(app: *App, cx: *Context, page: Page) void {
        app.page = page;
        cx.redraw();
    }

    fn at_end(app: *const App) bool {
        return app.clock.millis() == glue.timeline_ms;
    }

    /// The row after `row` with a finite range, wrapping (section 5).
    pub fn next_source(app: *const App, row: u8) u8 {
        var next = row;
        for (0..glue.row_count) |_| {
            next = @intCast((next + 1) % glue.row_count);
            const range = app.motion.ranges[next];
            if (std.math.isFinite(range[0]) and std.math.isFinite(range[1])) return next;
        }
        unreachable;
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const clip: Clip = .{ .x0 = 0, .y0 = 0, .x1 = cx.window.width, .y1 = cx.window.height };
        app.draw_transport(cx, clip);
        app.motion.sample_head(app.clock, &app.frame);
        switch (app.page) {
            .scope => app.draw_scope(cx, clip),
            .shapes => app.draw_shapes(cx, clip),
            .bouncers => app.draw_bouncers(cx, clip),
        }
    }

    fn draw_scope(app: *App, cx: *Context, clip: Clip) void {
        app.motion.sample_window(app.clock, &app.frame);
        app.row_dot_counts = @splat(0);
        for (app.frame.dots[0..app.frame.dot_count]) |dot| {
            const count = &app.row_dot_counts[dot.row];
            app.row_dots[dot.row][count.*] = .{ dot.at, dot.value };
            count.* += 1;
        }
        for (0..glue.scope_row_count) |index| {
            const rect: Rect = .{
                .x = 0,
                .y = transport_height + row_height * @as(f32, @floatFromInt(index)),
                .width = cx.window.width,
                .height = row_height,
            };
            scope.draw(cx, app.scope_row(index), rect, clip);
        }
    }

    fn draw_shapes(app: *App, cx: *Context, clip: Clip) void {
        const values = app.destination_values();
        for (&app.knobs, 0..) |*knob, index| {
            knob.value = knob_value(index, app.motion.knob(index, app.clock));
            var buffer: [16]u8 = undefined;
            const shown = app.knob_text(index, &buffer);
            _ = cx.begin_at(knob_rect(index), .{ .flow = .down });
            knob.draw_text(cx, ui.sized(.fill, .fill), shown);
            _ = cx.end();
        }
        for (&app.sources, patch.destinations, values, 0..) |*source, destination, value, index| {
            const rect = patch_rect(index);
            const name: Rect = .{ .x = rect.x, .y = rect.y, .width = 120, .height = rect.height };
            text.place(cx.drawing(), name_style, destination.name, name, clip, left);
            const at: Rect = .{ .x = rect.x + 128, .y = rect.y + 2, .width = 112, .height = 28 };
            _ = cx.begin_at(at, .{ .flow = .down });
            source.draw(cx, ui.sized(.fill, .fill));
            _ = cx.end();
            const share = (value - destination.low) / (destination.high - destination.low);
            const track: Rect = .{ .x = rect.x + 248, .y = rect.y + 12, .width = 88, .height = 8 };
            var bar = track;
            bar.width = track.width * share;
            const row_accent = accent(app.motion.signals.rows[app.patch[index]].accent);
            box(cx, track, clip, theme.dark.colors.track, 4);
            if (bar.width > 0) box(cx, bar, clip, row_accent, 4);
        }
        var accents: [4][4]f32 = undefined;
        for (&accents, 0..) |*color, index| color.* = accent(@intCast(index));
        shapes.draw(cx, &values, accents, clip);
    }

    fn draw_bouncers(app: *App, cx: *Context, clip: Clip) void {
        app.motion.sample_hits(app.clock, &app.hits);
        const hits = &app.hits;
        for (app.motion.bouncers.lanes, 0..) |lane, index| {
            var points: [bouncers.points_max][2]f32 = undefined;
            const ends = hits.ends[index];
            const window = hits.window[0..hits.window_count];
            const rect = bouncers.lane_rect(transport_height, cx.window.width, index);
            bouncers.draw(cx, .{
                .name = lane.name,
                .note = lane.note,
                .color = accent(lane.accent),
                .points = bouncers.polyline(ends[0], ends[1], window, index, &points),
                .bars = hits.bars[0..hits.bar_count],
                .head_at = head_at,
                .head = hits.heads[index],
                .flash = bouncers.flash(hits.since[index]),
                .high = hits.last_high[index],
            }, rect, clip);
        }
        var buffers: [bouncers.log_lines][line_cap]u8 = undefined;
        var lines: [bouncers.log_lines][]const u8 = undefined;
        const recent = hits.recent[0..hits.recent_count];
        const shown = @min(recent.len, bouncers.log_lines);
        for (lines[0..shown], buffers[0..shown], 0..) |*line, *buffer, index| {
            line.* = app.log_line(recent[recent.len - 1 - index], buffer);
        }
        bouncers.draw_log(cx, lines[0..shown], cx.window.width, clip);
    }

    /// A hit as a line of the log: seconds to nine places, flicks, the lane, the wall, the value.
    pub fn log_line(app: *const App, hit: glue.Hit, out: *[line_cap]u8) []const u8 {
        assert(hit.flicks >= 0);
        const flicks: u64 = @intCast(hit.flicks);
        const per_second: u64 = glue.flicks_per_second;
        const seconds = @as(f64, @floatFromInt(flicks)) / @as(f64, @floatFromInt(per_second));
        var grouped: [32]u8 = undefined;
        const lane = app.motion.bouncers.lanes[hit.lane];
        const wall = if (hit.high) "high" else "low";
        const sign: u8 = if (hit.high) '+' else '-';
        const args = .{ seconds, group(flicks, &grouped), lane.name, wall, sign, lane.speed };
        const format = "{d:>13.9} s  {s:>15} fl   {s:<4} {s:<5} {c}{d:.2}";
        return std.fmt.bufPrint(out, format, args) catch unreachable;
    }

    /// Every destination's value at the playhead, through its source's range (section 5).
    pub fn destination_values(app: *const App) [patch.count]f32 {
        var values: [patch.count]f32 = undefined;
        for (&values, patch.destinations, app.patch) |*value, destination, row| {
            value.* = patch.map(destination, app.frame.heads[row], app.motion.ranges[row]);
        }
        return values;
    }

    /// Knob `index`'s parameter at t, to two decimals.
    fn knob_text(app: *const App, index: usize, out: *[16]u8) []const u8 {
        const value = app.motion.knob(index, app.clock);
        return std.fmt.bufPrint(out, "{d:.2}", .{value}) catch unreachable;
    }

    fn draw_transport(app: *App, cx: *Context, clip: Clip) void {
        app.play.label = if (app.playing) "pause" else "play";
        app.page_button.label = @tagName(app.page.next());
        app.scrub.value = app.clock.fraction();
        _ = cx.begin_at(play_rect, .{ .flow = .down });
        app.play.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        _ = cx.begin_at(page_rect, .{ .flow = .down });
        app.page_button.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        _ = cx.begin_at(scrub_rect, .{ .flow = .down });
        app.scrub.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        var buffer: [line_cap]u8 = undefined;
        text.place(cx.drawing(), label_style, app.label(&buffer), label_rect, clip, left);
    }

    /// The transport label: the page, `t` to the millisecond, then the report.
    pub fn label(app: *const App, out: *[line_cap]u8) []const u8 {
        const ms: u64 = @intCast(app.clock.millis());
        const report = if (app.page == .bouncers) app.motion.bouncer_report else app.motion.report;
        const seekable = if (report.seekable) "seekable" else "not seekable";
        const name = if (report.first) |index| app.motion.signals.rows[index].name else "";
        assert(report.stepped == (report.first != null));
        const stepped = if (report.stepped) ", stepped from " else "";
        const page = @tagName(app.page);
        const args = .{ page, @divFloor(ms, 1000), @mod(ms, 1000), seekable, stepped, name };
        return std.fmt.bufPrint(out, "{s}   t {d}.{d:0>3} s   {s}{s}{s}", args) catch unreachable;
    }

    /// Row `index` of the scope, from the last sampled frame.
    fn scope_row(app: *const App, index: usize) scope.Row {
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
            .dots = app.row_dots[index][0..app.row_dot_counts[index]],
        };
    }
};

fn button(id: ui.Id, name: []const u8, style: text.Style, paint: widgets.Paint) widgets.Button {
    return .{
        .id = id,
        .label = name,
        .style = style,
        .padding = .xy(8, 0),
        .paint = paint,
        .hover = .init(widgets.hover_rate_per_ms),
        .down = .init(widgets.down_rate_per_ms),
    };
}

/// `value` in decimal with a comma every three digits, as the log shows flicks.
pub fn group(value: u64, out: *[32]u8) []const u8 {
    var digits: [24]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
    var count: usize = 0;
    for (plain, 0..) |digit, index| {
        if (index > 0 and (plain.len - index) % 3 == 0) {
            out[count] = ',';
            count += 1;
        }
        out[count] = digit;
        count += 1;
    }
    assert(count <= out.len);
    return out[0..count];
}

fn box(cx: *Context, rect: Rect, clip: Clip, color: [4]f32, radius: f32) void {
    cx.append(quads.Box, null, .of(rect, clip, .{ .fill = color, .radius = radius })) catch {};
}

fn accent(index: u8) [4]f32 {
    const paint = widgets.accents[index % widgets.accents.len];
    return .{ paint.r, paint.g, paint.b, paint.a };
}

comptime {
    assert(glue.sample_count == quads.path.plot_samples_max);
    const Steps = @typeInfo(@FieldType(glue.Frame, "steps")).array.child;
    assert(@typeInfo(Steps).array.len <= scope.steps_max);
    assert(scrub_rect.x + scrub_rect.width < label_rect.x);
    assert(transport_height + glue.scope_row_count * row_height <= 720);
    assert(patch_y + patch.count * patch_pitch <= 720);
    assert(transport_height + glue.lane_count * bouncers.lane_height <= bouncers.log_y);
    assert(bouncers.log_y + bouncers.log_lines * bouncers.log_pitch <= 720);
    assert(knob_y + knob_pitch[1] + widgets.knob_height <= patch_y);
    assert(glue.row_count <= std.math.maxInt(u8));
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

fn replay(app: *App, name: []const u8, steps_limit: u32) !void {
    for (App.scenarios) |*scenario| {
        if (!std.mem.eql(u8, scenario.name, name)) continue;
        const cx = &fixture.context;
        const bench = patchwork.bench;
        const size = .{ 1280, 720 };
        _ = try bench.replay_headless_paced(App, app, cx, scenario, size, steps_limit, 16);
        return;
    }
    unreachable;
}

test {
    _ = glue;
    _ = scope;
    _ = patch;
    _ = shapes;
    _ = bouncers;
}

// Locks the transport's ends: playing stops at 600 s and play from there restarts at 0, and a
// paused frame asks for no redraw and no further frame.
test "playing stops at the end and starts again from zero" {
    const app = new_app();
    const cx = frame_at(app);
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    try std.testing.expect(!cx.dirty);
    send(app, key_down(.end, ""));
    send(app, key_down(.left, ""));
    try std.testing.expectEqual(@as(i64, glue.timeline_ms - step_ms), app.clock.millis());
    send(app, key_down(.other, " "));
    try std.testing.expect(app.playing);
    var frames: u32 = 0;
    while (ui.animate(App, app, cx, 50)) : (frames += 1) {
        try std.testing.expect(frames < 100);
        _ = frame_at(app);
    }
    try std.testing.expect(!app.playing);
    try std.testing.expectEqual(@as(i64, glue.timeline_ms), app.clock.millis());
    try std.testing.expectEqual(@as(u32, 1), frames);
    _ = frame_at(app);
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    try std.testing.expect(!cx.dirty);
    send(app, key_down(.other, " "));
    try std.testing.expect(app.playing);
    try std.testing.expectEqual(@as(i64, 0), app.clock.millis());
    try std.testing.expect(ui.animate(App, app, cx, 250));
    try std.testing.expectEqual(@as(i64, 100), app.clock.millis());
}

// Locks the keys: Home and End, the arrows by 100 ms, and Page Up and Down by 10 s, all clamped;
// 1 and 2 and the page button switch pages, and the shapes page, paused, asks for no frame.
test "the keys move along the timeline and switch pages" {
    const app = new_app();
    send(app, key_down(.left, ""));
    try std.testing.expectEqual(@as(i64, 0), app.clock.millis());
    send(app, key_down(.right, ""));
    send(app, key_down(.right, ""));
    try std.testing.expectEqual(@as(i64, 200), app.clock.millis());
    send(app, key_down(.page_down, ""));
    try std.testing.expectEqual(@as(i64, 10_200), app.clock.millis());
    send(app, key_down(.page_up, ""));
    send(app, key_down(.page_up, ""));
    try std.testing.expectEqual(@as(i64, 0), app.clock.millis());
    send(app, key_down(.end, ""));
    send(app, key_down(.page_down, ""));
    try std.testing.expectEqual(@as(i64, glue.timeline_ms), app.clock.millis());
    send(app, key_down(.home, ""));
    try std.testing.expectEqual(@as(i64, 0), app.clock.millis());
    send(app, key_down(.other, "2"));
    try std.testing.expectEqual(Page.shapes, app.page);
    const cx = frame_at(app);
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    try std.testing.expect(!cx.dirty);
    send(app, key_down(.other, "1"));
    try std.testing.expectEqual(Page.scope, app.page);
    _ = frame_at(app);
    const page = fixture.context.find(ui.id("page", 0)).?;
    const at: input.Button = .{
        .x = page.rect[0] + 10,
        .y = page.rect[1] + 10,
        .time_ms = 0,
        .button = .left,
        .mods = .none,
    };
    send(app, .{ .pointer_down = at });
    send(app, .{ .pointer_up = at });
    try std.testing.expectEqual(Page.shapes, app.page);
}

// Locks the label and the report: the page, seekable, stepped, and the chase named first.
test "the label shows the page, the time, and the report" {
    const app = new_app();
    app.clock.seek(0.5);
    var buffer: [line_cap]u8 = undefined;
    const expected = "scope   t 300.000 s   seekable, stepped from chase";
    try std.testing.expectEqualStrings(expected, app.label(&buffer));
}

// Locks the scrub clicks: `scrub` lands on 300 s exactly and pauses, `scrub_back` near 500 s first.
test "the scrub scenarios land where their clicks map" {
    var app = new_app();
    send(app, key_down(.other, " "));
    try replay(app, "scrub", 1);
    try std.testing.expectEqual(@as(i64, 300_000), app.clock.millis());
    try std.testing.expect(!app.playing);
    app = new_app();
    try replay(app, "scrub_back", 1);
    try std.testing.expectEqual(@as(i64, 499_675), app.clock.millis());
}

/// Copies of two frames' Path instances and point pools, static for their size.
const frozen = struct {
    var copies: [2][2][128 * 1024]u8 = undefined;
};

// Locks the picture after a scrub back: `scrub_back` ends with the very Path instances, point
// pool, and dots `scrub` does, byte for byte, though its scope reader came from 500 s and its
// checkpoints: the dots are re-derived from the graph, not kept.
test "scrubbing back draws the same picture" {
    const cx = &fixture.context;
    var paths: [2][]const u8 = undefined;
    var points: [2][]const u8 = undefined;
    var dots: [2][glue.dots_max]glue.Dot = undefined;
    var dot_counts: [2]u32 = undefined;
    const copies = &frozen.copies;
    for ([_][]const u8{ "scrub", "scrub_back" }, 0..) |name, index| {
        const app = new_app();
        try replay(app, name, 64);
        _ = frame_at(app);
        try std.testing.expectEqual(@as(i64, 300_000), app.clock.millis());
        const path_bytes = std.mem.sliceAsBytes(cx.draw.items(quads.Path));
        const point_bytes = std.mem.sliceAsBytes(cx.draw.points[0..cx.draw.point_count]);
        @memcpy(copies[index][0][0..path_bytes.len], path_bytes);
        @memcpy(copies[index][1][0..point_bytes.len], point_bytes);
        paths[index] = copies[index][0][0..path_bytes.len];
        dots[index] = app.frame.dots;
        dot_counts[index] = app.frame.dot_count;
        points[index] = copies[index][1][0..point_bytes.len];
    }
    try std.testing.expect(paths[0].len > 0);
    try std.testing.expectEqualSlices(u8, paths[0], paths[1]);
    try std.testing.expectEqualSlices(u8, points[0], points[1]);
    try std.testing.expect(dot_counts[0] > 8);
    const bytes = std.mem.sliceAsBytes;
    const kept = .{ dots[0][0..dot_counts[0]], dots[1][0..dot_counts[1]] };
    try std.testing.expectEqualSlices(u8, bytes(kept[0]), bytes(kept[1]));
}

// Locks the knob maps: every knob at 0.5 gives its track's default exactly, the map and its
// inverse agree, and the `knob` scenario's drag of 30 px at 2 s puts `chase s` at 0.75, which is
// 1 s exactly, written once at 2 s and nowhere else.
test "the knobs give their defaults at 0.5 and 1 s at 0.75" {
    for (0..knob_count) |index| {
        try std.testing.expectEqual(knob_middles[index], knob_param(index, 0.5));
        try std.testing.expectEqual(@as(f32, 0.5), knob_value(index, knob_middles[index]));
        try std.testing.expectEqual(@as(f32, 0.75), knob_value(index, knob_param(index, 0.75)));
    }
    var app = new_app();
    try replay(app, "knob", 22);
    try std.testing.expectEqual(@as(i64, 2000), app.clock.millis());
    try std.testing.expectEqual(@as(f32, 0.75), app.knobs[1].value);
    try std.testing.expectEqual(@as(f64, 1), app.motion.knob(1, app.clock));
    try std.testing.expectEqual(@as(u32, 1), app.writes);
    var before = app.clock;
    before.step(-1);
    try std.testing.expectEqual(@as(f64, 0.5), app.motion.knob(1, before));
    app = new_app();
    try replay(app, "knob", 64);
    try std.testing.expectEqual(Page.scope, app.page);
}

// Locks what a knob means: a turn at 10 s leaves the program and every value before 10 s as they
// were, bit for bit, changes what follows, and the knob shows the value played at each time: its
// default at 5 s, its turn at 12 s. A right press at 12 s resets it from 12 s on, not before.
test "a knob applies from now on and shows what was played" {
    const app = new_app();
    send(app, key_down(.other, "2"));
    send(app, key_down(.page_down, ""));
    _ = frame_at(app);
    const nodes = app.motion.signals.program.nodes.ptr;
    var five: glue.Clock = .{};
    five.step(5000);
    var twelve: glue.Clock = .{};
    twelve.step(12_000);
    app.motion.sample_head(five, &app.frame);
    const at_five = app.frame.heads;
    app.motion.sample_head(twelve, &app.frame);
    const at_twelve = app.frame.heads;
    const knob = fixture.context.find(ui.id("knob", 0)).?;
    const down: input.Button = .{
        .x = knob.rect[0] + 40,
        .y = knob.rect[1] + 36,
        .time_ms = 0,
        .button = .left,
        .mods = .none,
    };
    send(app, .{ .pointer_down = down });
    var moved = down;
    moved.y -= 60;
    send(app, .{ .pointer_move = .{ .x = moved.x, .y = moved.y } });
    send(app, .{ .pointer_up = moved });
    try std.testing.expect(app.writes >= 1);
    try std.testing.expectEqual(nodes, app.motion.signals.program.nodes.ptr);
    app.motion.sample_head(five, &app.frame);
    try std.testing.expectEqualSlices(f32, &at_five, &app.frame.heads);
    app.motion.sample_head(twelve, &app.frame);
    try std.testing.expect(!std.mem.eql(f32, &at_twelve, &app.frame.heads));
    app.clock = five;
    _ = frame_at(app);
    try std.testing.expectEqual(@as(f32, 0.5), app.knobs[0].value);
    app.clock = twelve;
    _ = frame_at(app);
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].value);
    var right_press = down;
    right_press.button = .right;
    send(app, .{ .pointer_down = right_press });
    send(app, .{ .pointer_up = right_press });
    try std.testing.expectEqual(knob_middles[0], app.motion.knob(0, twelve));
    var eleven: glue.Clock = .{};
    eleven.step(11_000);
    try std.testing.expectEqual(knob_param(0, 1), app.motion.knob(0, eleven));
}

// Locks re-pointing: a click on lines.width's source button moves it to the next row and leaves
// the program and both readers as they were, and the destination reads the new row's value. The
// chase, with no finite range, is skipped.
test "re-pointing a destination does not touch the program" {
    const app = new_app();
    send(app, key_down(.other, "2"));
    send(app, key_down(.page_down, ""));
    _ = frame_at(app);
    const nodes = app.motion.signals.program.nodes.ptr;
    const steps_run = .{ app.motion.readers[0].steps_run, app.motion.readers[1].steps_run };
    const width = @backingInt(patch.Dest.lines_width);
    try std.testing.expectEqualStrings("pulse", app.motion.signals.rows[app.patch[width]].name);
    try replay(app, "repoint", 3);
    try std.testing.expectEqualStrings("soft", app.motion.signals.rows[app.patch[width]].name);
    try std.testing.expectEqualStrings("soft", app.sources[width].label);
    try std.testing.expectEqual(nodes, app.motion.signals.program.nodes.ptr);
    try std.testing.expectEqual(steps_run[0], app.motion.readers[0].steps_run);
    try std.testing.expectEqual(@as(u32, 0), app.writes);
    const newtonian = app.row_named("newtonian");
    const after_newtonian = app.motion.signals.rows[app.next_source(newtonian)];
    try std.testing.expectEqualStrings("follow", after_newtonian.name);
    _ = frame_at(app);
    const row = app.patch[width];
    const range = app.motion.ranges[row];
    const expected = patch.map(patch.destinations[width], app.frame.heads[row], range);
    try std.testing.expectEqual(expected, app.destination_values()[width]);
}

// Locks the range proof: every row with a finite range, pointed at every destination, every
// quarter second of the 600 s, sits inside its declared range (`patch.fraction` asserts it), so
// every destination stays in its own range. The knobs are written along the way, at their ends.
test "every destination stays in its range for every source" {
    const app = new_app();
    var clock: glue.Clock = .{};
    var turns: u32 = 0;
    while (true) : (clock.step(250)) {
        if (@mod(clock.millis(), 37_000) == 0) {
            turns += 1;
            for (0..knob_count) |index| {
                const extreme: f32 = if ((turns + index) % 2 == 0) 0 else 1;
                try std.testing.expect(app.motion.write(index, clock, knob_param(index, extreme)));
            }
        }
        app.motion.sample_head(clock, &app.frame);
        for (app.frame.heads, app.motion.ranges) |value, range| {
            if (!std.math.isFinite(range[0]) or !std.math.isFinite(range[1])) continue;
            for (patch.destinations) |destination| {
                const mapped = patch.map(destination, value, range);
                try std.testing.expect(mapped >= destination.low and mapped <= destination.high);
            }
        }
        if (clock.millis() == glue.timeline_ms) break;
    }
}

// Locks the scenarios without a GPU (`patchwork.bench`, section 2a): none refuses a draw.
// `knob_600` reads 600 s cold once, so it runs its setup and two drags.
test "the scenarios replay headless" {
    for (App.scenarios) |scenario| {
        const app = new_app();
        // These read 590 s or 600 s cold once, so they run their setup and a few frames.
        const cold = std.mem.endsWith(u8, scenario.name, "_600") or
            std.mem.endsWith(u8, scenario.name, "_590");
        const limit: u32 = if (cold) 6 else 200;
        try replay(app, scenario.name, limit);
        try std.testing.expectEqual(@as(u32, 0), fixture.context.draw.overflow_count);
    }
}

// Locks the pages: the page button cycles scope, shapes, bouncers and names the next page; 3 goes
// to the bouncers, whose label reports their own program, seekable with no steps, and which,
// paused, ask for no frame.
test "the page button cycles the three pages" {
    const app = new_app();
    const order = [_]Page{ .shapes, .bouncers, .scope };
    for (order) |expected| {
        _ = frame_at(app);
        try std.testing.expectEqualStrings(@tagName(expected), app.page_button.label);
        const page = fixture.context.find(ui.id("page", 0)).?;
        const at: input.Button = .{
            .x = page.rect[0] + 10,
            .y = page.rect[1] + 10,
            .time_ms = 0,
            .button = .left,
            .mods = .none,
        };
        send(app, .{ .pointer_down = at });
        send(app, .{ .pointer_up = at });
        try std.testing.expectEqual(expected, app.page);
    }
    send(app, key_down(.other, "3"));
    try std.testing.expectEqual(Page.bouncers, app.page);
    app.clock.seek(0.5);
    var buffer: [line_cap]u8 = undefined;
    try std.testing.expectEqualStrings("bouncers   t 300.000 s   seekable", app.label(&buffer));
    const idle = new_app();
    send(idle, key_down(.other, "3"));
    const cx = frame_at(idle);
    try std.testing.expect(!ui.animate(App, idle, cx, 16));
    try std.testing.expect(!cx.dirty);
}

// Locks `bouncers_300`: at 300 s six lanes have just hit the floor, so their low walls flash at
// full, and the 0.7 lane's last hit was 1.43 s before; the log's newest line is a hit at 300 s.
test "at 300 s six bouncers hit at once" {
    const app = new_app();
    try replay(app, "bouncers_300", 64);
    try std.testing.expectEqual(@as(i64, 300_000), app.clock.millis());
    try std.testing.expectEqual(Page.bouncers, app.page);
    const hits = &app.hits;
    for (1..glue.lane_count) |lane| {
        try std.testing.expectEqual(@as(f32, 1), bouncers.flash(hits.since[lane]));
        try std.testing.expect(!hits.last_high[lane]);
    }
    try std.testing.expectEqual(@as(f32, 0), bouncers.flash(hits.since[0]));
    try std.testing.expect(hits.since[0] > 1.4 and hits.since[0] < 1.43);
    var buffer: [line_cap]u8 = undefined;
    const newest = hits.recent[hits.recent_count - 1];
    const line = app.log_line(newest, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, line, "300.000000000 s  211,680,000,000 fl"));
}

// Locks the log's format on step 7's first hit, and the grouping of flicks.
test "the log shows a hit's exact time" {
    const app = new_app();
    var buffer: [line_cap]u8 = undefined;
    const hit: glue.Hit = .{ .lane = 0, .flicks = 1_008_000_001, .at = 0, .high = true };
    const expected = "  1.428571430 s    1,008,000,001 fl   0.7  high  +0.70";
    try std.testing.expectEqualStrings(expected, app.log_line(hit, &buffer));
    var grouped: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", group(0, &grouped));
    try std.testing.expectEqualStrings("999", group(999, &grouped));
    try std.testing.expectEqualStrings("1,000", group(1000, &grouped));
    try std.testing.expectEqualStrings("423,360,000,000", group(423_360_000_000, &grouped));
}
