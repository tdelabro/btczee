const std = @import("std");
const net = std.net;
const posix = std.posix;
const builtin = @import("builtin");
const native_os = builtin.os.tag;

pub fn tcpConnectToAddressNonBlocking(address: net.Address) net.TcpConnectToAddressError!net.Stream {
    const nonblock = 0;
    const sock_flags = posix.SOCK.STREAM | nonblock |
        (if (native_os == .windows) 0 else posix.SOCK.CLOEXEC);
    const sockfd = try posix.socket(address.any.family, sock_flags, posix.IPPROTO.TCP);
    errdefer net.Stream.close(.{ .handle = sockfd });

    try posix.connect(sockfd, &address.any, address.getOsSockLen());

    return net.Stream{ .handle = sockfd };
}
