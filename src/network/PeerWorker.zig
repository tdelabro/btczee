const std = @import("std");
const posix = std.posix;
const Peer = @import("peer.zig").Peer;
const wire = @import("wire/lib.zig");
const system = std.posix.system;

const Self = @This();

epoll: i32,
running: bool = false,
peers: std.AutoHashMap(posix.socket_t, *Peer),

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .epoll = try posix.epoll_create1(0),
        .peers = std.AutoHashMap(i32, *Peer).init(allocator),
    };
}
fn deinit(self: *Self) void {
    posix.close(self.epoll);
    self.peers.deinit();
}

fn addPeer(self: *const Self, peer: *const Peer) !void {
    const peer_stream_fd = peer.*.stream.handle;
    const event = system.epoll_event{ .events = system.EPOLL.IN | system.EPOLL.RDHUP, .data = .{ .fd = peer_stream_fd } };
    try self.peers.put(peer_stream_fd, *Peer);
    errdefer self.peers.remove(peer_stream_fd);
    try posix.epoll_ctl(self.epoll, system.EPOLL.CTL_ADD, peer_stream_fd, &event);
}
fn deletePeer(self: *const Self, peer: *const Peer) !void {
    const peer_stream_fd = peer.*.stream.handle;
    try self.deleteSocket(peer_stream_fd);
}
fn deleteSocket(self: *const Self, peer_socket: posix.socket_t) !void {
    self.peers.remove(peer_socket);
    try posix.epoll_ctl(self.epoll, system.EPOLL.CTL_DEL, peer_socket, null);
}

pub fn start(self: *Self, allocator: std.mem.Allocator, network: [4]u8) !void {
    var events: [10]system.epoll_event = undefined;
    while (self.running) {
        const n_fd_ready = posix.epoll_wait(
            self.epoll,
            &events,
            std.time.ms_per_s,
        );

        for (0..n_fd_ready) |i| {
            switch (events[i].events) {
                system.EPOLL.IN => {
                    const message = (wire.pollMessage(allocator, events[i].data.fd, network) catch try self.deleteSocket(events[i].data.fd)).?;
                    std.debug.print("received message {any}", .{message});
                },
            }
        }
    }
}
