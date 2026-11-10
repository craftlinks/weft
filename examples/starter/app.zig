//! The starter: the smallest Patchwork app that reads a Weft program.
//!
//! It shows the whole bridge between the two libraries, which never see each other:
//! 1. `motion.weft` is compiled once, at init, into a `weft.Program`.
//! 2. The app owns a clock, a `weft.Time`, and nothing else about the motion.
//! 3. Each frame, `draw` asks the program what every value is at the clock's time, and draws
//!    plain numbers with Patchwork.
//!
//! Space plays and pauses. Left and Right step 100 ms; Home goes back to 0. Because every frame is
//! a function of the time, stepping backwards needs no code of its own.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const weft = @import("weft");
const ui = patchwork.ui;
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const input = patchwork.input;
const Rect = quads.Rect;
const Clip = quads.Clip;

const Context = patchwork.app.Context(App);

// ---- The motion ----------------------------------------------------------------------------

const source = @embedFile("motion.weft");
const dot_count = 24;

/// `weft check motion.weft` prints the counts these limits must hold.
const Motion = weft.lang.Compiled(.{ .nodes = 16, .slab = 274, .cues = 4, .goals = 4 });

const flicks_per_ms = @divExact(weft.time.flicks_per_second, 1000);
const flash_ms = 200;

// ---- The app -------------------------------------------------------------------------------

pub const App = struct {
    /// The compiled file. It holds the tables its program points at, so it never moves.
    motion: Motion,
    /// One reader's memory: every node's value at the time last evaluated.
    slab: [274]f64,
    reader: weft.State,
    height: weft.Id,
    tint: weft.Id,
    marker: weft.Id,
    hop: weft.Id,
    /// The clock. The only thing about the motion that the app changes.
    t: weft.Time,
    playing: bool,

    pub const config: patchwork.app.Config = .{
        .title = "weft starter",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 64 },
            .{ .type = quads.Glyph, .cap = 256 },
        },
        .area_cap = 8,
    };

    /// Scenarios drive the app with no window: `zig build test` replays them headless, and
    /// `./zig-out/bin/starter --render play --out frames` writes their frames as PNGs.
    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 2 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 1 },
        .{ .name = "play", .setup = &.{space}, .cycle = &.{}, .frames = 150 },
    };
    const space: patchwork.bench.Step = .{ .key = .{ .key = .other, .text = " " } };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        // A file that does not compile lists what is wrong, with a line, a column, and a hint.
        app.motion.compile(source) catch {
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            for (app.motion.errors()) |found| found.render(source, "motion.weft", &writer) catch {};
            std.debug.panic("motion.weft does not compile:\n{s}", .{writer.buffered()});
        };
        const program = app.motion.program;
        assert(program.slab_count == app.slab.len);
        app.reader = .init(program, &app.slab);
        // Names are resolved once. From here on the app holds node ids.
        app.height = app.motion.signal("height").?;
        app.tint = app.motion.signal("tint").?;
        app.marker = app.motion.signal("marker").?;
        app.hop = app.motion.signal("hop").?;
        assert(app.reader.extent(app.height).lanes == dot_count);
        app.t = .{ .flicks = 0 };
        app.playing = false;
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (event_value) {
            // The transport: time comes from the frames, and the app sleeps when paused.
            .frame => |dt_ms| {
                if (!app.playing) return;
                app.t.flicks += @as(i64, @intFromFloat(@round(dt_ms))) * flicks_per_ms;
                cx.redraw();
                cx.keep_animating();
            },
            .key_down => |press| {
                switch (press.key) {
                    .home => app.t.flicks = 0,
                    .left => app.t.flicks = @max(0, app.t.flicks - 100 * flicks_per_ms),
                    .right => app.t.flicks += 100 * flicks_per_ms,
                    .other => {
                        if (!std.mem.eql(u8, press.typed(), " ")) return;
                        app.playing = !app.playing;
                    },
                    else => return,
                }
                cx.redraw();
            },
            else => {},
        }
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const clip: Clip = .{ .x0 = 0, .y0 = 0, .x1 = cx.window.width, .y1 = cx.window.height };
        const ink = theme.dark.colors.text;
        const reader = &app.reader;

        // Events first: what happened in the last `flash_ms`. Each has an exact time, so the
        // flash's age does not depend on when frames fell. A program with no stepped node may
        // read any window; a stepped one reads from the last frame's time to this one.
        var found: [8]weft.Event = undefined;
        const since: weft.Time = .{ .flicks = app.t.flicks - flash_ms * flicks_per_ms + 1 };
        const window = reader.events(since, .{ .flicks = app.t.flicks + 1 }, &found);
        var flash: f32 = 0;
        for (found[0..window.count]) |hit| {
            if (hit.source.index != app.hop.index) continue;
            const age: f32 = @floatFromInt(app.t.flicks - hit.time.flicks);
            flash = @max(flash, 1 - age / (flash_ms * flicks_per_ms));
        }

        // Then the values at t. `events` leaves the slab at no particular time, so eval follows.
        reader.eval(app.t);
        const heights = reader.values(app.height); // 24 lanes of one f64
        const tints = reader.values(app.tint); // 24 lanes of three f64: OKLab
        const marker: f32 = @floatCast(reader.value(app.marker));
        const hop: f32 = @floatCast(reader.value(app.hop));

        const field: Rect = .{ .x = 40, .y = 60, .width = 1200, .height = 520 };
        box(cx, field, clip, theme.dark.colors.panel, 8, 0, ink);
        const cell = field.width / dot_count;
        for (heights, 0..) |height, lane| {
            const rgb = weft.colour.to_srgb(tints[3 * lane ..][0..3].*);
            const tall: f32 = @floatCast(height * (field.height - 40));
            const column: f32 = @floatFromInt(lane);
            const bar: Rect = .{
                .x = field.x + column * cell + 6,
                .y = field.y + field.height - 20 - tall,
                .width = cell - 12,
                .height = tall,
            };
            if (tall < 0.5) continue;
            box(cx, bar, clip, .{ @floatCast(rgb[0]), @floatCast(rgb[1]), @floatCast(rgb[2]), 1 }, 6, 0, ink);
        }

        // The marker springs along x and bounces along y; its ring flashes at each wall.
        const side: f32 = 28;
        const dot: Rect = .{
            .x = field.x + marker * (field.width - side),
            .y = field.y + 20 + (1 - hop) * (field.height - 40 - side),
            .width = side,
            .height = side,
        };
        box(cx, dot, clip, ink, side / 2, 4 * flash, theme.dark.colors.value);

        var buffer: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "t = {d:.2} s    space: play, left/right: step, home: start", .{app.t.seconds()}) catch unreachable;
        const style: text.Style = .{ .face = .sans, .size = 14, .color = ink };
        const line_rect: Rect = .{ .x = 40, .y = 600, .width = 1200, .height = 24 };
        text.place(cx.drawing(), style, line, line_rect, clip, .{ .align_x = .start, .align_y = .center, .ellipsis = true });
    }
};

fn box(cx: anytype, rect: Rect, clip: Clip, fill: [4]f32, radius: f32, border: f32, border_color: [4]f32) void {
    const look: quads.BoxLook = .{ .fill = fill, .radius = radius, .border_width = border, .border_color = border_color };
    cx.append(quads.Box, null, .of(rect, clip, look)) catch {};
}

comptime {
    patchwork.app.check(App);
}

// ---- Tests: no window, no GPU --------------------------------------------------------------

const testing = std.testing;

// Static, like the hosts' context, so the pools stay off the stack.
const fixture = struct {
    var context: Context = undefined;
    var app: App = undefined;
};

fn new_app() *App {
    fixture.context.init();
    patchwork.app.start(App, &fixture.context);
    // The context's own textures, so an app that creates one in `init` works here too.
    App.init(&fixture.app, &fixture.context.draw.textures);
    return &fixture.app;
}

test "a frame is a function of t: forwards, backwards, and again" {
    const app = new_app();
    const second = weft.time.flicks_per_second;
    app.reader.eval(.{ .flicks = 2 * second });
    const there = app.reader.value(app.marker);
    app.reader.eval(.{ .flicks = 30 * second });
    app.reader.eval(.{ .flicks = 2 * second });
    try testing.expectEqual(there, app.reader.value(app.marker));
    // The spring is heading from 0.9 to 0.35 at 2 s; long after its last goal it rests on 0.65.
    app.reader.eval(.{ .flicks = 60 * second });
    try testing.expectEqual(@as(f64, 0.65), app.reader.value(app.marker));
}

test "the scenarios replay headless and refuse no draw" {
    for (App.scenarios) |*scenario| {
        const app = new_app();
        const cx = &fixture.context;
        _ = try patchwork.bench.replay_headless_paced(App, app, cx, scenario, .{ 1280, 720 }, 400, 16);
        try testing.expect(cx.draw.items(quads.Box).len >= 2);
    }
}
