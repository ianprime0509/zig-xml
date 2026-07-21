const std = @import("std");
const Io = std.Io;
const log = std.log;
const xml = @import("xml");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.InvalidArguments; // usage: format file

    var input_file = try Io.Dir.cwd().openFile(io, args[1], .{});
    defer input_file.close(io);
    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(io, &input_buf);
    var streaming_reader: xml.Reader.Streaming = .init(gpa, &input_reader.interface, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    var writer: xml.Writer = .init(gpa, stdout, .{ .indent = "  " });
    defer writer.deinit();

    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => {
                try stdout.flush();
                const loc = reader.errorLocation();
                log.err("{}:{}: {}", .{ loc.line, loc.column, reader.errorCode() });
                return error.MalformedXml;
            },
            else => |other| return other,
        };
        switch (node) {
            .eof => break,
            .xml_declaration => {
                try writer.xmlDeclaration(
                    reader.xmlDeclarationEncoding(),
                    reader.xmlDeclarationStandalone(),
                );
            },
            .element_start => {
                try writer.elementStart(reader.elementName());
                for (0..reader.attributeCount()) |i| {
                    try writer.attribute(
                        reader.attributeName(i),
                        try reader.attributeValue(i),
                    );
                }
            },
            .element_end => {
                try writer.elementEnd();
            },
            .comment => {
                try writer.comment(try reader.comment());
            },
            .pi => {
                try writer.pi(reader.piTarget(), try reader.piData());
            },
            .text => {
                try writer.text(try reader.text());
            },
            .cdata => {
                try writer.cdata(try reader.cdata());
            },
            .entity_reference => {
                try writer.entityReference(reader.entityReferenceName());
            },
            .character_reference => {
                try writer.characterReference(reader.characterReferenceChar());
            },
        }
    }

    try writer.eof();
    try stdout.flush();
}
