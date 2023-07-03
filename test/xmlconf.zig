//! A test runner for the W3C XML conformance test suite:
//! https://www.w3.org/XML/Test/

const std = @import("std");
const xml = @import("xml");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const usage =
    \\Usage: xmlconf [options] files...
    \\
    \\The provided files are expected to be XML documents containing a root
    \\TESTCASES element containing TESTs.
    \\
    \\Options:
    \\  -h, --help          show help
    \\  -v, --verbose       enable verbose output
    \\
;

const max_test_data_bytes = 2 * 1024 * 1024; // 2MB

const Suite = struct {
    profile: ?[]const u8,
    tests: []const Test,
};

const Test = struct {
    id: []const u8,
    type: Type,
    version: ?[]const u8,
    edition: ?[]const u8,
    entities: Entities,
    namespace: bool,
    sections: []const u8,
    description: []const u8,
    input: []const u8,
    output: ?[]const u8,

    const Type = enum {
        valid,
        invalid,
        @"not-wf",
        @"error",

        fn parse(value: []const u8) !Type {
            inline for (std.meta.fields(Type)) |field| {
                if (mem.eql(u8, value, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.InvalidTest;
        }
    };

    const Entities = enum {
        both,
        none,
        parameter,
        general,

        fn parse(value: []const u8) !Entities {
            inline for (std.meta.fields(Entities)) |field| {
                if (mem.eql(u8, value, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.InvalidTest;
        }
    };
};

fn Context(comptime OutType: type) type {
    return struct {
        allocator: Allocator,
        verbose: bool,
        tty_config: io.tty.Config,
        out: OutType,
        passed: ArrayListUnmanaged(Test) = .{},
        failed: ArrayListUnmanaged(Test) = .{},
        skipped: ArrayListUnmanaged(Test) = .{},

        const Self = @This();

        fn msg(self: Self, comptime format: []const u8, args: anytype) !void {
            try self.out.print(format ++ "\n", args);
        }

        fn pass(self: *Self, @"test": Test) !void {
            try self.passed.append(self.allocator, @"test");
            if (self.verbose) {
                try self.tty_config.setColor(self.out, .green);
                try self.out.print("PASS: {s} ({s})\n", .{ @"test".id, @"test".sections });
                try self.tty_config.setColor(self.out, .reset);
            }
        }

        fn fail(self: *Self, @"test": Test, reason: []const u8) !void {
            try self.failed.append(self.allocator, @"test");
            try self.tty_config.setColor(self.out, .red);
            try self.out.print("FAIL: {s} ({s}): {s}\n", .{ @"test".id, @"test".sections, reason });
            try self.tty_config.setColor(self.out, .reset);
        }

        fn skip(self: *Self, @"test": Test, reason: []const u8) !void {
            try self.skipped.append(self.allocator, @"test");
            if (self.verbose) {
                try self.tty_config.setColor(self.out, .yellow);
                try self.out.print("SKIP: {s} ({s}): {s}\n", .{ @"test".id, @"test".sections, reason });
                try self.tty_config.setColor(self.out, .reset);
            }
        }
    };
}

fn context(allocator: Allocator, verbose: bool, tty_config: io.tty.Config, out: anytype) Context(@TypeOf(out)) {
    return .{ .allocator = allocator, .verbose = verbose, .tty_config = tty_config, .out = out };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_iter = try process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();

    const stderr = io.getStdErr().writer();

    var allow_options = true;
    var verbose = false;
    var suites = ArrayListUnmanaged(Suite){};
    while (args_iter.next()) |arg| {
        if (allow_options and mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                try stderr.writeAll(usage);
                process.exit(0);
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                verbose = true;
            } else if (std.mem.eql(u8, arg, "--")) {
                allow_options = false;
            } else {
                try stderr.print("unrecognized option: {s}", .{arg});
                process.exit(1);
            }
        } else {
            var suite_dir = try fs.cwd().openDir(fs.path.dirname(arg) orelse ".", .{});
            defer suite_dir.close();
            var suite_file = try suite_dir.openFile(fs.path.basename(arg), .{});
            defer suite_file.close();

            var buf_reader = io.bufferedReader(suite_file.reader());
            var suite_reader = xml.reader(allocator, buf_reader.reader(), xml.encoding.DefaultDecoder{}, .{});
            defer suite_reader.deinit();
            try suites.append(allocator, try readSuite(allocator, suite_dir, &suite_reader));
        }
    }

    if (suites.items.len == 0) {
        try stderr.writeAll("expected at least one test suite file");
        process.exit(1);
    }

    const stdout = io.getStdOut();
    const tty_config = io.tty.detectConfig(stdout);
    var stdout_buf = io.bufferedWriter(stdout.writer());
    var ctx = context(allocator, verbose, tty_config, stdout_buf.writer());

    for (suites.items) |suite| {
        try runSuite(suite, &ctx);
    }

    try ctx.msg("DONE: {} passed, {} failed, {} skipped", .{
        ctx.passed.items.len,
        ctx.failed.items.len,
        ctx.skipped.items.len,
    });
    try stdout_buf.flush();
}

fn readSuite(allocator: Allocator, suite_dir: fs.Dir, suite_reader: anytype) !Suite {
    var profile: ?[]const u8 = null;
    var tests = ArrayListUnmanaged(Test){};

    while (try suite_reader.next()) |event| {
        switch (event) {
            .element_start => |element_start| if (element_start.name.is(null, "TESTCASES")) {
                for (element_start.attributes) |attr| {
                    if (attr.name.is(null, "PROFILE")) {
                        profile = try allocator.dupe(u8, attr.value);
                    }
                }
            } else if (element_start.name.is(null, "TEST")) {
                try tests.append(allocator, try readTest(allocator, suite_dir, element_start, suite_reader.children()));
            } else {
                try suite_reader.children().skip();
            },
            else => {},
        }
    }

    return .{
        .profile = profile,
        .tests = tests.items,
    };
}

fn readTest(allocator: Allocator, suite_dir: fs.Dir, test_start: xml.Event.ElementStart, test_reader: anytype) !Test {
    var id: ?[]const u8 = null;
    var @"type": ?Test.Type = null;
    var version: ?[]const u8 = null;
    var edition: ?[]const u8 = null;
    var entities = Test.Entities.none;
    var namespace = true;
    var sections: ?[]const u8 = null;
    var description = ArrayListUnmanaged(u8){};
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    for (test_start.attributes) |attr| {
        if (attr.name.is(null, "ID")) {
            id = try allocator.dupe(u8, attr.value);
        } else if (attr.name.is(null, "TYPE")) {
            @"type" = try Test.Type.parse(attr.value);
        } else if (attr.name.is(null, "VERSION")) {
            version = try allocator.dupe(u8, attr.value);
        } else if (attr.name.is(null, "EDITION")) {
            edition = try allocator.dupe(u8, attr.value);
        } else if (attr.name.is(null, "ENTITIES")) {
            entities = try Test.Entities.parse(attr.value);
        } else if (attr.name.is(null, "NAMESPACE")) {
            namespace = mem.eql(u8, attr.value, "yes");
        } else if (attr.name.is(null, "SECTIONS")) {
            sections = try allocator.dupe(u8, attr.value);
        } else if (attr.name.is(null, "URI")) {
            input = try suite_dir.readFileAlloc(allocator, attr.value, max_test_data_bytes);
        } else if (attr.name.is(null, "OUTPUT")) {
            output = try suite_dir.readFileAlloc(allocator, attr.value, max_test_data_bytes);
        }
    }

    while (try test_reader.next()) |event| {
        switch (event) {
            .element_content => |element_content| try description.appendSlice(allocator, element_content.content),
            else => {},
        }
    }

    return .{
        .id = id orelse return error.InvalidTest,
        .type = @"type" orelse return error.InvalidTest,
        .version = version,
        .edition = edition,
        .entities = entities,
        .namespace = namespace,
        .sections = sections orelse return error.InvalidTest,
        .description = description.items,
        .input = input orelse return error.InvalidTest,
        .output = output,
    };
}

fn runSuite(suite: Suite, ctx: anytype) !void {
    try ctx.msg("START: {s}", .{suite.profile orelse "untitled"});
    var suite_ctx = context(ctx.allocator, ctx.verbose, ctx.tty_config, ctx.out);
    for (suite.tests) |@"test"| {
        try runTest(@"test", &suite_ctx);
    }
    try ctx.msg("DONE: {s}: passed={} failed={} skipped={}", .{
        suite.profile orelse "untitled",
        suite_ctx.passed.items.len,
        suite_ctx.failed.items.len,
        suite_ctx.skipped.items.len,
    });
    try ctx.passed.appendSlice(ctx.allocator, suite_ctx.passed.items);
    try ctx.failed.appendSlice(ctx.allocator, suite_ctx.failed.items);
    try ctx.skipped.appendSlice(ctx.allocator, suite_ctx.skipped.items);
}

fn runTest(@"test": Test, ctx: anytype) !void {
    if (@"test".version) |version| {
        if (!mem.eql(u8, version, "1.0")) {
            return try ctx.skip(@"test", "only XML 1.0 is supported");
        }
    }
    if (@"test".edition) |edition| {
        // This check will technically be incorrect if a 15th edition is
        // released at some point, which seems highly unlikely
        if (mem.indexOfScalar(u8, edition, '5') == null) {
            return try ctx.skip(@"test", "only the fifth edition of XML 1.0 is supported");
        }
    }

    switch (@"test".type) {
        .valid, .invalid => {
            var input_stream = io.fixedBufferStream(@"test".input);
            // TODO: making namespace_aware a comptime option makes this possibly more difficult than it should be
            if (@"test".namespace) {
                var input_reader = xml.reader(ctx.allocator, input_stream.reader(), xml.encoding.DefaultDecoder{}, .{});
                defer input_reader.deinit();
                try runTestValid(@"test", &input_reader, ctx);
            } else {
                var input_reader = xml.reader(ctx.allocator, input_stream.reader(), xml.encoding.DefaultDecoder{}, .{
                    .namespace_aware = false,
                });
                defer input_reader.deinit();
                try runTestValid(@"test", &input_reader, ctx);
            }
        },
        .@"not-wf" => {
            var input_stream = io.fixedBufferStream(@"test".input);
            if (@"test".namespace) {
                var input_reader = xml.reader(ctx.allocator, input_stream.reader(), xml.encoding.DefaultDecoder{}, .{});
                defer input_reader.deinit();
                try runTestNonWf(@"test", &input_reader, ctx);
            } else {
                var input_reader = xml.reader(ctx.allocator, input_stream.reader(), xml.encoding.DefaultDecoder{}, .{
                    .namespace_aware = false,
                });
                defer input_reader.deinit();
                try runTestNonWf(@"test", &input_reader, ctx);
            }
        },
        .@"error" => return try ctx.skip(@"test", "TODO: not sure how to run error tests"),
    }
}

fn runTestValid(@"test": Test, input_reader: anytype, ctx: anytype) !void {
    var buf = ArrayListUnmanaged(u8){};
    defer buf.deinit(ctx.allocator);
    while (input_reader.next()) |maybe_event| {
        if (maybe_event) |event| {
            try writeCanonical(ctx.allocator, &buf, event);
        } else {
            if (@"test".output) |output| {
                if (!mem.eql(u8, buf.items, output)) {
                    return try ctx.fail(@"test", "expected output does not match");
                }
            }
            return try ctx.pass(@"test");
        }
    } else |e| switch (e) {
        error.DoctypeNotSupported => return try ctx.skip(@"test", "doctype not supported"),
        error.CannotUndeclareNsPrefix,
        error.DuplicateAttribute,
        error.InvalidCharacterReference,
        error.InvalidEncoding,
        error.InvalidNsBinding,
        error.InvalidPiTarget,
        error.InvalidQName,
        error.InvalidUtf8,
        error.InvalidUtf16,
        error.MismatchedEndTag,
        error.SyntaxError,
        error.UndeclaredEntityReference,
        error.UndeclaredNsPrefix,
        error.UnexpectedEndOfInput,
        error.QNameNotAllowed,
        => return try ctx.fail(@"test", @errorName(e)),
        else => |other_e| return other_e,
    }
}

fn runTestNonWf(@"test": Test, input_reader: anytype, ctx: anytype) !void {
    while (input_reader.next()) |event| {
        if (event == null) {
            return try ctx.fail(@"test", "expected error, found none");
        }
    } else |e| switch (e) {
        error.DoctypeNotSupported => return try ctx.skip(@"test", "doctype not supported"),
        error.CannotUndeclareNsPrefix,
        error.DuplicateAttribute,
        error.InvalidCharacterReference,
        error.InvalidEncoding,
        error.InvalidNsBinding,
        error.InvalidPiTarget,
        error.InvalidQName,
        error.InvalidUtf8,
        error.InvalidUtf16,
        error.MismatchedEndTag,
        error.SyntaxError,
        error.UndeclaredEntityReference,
        error.UndeclaredNsPrefix,
        error.UnexpectedEndOfInput,
        error.QNameNotAllowed,
        => return try ctx.pass(@"test"),
        else => |other_e| return other_e,
    }
}

fn writeCanonical(allocator: Allocator, buf: *ArrayListUnmanaged(u8), event: xml.Event) !void {
    switch (event) {
        .xml_declaration, .comment => {},
        .element_start => |element_start| {
            try buf.append(allocator, '<');
            try writeQName(allocator, buf, element_start.name);
            const attrs = try allocator.dupe(xml.Event.Attribute, element_start.attributes);
            defer allocator.free(attrs);
            std.sort.heap(xml.Event.Attribute, attrs, {}, attrLessThan);
            for (attrs) |attr| {
                try buf.append(allocator, ' ');
                try writeQName(allocator, buf, attr.name);
                try buf.appendSlice(allocator, "=\"");
                try writeContent(allocator, buf, attr.value);
                try buf.append(allocator, '"');
            }
            try buf.append(allocator, '>');
        },
        .element_content => |element_content| {
            try writeContent(allocator, buf, element_content.content);
        },
        .element_end => |element_end| {
            try buf.appendSlice(allocator, "</");
            try writeQName(allocator, buf, element_end.name);
            try buf.append(allocator, '>');
        },
        .pi => |pi| {
            try buf.appendSlice(allocator, "<?");
            try buf.appendSlice(allocator, pi.target);
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, pi.content);
            try buf.appendSlice(allocator, "?>");
        },
    }
}

fn writeQName(allocator: Allocator, buf: *ArrayListUnmanaged(u8), qname: xml.QName) !void {
    if (qname.prefix) |prefix| {
        try buf.appendSlice(allocator, prefix);
        try buf.append(allocator, ':');
    }
    try buf.appendSlice(allocator, qname.local);
}

fn writeContent(allocator: Allocator, buf: *ArrayListUnmanaged(u8), content: []const u8) !void {
    for (content) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\t' => try buf.appendSlice(allocator, "&#9;"),
            '\n' => try buf.appendSlice(allocator, "&#10;"),
            '\r' => try buf.appendSlice(allocator, "&#13"),
            else => try buf.append(allocator, c),
        }
    }
}

fn attrLessThan(_: void, lhs: xml.Event.Attribute, rhs: xml.Event.Attribute) bool {
    // This is a pretty stupid implementation, but it should work for all
    // reasonable test cases
    var lhs_buf: [1024]u8 = undefined;
    const lhs_name = if (lhs.name.ns) |ns|
        std.fmt.bufPrint(&lhs_buf, "{s}:{s}", .{ ns, lhs.name.local }) catch @panic("attribute name too long")
    else
        lhs.name.local;

    var rhs_buf: [1024]u8 = undefined;
    const rhs_name = if (rhs.name.ns) |ns|
        std.fmt.bufPrint(&rhs_buf, "{s}:{s}", .{ ns, rhs.name.local }) catch @panic("attribute name too long")
    else
        rhs.name.local;

    return mem.lessThan(u8, lhs_name, rhs_name);
}
