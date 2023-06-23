const xml = @import("xml");

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var scanner = xml.Scanner{};
    var decoder = xml.encoding.Utf8Decoder{};
    for (data) |b| {
        if (try decoder.next(b)) |c| {
            _ = try scanner.next(c, 1);
        }
    }
}
