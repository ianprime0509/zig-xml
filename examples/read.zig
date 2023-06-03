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
    var reader = xml.reader(allocator, input_buffered_reader.reader());
    defer reader.deinit();

    while (try reader.next()) |event| {
        try printEvent(stdout, event);
    }
    try stdout_buffered_writer.flush();
}

fn printEvent(out: anytype, event: xml.Event) !void {
    switch (event) {
        .element_start => |element_start| try out.print("<{s}\n", .{element_start.name}),
        .element_content => |element_content| {
            try out.print(".{s} ", .{element_content.element_name});
            try printContent(out, element_content.content);
            _ = try out.write("\n");
        },
        .element_end => |element_end| try out.print("/{s}\n", .{element_end.name}),
        .attribute_start => |attribute_start| try out.print("*{s} ={s}\n", .{ attribute_start.element_name, attribute_start.name }),
        .attribute_content => |attribute_content| {
            try out.print("*{s} .{s} ", .{ attribute_content.element_name, attribute_content.attribute_name });
            try printContent(out, attribute_content.content);
            _ = try out.write("\n");
        },
        .comment_start => _ = try out.write("!<\n"),
        .comment_content => |comment_content| try out.print("!. {s}\n", .{comment_content.content}),
        .pi_start => |pi_start| try out.print("?<{s}\n", .{pi_start.target}),
        .pi_content => |pi_content| try out.print("?.{s} {s}\n", .{ pi_content.pi_target, pi_content.content }),
    }
}

fn printContent(out: anytype, content: xml.Event.Content) !void {
    switch (content) {
        .text => |text| _ = try out.write(text),
        .entity_ref => |entity_ref| try out.print("entity_ref: {s}", .{entity_ref}),
        .char_ref => |char_ref| try out.print("char_ref: {u}", .{char_ref}),
    }
}
