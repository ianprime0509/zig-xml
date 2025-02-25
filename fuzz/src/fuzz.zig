const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const xml = @import("xml");

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();
    fuzz(gpa, buf[0..@intCast(len)]) catch @panic("OOM");
}

fn fuzz(gpa: Allocator, input: []const u8) !void {
    var fbs = std.io.fixedBufferStream(input);
    var doc = xml.streamingDocument(gpa, fbs.reader());
    defer doc.deinit();
    var reader = doc.reader(gpa, .{});
    defer reader.deinit();

    var out_bytes = std.ArrayList(u8).init(gpa);
    defer out_bytes.deinit();
    const output = xml.streamingOutput(out_bytes.writer());
    var writer = output.writer(gpa, .{});
    defer writer.deinit();

    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => break,
            error.OutOfMemory => return error.OutOfMemory,
        };
        switch (node) {
            .eof => break,
            .xml_declaration => {
                try writer.xmlDeclaration(reader.xmlDeclarationEncoding(), reader.xmlDeclarationStandalone());
            },
            .comment => {
                // TODO: not implemented yet
            },
            .element_start => {
                try writer.elementStart(reader.elementName());
                for (0..reader.attributeCount()) |i| {
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
}
