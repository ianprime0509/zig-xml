const std = @import("std");
const root = @import("root");

pub usingnamespace if (@hasDecl(root, "enable_tracy") and root.enable_tracy) tracy_real else tracy_stub;

const tracy_stub = struct {
    pub const Frame = struct {
        pub inline fn end(_: Frame) void {}
    };

    pub inline fn frame(_: ?[*c]const u8) Frame {
        return .{};
    }

    pub const Ctx = struct {
        pub inline fn end(_: Ctx) void {}
    };

    pub inline fn trace(comptime _: std.builtin.SourceLocation, _: ?[*c]const u8) Ctx {
        return .{};
    }
};

const tracy_real = struct {
    // https://github.com/nektro/zig-tracy/blob/f4c2de6ccae95f8f8a561653d35c078e80e4c7a8/src/lib.zig

    // MIT License
    //
    // Copyright (c) 2021 Meghan Denny
    //
    // Permission is hereby granted, free of charge, to any person obtaining a copy
    // of this software and associated documentation files (the "Software"), to deal
    // in the Software without restriction, including without limitation the rights
    // to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    // copies of the Software, and to permit persons to whom the Software is
    // furnished to do so, subject to the following conditions:
    //
    // The above copyright notice and this permission notice shall be included in all
    // copies or substantial portions of the Software.
    //
    // THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    // IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    // FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    // AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    // LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    // OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    // SOFTWARE.

    pub const c = @cImport({
        @cDefine("TRACY_ENABLE", "");
        @cInclude("TracyC.h");
    });

    pub const Frame = struct {
        name: [:0]const u8,

        pub fn end(self: Frame) void {
            c.___tracy_emit_frame_mark_end(self.name.ptr);
        }
    };

    pub fn frame(name: ?[:0]const u8) Frame {
        const f = Frame{
            .name = if (name) |n| n else null,
        };
        c.___tracy_emit_frame_mark_start(f.name.ptr);
        return f;
    }

    pub const Ctx = struct {
        c: c.___tracy_c_zone_context,

        pub fn end(self: Ctx) void {
            c.___tracy_emit_zone_end(self.c);
        }
    };

    // Cannot be inline due to https://github.com/ziglang/zig/issues/15668
    pub fn trace(comptime src: std.builtin.SourceLocation, name: ?[:0]const u8) Ctx {
        const loc: c.___tracy_source_location_data = .{
            .name = if (name) |n| n.ptr else null,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        };
        return Ctx{
            .c = c.___tracy_emit_zone_begin_callstack(&loc, 1, 1),
        };
    }
};
