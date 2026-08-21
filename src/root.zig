//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const Loom = @import("engine/Loom.zig").Loom;
pub const Cluster = @import("engine/Cluster.zig").Cluster;
pub const Client = @import("engine/Client.zig");
pub const Scheduler = @import("engine/async/Scheduler.zig");
pub const xsuspend = @import("engine/Loom.zig").xsuspend;
pub const WebSocket = @import("engine/Websocket.zig");
pub const Logger = @import("engine/Logger.zig");
pub const Time = @import("engine/Time.zig");

test {
    // Zig only collects `test` blocks from the root source file of a
    // test binary, so every file carrying tests has to be named here or
    // its tests are silently never run.
    _ = @import("engine/Client.zig");
    _ = @import("engine/Poller.zig");
    _ = @import("engine/Logger.zig");
    _ = @import("engine/Websocket.zig");
    _ = @import("engine/wss_deflate.zig");
}
