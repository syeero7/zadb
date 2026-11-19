const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

const Status = enum {
    okay,
    fail,
    done,
    dent,

    pub fn fromString(string: []const u8) !@This() {
        var buffer: [4]u8 = undefined;
        const lowercased = std.ascii.lowerString(&buffer, string);

        const status_info = comptime @typeInfo(Status).@"enum";
        inline for (status_info.field_names, status_info.field_values) |key, value| {
            if (mem.eql(u8, key, lowercased)) return @fromBackingInt(value);
        }

        return error.UnkownStatus;
    }
};

pub fn version(writer: *Io.Writer, reader: *Io.Reader, allocator: Allocator) ![]const u8 {
    const payload = "host:version";
    const request = fmt.comptimePrint("{x:0>4}{s}", .{ payload.len, payload });
    try writer.writeAll(request);
    try writer.flush();

    switch (try status(reader)) {
        .okay => {
            const len = try length(reader);
            return reader.readAllocAll(allocator, len);
        },
        .fail => {
            // TODO:
            @panic("not implemented");
        },
        else => unreachable,
    }
}

fn length(reader: *Io.Reader) !usize {
    const result = try reader.take(4);
    return fmt.parseInt(usize, result, 16);
}

fn status(reader: *Io.Reader) !Status {
    const result = try reader.take(4);
    return Status.fromString(result);
}
