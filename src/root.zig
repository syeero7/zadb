const std = @import("std");

pub const Client = @import("Client.zig");

test {
    _ = @import("internal.zig");
    std.testing.refAllDecls(@This());
}
