# Agent log: building the swarm page from `docs/agents.md`

Task: add a seventh Play page, key 7, named after `lanes`, running `play/swarm.weft`, using only the
repository, its docs, and the `weft` command. The page: 48 dots, each a `follow` of its own x and y
(`lanes(48, follow(...))`), trailed by a ghost (`chase` of the follower), ringed while a `crossing`
gate on its x reads 1. Stepped (simulated) lanes, which no existing page shows.

Counts: about 14 `zig build test` runs in `play/` (2 ReleaseFast), 9 `weft check`/`sample` runs,
3 regress runs (2 full, about 97 s each, 1 `--render` pair), 1 `zig build` at the root.
Marks: **guess**, **workaround**, **missing**, **wrong**.

## Entries

1. **Choosing the idea (guess).** `docs/agents.md` says what the page parts are but not which
   Weft ideas Play already shows. I read the six `.weft` files and `describe` to find what none
   uses: a simulated program in lanes, `chase` of a lane signal, `crossing` in lanes. Nothing in the
   docs says whether `follow`, `chase`, or `crossing` take lanes; I wrote it and `check` said
   `ok: 15 nodes ... seekable, stepped`, `sample` printed `"lanes":48`. It worked first try, but
   `describe` says nothing of lanes behaviour per primitive: README's lanes section lists
   noise, follower, shift, delay, wave, tween, spring, newtonian, bounce and "anything else has the
   most lanes of what it reads". Whether `crossing` and `chase` count as "anything else" had to be
   tried. **missing**: a `lanes` field per primitive in `describe` (`own`, `stagger`, `inherits`).

2. **Slab count is not printed by `check` (wrong).** `agents.md` section 3 says the counts in
   `signals.zig` are exact: "compile once with `weft check`, then assert what it prints". `check`
   prints the node count only (`ok: 15 nodes, 1 cues, 0 tracks, seekable, stepped`), not the slab
   count, and `Compiled`'s `.slab` limit is needed for it. Workaround: set `.slab = 100000`, a
   throwaway test printing `program.slab_count` (3748 at 96 lanes), then fit it. When I cut to 48 lanes
   I guessed `39 * lanes + 4 = 1876` from the first number (3748 = 39 * 96 + 4), and it held, but that
   formula is mine. **missing**: `check` printing the slab count (and the cue, goal, region, track
   counts the `Limits` need).

3. **`Limits` fields by trial (guess).** `tokens`, `tree`, `names` (1024, 512, 32) were guessed from the
   lanes page's (512, 256, 16) by doubling. `.regions`: I set 4, then found 0 gives `thread panic:
   attempt to unwrap error: Invalid`, 2 passes and 1 passes (the two followers share one
   `[-1..1]` region). **wrong**-ish: `Build.compile(...) catch unreachable` throws away the checked
   file's errors and hints, so an under-sized limit is `Invalid` with no word about which limit,
   while the docs section 1 says errors come with hints. The `raise Limits.nodes` hints I
   saw in `src/lang/graph.zig` exist but never print here. **missing**: a helper that prints
   `compiled.errors` in `build` before `unreachable`, or a Limits table in `agents.md`.
   Source read: grep of `src/lang/*.zig` for `Limits` and `lang.zig` lines 95-110 (the `Limits`
   struct and its defaults), to see which fields exist. Reason: the error said nothing.

4. **`sample` events: source is a node index, time is flicks, no value (missing).** `sample` prints
   events as `{"t":1470000,"source":1,"instance":56}`. `t` is flicks (the docs say sample's `--from`
   and `--to` are seconds; here a plain `1` was a flick, not a second). `source` is the node
   index, with no name and no listing of node index to signal name. I had to guess that `source: 14`
   was `gate` (node order: it was my last declaration, the 15th node, but `follow`'s lane
   arrivals were nodes 0 and 1 and I confirmed by counting). The `value` field (`event.value`,
   which glue.zig uses for hit direction) is not printed at all. **missing**: names in events,
   seconds as well as flicks, and `value`.

5. **A crossing's first event is at t = 1 flick (guess).** With `level: 0` and every follower
   starting at 0, the gate starts 1 (at or above) and all 96 lanes fire at t=1. The README's "1 at
   or above the level" says so, but a reader does not expect 96 events at the first flick. I moved the
   level to 0.25. Also: `direction` changes events only; the gate value is the same either way (I
   tested by `sample` against `wander_x`). Not in `describe` or the README.

6. **Stepped programs and the events window (missing; cost me a redesign).** The lanes page reads
   its events as `(t - 250 ms, t]`. I copied that for the swarm, whose program is stepped. At 96 lanes
   the frame cost 5.9 ms at 60 s and 6.4 ms at 600 s: the window starts behind the last eval, so each
   frame restores a checkpoint (up to a second back) and re-steps. The README's "Evals and events on
   one reader" says an interleaved reader should read `(s, s']`, but a flash that fades needs
   history, which that does not give. Nothing says "do not read a window behind the playhead on a
   stepped program" or what it costs. I dropped events from this page and show the gate's value
   (lit while past the line) and cut to 48 lanes. **missing**: a sentence in `agents.md` section 3 and
   a cost note in the README; ideally a way to ask a reader for events without the rewind (a second
   reader kept at the window's start would also rewind).

7. **Report and the label (wrong).** `agents.md` lists "the label's report" as plain wiring. The
   label asserts `report.stepped == (report.first != null)`, where `first` is a row of the scope's
   signal table (`glue.Report.first: ?usize`), so no own-program page can be stepped: the test crashed
   at `app.zig:1055` (`assert(report.stepped == (report.first != null))`). Workaround: the label
   names `wander_x` for the swarm and the assert allows `.swarm`. Source read: `src/core/graph.zig`
   `Program.report`, lines 940-966, to see whether it names the node (it does: `first_simulated: ?Id`,
   which Play's `Report` drops). **missing**: Play's `Report` should carry a name, not a row.

8. **First seek to the end of a stepped page (missing).** The cost test the guide describes (seek, then
   20 frames of 0 or 16 ms forward) measures playing on, which costs 57 us at 60 s and 17 us at 600 s,
   well under 1 ms. It hides the first frame after a seek, which runs every step from 0: 160 ms at
   60 s and 1.44 s at 600 s, printed apart by my test. That is a real freeze when a user presses End,
   and only once (the checkpoints fill); later jumps cost at most 479 steps, about 2.5 ms. Not
   fixed: it is the program's cost (48 lanes, 8 stepped nodes). The README says "evaluating the latest
   time once, while loading, fills them all", but not that Play does not. **missing**: a warm-up
   in `Motion.build`, or a line in the guide; I did not add one (it would be a second freeze at
   start).

9. **`slab` memory for the checkpoints (guess).** A stepped page needs `(1 + checkpoint_seconds) * slab`
   f64 of memory (604 checkpoints of 1876 f64: about 9 MB). The guide does not say how the page
   gets it; I read `Motion.memory` in `glue.zig` and added a `swarm_memory` field. The `agents.md`
   page for "its reader and slab are `Motion` fields" does not mention checkpoints at all.

10. **Faster loop than the 97 s regress (missing).** `agents.md` says `zig build regress` and then
    bless. `play --regress --only NAME` and `play --render NAME --out DIR` exist (found in
    `patchwork/src/bench.zig`'s usage text, via `play --help`), not in the guide.
    The goldens are hashes: to see that `lanes` changed only in its button I had to build the old tree
    (`git archive HEAD` into the scratchpad, a symlink for `../patchwork`), render the old frame with
    `--render`, and diff with ImageMagick: 47 x 12 px at (124, 21), inside the button. The task text
    asks for that check; the guide has no tool for it. **missing**: `--regress` keeping the old image
    on a change (`.old.png` beside `.new.png`).

11. **The glue budget (wrong).** README: "The glue has a budget of 60 lines of code". `glue.zig` is over a
    thousand lines and nothing counts them; I added about 40. Harmless, but it reads as a rule.

12. **`zig build test` prints `failed command` after a pass (workaround).** After a test that
    `debug.print`s (my first probe, and the ReleaseFast cost tests) the build prints `failed command: ./.zig-cache/.../test ...`
    though all tests pass, and the first one I could not reproduce with no output. Ignore it;
    it cost me a few minutes.

13. **Helpers copied by hand (guess).** `signals.ms`, `one_after`, and the pattern of the `Report` were
    found in `glue.zig`, not in the guide. The guide's page recipe leaves out that the draw functions
    and `Page` struct have no shared helpers: `within`, `box`, and `with_alpha` are copied into each drawing
    file (`field.zig`, `vectors.zig`, now `swarm.zig`).

14. **`polyline` for a thread each lane (ok).** 48 two-point polylines and the boxes fit `App.config`
    caps (Box 2304, Path 1024, `batch_cap` 32) with no refusal, so I did not raise a pool. I had worried about
    `batch_cap = 32`; the tests would have said.

## Source reads (all of them)

- `cli/commands.zig`, lines 295-330: how `sample` prints events (entry 4). Not `src/`.
- `src/lang/lang.zig`, `Limits` fields and `grep Limits src/lang/*.zig` (entry 3): `src/lang`, because the
  panic was `Invalid` and the guide gave no limits table.
- `src/core/graph.zig`, `Program.report` (entry 7).
- Everything else: `play/*`, `README.md`, `docs/agents.md`, `describe` output, Patchwork's
  `draw/path.zig` `polyline` signature (read-only reference).

## The three changes that would have helped most

1. **`weft check` should print what a client needs to size `Limits`**: slab count, cue, goal, region,
   track and sample counts, plus token, tree, and name counts; and `Compiled.compile`'s `Invalid` should
   surface the first error and hint in the failing build (entries 2, 3).
2. **Guide the stepped page**: say in `agents.md` that a stepped program needs checkpoint memory, that
   events behind the playhead cost a rewind each frame (about 5 ms at 96 lanes), that a first seek to
   the end costs seconds in steps, and make `sample`'s events carry names, seconds, and `value`
   (entries 4, 6, 8, 9).
3. **Play's `Report` and the cost test**: let a page's report name its first stepped node instead of a
   scope row, and have the cost test print the first frame after a seek next to the steady frame (entries 7,
   8). With it, `--only`, `--render`, and an `.old.png` diff in the guide (entry 10).
