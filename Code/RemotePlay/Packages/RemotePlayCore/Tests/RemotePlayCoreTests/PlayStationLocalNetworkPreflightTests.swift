import Darwin
import Foundation
import Testing
@testable import PlayStationRemotePlay

@Suite("Local Network prompt preparation", .timeLimit(.minutes(1)))
struct PlayStationLocalNetworkPreflightTests {
    @Test("Only broadcast-capable link-local IPv6 interfaces are eligible")
    func eligibility() {
        let valid = syntheticInterface()
        #expect(valid.isEligible)
        var nonbroadcast = valid
        nonbroadcast.flags = 0
        #expect(!nonbroadcast.isEligible)
        var wrongFamily = valid
        wrongFamily.address.sin6_family = sa_family_t(AF_INET)
        #expect(!wrongFamily.isEligible)
        var shortAddress = valid
        shortAddress.address.sin6_len = 0
        #expect(!shortAddress.isEligible)
        #expect(syntheticInterface(prefix: [0xfe, 0xbf]).isEligible)
        #expect(!syntheticInterface(prefix: [0xfe, 0xc0]).isEligible)
        #expect(!syntheticInterface(prefix: [0x20, 0x01]).isEligible)
    }

    @Test("Peer generation changes only the host portion and port")
    func scopedPeer() {
        let interface = syntheticInterface()
        let original = addressBytes(interface.address)
        let peer = interface.peer(host: 0x0102030405060708)
        #expect(Array(addressBytes(peer).prefix(8)) == Array(original.prefix(8)))
        #expect(Array(addressBytes(peer).suffix(8)) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(peer.sin6_scope_id == interface.address.sin6_scope_id)
        #expect(peer.sin6_flowinfo == interface.address.sin6_flowinfo)
        #expect(peer.sin6_family == interface.address.sin6_family)
        #expect(peer.sin6_len == interface.address.sin6_len)
        #expect(peer.sin6_port == UInt16(9).bigEndian)
        #expect(addressBytes(interface.address) == original)
    }

    @Test("Two scoped randomized peers are prepared per eligible interface")
    func twoPeersPerInterface() async {
        var second = syntheticInterface()
        second.address.sin6_scope_id = 8
        var excluded = syntheticInterface()
        excluded.flags = 0
        let recorder = PreflightRecorder(
            interfaces: [syntheticInterface(), excluded, second],
            descriptors: [10, 11, 12, 13], results: [true, true, true, true]
        )
        let result = await recorder.preflight.requestAccess()
        let snapshot = recorder.snapshot
        #expect(result)
        #expect(snapshot.interfaceReads == 1)
        #expect(snapshot.randomReads == 4)
        #expect(snapshot.connected == [10, 11, 12, 13])
        #expect(snapshot.closed == snapshot.connected)
        #expect(snapshot.peers.map(\.sin6_scope_id) == [7, 7, 8, 8])
        #expect(Set(snapshot.peers.map { addressBytes($0) }).count == 4)
    }

    @Test("An unavailable interface list causes no socket operation")
    func noInterfaces() async {
        let recorder = PreflightRecorder(interfaces: [])
        let result = await recorder.preflight.requestAccess()
        #expect(!result)
        #expect(recorder.snapshot.interfaceReads == 1)
        #expect(recorder.snapshot.opened.isEmpty)
        #expect(recorder.snapshot.connected.isEmpty)
        #expect(recorder.snapshot.randomReads == 0)
    }

    @Test("Ineligible interface data never reaches the socket layer")
    func noEligibleInterfaces() async {
        let recorder = PreflightRecorder(interfaces: [syntheticInterface(prefix: [0x20, 1])])
        let result = await recorder.preflight.requestAccess()
        #expect(!result)
        #expect(recorder.snapshot.opened.isEmpty)
        #expect(recorder.snapshot.closed.isEmpty)
    }

    @Test("Failed socket creation is skipped without closing an invalid descriptor")
    func socketCreationFailure() async {
        let recorder = PreflightRecorder(descriptors: [-1, 11], results: [true])
        let result = await recorder.preflight.requestAccess()
        #expect(result)
        #expect(recorder.snapshot.opened == [-1, 11])
        #expect(recorder.snapshot.connected == [11])
        #expect(recorder.snapshot.closed == [11])
    }

    @Test("Any successful connect is retained while every descriptor closes")
    func mixedConnectResults() async {
        let recorder = PreflightRecorder(results: [true, false])
        let result = await recorder.preflight.requestAccess()
        #expect(result)
        #expect(recorder.snapshot.closed == [10, 11])
    }

    @Test("Connect failures are nonfatal and close all descriptors")
    func allConnectsFail() async {
        let recorder = PreflightRecorder(results: [false, false])
        let result = await recorder.preflight.requestAccess()
        #expect(!result)
        #expect(recorder.snapshot.connected == [10, 11])
        #expect(recorder.snapshot.closed == [10, 11])
    }

    @Test("An already-cancelled request invokes no operations")
    func cancelledEntry() async {
        let recorder = PreflightRecorder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await recorder.preflight.requestAccess()
        }
        let result = await task.value
        #expect(!result)
        #expect(recorder.snapshot.interfaceReads == 0)
        #expect(recorder.snapshot.opened.isEmpty)
    }

    @Test("Cancellation after opening closes the socket without connecting")
    func cancellationAfterOpen() async {
        let recorder = PreflightRecorder(cancelOnOpen: true)
        let result = await recorder.preflight.requestAccess()
        #expect(!result)
        #expect(recorder.snapshot.opened == [10])
        #expect(recorder.snapshot.connected.isEmpty)
        #expect(recorder.snapshot.closed == [10])
    }

    @Test("Cancellation during connect closes the socket and stops further work")
    func cancellationDuringConnect() async {
        let recorder = PreflightRecorder(cancelOnConnect: true)
        let result = await recorder.preflight.requestAccess()
        #expect(!result)
        #expect(recorder.snapshot.opened == [10])
        #expect(recorder.snapshot.connected == [10])
        #expect(recorder.snapshot.closed == [10])
    }

    @Test("Caller cancellation reaches an in-flight worker and closes its socket")
    func callerCancellationReachesWorker() async {
        let recorder = PreflightRecorder()
        let release = DispatchSemaphore(value: 0)
        let (events, entered) = AsyncStream<Void>.makeStream()
        var operations = recorder.operations
        let originalOpen = operations.openSocket
        operations.openSocket = {
            let descriptor = originalOpen()
            entered.yield(())
            // Bound the synthetic syscall pause even if this regression fails.
            _ = release.wait(timeout: .now() + 5)
            return descriptor
        }
        let preflight = PlayStationLocalNetworkPreflight(operations: operations)
        let caller = Task {
            defer { entered.finish() }
            return await preflight.requestAccess()
        }
        for await _ in events { break }
        caller.cancel()
        release.signal()
        let result = await caller.value
        #expect(!result)
        #expect(recorder.snapshot.opened == [10])
        #expect(recorder.snapshot.connected.isEmpty)
        #expect(recorder.snapshot.closed == [10])
    }
}

// Entirely synthetic data: no real interfaces, addresses or sockets are used.
private func syntheticInterface(prefix: [UInt8] = [0xfe, 0x80]) -> LocalNetworkPreflightInterface {
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_scope_id = 7
    address.sin6_flowinfo = 42
    withUnsafeMutableBytes(of: &address.sin6_addr) {
        $0.copyBytes(from: prefix + Array(repeating: UInt8(0), count: 13) + [42])
    }
    return LocalNetworkPreflightInterface(address: address, flags: UInt32(IFF_BROADCAST))
}

private func addressBytes(_ address: sockaddr_in6) -> [UInt8] {
    withUnsafeBytes(of: address.sin6_addr) { Array($0) }
}

private final class PreflightRecorder: @unchecked Sendable {
    struct Snapshot {
        var interfaceReads = 0
        var randomReads = 0
        var opened: [Int32] = []
        var connected: [Int32] = []
        var peers: [sockaddr_in6] = []
        var closed: [Int32] = []
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private let interfaces: [LocalNetworkPreflightInterface]
    private let descriptors: [Int32]
    private let results: [Bool]
    private let cancelOnOpen: Bool
    private let cancelOnConnect: Bool

    init(
        interfaces: [LocalNetworkPreflightInterface] = [syntheticInterface()],
        descriptors: [Int32] = [10, 11], results: [Bool] = [true, true],
        cancelOnOpen: Bool = false, cancelOnConnect: Bool = false
    ) {
        self.interfaces = interfaces
        self.descriptors = descriptors
        self.results = results
        self.cancelOnOpen = cancelOnOpen
        self.cancelOnConnect = cancelOnConnect
    }

    var snapshot: Snapshot { lock.withLock { state } }

    var preflight: PlayStationLocalNetworkPreflight {
        PlayStationLocalNetworkPreflight(operations: operations)
    }

    var operations: LocalNetworkPreflightOperations {
        LocalNetworkPreflightOperations(
            interfaces: { [self] in
                lock.withLock { state.interfaceReads += 1 }
                return interfaces
            },
            randomHost: { [self] in
                lock.withLock {
                    state.randomReads += 1
                    return UInt64(state.randomReads)
                }
            },
            openSocket: { [self] in
                let descriptor = lock.withLock {
                    let index = state.opened.count
                    let descriptor = index < descriptors.count ? descriptors[index] : -1
                    state.opened.append(descriptor)
                    return descriptor
                }
                if cancelOnOpen { withUnsafeCurrentTask { $0?.cancel() } }
                return descriptor
            },
            connectSocket: { [self] descriptor, peer in
                let result = lock.withLock {
                    let index = state.connected.count
                    state.connected.append(descriptor)
                    state.peers.append(peer)
                    return index < results.count ? results[index] : false
                }
                if cancelOnConnect { withUnsafeCurrentTask { $0?.cancel() } }
                return result
            },
            closeSocket: { [self] descriptor in
                lock.withLock { state.closed.append(descriptor) }
            }
        )
    }
}
