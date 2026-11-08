//! Weft: composable motion. Motion is an object of its own, apart from whatever it moves.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Contract
//! Every frame is a function of t: a reader supplies a `Time` and gets a value, and it cannot tell
//! how the value was computed. A `Wave` is the simplest case, and a graph of them is a `Program`
//! that each reader evaluates into a `State` of its own. Signals with no closed form run on a
//! fixed step that no reader's rate can reach, so they keep the contract too. A reader can also
//! ask what happened in a range of time: events, each at an exact flick, the same however the
//! reader splits its timeline. A client can prove things without sampling: every node has a range
//! its values never leave, and the program says whether it can be reached at any time. Live input
//! is the one exception to the contract, and the program names it.
//!
//! ## 2. Rules That Hold From the First File
//! - Weft imports nothing but `std`, and links nothing. A client glues it to a destination.
//! - Everything here is realtime-safe: no allocation, no locks, no unbounded work.
//! - A sampled signal has the same bits on native and wasm, which `zig build regress` enforces.

pub const cue = @import("core/cue.zig");
pub const ease = @import("core/ease.zig");
pub const elementary = @import("core/elementary.zig");
pub const event = @import("core/event.zig");
pub const graph = @import("core/graph.zig");
pub const motion = @import("core/motion.zig");
pub const noise = @import("core/noise.zig");
pub const range = @import("core/range.zig");
pub const recording = @import("core/recording.zig");
pub const simulation = @import("core/simulation.zig");
pub const time = @import("core/time.zig");
pub const track = @import("core/track.zig");
pub const wave = @import("core/wave.zig");
pub const lang = @import("lang/lang.zig");

pub const Cue = cue.Cue;
pub const Cues = cue.Cues;
pub const Ease = ease.Ease;
pub const Builder = graph.Builder;
pub const Bounce = graph.Bounce;
pub const Chase = graph.Chase;
pub const Class = range.Class;
pub const Crossing = graph.Crossing;
pub const CueSpan = graph.CueSpan;
pub const Event = event.Event;
pub const Events = event.Events;
pub const Extent = graph.Extent;
pub const Follow = graph.Follow;
pub const Id = graph.Id;
pub const Input = graph.Input;
pub const MoverFrom = graph.MoverFrom;
pub const Node = graph.Node;
pub const Oscillator = graph.Oscillator;
pub const Program = graph.Program;
pub const Range = range.Range;
pub const Report = range.Report;
pub const Shift = graph.Shift;
pub const State = graph.State;
pub const Tween = graph.Tween;
pub const Goal = motion.Goal;
pub const Goals = motion.Goals;
pub const Newtonian = motion.Newtonian;
pub const Path = motion.Path;
pub const Spring = motion.Spring;
pub const Noise = noise.Noise;
pub const Clip = recording.Clip;
pub const Recording = recording.Recording;
pub const Sample = recording.Sample;
pub const Samples = recording.Samples;
pub const Region = simulation.Region;
pub const Regions = simulation.Regions;
pub const Span = simulation.Span;
pub const Rate = time.Rate;
pub const Track = track.Track;
pub const TrackId = track.TrackId;
pub const Tracks = track.Tracks;
pub const Time = time.Time;
pub const Shape = wave.Shape;
pub const Wave = wave.Wave;

test {
    _ = cue;
    _ = ease;
    _ = elementary;
    _ = event;
    _ = graph;
    _ = motion;
    _ = noise;
    _ = range;
    _ = recording;
    _ = simulation;
    _ = time;
    _ = track;
    _ = wave;
    _ = lang;
}
