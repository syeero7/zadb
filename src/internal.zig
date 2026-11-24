const std = @import("std");
const Io = std.Io;
const net = Io.net;
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;
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

pub const DeviceInfo = struct {
    const Status = enum {
        device,
        offline,
        unauthoried,
        authorizing,
        unkown,

        pub fn fromString(string: []const u8) @This() {
            const status_info = comptime @typeInfo(DeviceInfo.Status).@"enum";
            inline for (status_info.field_names, status_info.field_values) |key, value| {
                if (mem.eql(u8, key, string)) return @fromBackingInt(value);
            }

            return .unkown;
        }
    };

    serial: []const u8,
    device: ?[]const u8 = null,
    model: ?[]const u8 = null,
    product: ?[]const u8 = null,
    status: DeviceInfo.Status = .unkown,

    pub fn init(device_line: []const u8) @This() {
        var device_info: DeviceInfo = undefined;
        const device_serial_end = mem.findScalar(u8, device_line, ' ').?;
        device_info.serial = device_line[0..device_serial_end];

        const device_line_excluding_serial = mem.trimStart(u8, device_line[device_serial_end..], " ");
        const device_status_end = mem.findScalar(u8, device_line_excluding_serial, ' ').?;
        device_info.status = .fromString(device_line_excluding_serial[0..device_status_end]);
        if (device_info.status != .device) return device_info;

        const device_line_rest = device_line_excluding_serial[device_status_end..];
        inline for ([_][]const u8{ "product", "model", "device" }) |field| {
            const prefix = field ++ ":";
            if (mem.find(u8, device_line_rest, prefix)) |field_start| {
                const field_value_start = field_start + prefix.len;
                const field_end = mem.findScalarPos(u8, device_line_rest, field_value_start, ' ').?;
                @field(device_info, field) = device_line_rest[field_value_start..field_end];
            }
        }

        return device_info;
    }
};

test "parse device line" {
    const expected = DeviceInfo{
        .serial = "SX1QW2RE48F",
        .status = .device,
        .product = "brick01s",
        .model = "B01fx",
        .device = "brick01",
    };

    const device_line = fmt.comptimePrint("{s}{s}{s} usb:3-2 product:{s} model:{s} device:{s} transport_id:2", .{
        expected.serial,
        @as([12]u8, @splat(' ')),
        @tagName(expected.status),
        expected.product.?,
        expected.model.?,
        expected.device.?,
    });

    try testing.expectEqualDeep(expected, DeviceInfo.init(device_line));
}

pub const TransportMode = union(enum) {
    serial_number: []const u8,
    usb,
    local,
    any,

    pub fn toPayload(self: @This(), allocator: Allocator) ![]const u8 {
        const prefix = "host:transport";
        return switch (self) {
            .serial_number => |serial| mem.concat(allocator, u8, &.{ prefix, ":", serial }),
            else => mem.concat(allocator, u8, &.{ prefix, "-", @tagName(self) }),
        };
    }
};

pub const Transport = struct {
    const buffer_size = 1024 * 4;
    stream: net.Stream,
    w_buffer: [buffer_size]u8 = undefined,
    stream_writer: net.Stream.Writer,
    r_buffer: [buffer_size]u8 = undefined,
    stream_reader: net.Stream.Reader,

    pub fn init(io: Io, allocator: Allocator, address: net.IpAddress, mode: TransportMode) !@This() {
        var t: Transport = undefined;
        t.stream = try address.connect(io, .{ .protocol = .tcp, .mode = .stream });
        errdefer t.stream.close(io);
        t.stream_writer = t.stream.writer(io, &t.w_buffer);
        t.stream_reader = t.stream.reader(io, &t.r_buffer);
        try t.execute(io, transport, .{ allocator, mode });
        return t;
    }

    pub fn execute(self: *@This(), io: Io, comptime callback: anytype, args: anytype) !void {
        _ = io;
        const rw_args = .{ &self.stream_writer.interface, &self.stream_reader.interface };
        try @call(.auto, callback, rw_args ++ args);
    }

    pub fn deinit(self: @This(), io: Io) void {
        defer self.stream.close(io);
        self.stream.shutdown(io, .both) catch |err| @panic(@errorName(err));
    }
};

pub fn version(writer: *Io.Writer, reader: *Io.Reader) !u32 {
    const payload = "host:version";
    const request = fmt.comptimePrint("{x:0>4}{s}", .{ payload.len, payload });
    try writer.writeAll(request);
    try writer.flush();

    switch (try status(reader)) {
        .okay => {
            const len = try length(reader);
            const version_string = try reader.take(len);
            return fmt.parseInt(u32, version_string, 10);
        },
        .fail => {
            // TODO:
            @panic("not implemented");
        },
        else => unreachable,
    }
}

pub fn kill(writer: *Io.Writer, reader: *Io.Reader) !void {
    const payload = "host:kill";
    const request = fmt.comptimePrint("{x:0>4}{s}", .{ payload.len, payload });
    try writer.writeAll(request);
    try writer.flush();

    switch (try status(reader)) {
        .okay => return,
        .fail => {
            // TODO:
            @panic("not implemented");
        },
        else => unreachable,
    }
}

pub fn devices(writer: *Io.Writer, reader: *Io.Reader, allocator: Allocator) ![]DeviceInfo {
    const payload = "host:devices-l";
    const request = fmt.comptimePrint("{x:0>4}{s}", .{ payload.len, payload });
    try writer.writeAll(request);
    try writer.flush();

    switch (try status(reader)) {
        .okay => {
            var device_list: std.ArrayList(DeviceInfo) = .empty;
            errdefer device_list.deinit(allocator);

            _ = try reader.discard(.limited(4));
            while (try reader.takeDelimiter('\n')) |device_line| {
                try device_list.append(allocator, .init(device_line));
            }

            return device_list.toOwnedSlice(allocator);
        },
        .fail => {
            // TODO:
            @panic("not implemented");
        },
        else => unreachable,
    }
}

pub fn transport(
    writer: *Io.Writer,
    reader: *Io.Reader,
    allocator: Allocator,
    mode: TransportMode,
) !void {
    const payload = try mode.toPayload(allocator);
    defer allocator.free(payload);

    const request = try allocator.print("{x:0>4}{s}", .{ payload.len, payload });
    defer allocator.free(request);
    try writer.writeAll(request);
    try writer.flush();

    switch (try status(reader)) {
        .okay => {},
        .fail => {
            // TODO:
            @panic("not implemented");
        },
        else => unreachable,
    }
}

const ShellResult = struct {
    const Kind = enum(u8) {
        stderr = '2',
        stdout = '1',
        exit = '3',
    };
};

pub fn command(writer: *Io.Writer, reader: *Io.Reader, allocator: Allocator, cmd_string: []const u8) !void {
    const payload = try mem.concat(allocator, u8, &.{ "shell,v2:", cmd_string });
    defer allocator.free(payload);

    const request = try allocator.print("{x:0>4}{s}", .{ payload.len, payload });
    defer allocator.free(request);
    try writer.writeAll(request);
    try writer.flush();

    switch (try status(reader)) {
        .okay => {
            const rem = try reader.allocRemaining(allocator, .limited(1024 * 5));
            defer allocator.free(rem);
            std.debug.print("output: {any}\n", .{rem});
        },
        .fail => {
            // TODO:

            const len = try length(reader);
            const version_string = try reader.take(len);
            std.debug.print("output: {s}\n", .{version_string});
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
