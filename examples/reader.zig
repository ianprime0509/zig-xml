const std = @import("std");
const log = std.log;
const xml = @import("xml");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) {
        return error.InvalidArguments; // usage: reader file
    }

    var input_file = try std.fs.cwd().openFile(args[1], .{});
    defer input_file.close();
    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(&input_buf);
    var streaming_reader: xml.Reader.Streaming = .init(gpa, &input_reader.interface, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

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
                try stdout.print("xml_declaration: version={s} encoding={?s} standalone={?}\n", .{
                    reader.xmlDeclarationVersion(),
                    reader.xmlDeclarationEncoding(),
                    reader.xmlDeclarationStandalone(),
                });
            },
            .element_start => {
                const element_name = reader.elementNameNs();
                try stdout.print("element_start: \"{f}\"[\"{f}\"]:\"{f}\"\n", .{
                    std.zig.fmtString(element_name.prefix),
                    std.zig.fmtString(element_name.ns),
                    std.zig.fmtString(element_name.local),
                });
                for (0..reader.attributeCount()) |i| {
                    const attribute_name = reader.attributeNameNs(i);
                    try stdout.print("  attribute: \"{f}\"[\"{f}\"]:\"{f}\" = \"{f}\"\n", .{
                        std.zig.fmtString(attribute_name.prefix),
                        std.zig.fmtString(attribute_name.ns),
                        std.zig.fmtString(attribute_name.local),
                        std.zig.fmtString(try reader.attributeValue(i)),
                    });
                }
            },
            .element_end => {
                const element_name = reader.elementNameNs();
                try stdout.print("element_end: \"{f}\"[\"{f}\"]:\"{f}\"\n", .{
                    std.zig.fmtString(element_name.prefix),
                    std.zig.fmtString(element_name.ns),
                    std.zig.fmtString(element_name.local),
                });
            },
            .comment => {
                try stdout.print("comment: \"{f}\"\n", .{
                    std.zig.fmtString(try reader.comment()),
                });
            },
            .pi => {
                try stdout.print("pi: \"{f}\" \"{f}\"\n", .{
                    std.zig.fmtString(reader.piTarget()),
                    std.zig.fmtString(try reader.piData()),
                });
            },
            .text => {
                try stdout.print("text: \"{f}\"\n", .{
                    std.zig.fmtString(try reader.text()),
                });
            },
            .cdata => {
                try stdout.print("cdata: \"{f}\"\n", .{
                    std.zig.fmtString(try reader.cdata()),
                });
            },
            .entity_reference => {
                try stdout.print("entity_reference: \"{f}\"\n", .{
                    std.zig.fmtString(reader.entityReferenceName()),
                });
            },
            .character_reference => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(reader.characterReferenceChar(), &buf) catch unreachable;
                try stdout.print("character_reference: {} (\"{f}\")\n", .{
                    reader.characterReferenceChar(),
                    std.zig.fmtString(buf[0..len]),
                });
            },
        }
    }

    try stdout.flush();
}
