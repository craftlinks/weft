//! The parser: tokens to a flat tree of items, one declaration a line.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. A Flat Tree
//! Every item is one `Item` in one array: a tag, a token, two operands, and the span of tokens it
//! covers. An operand is another item's index, or for a call or a list, the first of its children
//! in `extra`, with `b` the count. Children are gathered on a bounded stack while they are parsed,
//! since their own children land between them in `items`, then copied to `extra` in one run. So
//! the tree holds no pointers and moves as bytes, like the graph.
//!
//! ## 2. Lines
//! A declaration ends at a newline, but inside parentheses and brackets a newline is space, so a
//! call can wrap. Comments are skipped here; the formatter reads them from the tokens, and every
//! item's span of tokens tells it which comments fall where.
//!
//! ## 3. The Grammar
//! ```text
//! file    = { declaration newline }
//! declaration
//!         = "seed" number | "start" name
//!         | "cue" name "=" expr [ ".." expr "every" expr ]
//!         | "track" name "=" expr "in" expr ".." expr
//!         | name "=" value | name "<-" value
//!         | "module" name "(" [ param { "," param } [","] ] ")" [ "in" value ] "=" expr
//!         | "use" name
//! param   = name [ ":" value ]
//! value   = expr [ ".." expr ]
//! expr    = term { ("+" | "-") term }
//! term    = unary { ("*" | "/") unary }
//! unary   = "-" unary | postfix
//! postfix = primary { "." name | "[" ( number | name ) "]" }
//! primary = literal | string | name | name "(" [ arg { "," arg } [","] ] ")" | "(" expr ")"
//!         | "[" [ item { "," item } [","] ] "]"
//! arg     = [ name ":" ] value
//! item    = value [ ":" expr ]
//! ```
//! A `-` right before a literal makes a negative literal, not a negation, so `-0.8` is one
//! constant, as the builder's `constant(-0.8)` is. An index is a number, or a name, which the
//! checker allows only as `lane` (step 28); an expression in brackets is refused here, with a hint.
//! A series written as a list, `cue title = [1s, 1080ms]`, is a `cue` whose time is a `list`. `/` binds as `*` does, left to right, so
//! `x / 3 / 2` is `(x / 3) / 2`; that a divisor is a number is the checker's rule, not the
//! grammar's.
//!
//! ## 4. Recovery
//! A syntax error adds a diagnostic and skips to the next line that starts at column 1, so one
//! bad line does not hide the errors after it. A wrapped call's own lines are indented, so they
//! are skipped with it.
//!
//! ## 5. TigerStyle Invariants
//! - Expressions nest at most `depth_max` deep, counted, so the recursion is bounded.
//! - Every array is the caller's; a full one is an error that names its limit, and parsing stops.

const std = @import("std");
const assert = std.debug.assert;
const token_module = @import("token.zig");
const Token = token_module.Token;
pub const TokenTag = token_module.Tag;
const error_module = @import("error.zig");
/// The fields of `Limits`, so a hint can only name one that exists.
const LimitField = std.meta.FieldEnum(@import("lang.zig").Limits);
const Diagnostics = error_module.List;

pub const depth_max = 32;

pub const Tag = enum(u8) {
    /// token: the number.
    seed,
    /// token: the cue's name.
    start,
    /// token: the name; a: the time.
    cue,
    /// token: the name; a: the first time; b: in `extra`, the last time then the step.
    cue_series,
    /// token: the name; a: the initial value; b: the range of its bounds.
    track,
    /// token: the name; a: the value.
    bind,
    /// token: the delay's name; a: the value it is fed.
    feed,
    /// token: the name; a: the parameters, a `list` of `param`s; b: the body; c: 1 + the
    /// declared range, or 0.
    module,
    /// token: the library's name.
    use,
    /// token: a number, time, frequency, or string; a: 1 when negated.
    literal,
    /// token: the name.
    name,
    /// token: the name; a: the first argument in `extra`; b: how many.
    call,
    /// token: the parameter's name; a: the value.
    named,
    /// a: the first item in `extra`; b: how many.
    list,
    /// a: the cue; b: the value.
    goal,
    /// a: the low end; b: the high end.
    range,
    add,
    subtract,
    multiply,
    /// a: the dividend; b: the divisor, a number the checker knows (`check.zig`, section 3).
    divide,
    /// a: the operand.
    negate,
    /// token: the output's name; a: the base.
    output,
    /// token: the index, a number or a name; a: the base.
    element,
    /// a: the inner expression.
    paren,
    /// token: the parameter's name; a: 1 + its default value, or 0.
    param,

    pub fn is_declaration(tag: Tag) bool {
        return @backingInt(tag) <= @backingInt(Tag.use);
    }
};

pub const Item = struct {
    tag: Tag,
    token: u32,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    /// The first and last tokens of the item, comments between them included.
    first: u32,
    last: u32,
};

pub const Tree = struct {
    source: []const u8,
    tokens: []const Token,
    items: []const Item,
    extra: []const u32,
    /// The declarations, in order, as item indices.
    declarations: []const u32,
    /// False when a limit stopped the parse, so the tree is not the whole file.
    complete: bool,

    pub fn item(tree: *const Tree, index: u32) Item {
        return tree.items[index];
    }

    pub fn children(tree: *const Tree, index: u32) []const u32 {
        const parent = tree.items[index];
        assert(parent.tag == .call or parent.tag == .list);
        return tree.extra[parent.a..][0..parent.b];
    }

    pub fn token_text(tree: *const Tree, index: u32) []const u8 {
        return tree.tokens[index].text(tree.source);
    }

    /// The text of an item's main token.
    pub fn text(tree: *const Tree, index: u32) []const u8 {
        return tree.token_text(tree.items[index].token);
    }
};

/// The memory a parse writes, all the caller's.
pub const Memory = struct {
    items: []Item,
    extra: []u32,
    /// Children waiting to be copied to `extra`, at most this many at once.
    stack: []u32,
    declarations: []u32,
};

const Fail = error{Syntax};

/// Parses the tokens of `source`, which end with `eof`, into `memory`.
pub fn parse(
    source: []const u8,
    tokens: []const Token,
    memory: Memory,
    diagnostics: *Diagnostics,
) Tree {
    assert(tokens.len >= 1);
    assert(tokens[tokens.len - 1].tag == .eof);
    var parser: Parser = .{
        .source = source,
        .tokens = tokens,
        .memory = memory,
        .diagnostics = diagnostics,
    };
    while (!parser.stopped) {
        parser.skip_blank();
        if (parser.peek_tag() == .eof) break;
        parser.declaration() catch parser.recover();
    }
    return .{
        .source = source,
        .tokens = tokens,
        .items = memory.items[0..parser.item_count],
        .extra = memory.extra[0..parser.extra_count],
        .declarations = memory.declarations[0..parser.declaration_count],
        .complete = !parser.stopped,
    };
}

const Parser = struct {
    source: []const u8,
    tokens: []const Token,
    memory: Memory,
    item_count: u32 = 0,
    extra_count: u32 = 0,
    stack_count: u32 = 0,
    declaration_count: u32 = 0,
    position: u32 = 0,
    /// Parentheses and brackets open, inside which a newline is space.
    nest: u32 = 0,
    /// The `(` of each call and group open, innermost last, so an error at the end of the file
    /// can say which one is never closed.
    open: [depth_max]u32 = undefined,
    open_count: u32 = 0,
    depth: u32 = 0,
    /// The last token consumed.
    last: u32 = 0,
    /// The first token of the declaration being parsed.
    declaration_first: u32 = 0,
    /// A limit was reached: parsing stops.
    stopped: bool = false,
    diagnostics: *Diagnostics,

    fn text_of(parser: *const Parser, index: u32) []const u8 {
        return parser.tokens[index].text(parser.source);
    }

    /// Moves past comments, and past newlines inside parentheses or brackets.
    fn skip_trivia(parser: *Parser) void {
        while (true) {
            const tag = parser.tokens[parser.position].tag;
            if (tag == .comment or (tag == .newline and parser.nest > 0)) {
                parser.position += 1;
                continue;
            }
            return;
        }
    }

    /// Moves past comments and newlines between declarations.
    fn skip_blank(parser: *Parser) void {
        while (true) {
            const tag = parser.tokens[parser.position].tag;
            if (tag != .comment and tag != .newline) return;
            parser.position += 1;
        }
    }

    fn peek(parser: *Parser) u32 {
        parser.skip_trivia();
        return parser.position;
    }

    fn peek_tag(parser: *Parser) TokenTag {
        return parser.tokens[parser.peek()].tag;
    }

    /// The tag of the significant token after the next one, without moving.
    fn peek_second_tag(parser: *Parser) TokenTag {
        const saved = parser.position;
        const saved_last = parser.last;
        defer {
            parser.position = saved;
            parser.last = saved_last;
        }
        _ = parser.take();
        return parser.peek_tag();
    }

    fn take(parser: *Parser) u32 {
        const index = parser.peek();
        assert(parser.tokens[index].tag != .eof);
        parser.position += 1;
        parser.last = index;
        return index;
    }

    fn is_word(parser: *Parser, word: []const u8) bool {
        const index = parser.peek();
        const token = parser.tokens[index];
        return token.tag == .name and std.mem.eql(u8, token.text(parser.source), word);
    }

    fn expect(parser: *Parser, tag: TokenTag, what: []const u8) Fail!u32 {
        const index = parser.peek();
        if (parser.tokens[index].tag == tag) return parser.take();
        return parser.fail_at(index, .unexpected_token, "expected {s}, found {s}", .{
            what,
            describe(parser.tokens[index], parser.source),
        });
    }

    fn fail_at(
        parser: *Parser,
        index: u32,
        code: error_module.Code,
        comptime format: []const u8,
        args: anytype,
    ) Fail {
        if (parser.open_count > 0 and parser.tokens[index].tag == .eof) {
            // The file ended inside a call or a group: the `(` is the mistake, not the end.
            const open = parser.tokens[parser.open[parser.open_count - 1]];
            const unclosed = parser.diagnostics.add(code, open.start, 1, "this `(` is never closed", .{});
            error_module.hint(unclosed, "close it with `)`", .{});
            return error.Syntax;
        }
        const token = parser.tokens[index];
        const diagnostic = parser.diagnostics.add(code, token.start, @max(token.len, 1), format, args);
        if (code == .bad_unit) {
            error_module.hint(diagnostic, "a unit is s, ms, or hz, right after the number", .{});
        }
        return error.Syntax;
    }

    /// An expression in brackets, such as `beat[lane + 1]`: an index is one number or `lane`.
    fn fail_index(parser: *Parser, index: u32) Fail {
        const token = parser.tokens[index];
        const diagnostic = parser.diagnostics.add(.unexpected_token, token.start, @max(token.len, 1), "an index is a whole number, or `lane` inside a region, found {s}", .{
            describe(token, parser.source),
        });
        error_module.hint(diagnostic, "declare the cues the lanes want, `cue NAME = [1s, 1200ms]`, then write `NAME[lane]`", .{});
        return error.Syntax;
    }

    /// How a token reads in an error.
    fn describe(token: Token, source: []const u8) []const u8 {
        return switch (token.tag) {
            .newline => "the end of the line",
            .eof => "the end of the file",
            else => token.text(source),
        };
    }

    fn recover(parser: *Parser) void {
        parser.nest = 0;
        parser.depth = 0;
        parser.open_count = 0;
        parser.stack_count = 0;
        // An error found at a token that starts a later line, such as an unclosed call running into
        // the next declaration, resumes at that token, so the next line is not lost.
        const at = parser.tokens[parser.position];
        const line_start = at.start == 0 or parser.source[at.start - 1] == '\n';
        if (parser.position > parser.declaration_first and line_start and at.tag != .newline) return;
        while (true) {
            const token = parser.tokens[parser.position];
            if (token.tag == .eof) return;
            parser.position += 1;
            if (token.tag != .newline) continue;
            const next = parser.tokens[parser.position];
            if (next.start == 0 or parser.source[next.start - 1] == '\n') return;
        }
    }

    fn push(parser: *Parser, item: Item) Fail!u32 {
        if (parser.item_count == parser.memory.items.len) return parser.limit("tree", .tree, parser.memory.items.len);
        const index = parser.item_count;
        parser.memory.items[index] = item;
        parser.item_count += 1;
        return index;
    }

    /// A table of `Limits.field` is full. The field is an enum, so a hint names one that exists.
    fn limit(parser: *Parser, noun: []const u8, comptime field: LimitField, count: usize) Fail {
        const token = parser.tokens[parser.position];
        const diagnostic = parser.diagnostics.add(.limit, token.start, @max(token.len, 1), "the file needs more than {d} {s} entries", .{ count, noun });
        error_module.hint(diagnostic, "raise `Limits.{s}`", .{@tagName(field)});
        parser.stopped = true;
        return error.Syntax;
    }

    fn declaration(parser: *Parser) Fail!void {
        const first = parser.peek();
        parser.declaration_first = first;
        const token = parser.tokens[first];
        if (token.tag != .name) {
            return parser.fail_at(first, .expected_declaration, "expected a declaration, found {s}", .{
                describe(token, parser.source),
            });
        }
        const index = try parser.declaration_body(first);
        const end = parser.peek();
        const end_tag = parser.tokens[end].tag;
        if (end_tag != .newline and end_tag != .eof) {
            return parser.fail_at(end, .unexpected_token, "expected the end of the line, found {s}", .{
                describe(parser.tokens[end], parser.source),
            });
        }
        if (parser.declaration_count == parser.memory.declarations.len) {
            return parser.limit("declarations", .names, parser.memory.declarations.len);
        }
        parser.memory.declarations[parser.declaration_count] = index;
        parser.declaration_count += 1;
    }

    fn declaration_body(parser: *Parser, first: u32) Fail!u32 {
        const word = parser.text_of(first);
        if (std.mem.eql(u8, word, "seed") and parser.peek_second_tag() != .equal) {
            _ = parser.take();
            const number = try parser.expect(.number, "a whole number");
            return parser.push(.{ .tag = .seed, .token = number, .first = first, .last = parser.last });
        }
        if (std.mem.eql(u8, word, "start") and parser.peek_second_tag() != .equal) {
            _ = parser.take();
            const name = try parser.expect(.name, "a cue's name");
            return parser.push(.{ .tag = .start, .token = name, .first = first, .last = parser.last });
        }
        if (std.mem.eql(u8, word, "cue") and parser.peek_second_tag() == .name) {
            _ = parser.take();
            const name = try parser.expect(.name, "a cue's name");
            _ = try parser.expect(.equal, "`=`");
            const from = try parser.expression();
            if (parser.peek_tag() != .dot_dot) {
                return parser.push(.{ .tag = .cue, .token = name, .a = from, .first = first, .last = parser.last });
            }
            _ = parser.take();
            const to = try parser.expression();
            if (!parser.is_word("every")) {
                return parser.fail_at(parser.peek(), .unexpected_token, "expected `every` and a step, found {s}", .{
                    describe(parser.tokens[parser.peek()], parser.source),
                });
            }
            _ = parser.take();
            const every = try parser.expression();
            const pair = try parser.extra_pair(to, every);
            return parser.push(.{ .tag = .cue_series, .token = name, .a = from, .b = pair, .first = first, .last = parser.last });
        }
        if (std.mem.eql(u8, word, "track") and parser.peek_second_tag() == .name) {
            _ = parser.take();
            const name = try parser.expect(.name, "a track's name");
            _ = try parser.expect(.equal, "`=`");
            const initial = try parser.expression();
            if (!parser.is_word("in")) {
                return parser.fail_at(parser.peek(), .unexpected_token, "expected `in` and the track's bounds, found {s}", .{
                    describe(parser.tokens[parser.peek()], parser.source),
                });
            }
            _ = parser.take();
            const bounds = try parser.value();
            return parser.push(.{ .tag = .track, .token = name, .a = initial, .b = bounds, .first = first, .last = parser.last });
        }
        if (std.mem.eql(u8, word, "use") and parser.peek_second_tag() == .name) {
            _ = parser.take();
            const name = try parser.expect(.name, "a library's name");
            return parser.push(.{ .tag = .use, .token = name, .first = first, .last = parser.last });
        }
        if (std.mem.eql(u8, word, "module") and parser.peek_second_tag() == .name) {
            return parser.module(first);
        }
        const name = parser.take();
        const operator = parser.peek();
        const tag: Tag = switch (parser.tokens[operator].tag) {
            .equal => .bind,
            .feed => .feed,
            else => return parser.fail_at(operator, .unexpected_token, "expected `=` or `<-` after `{s}`, found {s}", .{
                parser.text_of(name),
                describe(parser.tokens[operator], parser.source),
            }),
        };
        _ = parser.take();
        const operand = try parser.value();
        return parser.push(.{ .tag = tag, .token = name, .a = operand, .first = first, .last = parser.last });
    }

    /// `module name(p, q: default) [in lo..hi] = expr`. The parameters are on the stack while
    /// the body and the range parse above them, so they copy to `extra` last, as one run.
    fn module(parser: *Parser, first: u32) Fail!u32 {
        _ = parser.take();
        const name = try parser.expect(.name, "a module's name");
        _ = try parser.expect(.l_paren, "`(`");
        parser.nest += 1;
        const base = parser.stack_count;
        while (parser.peek_tag() != .r_paren) {
            const at = try parser.expect(.name, "a parameter's name");
            var default: u32 = 0;
            if (parser.peek_tag() == .colon) {
                _ = parser.take();
                default = try parser.value() + 1;
            }
            const param = try parser.push(.{ .tag = .param, .token = at, .a = default, .first = at, .last = parser.last });
            try parser.stack_push(param);
            if (parser.peek_tag() == .comma) {
                _ = parser.take();
                continue;
            }
            if (parser.peek_tag() != .r_paren) {
                return parser.fail_at(parser.peek(), .unexpected_token, "expected `,` or `)`, found {s}", .{
                    describe(parser.tokens[parser.peek()], parser.source),
                });
            }
        }
        parser.nest -= 1;
        _ = parser.take();
        var range: u32 = 0;
        if (parser.is_word("in")) {
            _ = parser.take();
            range = try parser.value() + 1;
        }
        _ = try parser.expect(.equal, "`=`");
        const body = try parser.expression();
        const run = try parser.stack_pop(base);
        const params = try parser.push(.{ .tag = .list, .token = first, .a = run.first, .b = run.count, .first = first, .last = parser.last });
        return parser.push(.{ .tag = .module, .token = name, .a = params, .b = body, .c = range, .first = first, .last = parser.last });
    }

    fn extra_pair(parser: *Parser, a: u32, b: u32) Fail!u32 {
        if (parser.memory.extra.len - parser.extra_count < 2) return parser.limit("extra", .tree, parser.memory.extra.len);
        const index = parser.extra_count;
        parser.memory.extra[index] = a;
        parser.memory.extra[index + 1] = b;
        parser.extra_count += 2;
        return index;
    }

    fn enter(parser: *Parser) Fail!void {
        if (parser.depth == depth_max) {
            const token = parser.tokens[parser.peek()];
            const diagnostic = parser.diagnostics.add(.too_deep, token.start, @max(token.len, 1), "expressions nest more than {d} deep here", .{depth_max});
            error_module.hint(diagnostic, "the depth is fixed, not a `Limits` field; name a part of it", .{});
            return error.Syntax;
        }
        parser.depth += 1;
    }

    fn value(parser: *Parser) Fail!u32 {
        const first = parser.peek();
        const low = try parser.expression();
        if (parser.peek_tag() != .dot_dot) return low;
        _ = parser.take();
        const high = try parser.expression();
        return parser.push(.{ .tag = .range, .token = first, .a = low, .b = high, .first = first, .last = parser.last });
    }

    fn expression(parser: *Parser) Fail!u32 {
        try parser.enter();
        defer parser.depth -= 1;
        const first = parser.peek();
        var left = try parser.term();
        while (true) {
            const tag: Tag = switch (parser.peek_tag()) {
                .plus => .add,
                .minus => .subtract,
                else => return left,
            };
            const operator = parser.take();
            const right = try parser.term();
            left = try parser.push(.{ .tag = tag, .token = operator, .a = left, .b = right, .first = first, .last = parser.last });
        }
    }

    fn term(parser: *Parser) Fail!u32 {
        const first = parser.peek();
        var left = try parser.unary();
        while (true) {
            const tag: Tag = switch (parser.peek_tag()) {
                .star => .multiply,
                .slash => .divide,
                else => return left,
            };
            const operator = parser.take();
            const right = try parser.unary();
            left = try parser.push(.{ .tag = tag, .token = operator, .a = left, .b = right, .first = first, .last = parser.last });
        }
    }

    fn unary(parser: *Parser) Fail!u32 {
        if (parser.peek_tag() != .minus) return parser.postfix();
        try parser.enter();
        defer parser.depth -= 1;
        const minus = parser.take();
        const next = parser.peek();
        const tag = parser.tokens[next].tag;
        if (tag == .number or tag == .time or tag == .frequency) {
            // A negative literal (section 3), unless a postfix follows, which no literal takes.
            _ = parser.take();
            return parser.push(.{ .tag = .literal, .token = next, .a = 1, .first = minus, .last = parser.last });
        }
        const operand = try parser.unary();
        return parser.push(.{ .tag = .negate, .token = minus, .a = operand, .first = minus, .last = parser.last });
    }

    fn postfix(parser: *Parser) Fail!u32 {
        const first = parser.peek();
        var base = try parser.primary();
        while (true) {
            switch (parser.peek_tag()) {
                .dot => {
                    _ = parser.take();
                    const name = try parser.expect(.name, "an output's name");
                    base = try parser.push(.{ .tag = .output, .token = name, .a = base, .first = first, .last = parser.last });
                },
                .l_bracket => {
                    // An element follows a name with no space, so `[` after a space starts nothing.
                    const open = parser.peek();
                    const before = parser.tokens[open].start;
                    if (before == 0 or parser.source[before - 1] == ' ') return base;
                    _ = parser.take();
                    parser.nest += 1;
                    const index = if (parser.peek_tag() == .name) parser.take() else try parser.expect(.number, "an index");
                    parser.nest -= 1;
                    if (parser.peek_tag() != .r_bracket) return parser.fail_index(parser.peek());
                    _ = parser.take();
                    base = try parser.push(.{ .tag = .element, .token = index, .a = base, .first = first, .last = parser.last });
                },
                else => return base,
            }
        }
    }

    fn primary(parser: *Parser) Fail!u32 {
        const first = parser.peek();
        const token = parser.tokens[first];
        switch (token.tag) {
            .number, .time, .frequency, .string => {
                _ = parser.take();
                return parser.push(.{ .tag = .literal, .token = first, .first = first, .last = first });
            },
            .bad_string => {
                const diagnostic = parser.diagnostics.add(.unclosed_string, token.start, 1, "this string has no closing quote on its line", .{});
                error_module.hint(diagnostic, "a string ends with `\"` on the line it starts on, and holds no `\"` itself", .{});
                return error.Syntax;
            },
            .bad_unit => {
                const digits = token_module.digits_of(token, parser.source);
                return parser.fail_at(first, .bad_unit, "`{s}` is not a unit", .{token.text(parser.source)[digits.len..]});
            },
            .name => {
                _ = parser.take();
                if (parser.tokens[parser.position].tag == .l_paren) return parser.call(first);
                return parser.push(.{ .tag = .name, .token = first, .first = first, .last = first });
            },
            .l_paren => {
                try parser.enter();
                defer parser.depth -= 1;
                parser.open_paren(parser.take());
                parser.nest += 1;
                const inner = try parser.value();
                parser.nest -= 1;
                _ = try parser.expect(.r_paren, "`)`");
                parser.open_count -= 1;
                return parser.push(.{ .tag = .paren, .token = first, .a = inner, .first = first, .last = parser.last });
            },
            .l_bracket => return parser.list(first),
            .invalid => return parser.fail_at(first, .invalid_character, "`{s}` starts nothing here", .{token.text(parser.source)}),
            else => return parser.fail_at(first, .expected_value, "expected a value, found {s}", .{describe(token, parser.source)}),
        }
    }

    /// Notes the `(` at `token` as open, which `enter` bounded by `depth_max`.
    fn open_paren(parser: *Parser, token: u32) void {
        assert(parser.open_count < depth_max);
        parser.open[parser.open_count] = token;
        parser.open_count += 1;
    }

    fn call(parser: *Parser, name: u32) Fail!u32 {
        try parser.enter();
        defer parser.depth -= 1;
        parser.open_paren(parser.take());
        parser.nest += 1;
        const base = parser.stack_count;
        while (parser.peek_tag() != .r_paren) {
            const at = parser.peek();
            const child = if (parser.tokens[at].tag == .name and parser.peek_second_tag() == .colon) named: {
                _ = parser.take();
                _ = parser.take();
                const operand = try parser.value();
                break :named try parser.push(.{ .tag = .named, .token = at, .a = operand, .first = at, .last = parser.last });
            } else try parser.value();
            try parser.stack_push(child);
            if (parser.peek_tag() == .comma) {
                _ = parser.take();
                continue;
            }
            if (parser.peek_tag() != .r_paren) {
                return parser.fail_at(parser.peek(), .unexpected_token, "expected `,` or `)`, found {s}", .{
                    describe(parser.tokens[parser.peek()], parser.source),
                });
            }
        }
        parser.nest -= 1;
        _ = parser.take();
        parser.open_count -= 1;
        const run = try parser.stack_pop(base);
        return parser.push(.{ .tag = .call, .token = name, .a = run.first, .b = run.count, .first = name, .last = parser.last });
    }

    fn list(parser: *Parser, open: u32) Fail!u32 {
        try parser.enter();
        defer parser.depth -= 1;
        _ = parser.take();
        parser.nest += 1;
        const base = parser.stack_count;
        while (parser.peek_tag() != .r_bracket) {
            const at = parser.peek();
            var child = try parser.value();
            if (parser.peek_tag() == .colon) {
                _ = parser.take();
                const goal_value = try parser.expression();
                child = try parser.push(.{ .tag = .goal, .token = at, .a = child, .b = goal_value, .first = at, .last = parser.last });
            }
            try parser.stack_push(child);
            if (parser.peek_tag() == .comma) {
                _ = parser.take();
                continue;
            }
            if (parser.peek_tag() != .r_bracket) {
                return parser.fail_at(parser.peek(), .unexpected_token, "expected `,` or `]`, found {s}", .{
                    describe(parser.tokens[parser.peek()], parser.source),
                });
            }
        }
        parser.nest -= 1;
        _ = parser.take();
        const run = try parser.stack_pop(base);
        return parser.push(.{ .tag = .list, .token = open, .a = run.first, .b = run.count, .first = open, .last = parser.last });
    }

    fn stack_push(parser: *Parser, child: u32) Fail!void {
        if (parser.stack_count == parser.memory.stack.len) return parser.limit("stack", .tree, parser.memory.stack.len);
        parser.memory.stack[parser.stack_count] = child;
        parser.stack_count += 1;
    }

    const Run = struct { first: u32, count: u32 };

    /// Copies the children from `base` up to `extra`, as one run, and pops them.
    fn stack_pop(parser: *Parser, base: u32) Fail!Run {
        assert(base <= parser.stack_count);
        const count = parser.stack_count - base;
        if (parser.memory.extra.len - parser.extra_count < count) return parser.limit("extra", .tree, parser.memory.extra.len);
        const first = parser.extra_count;
        @memcpy(parser.memory.extra[first..][0..count], parser.memory.stack[base..][0..count]);
        parser.extra_count += count;
        parser.stack_count = base;
        return .{ .first = first, .count = count };
    }
};

const testing = std.testing;

pub const Fixture = struct {
    tokens: [512]Token,
    items: [512]Item,
    extra: [512]u32,
    stack: [128]u32,
    declarations: [64]u32,
    diagnostic_entries: [8]error_module.Diagnostic,
    diagnostics: Diagnostics,

    pub fn run(fixture: *Fixture, source: []const u8) Tree {
        const result = token_module.tokenize(source, &fixture.tokens);
        assert(!result.full);
        fixture.diagnostics = Diagnostics.init(&fixture.diagnostic_entries);
        return parse(source, fixture.tokens[0..result.count], .{
            .items = &fixture.items,
            .extra = &fixture.extra,
            .stack = &fixture.stack,
            .declarations = &fixture.declarations,
        }, &fixture.diagnostics);
    }
};

// Locks the shape of each declaration and the precedence of section 3.
test "declarations and expressions parse into the flat tree" {
    var fixture: Fixture = undefined;
    const tree = fixture.run(
        \\seed 7
        \\cue c1 = 2s
        \\cue bar = 0s..600s every 2s
        \\track glide_v = 1 in 0.25..4
        \\x = a + b * -0.8 - -c
        \\fb <- chase(x, time: 0.5s,)
        \\
    );
    try testing.expectEqual(@as(u32, 0), fixture.diagnostics.total());
    const tags = [_]Tag{ .seed, .cue, .cue_series, .track, .bind, .feed };
    try testing.expectEqual(tags.len, tree.declarations.len);
    for (tags, tree.declarations) |tag, index| try testing.expectEqual(tag, tree.item(index).tag);
    // x = (a + (b * -0.8)) - (-c)
    const sum = tree.item(tree.item(tree.declarations[4]).a);
    try testing.expectEqual(Tag.subtract, sum.tag);
    try testing.expectEqual(Tag.add, tree.item(sum.a).tag);
    try testing.expectEqual(Tag.negate, tree.item(sum.b).tag);
    const product = tree.item(tree.item(sum.a).b);
    try testing.expectEqual(Tag.multiply, product.tag);
    try testing.expectEqual(@as(u32, 1), tree.item(product.b).a);
    const feed_call = tree.item(tree.declarations[5]).a;
    try testing.expectEqual(@as(usize, 2), tree.children(feed_call).len);
    try testing.expectEqual(Tag.named, tree.item(tree.children(feed_call)[1]).tag);
}

// Locks lists of goals and of ranges, outputs, elements, and a call that wraps.
test "lists, goals, outputs, and elements" {
    var fixture: Fixture = undefined;
    const tree = fixture.run(
        \\moves = [c1: 1, bar[3]: -0.5]
        \\r = follow(
        \\    [-1..-0.5, 0.5..1], # two regions
        \\    seed: 2,
        \\)
        \\v = b.velocity
        \\
    );
    try testing.expectEqual(@as(u32, 0), fixture.diagnostics.total());
    const moves = tree.item(tree.declarations[0]).a;
    const goals = tree.children(moves);
    try testing.expectEqual(Tag.goal, tree.item(goals[0]).tag);
    try testing.expectEqual(Tag.element, tree.item(tree.item(goals[1]).a).tag);
    const follow = tree.item(tree.declarations[1]).a;
    const regions = tree.item(tree.children(follow)[0]);
    try testing.expectEqual(Tag.list, regions.tag);
    try testing.expectEqual(Tag.output, tree.item(tree.item(tree.declarations[2]).a).tag);
}

// Locks `/` in section 3 (step 30): it binds as `*`, left to right, and below `+`.
test "a quotient is a term, left to right" {
    var fixture: Fixture = undefined;
    const tree = fixture.run("x = a / 3 / 2 * b + c / -4\n");
    try testing.expectEqual(@as(u32, 0), fixture.diagnostics.total());
    // x = (((a / 3) / 2) * b) + (c / -4)
    const sum = tree.item(tree.item(tree.declarations[0]).a);
    try testing.expectEqual(Tag.add, sum.tag);
    const product = tree.item(sum.a);
    try testing.expectEqual(Tag.multiply, product.tag);
    const outer = tree.item(product.a);
    try testing.expectEqual(Tag.divide, outer.tag);
    try testing.expectEqualStrings("2", tree.text(outer.b));
    try testing.expectEqual(Tag.divide, tree.item(outer.a).tag);
    try testing.expectEqualStrings("3", tree.text(tree.item(outer.a).b));
    const right = tree.item(sum.b);
    try testing.expectEqual(Tag.divide, right.tag);
    try testing.expectEqual(@as(u32, 1), tree.item(right.b).a);
}

// Locks recovery (section 4): each bad line gives one error, and the good lines still parse.
test "a bad line gives one error and the next line still parses" {
    var fixture: Fixture = undefined;
    const tree = fixture.run(
        \\a = wave(sine, 1hz
        \\b = 2sec
        \\c = (1
        \\d = 1
        \\e = $
        \\f = 2
        \\
    );
    try testing.expectEqual(@as(u32, 4), fixture.diagnostics.total());
    try testing.expectEqual(@as(usize, 2), tree.declarations.len);
    try testing.expectEqualStrings("d", tree.token_text(tree.item(tree.declarations[0]).token));
    try testing.expectEqual(error_module.Code.bad_unit, fixture.diagnostics.items()[1].code);
    try testing.expectEqual(error_module.Code.invalid_character, fixture.diagnostics.items()[3].code);
}

// Locks the bound on nesting: 40 parentheses is an error, not a deep recursion.
test "nesting deeper than the bound is an error" {
    var fixture: Fixture = undefined;
    const open: [40]u8 = @splat('(');
    const close: [40]u8 = @splat(')');
    _ = fixture.run("x = " ++ open ++ "1" ++ close ++ "\n");
    try testing.expectEqual(error_module.Code.too_deep, fixture.diagnostics.items()[0].code);
}
