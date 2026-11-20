const std = @import("std");
const zadb = @import("zadb");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // const gpa = init.gpa;

    const client = try zadb.Client.init(.default);
    const version = try client.version(io);
    std.debug.print("version: {d}\n", .{version});
}
