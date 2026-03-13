const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

const xml = @import("xml");

const usage =
    \\Usage: xmlconf [options] files...
    \\
    \\Runs the provided xmlconf test suites.
    \\
    \\Options:
    \\  -h, --help      show help
    \\  -v, --verbose   increase verbosity
    \\
;

var log_tty_config: std.Io.tty.Config = undefined; // Will be initialized immediately in main
var log_level: std.log.Level = .warn;

pub const std_options: std.Options = .{
    .logFn = logImpl,
};

pub fn logImpl(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(log_level)) return;

    const prefix = if (scope == .default)
        comptime level.asText() ++ ": "
    else
        comptime level.asText() ++ "(" ++ @tagName(scope) ++ "): ";
    var buffer: [64]u8 = undefined;
    const stderr, _ = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    log_tty_config.setColor(stderr, switch (level) {
        .err => .bright_red,
        .warn => .bright_yellow,
        .info => .bright_blue,
        .debug => .bright_magenta,
    }) catch return;
    stderr.writeAll(prefix) catch return;
    log_tty_config.setColor(stderr, .reset) catch return;
    stderr.print(format ++ "\n", args) catch return;
}

pub fn main() !void {
    log_tty_config = std.Io.tty.detectConfig(std.fs.File.stderr());

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var suite_paths: std.ArrayList([]const u8) = .empty;

    var args: ArgIterator = .{ .args = try std.process.argsWithAllocator(arena) };
    _ = args.next();
    while (args.next()) |arg| {
        switch (arg) {
            .option => |option| if (option.is('h', "help")) {
                try std.fs.File.stdout().writeAll(usage);
                std.process.exit(0);
            } else if (option.is('v', "verbose")) {
                log_level = switch (log_level) {
                    .err => .warn,
                    .warn => .info,
                    .info => .debug,
                    .debug => .debug,
                };
            } else {
                fatal("unrecognized option: {f}", .{option});
            },
            .param => |param| {
                try suite_paths.append(arena, try arena.dupe(u8, param));
            },
            .unexpected_value => |unexpected_value| fatal("unexpected value to --{s}: {s}", .{
                unexpected_value.option,
                unexpected_value.value,
            }),
        }
    }

    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var results: Results = .{};
    for (suite_paths.items) |suite_path| {
        runFile(gpa, suite_path, &results) catch |err|
            results.err("running suite {s}: {}", .{ suite_path, err });
    }
    std.debug.print("{} passed, {} failed, {} skipped\n", .{ results.passed, results.failed, results.skipped });
    std.process.exit(if (results.ok()) 0 else 1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}

const Results = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    run_error: bool = false,

    fn ok(results: Results) bool {
        return results.failed == 0 and !results.run_error;
    }

    fn pass(results: *Results, id: []const u8) void {
        log.debug("pass: {s}", .{id});
        results.passed += 1;
    }

    fn fail(results: *Results, id: []const u8, comptime fmt: []const u8, args: anytype) void {
        log.err("fail: {s}: " ++ fmt, .{id} ++ args);
        results.failed += 1;
    }

    fn skip(results: *Results, id: []const u8, comptime fmt: []const u8, args: anytype) void {
        log.info("skip: {s}: " ++ fmt, .{id} ++ args);
        results.skipped += 1;
    }

    fn err(results: *Results, comptime fmt: []const u8, args: anytype) void {
        log.err(fmt, args);
        results.run_error = true;
    }
};

const max_file_size = 2 * 1024 * 1024;

fn runFile(gpa: Allocator, path: []const u8, results: *Results) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, std.fs.path.dirname(path) orelse ".", .{});
    defer dir.close(std.testing.io);

    const file = try dir.openFile(std.testing.io, std.fs.path.basename(path), .{});
    defer file.close(std.testing.io);

    var file_buf: [1024]u8 = undefined;
    var file_reader = file.reader(std.testing.io, &file_buf);

    const data = try file_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(data);

    var data_reader: std.Io.Reader = .fixed(data);
    var streaming_reader: xml.Reader.Streaming = .init(gpa, &data_reader, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    try reader.skipProlog();
    if (!std.mem.eql(u8, "TESTCASES", reader.elementName())) return error.InvalidTest;
    try runSuite(gpa, dir, reader, results);
}

fn runSuite(gpa: Allocator, dir: std.Io.Dir, reader: *xml.Reader, results: *Results) !void {
    if (reader.attributeIndex("PROFILE")) |profile_attr| {
        log.info("suite: {s}", .{try reader.attributeValue(profile_attr)});
    }

    while (true) {
        switch (try reader.read()) {
            .element_start => if (std.mem.eql(u8, reader.elementName(), "TESTCASES")) {
                try runSuite(gpa, dir, reader, results);
            } else if (std.mem.eql(u8, reader.elementName(), "TEST")) {
                try runTest(gpa, dir, reader, results);
            } else {
                return error.InvalidTest;
            },
            .element_end => break,
            else => {},
        }
    }
}

fn runTest(gpa: Allocator, dir: std.Io.Dir, reader: *xml.Reader, results: *Results) !void {
    const @"type" = type: {
        const index = reader.attributeIndex("TYPE") orelse return error.InvalidTest;
        break :type std.meta.stringToEnum(TestType, try reader.attributeValue(index)) orelse return error.InvalidTest;
    };
    const id = id: {
        const index = reader.attributeIndex("ID") orelse return error.InvalidTest;
        break :id try reader.attributeValueAlloc(gpa, index);
    };
    defer gpa.free(id);
    if (reader.attributeIndex("VERSION")) |index| check_version: {
        const versions = try reader.attributeValue(index);
        var iter = std.mem.splitScalar(u8, versions, ' ');
        while (iter.next()) |version| {
            if (std.mem.eql(u8, version, "1.0")) break :check_version;
        }
        return results.skip(id, "only XML 1.0 is supported", .{});
    }
    if (reader.attributeIndex("EDITION")) |index| check_edition: {
        const editions = try reader.attributeValue(index);
        var iter = std.mem.splitScalar(u8, editions, ' ');
        while (iter.next()) |edition| {
            if (std.mem.eql(u8, edition, "5")) break :check_edition;
        }
        return results.skip(id, "only the fifth edition of XML 1.0 is supported", .{});
    }
    const namespace = namespace: {
        const index = reader.attributeIndex("NAMESPACE") orelse break :namespace .yes;
        break :namespace std.meta.stringToEnum(enum { yes, no }, try reader.attributeValue(index)) orelse return error.InvalidTest;
    };
    const input = input: {
        const index = reader.attributeIndex("URI") orelse return error.InvalidTest;
        const path = try reader.attributeValue(index);
        const buf = try gpa.alloc(u8, max_file_size);
        const input = dir.readFile(std.testing.io, path, buf) catch |err|
            return results.err("{s}: reading input file: {s}: {}", .{ id, path, err });
        break :input .{ .parent = buf, .data = input };
    };
    defer gpa.free(input.parent);
    const output: struct { parent: ?[]u8, data: ?[]u8 } = output: {
        const index = reader.attributeIndex("OUTPUT") orelse break :output .{ .parent = null, .data = null };
        const path = try reader.attributeValue(index);
        const buf = try gpa.alloc(u8, max_file_size);
        const output: ?[]u8 = dir.readFile(std.testing.io, path, buf) catch |err|
            return results.err("{s}: reading output file: {s}: {}", .{ id, path, err });
        break :output .{ .parent = buf, .data = output };
    };
    defer if (output.parent) |o| gpa.free(o);
    try reader.skipElement();

    const options: TestOptions = .{
        .namespace = namespace == .yes,
    };
    switch (@"type") {
        .valid, .invalid => try runTestParseable(gpa, id, input.data, output.data, options, results),
        .@"not-wf" => try runTestUnparseable(gpa, id, input.data, options, results),
        .@"error" => results.skip(id, "not sure how to run error tests", .{}),
    }
}

const TestOptions = struct {
    namespace: bool,
};

fn runTestParseable(
    gpa: Allocator,
    id: []const u8,
    input: []const u8,
    output: ?[]const u8,
    options: TestOptions,
    results: *Results,
) !void {
    var input_reader: std.Io.Reader = .fixed(input);
    var streaming_reader: xml.Reader.Streaming = .init(gpa, &input_reader, .{
        .namespace_aware = options.namespace,
    });
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    var canonical_output: std.Io.Writer.Allocating = .init(gpa);
    defer canonical_output.deinit();
    var canonical: xml.Writer = .init(gpa, &canonical_output.writer, .{});
    defer canonical.deinit();

    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => {
                switch (reader.errorCode()) {
                    .doctype_unsupported => return results.skip(id, "doctype unsupported", .{}),
                    .xml_declaration_encoding_unsupported => return results.skip(id, "encoding unsupported", .{}),
                    else => |code| {
                        const loc = reader.errorLocation();
                        return results.fail(id, "malformed: {}:{}: {}", .{ loc.line, loc.column, code });
                    },
                }
            },
            else => |other| return other,
        };
        switch (node) {
            .eof => break,
            .xml_declaration, .comment => {}, // ignored in canonical form
            .element_start => {
                try canonical.elementStart(reader.elementName());

                const sorted_attrs = try gpa.alloc(usize, reader.attributeCount());
                defer gpa.free(sorted_attrs);
                for (0..reader.attributeCount()) |i| sorted_attrs[i] = i;
                std.sort.pdq(usize, sorted_attrs, reader, struct {
                    fn lessThan(r: @TypeOf(reader), lhs: usize, rhs: usize) bool {
                        return std.mem.lessThan(u8, r.attributeName(lhs), r.attributeName(rhs));
                    }
                }.lessThan);
                for (sorted_attrs) |i| {
                    try canonical.attribute(reader.attributeName(i), try reader.attributeValue(i));
                }
            },
            .element_end => {
                try canonical.elementEnd();
            },
            .pi => {
                try canonical.pi(reader.piTarget(), try reader.piData());
            },
            .text => {
                try canonical.text(try reader.text());
            },
            .cdata => {
                try canonical.text(try reader.cdata());
            },
            .character_reference => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(reader.characterReferenceChar(), &buf) catch unreachable;
                try canonical.text(buf[0..len]);
            },
            .entity_reference => {
                const value = xml.predefined_entities.get(reader.entityReferenceName()) orelse unreachable;
                try canonical.text(value);
            },
        }
    }

    if (output) |expected_canonical| {
        if (!std.mem.eql(u8, canonical_output.written(), expected_canonical)) {
            return results.fail(
                id,
                "canonical output does not match\n\nexpected:\n{s}\n\nactual:{s}",
                .{ expected_canonical, canonical_output.written() },
            );
        }
    }
    return results.pass(id);
}

fn runTestUnparseable(
    gpa: Allocator,
    id: []const u8,
    input: []const u8,
    options: TestOptions,
    results: *Results,
) !void {
    var min_buffer_reader: MinBufferFixedReader(2) = .init(input);
    var input_reader = min_buffer_reader.reader();
    var streaming_reader: xml.Reader.Streaming = .init(gpa, &input_reader, .{
        .namespace_aware = options.namespace,
    });
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => switch (reader.errorCode()) {
                .doctype_unsupported => return results.skip(id, "doctype unsupported", .{}),
                .xml_declaration_encoding_unsupported => return results.skip(id, "encoding unsupported", .{}),
                else => return results.pass(id),
            },
            else => |other| return other,
        };
        if (node == .eof) return results.fail(id, "expected to fail to parse", .{});
    }
}

const TestType = enum {
    valid,
    invalid,
    @"not-wf",
    @"error",
};

// Inspired by https://github.com/judofyr/parg
const ArgIterator = struct {
    args: std.process.ArgIterator,
    state: union(enum) {
        normal,
        short: []const u8,
        long: struct {
            option: []const u8,
            value: []const u8,
        },
        params_only,
    } = .normal,

    const Arg = union(enum) {
        option: union(enum) {
            short: u8,
            long: []const u8,

            fn is(option: @This(), short: ?u8, long: ?[]const u8) bool {
                return switch (option) {
                    .short => |c| short == c,
                    .long => |s| std.mem.eql(u8, long orelse return false, s),
                };
            }

            pub fn format(option: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                switch (option) {
                    .short => |c| try writer.print("-{c}", .{c}),
                    .long => |s| try writer.print("--{s}", .{s}),
                }
            }
        },
        param: []const u8,
        unexpected_value: struct {
            option: []const u8,
            value: []const u8,
        },
    };

    fn deinit(iter: *ArgIterator) void {
        iter.args.deinit();
        iter.* = undefined;
    }

    fn next(iter: *ArgIterator) ?Arg {
        switch (iter.state) {
            .normal => {
                const arg = iter.args.next() orelse return null;
                if (std.mem.eql(u8, arg, "--")) {
                    iter.state = .params_only;
                    return .{ .param = iter.args.next() orelse return null };
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    if (std.mem.indexOfScalar(u8, arg, '=')) |equals_index| {
                        const option = arg["--".len..equals_index];
                        iter.state = .{ .long = .{
                            .option = option,
                            .value = arg[equals_index + 1 ..],
                        } };
                        return .{ .option = .{ .long = option } };
                    } else {
                        return .{ .option = .{ .long = arg["--".len..] } };
                    }
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                    if (arg.len > 2) {
                        iter.state = .{ .short = arg["-".len + 1 ..] };
                    }
                    return .{ .option = .{ .short = arg["-".len] } };
                } else {
                    return .{ .param = arg };
                }
            },
            .short => |rest| {
                if (rest.len > 1) {
                    iter.state = .{ .short = rest[1..] };
                }
                return .{ .option = .{ .short = rest[0] } };
            },
            .long => |long| return .{ .unexpected_value = .{
                .option = long.option,
                .value = long.value,
            } },
            .params_only => return .{ .param = iter.args.next() orelse return null },
        }
    }

    fn optionValue(iter: *ArgIterator) ?[]const u8 {
        switch (iter.state) {
            .normal => return iter.args.next(),
            .short => |rest| {
                iter.state = .normal;
                return rest;
            },
            .long => |long| {
                iter.state = .normal;
                return long.value;
            },
            .params_only => unreachable,
        }
    }
};

/// A utility wrapper for `std.Io.Reader.fixed` that ensures a minimum buffer
/// is always available.
fn MinBufferFixedReader(comptime min_buf_len: usize) type {
    return union(enum) {
        direct: []const u8,
        buffered: struct {
            buf: [min_buf_len]u8,
            len: usize,
        },

        pub fn init(data: []const u8) @This() {
            if (data.len >= min_buf_len) return .{ .direct = data };
            var buf: [min_buf_len]u8 = undefined;
            @memcpy(buf[0..data.len], data);
            return .{ .buffered = .{
                .buf = buf,
                .len = data.len,
            } };
        }

        pub fn reader(self: *@This()) std.Io.Reader {
            return switch (self.*) {
                .direct => |buf| .fixed(buf),
                .buffered => |*state| buffered: {
                    var r: std.Io.Reader = .fixed(&state.buf);
                    r.end = state.len;
                    break :buffered r;
                },
            };
        }
    };
}
