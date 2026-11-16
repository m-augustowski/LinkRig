import Foundation
import Network
import RigProtocol

extension NWConnection {
    func cancelAndWait() async {
        if case .cancelled = state {
            return
        }
        await withCheckedContinuation { continuation in
            let latch = CancellationLatch(continuation)
            stateUpdateHandler = { state in
                if case .cancelled = state {
                    Task { await latch.finish() }
                }
            }
            cancel()
            if case .cancelled = state {
                Task { await latch.finish() }
            }
        }
    }

    func read(maximum: Int = 16_384) async throws -> Data? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, done, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if done {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func finishWrite() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func write(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                send(
                    content: data,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
            }
        } onCancel: {
            self.cancel()
        }
    }
}

/// Listener owns and cancels all accepted sockets on shutdown. No payload logging.
public actor TCPServer {
    private let listener: NWListener
    private var sockets: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var disconnecting: Task<Void, Never>?
    private var started = false
    private var stopped = false

    public init(host: String = "127.0.0.1", port: UInt16 = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .init(host),
            port: .init(rawValue: port)!
        )
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    public func start(
        handler: @escaping @Sendable (NWConnection) async -> Void
    ) async throws -> UInt16 {
        guard !started, !stopped else {
            throw RigFailure("lifecycle", "Create a new listener after stop or failed startup.")
        }
        started = true
        listener.newConnectionHandler = { connection in
            Task { await self.accept(connection, handler: handler) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            // State callback may fire repeatedly; a small actor resolves readiness exactly once.
            let ready = Readiness(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { await ready.finish(.success(self.listener.port!.rawValue)) }
                case .failed(let error):
                    Task { await ready.finish(.failure(error)) }
                case .cancelled:
                    Task { await ready.finish(.failure(CancellationError())) }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    private func accept(
        _ connection: NWConnection,
        handler: @escaping @Sendable (NWConnection) async -> Void
    ) {
        guard !stopped, sockets.count < 64 else {
            connection.cancel()
            return
        }
        let id = UUID()
        sockets[id] = connection
        connection.start(queue: .global(qos: .userInitiated))
        tasks[id] = Task {
            await handler(connection)
            connection.cancel()
            self.finished(id)
        }
    }

    private func finished(_ id: UUID) {
        sockets[id] = nil
        tasks[id] = nil
    }

    public func disconnectAll() async {
        if let disconnecting {
            await disconnecting.value
            return
        }
        let accepted = Array(sockets.values)
        for task in tasks.values {
            task.cancel()
        }
        let operation = Task {
            await withTaskGroup(of: Void.self) { group in
                for socket in accepted {
                    group.addTask { await socket.cancelAndWait() }
                }
            }
        }
        disconnecting = operation
        await operation.value
        disconnecting = nil
    }

    public func stop() async {
        stopped = true
        listener.cancel()
        await disconnectAll()
    }
}

private actor CancellationLatch {
    var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor Readiness {
    var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<UInt16, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

public protocol NetworkEngine: Sendable {
    func apply(_ conditions: NetworkConditions) async throws
    func interrupt() async throws
    func restore() async throws
}

/// Scoped byte-stream relay. Never changes system network settings or stores persistent rules.
public actor TCPRelay: NetworkEngine {
    private let server: TCPServer
    private let upstreamHost: String
    private let upstreamPort: UInt16
    private var conditions = NetworkConditions()
    private var blocked = false
    private var upstreams: [UUID: NWConnection] = [:]
    private var interrupting: Task<Void, Never>?

    public init(
        listenHost: String = "127.0.0.1",
        port: UInt16 = 0,
        upstreamHost: String,
        upstreamPort: UInt16
    ) throws {
        server = try TCPServer(host: listenHost, port: port)
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
    }

    public func start() async throws -> UInt16 {
        try await server.start { client in
            await self.forward(client)
        }
    }

    public func apply(_ conditions: NetworkConditions) throws {
        try conditions.validate()
        self.conditions = conditions
    }

    public func interrupt() async throws {
        blocked = true
        if let interrupting {
            await interrupting.value
            return
        }
        let connections = Array(upstreams.values)
        let operation = Task { [server] in
            await withTaskGroup(of: Void.self) { group in
                for connection in connections {
                    group.addTask { await connection.cancelAndWait() }
                }
            }
            await server.disconnectAll()
        }
        interrupting = operation
        await operation.value
        interrupting = nil
    }

    public func restore() {
        conditions = .init()
        blocked = false
    }

    public func stop() async {
        blocked = true
        for connection in upstreams.values {
            connection.cancel()
        }
        await server.stop()
    }

    private func forward(_ client: NWConnection) async {
        guard !blocked else {
            return
        }
        let id = UUID()
        let upstream = NWConnection(
            host: .init(upstreamHost),
            port: .init(rawValue: upstreamPort)!,
            using: .tcp
        )
        upstreams[id] = upstream
        upstream.start(queue: .global(qos: .userInitiated))
        defer {
            upstream.cancel()
            upstreams[id] = nil
        }
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await self.pipe(client, to: upstream, download: false)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    try await self.pipe(upstream, to: client, download: true)
                    return true
                } catch {
                    return false
                }
            }
            while let success = await group.next() {
                if !success {
                    group.cancelAll()
                    client.cancel()
                    upstream.cancel()
                }
            }
        }
    }

    private func pipe(
        _ source: NWConnection,
        to destination: NWConnection,
        download: Bool
    ) async throws {
        while let chunk = try await source.read() {
            let received = ContinuousClock.now
            while received.duration(to: .now) < .milliseconds(conditions.chunkDelayMilliseconds) {
                try await Task.sleep(for: .milliseconds(10))
            }
            var offset = 0
            while offset < chunk.count {
                try Task.checkCancellation()
                guard !blocked else {
                    throw CancellationError()
                }
                let rate = download ? conditions.downloadKBps : conditions.uploadKBps
                let count = min(chunk.count - offset, rate.map { max(1, $0 * 20) } ?? 16_384)
                // Pace before write: there is no unlimited initial burst on each chunk.
                if let rate {
                    try await Task.sleep(for: .seconds(Double(count) / Double(rate * 1000)))
                }
                try await destination.write(chunk.subdata(in: offset..<(offset + count)))
                offset += count
            }
        }
        try await destination.finishWrite()
    }
}
