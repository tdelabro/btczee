//! P2P module handles the peer-to-peer networking of btczee.
//! It is responsible for the connection to other nodes in the network.
//! It can receive and send messages to other nodes, based on the Bitcoin protocol.
const std = @import("std");
const net = std.net;
const Config = @import("../config/config.zig").Config;
const Peer = @import("peer.zig").Peer;
const Boundness = @import("peer.zig").Boundness;
const wire = @import("wire/lib.zig");
const protocol = @import("protocol/lib.zig");
const PeerWorker = @import("PeerWorker.zig");

/// P2P network handler.
pub const P2P = struct {
    /// Allocator.
    allocator: std.mem.Allocator,
    /// Configuration.
    config: *const Config,
    /// List of peers.
    peers: std.ArrayList(*Peer),
    /// Thread pool for all p2p actions
    server_thread_pool: std.Thread.Pool = undefined,

    /// The thread listening to incomming connections on the p2p port
    listen_handle: std.Thread = undefined,
    should_listen: bool = false,

    /// A queue of received incomming messages
    in_peers: std.ArrayList(*Peer),
    in_peers_mtx: std.Thread.Mutex = std.Thread.Mutex{},

    //
    peer_worker: PeerWorker,
    peer_worker_thread: std.Thread = undefined,

    const Self = @This();

    /// Initialize the P2P network handler.
    pub fn init(allocator: std.mem.Allocator, config: *const Config) !P2P {
        return P2P{
            .allocator = allocator,
            .config = config,
            .peers = std.ArrayList(*Peer).init(allocator),
            .in_peers = std.ArrayList(*Peer).init(allocator),
            .peer_worker = try PeerWorker.init(allocator),
        };
    }

    pub fn kill(self: *Self) void {
        self.server_thread_pool.deinit();
        self.deinit();
    }

    /// Deinitialize the P2P network handler.
    pub fn deinit(self: *Self) void {
        for (self.peers.items) |peer| {
            peer.deinit();
        }
        self.peers.deinit();
        for (self.in_peers.items) |peer| {
            peer.deinit();
        }
        self.in_peers.deinit();
    }

    /// Start the P2P network handler.
    pub fn start(self: *Self) !void {
        // Init the peer connection mempool
        try std.Thread.Pool.init(&self.server_thread_pool, .{ .allocator = self.allocator, .n_jobs = 8 });
        errdefer self.server_thread_pool.deinit();

        self.peer_worker = try PeerWorker.init(self.allocator);
        self.peer_worker_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, PeerWorker.start, .{ &self.peer_worker, self.allocator, self.config.network_id });

        // Initializing a few outbound connections
        var n_outboud_peer: u8 = 0;
        seeds: for (self.config.dnsSeeds()) |seed| {
            const address_list = try std.net.getAddressList(self.allocator, seed.inner, 8333);
            for (address_list.addrs) |address| {
                var peer = Peer.newOutbound(self.allocator, self.config, address) catch continue;
                errdefer peer.deinit();
                try self.peers.append(peer);
                peer.handshake() catch continue;
                try self.server_thread_pool.spawn(
                    Peer.listen,
                    .{ peer, &self.server_thread_pool },
                );

                n_outboud_peer += 1;
                // TODO: replace the hardcoded value with one from config
                if (n_outboud_peer == 8) {
                    break :seeds;
                }
            }
        }
        std.log.info("Connected to {d} nodes", .{n_outboud_peer});

        self.should_listen = true;
        self.listen_handle = try std.Thread.spawn(.{ .allocator = self.allocator }, Self.listen, .{self});
    }

    pub fn listen(
        self: *Self,
    ) !void {
        const my_address = try std.net.Address.parseIp("127.0.0.1", self.config.p2p_port);
        var server = try my_address.listen(.{ .force_nonblocking = true });
        defer server.deinit();
        // Listening to inboud connections
        std.log.info("Starting P2P listening on port {}", .{self.config.p2p_port});

        while (self.should_listen) {
            const conn = server.accept() catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return e,
            };
            errdefer conn.stream.close();

            const peer = try Peer.newInbound(self.allocator, self.config, conn);

            self.in_peers_mtx.lock();
            try self.in_peers.append(peer);
            self.in_peers_mtx.unlock();
            try std.Thread.yield();
        }
    }
};
