//! Compatibility wrappers for APIs changed since Zig 0.12.

const std = @import("std");

pub fn ComptimeStringMapType(comptime V: type) type {
    return if (@hasDecl(std, "ComptimeStringMap"))
        type
    else
        std.StaticStringMap(V);
}

pub fn ComptimeStringMap(comptime V: type, comptime kvs_list: anytype) ComptimeStringMapType(V) {
    return if (@hasDecl(std, "ComptimeStringMap"))
        std.ComptimeStringMap(V, kvs_list)
    else
        std.StaticStringMap(V).initComptime(kvs_list);
}
