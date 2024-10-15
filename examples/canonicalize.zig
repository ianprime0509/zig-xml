const std = @import("std");
const log = std.log;
const xml = @import("xml");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args_iter = try std.process.argsWithAllocator(gpa);
    defer args_iter.deinit();
    _ = args_iter.next();
    var pretty = false;
    var input: ?[]u8 = null;
    defer if (input) |f| gpa.free(f);
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pretty")) {
            pretty = true;
        } else {
            if (input != null) return error.InvalidArguments; // usage: canonicalize [-p|--pretty] file
            input = try gpa.dupe(u8, arg);
        }
    }

    var input_file = try std.fs.cwd().openFile(input orelse return error.InvalidArguments, .{});
    defer input_file.close();
    var encoding = xml.Encoding.Default.init;
    var doc = xml.encodedDocument(gpa, input_file.reader(), encoding.encoding());
    defer doc.deinit();
    var reader = doc.reader(gpa, .{});
    defer reader.deinit();

    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout_output = xml.streamingOutput(stdout_buf.writer());
    var writer = stdout_output.writer(gpa, .{
        .indent = if (pretty) "  " else "",
    });
    defer writer.deinit();

    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => {
                const loc = reader.errorLocation();
                log.err("{}:{}: {}", .{ loc.line, loc.column, reader.errorCode() });
                return error.MalformedXml;
            },
            else => |other| return other,
        };
        switch (node) {
            .eof => break,
            .xml_declaration, .comment => {}, // ignored in canonical form
            .element_start => {
                try writer.elementStart(reader.elementName());

                const sorted_attrs = try gpa.alloc(usize, reader.attributeCount());
                defer gpa.free(sorted_attrs);
                for (0..reader.attributeCount()) |i| sorted_attrs[i] = i;
                std.sort.pdq(usize, sorted_attrs, reader, struct {
                    fn lessThan(r: @TypeOf(reader), lhs: usize, rhs: usize) bool {
                        return std.mem.lessThan(u8, r.attributeName(lhs), r.attributeName(rhs));
                    }
                }.lessThan);
                for (sorted_attrs) |i| {
                    try writer.attribute(reader.attributeName(i), try reader.attributeValue(i));
                }
            },
            .element_end => {
                try writer.elementEnd();
            },
            .pi => {
                try writer.pi(reader.piTarget(), try reader.piData());
            },
            .text => {
                try writer.text(try reader.text());
            },
            .cdata => {
                try writer.text(try reader.cdata());
            },
            .character_reference => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(reader.characterReferenceChar(), &buf) catch unreachable;
                try writer.text(buf[0..len]);
            },
            .entity_reference => {
                const value = xml.predefined_entities.get(reader.entityReferenceName()) orelse unreachable;
                try writer.text(value);
            },
        }
    }

    try stdout_buf.flush();
}
