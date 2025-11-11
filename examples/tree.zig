const std = @import("std");
const xml = @import("xml");

// deinit functions are omitted for brevity; this example uses an arena to
// store all allocations for the nodes so we don't have to worry about it.

const Document = struct {
    root_nodes: []const Node,

    fn parse(arena: std.mem.Allocator, reader: *xml.Reader) !Document {
        var root_nodes: std.ArrayList(Node) = .empty;
        while (true) {
            const node = try reader.read();
            switch (node) {
                .eof => break,
                .xml_declaration => continue,
                .element_start => try root_nodes.append(arena, .{ .element = try parseElement(arena, reader) }),
                .element_end => unreachable,
                .comment => continue,
                .pi => try root_nodes.append(arena, .{ .pi = try parsePi(arena, reader) }),
                .text, .cdata, .character_reference, .entity_reference => unreachable,
            }
        }
        return .{ .root_nodes = try root_nodes.toOwnedSlice(arena) };
    }

    fn parseElement(arena: std.mem.Allocator, reader: *xml.Reader) !Node.Element {
        const name = try arena.dupe(u8, reader.elementName());
        var attributes: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (0..reader.attributeCount()) |i| {
            try attributes.put(
                arena,
                try arena.dupe(u8, reader.attributeName(i)),
                try reader.attributeValueAlloc(arena, i),
            );
        }

        var children: std.ArrayList(Node) = .empty;
        var text: std.Io.Writer.Allocating = .init(arena);
        while (true) {
            const node = try reader.read();
            switch (node) {
                .eof, .xml_declaration => unreachable,
                .element_start => {
                    if (text.written().len > 0) {
                        try children.append(arena, .{ .text = try text.toOwnedSlice() });
                    }
                    try children.append(arena, .{ .element = try parseElement(arena, reader) });
                },
                .element_end => break,
                .comment => continue,
                .pi => {
                    if (text.written().len > 0) {
                        try children.append(arena, .{ .text = try text.toOwnedSlice() });
                    }
                    try children.append(arena, .{ .pi = try parsePi(arena, reader) });
                },
                .text => reader.textWrite(&text.writer) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                },
                .cdata => reader.cdataWrite(&text.writer) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                },
                .character_reference => {
                    text.writer.print("{u}", .{reader.characterReferenceChar()}) catch |err| switch (err) {
                        error.WriteFailed => return error.OutOfMemory,
                    };
                },
                .entity_reference => {
                    const value = xml.predefined_entities.get(reader.entityReferenceName()).?;
                    text.writer.writeAll(value) catch |err| switch (err) {
                        error.WriteFailed => return error.OutOfMemory,
                    };
                },
            }
        }
        if (text.written().len > 0) {
            try children.append(arena, .{ .text = try text.toOwnedSlice() });
        }

        return .{
            .name = name,
            .attributes = attributes,
            .children = try children.toOwnedSlice(arena),
        };
    }

    fn parsePi(arena: std.mem.Allocator, reader: *xml.Reader) !Node.Pi {
        const target = try arena.dupe(u8, reader.piTarget());
        var data: std.Io.Writer.Allocating = .init(arena);
        reader.piDataWrite(&data.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        return .{ .target = target, .data = try data.toOwnedSlice() };
    }

    fn dump(document: Document, writer: *std.Io.Writer) !void {
        for (document.root_nodes) |node| {
            try dumpNode(node, writer, 0);
        }
    }

    fn dumpNode(node: Node, writer: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void {
        switch (node) {
            .element => |element| try dumpElement(element, writer, indent),
            .pi => |pi| try dumpPi(pi, writer, indent),
            .text => |text| try dumpText(text, writer, indent),
        }
    }

    fn dumpElement(element: Node.Element, writer: *std.Io.Writer, indent: usize) !void {
        try dumpIndent(writer, indent);
        try writer.print("<{s}", .{element.name});
        for (element.attributes.keys(), element.attributes.values()) |name, value| {
            try writer.print(" {s}=\"{f}\"", .{ name, std.zig.fmtString(value) });
        }
        try writer.writeAll(">\n");
        for (element.children) |child| {
            try dumpNode(child, writer, indent + 1);
        }
    }

    fn dumpPi(pi: Node.Pi, writer: *std.Io.Writer, indent: usize) !void {
        try dumpIndent(writer, indent);
        try writer.print("<?{s} {s}?>", .{ pi.target, pi.data });
    }

    fn dumpText(text: []const u8, writer: *std.Io.Writer, indent: usize) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            try dumpIndent(writer, indent);
            try writer.print("|{s}\n", .{line});
        }
    }

    fn dumpIndent(writer: *std.Io.Writer, indent: usize) !void {
        for (0..indent) |_| {
            try writer.writeAll("  ");
        }
    }
};

const Node = union(enum) {
    element: Element,
    pi: Pi,
    text: []const u8,

    const Element = struct {
        name: []const u8,
        attributes: std.StringArrayHashMapUnmanaged([]const u8),
        children: []const Node,
    };

    const Pi = struct {
        target: []const u8,
        data: []const u8,
    };
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) {
        return error.InvalidArguments; // usage: tree file
    }

    var input_file = try std.fs.cwd().openFile(args[1], .{});
    defer input_file.close();
    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(&input_buf);
    var streaming_reader: xml.Reader.Streaming = .init(gpa, &input_reader.interface, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const document: Document = try .parse(arena, reader);
    try document.dump(stdout);
    try stdout.flush();
}
