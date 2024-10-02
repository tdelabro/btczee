const std = @import("std");
const net = std.net;
const protocol = @import("./protocol/lib.zig");
const wire = @import("./wire/lib.zig");
const Config = @import("../config/config.zig").Config;
const utils = @import("./utils.zig");

pub const Boundness = enum {
    inbound,
    outbound,

    pub fn isOutbound(self: Boundness) bool {
        return self == Boundness.outbound;
    }
    pub fn isInbound(self: Boundness) bool {
        return self == Boundness.inbound;
    }
};

/// Represents a peer connection in the Bitcoin network
pub const Peer = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    stream: net.Stream,
    address: net.Address,
    protocol_version: ?i32 = null,
    services: ?u64 = null,
    last_seen: i64,
    boundness: Boundness,
    should_listen: bool = false,

    const Self = @This();

    pub fn newOutbound(allocator: std.mem.Allocator, config: *const Config, address: net.Address) !*Self {
        const peer = try allocator.create(Self);
        errdefer allocator.destroy(peer);
        const stream = try utils.tcpConnectToAddressNonBlocking(address);

        peer.init(allocator, config, stream, address, Boundness.outbound);

        return peer;
    }

    pub fn newInbound(allocator: std.mem.Allocator, config: *const Config, conn: net.Server.Connection) !*Self {
        const peer = try allocator.create(Self);

        peer.init(allocator, config, conn.stream, conn.address, Boundness.inbound);

        return peer;
    }

    /// Initialize a new peer
    fn init(self: *Self, allocator: std.mem.Allocator, config: *const Config, stream: net.Stream, address: net.Address, boundness: Boundness) void {
        self.* = .{
            .allocator = allocator,
            .config = config,
            .stream = stream,
            .address = address,
            .last_seen = std.time.timestamp(),
            .boundness = boundness,
        };
    }

    /// Clean up peer resources
    pub fn deinit(self: *Self) void {
        self.stream.close();
        self.allocator.destroy(self);
    }

    /// Start peer operations
    pub fn handshake(self: *Self) !void {
        std.log.info("Starting peer connection with {}", .{self.address});
        if (self.boundness.isOutbound()) {
            try self.negociateProtocolOutboundConnection();
        } else {
            // Not implemented yet
            unreachable;
        }

        self.should_listen = true;
        std.log.info("Connected to {}", .{self.address});
    }

    fn negociateProtocolOutboundConnection(self: *Self) !void {
        try self.sendVersionMessage();

        var seen_version = false;
        while (true) {
            const received_message = try wire.pollMessage(self.allocator, self.stream.reader(), self.config.network_id) orelse continue;

            switch (received_message) {
                .version => |vm| {
                    if (seen_version) return error.InvalidHandshake else {
                        self.protocol_version = @min(self.config.protocol_version, vm.version);
                        self.services = vm.trans_services;
                        seen_version = true;
                    }
                },
                .verack => return if (seen_version) {} else error.InvalidHandshake,
                else => return error.InvalidHandshake,
            }
        }
    }

    /// Send version message to peer
    fn sendVersionMessage(self: *Self) !void {
        const message = protocol.messages.VersionMessage.new(
            self.config.protocol_version,
            .{ .ip = std.mem.zeroes([16]u8), .port = 0, .services = self.config.services },
            .{ .ip = self.address.in6.sa.addr, .port = self.address.in6.getPort(), .services = 0 },
            std.crypto.random.int(u64),
            self.config.bestBlock(),
        );

        try wire.sendMessage(
            self.allocator,
            self.stream.writer(),
            self.config.protocol_version,
            self.config.network_id,
            message,
        );
    }

    /// Listen and handle new messages
    pub fn listen(self: *Self, pool: *std.Thread.Pool) void {
        const opt_message = wire.pollMessage(self.allocator, self.stream.reader(), self.config.network_id) catch {
            self.should_listen = false;
            return;
        };
        if (opt_message) |message| {
            switch (message) {
                // We only received those during handshake, seeing them again is an error
                .version, .verack => {
                    self.should_listen = false;
                    return;
                },
                // TODO: handle other messages correctly
                else => |_| {
                    std.log.info("Self {any} sent a `{s}` message", .{ self.address, message.name() });
                },
            }
        }

        // Continue listening
        pool.spawn(Peer.listen, .{ self, pool }) catch {};
    }
};
