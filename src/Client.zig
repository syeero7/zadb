const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;
const assert = std.debug.assert;

const internal = @import("internal.zig");

const Client = @This();

const localhost = "127.0.0.1";
const default_adb_port = 5037;

const Address = union(enum) {
    /// localhost:5037
    default,
    custom: struct {
        ip4: []const u8,
        port: u16,
    },
};

ip4: net.IpAddress,

// TODO: devices, push, pull, list, kill, shell, stat

pub fn init(address: Address) !Client {
    switch (address) {
        .default => return .{ .ip4 = try .parse(localhost, default_adb_port) },
        .custom => |custom| return .{ .ip4 = try .parse(custom.ip4, custom.port) },
    }
    unreachable;
}

pub fn version(self: @This(), io: Io) !u32 {
    return execRequest(u32, io, self.ip4, internal.version, .{});
}

pub fn kill(self: @This(), io: Io) !void {
    return execRequest(void, io, self.ip4, internal.kill, .{});
}

pub fn devices(self: @This(), io: Io, allocator: Allocator) ![]internal.DeviceInfo {
    return execRequest([]internal.DeviceInfo, io, self.ip4, internal.devices, .{allocator});
}

pub fn transport(self: @This(), io: Io, allocator: Allocator, mode: internal.TransportMode) !void {
    return execRequest(void, io, self.ip4, internal.transport, .{ allocator, mode });
}

pub fn command(self: @This(), io: Io, allocator: Allocator, cmd_string: []const u8) !void {
    var t = try internal.Transport.init(io, allocator, self.ip4, .usb);
    defer t.deinit(io);
    try t.execute(io, internal.command, .{ allocator, cmd_string });
    // return execRequest(void, io, self.ip4, internal.command, .{ allocator, cmd_string });
}

fn execRequest(
    comptime T: type,
    io: Io,
    address: net.IpAddress,
    comptime callback: anytype,
    args: anytype,
) !T {
    comptime {
        const func_info = @typeInfo(@TypeOf(callback));
        assert(func_info == .@"fn");
        assert(func_info.@"fn".param_types.len >= 2);
        assert(func_info.@"fn".param_types[0] == *Io.Writer);
        assert(func_info.@"fn".param_types[1] == *Io.Reader);
    }

    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var w_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &w_buffer);

    var r_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &r_buffer);

    const rw_args = .{ &writer.interface, &reader.interface };
    const result = try @call(.auto, callback, rw_args ++ args);
    try stream.shutdown(io, .both);
    return result;
}
