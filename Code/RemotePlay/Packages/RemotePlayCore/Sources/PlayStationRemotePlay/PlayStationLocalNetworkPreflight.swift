import Darwin
import Foundation

/// Best-effort, user-initiated Local Network prompt preparation before pairing.
/// UDP connect performs the privacy check without transmitting discovery traffic.
/// See Apple's TN3179, "Trigger the local network alert". No interface or peer
/// address is logged, persisted, or returned to the caller.
public struct PlayStationLocalNetworkPreflight: Sendable {
    private let operations: LocalNetworkPreflightOperations

    public init() {
        operations = .live
    }

    init(operations: LocalNetworkPreflightOperations) {
        self.operations = operations
    }

    /// Returns whether any UDP connect syscall succeeded, NOT whether the user
    /// granted permission, saw a prompt, or has a reachable PS5. Failure must not
    /// prevent direct pairing; the first operation can fail before a decision.
    @discardableResult
    public func requestAccess() async -> Bool {
        guard !Task.isCancelled else { return false }
        let worker = Task.detached(priority: .userInitiated) { [operations] in
            Self.prepare(using: operations)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func prepare(using operations: LocalNetworkPreflightOperations) -> Bool {
        guard !Task.isCancelled else { return false }
        let interfaces = operations.interfaces()
        var didConnect = false
        for interface in interfaces where interface.isEligible {
            for _ in 0..<2 {
                guard !Task.isCancelled else { return false }
                let peer = interface.peer(host: operations.randomHost())
                let descriptor = operations.openSocket()
                guard descriptor >= 0 else { continue }
                defer { operations.closeSocket(descriptor) }
                guard !Task.isCancelled else { return false }
                if operations.connectSocket(descriptor, peer) {
                    didConnect = true
                }
            }
        }
        return !Task.isCancelled && didConnect
    }
}

/// Transient interface data, kept internal so tests can use only synthetic input.
struct LocalNetworkPreflightInterface: Sendable {
    var address: sockaddr_in6
    var flags: UInt32

    var isEligible: Bool {
        guard flags & UInt32(IFF_BROADCAST) != 0,
              address.sin6_family == AF_INET6,
              address.sin6_len >= MemoryLayout<sockaddr_in6>.size else {
            return false
        }
        return withUnsafeBytes(of: address.sin6_addr) { bytes in
            bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        }
    }

    func peer(host: UInt64) -> sockaddr_in6 {
        var peer = address
        peer.sin6_port = UInt16(9).bigEndian
        var hostBytes = host.bigEndian
        withUnsafeMutableBytes(of: &peer.sin6_addr) { addressBytes in
            withUnsafeBytes(of: &hostBytes) { addressBytes[8..<16].copyBytes(from: $0) }
        }
        return peer
    }
}

/// A narrow syscall seam. There is deliberately no send, receive, broadcast,
/// name resolution, permission query, or credential operation in this surface.
struct LocalNetworkPreflightOperations: Sendable {
    var interfaces: @Sendable () -> [LocalNetworkPreflightInterface]
    var randomHost: @Sendable () -> UInt64
    var openSocket: @Sendable () -> Int32
    var connectSocket: @Sendable (Int32, sockaddr_in6) -> Bool
    var closeSocket: @Sendable (Int32) -> Void

    static let live = Self(
        interfaces: {
            var list: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&list) == 0, let first = list else { return [] }
            defer { freeifaddrs(first) }
            var result: [LocalNetworkPreflightInterface] = []
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let node = cursor {
                defer { cursor = node.pointee.ifa_next }
                guard !Task.isCancelled else { return [] }
                guard let address = node.pointee.ifa_addr,
                      address.pointee.sa_family == AF_INET6,
                      address.pointee.sa_len >= MemoryLayout<sockaddr_in6>.size else {
                    continue
                }
                let value = UnsafeRawPointer(address).load(as: sockaddr_in6.self)
                let interface = LocalNetworkPreflightInterface(
                    address: value,
                    flags: node.pointee.ifa_flags
                )
                if interface.isEligible { result.append(interface) }
            }
            return result
        },
        randomHost: { UInt64.random(in: .min ... .max) },
        openSocket: { Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP) },
        connectSocket: { descriptor, peer in
            withUnsafePointer(to: peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        },
        closeSocket: { _ = Darwin.close($0) }
    )
}
