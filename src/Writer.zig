const std = @import("std");
const assert = std.debug.assert;

options: Options,

state: State,
indent_level: u32,

sink: Sink,

const Writer = @This();

pub const Options = struct {
    indent: []const u8 = "",
};

pub const Sink = struct {
    context: *const anyopaque,
    writeFn: *const fn (context: *const anyopaque, data: []const u8) anyerror!void,

    pub fn write(sink: *Sink, data: []const u8) anyerror!void {
        return sink.writeFn(sink.context, data);
    }
};

const State = enum {
    start,
    after_bom,
    after_xml_declaration,
    element_start,
    after_structure_end,
    text,
    end,
};

pub fn init(sink: Sink, options: Options) Writer {
    return .{
        .options = options,

        .state = .start,
        .indent_level = 0,

        .sink = sink,
    };
}

pub const WriteError = error{};

pub fn bom(writer: *Writer) anyerror!void {
    assert(writer.state == .start);
    try writer.raw("\u{FEFF}");
    writer.state = .after_bom;
}

pub fn xmlDeclaration(writer: *Writer, encoding: ?[]const u8, standalone: ?bool) anyerror!void {
    assert(writer.state == .start or writer.state == .after_bom);
    try writer.raw("<?xml version=\"1.0\"");
    if (encoding) |e| {
        try writer.raw(" encoding=\"");
        try writer.attributeText(e);
        try writer.raw("\"");
    }
    if (standalone) |s| {
        if (s) {
            try writer.raw(" standalone=\"yes\"");
        } else {
            try writer.raw(" standalone=\"no\"");
        }
    }
    try writer.raw("?>");
    if (writer.options.indent.len > 0) try writer.newLineAndIndent();
    writer.state = .after_xml_declaration;
}

pub fn elementStart(writer: *Writer, name: []const u8) anyerror!void {
    switch (writer.state) {
        .start, .after_bom, .after_xml_declaration, .text => {},
        .element_start => {
            try writer.raw(">");
            try writer.newLineAndIndent();
        },
        .after_structure_end => {
            try writer.newLineAndIndent();
        },
        .end => unreachable,
    }
    try writer.raw("<");
    try writer.raw(name);
    writer.state = .element_start;
    writer.indent_level += 1;
}

pub fn elementEnd(writer: *Writer, name: []const u8) anyerror!void {
    writer.indent_level -= 1;
    switch (writer.state) {
        .text => {},
        .element_start => {
            try writer.raw(">");
            try writer.newLineAndIndent();
        },
        .after_structure_end => {
            try writer.newLineAndIndent();
        },
        .start, .after_bom, .after_xml_declaration, .end => unreachable,
    }
    try writer.raw("</");
    try writer.raw(name);
    try writer.raw(">");
    writer.state = if (writer.indent_level > 0) .after_structure_end else .end;
}

pub fn elementEndEmpty(writer: *Writer) anyerror!void {
    assert(writer.state == .element_start);
    try writer.raw("/>");
    writer.state = .after_structure_end;
    writer.indent_level -= 1;
}

pub fn attribute(writer: *Writer, name: []const u8, value: []const u8) anyerror!void {
    assert(writer.state == .element_start);
    try writer.raw(" ");
    try writer.raw(name);
    try writer.raw("=\"");
    try writer.attributeText(value);
    try writer.raw("\"");
}

fn attributeText(writer: *Writer, s: []const u8) anyerror!void {
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, s, pos, "\r\n\t&<\"")) |esc_pos| {
        try writer.raw(s[pos..esc_pos]);
        try writer.raw(switch (s[esc_pos]) {
            '\r' => "&#xD;",
            '\n' => "&#xA;",
            '\t' => "&#x9;",
            '&' => "&amp;",
            '<' => "&lt;",
            '"' => "&quot;",
            else => unreachable,
        });
        pos = esc_pos + 1;
    }
    try writer.raw(s[pos..]);
}

pub fn pi(writer: *Writer, target: []const u8, data: []const u8) anyerror!void {
    switch (writer.state) {
        .start, .after_bom, .after_xml_declaration, .text, .end => {},
        .element_start => {
            try writer.raw(">");
            try writer.newLineAndIndent();
        },
        .after_structure_end => {
            try writer.newLineAndIndent();
        },
    }
    try writer.raw("<?");
    try writer.raw(target);
    try writer.raw(" ");
    try writer.raw(data);
    try writer.raw("?>");
    writer.state = .after_structure_end;
}

pub fn text(writer: *Writer, s: []const u8) anyerror!void {
    switch (writer.state) {
        .after_structure_end, .text => {},
        .element_start => try writer.raw(">"),
        .start, .after_bom, .after_xml_declaration, .end => unreachable,
    }
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, s, pos, "\r&<")) |esc_pos| {
        try writer.raw(s[pos..esc_pos]);
        try writer.raw(switch (s[esc_pos]) {
            '\r' => "&#xD;",
            '&' => "&amp;",
            '<' => "&lt;",
            else => unreachable,
        });
        pos = esc_pos + 1;
    }
    try writer.raw(s[pos..]);
    writer.state = .text;
}

// insert some existing XML document without escaping anything
pub fn embed(writer: *Writer, s: []const u8) anyerror!void {
    switch (writer.state) {
        .start, .after_bom, .after_xml_declaration, .after_structure_end, .text, .end => {},
        .element_start => try writer.raw(">"),
    }
    try writer.raw(s);
    writer.state = switch (writer.state) {
        .start, .after_bom, .after_xml_declaration => .after_xml_declaration,
        .element_start, .after_structure_end, .text => .text,
        .end => .end,
    };
}

fn newLineAndIndent(writer: *Writer) anyerror!void {
    if (writer.options.indent.len == 0) return;

    try writer.raw("\n");
    var n: usize = 0;
    while (n < writer.indent_level) : (n += 1) {
        try writer.raw(writer.options.indent);
    }
}

fn raw(writer: *Writer, s: []const u8) anyerror!void {
    try writer.sink.write(s);
}
