const std = @import("std");
const xml = @import("xml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        return error.InvalidArguments;
    }
    const input_path = args[1];

    const stdout_raw = std.io.getStdOut().writer();
    var stdout_buffered_writer = std.io.bufferedWriter(stdout_raw);
    const stdout = stdout_buffered_writer.writer();

    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();
    var input_buffered_reader = std.io.bufferedReader(input_file.reader());
    var reader = xml.reader(allocator, input_buffered_reader.reader(), xml.encoding.Utf8Decoder{});
    defer reader.deinit();

    while (try reader.next()) |event| {
        try printEvent(stdout, event);
    }
    try stdout_buffered_writer.flush();
}

fn printEvent(out: anytype, event: xml.Event) !void {
    switch (event) {
        .element_start => |element_start| {
            try out.print("<{?s}({?s}):{s}\n", .{ element_start.name.prefix, element_start.name.ns, element_start.name.local });
            for (element_start.attributes) |attr| {
                try out.print("  @{?s}({?s}):{s}={s}\n", .{ attr.name.prefix, attr.name.ns, attr.name.local, attr.value });
            }
        },
        .element_content => |element_content| try out.print("  {s}\n", .{element_content.content}),
        .element_end => |element_end| try out.print("/{?s}({?s}):{s}\n", .{ element_end.name.prefix, element_end.name.ns, element_end.name.local }),
        .comment => |comment| try out.print("<!--{s}\n", .{comment.content}),
        .pi => |pi| try out.print("<?{s} {s}\n", .{ pi.target, pi.content }),
    }
}
