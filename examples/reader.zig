const std = @import("std");
const xml = @import("xml");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) {
        return error.InvalidArguments; // usage: example-reader file
    }

    var input_file = try std.fs.cwd().openFile(args[1], .{});
    defer input_file.close();
    // It is not necessary to wrap the input in a BufferedReader. The streaming
    // document uses an internal buffer and reads its input in chunks, not byte
    // by byte.
    var doc = xml.streamingDocument(gpa, input_file.reader());
    defer doc.deinit();
    var reader = doc.reader(gpa, .{});
    defer reader.deinit();

    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = stdout_buf.writer();

    while (true) {
        const node = reader.read() catch |err| {
            try stdout.print("{}: {}\n", .{ err, reader.reader.error_code });
            break;
        };
        switch (node) {
            .eof => break,
            .xml_declaration => {
                try stdout.print("xml_declaration: version={s} encoding={?s} standalone={?}\n", .{
                    reader.xmlDeclarationVersion(),
                    reader.xmlDeclarationEncoding(),
                    reader.xmlDeclarationStandalone(),
                });
            },
            .element_start => {
                const element_name = reader.elementNameNs();
                try stdout.print("element_start: \"{}\"[\"{}\"]:\"{}\"\n", .{
                    std.zig.fmtEscapes(element_name.prefix),
                    std.zig.fmtEscapes(element_name.ns),
                    std.zig.fmtEscapes(element_name.local),
                });
                for (0..reader.reader.attributeCount()) |i| {
                    const attribute_name = reader.attributeNameNs(i);
                    try stdout.print("  attribute: \"{}\"[\"{}\"]:\"{}\" = \"{}\"\n", .{
                        std.zig.fmtEscapes(attribute_name.prefix),
                        std.zig.fmtEscapes(attribute_name.ns),
                        std.zig.fmtEscapes(attribute_name.local),
                        std.zig.fmtEscapes(try reader.attributeValue(i)),
                    });
                }
            },
            .element_end => {
                const element_name = reader.elementNameNs();
                try stdout.print("element_end: \"{}\"[\"{}\"]:\"{}\"\n", .{
                    std.zig.fmtEscapes(element_name.prefix),
                    std.zig.fmtEscapes(element_name.ns),
                    std.zig.fmtEscapes(element_name.local),
                });
            },
            .comment => {
                try stdout.print("comment: \"{}\"\n", .{
                    std.zig.fmtEscapes(try reader.comment()),
                });
            },
            .pi => {
                try stdout.print("pi: \"{}\" \"{}\"\n", .{
                    std.zig.fmtEscapes(reader.piTarget()),
                    std.zig.fmtEscapes(try reader.piData()),
                });
            },
            .text => {
                try stdout.print("text: \"{}\"\n", .{
                    std.zig.fmtEscapes(try reader.text()),
                });
            },
            .cdata => {
                try stdout.print("cdata: \"{}\"\n", .{
                    std.zig.fmtEscapes(try reader.cdata()),
                });
            },
            .entity_reference => {
                try stdout.print("entity_reference: \"{}\"\n", .{
                    std.zig.fmtEscapes(reader.entityReferenceName()),
                });
            },
            .character_reference => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(reader.characterReferenceChar(), &buf) catch unreachable;
                try stdout.print("character_reference: {} ('{'}')\n", .{
                    reader.characterReferenceChar(),
                    std.zig.fmtEscapes(buf[0..len]),
                });
            },
        }
    }

    try stdout_buf.flush();
}
