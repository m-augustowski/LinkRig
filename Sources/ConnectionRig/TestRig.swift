import Foundation
@_exported import RigProtocol

public struct RigConfiguration: Sendable {
    public let endpoint: URL
    public let pairingSecret: String
    public let commandTimeout: TimeInterval
    public let heartbeatInterval: Duration

    public init(
        endpoint: URL,
        pairingSecret: String,
        commandTimeout: TimeInterval = 5,
        heartbeatInterval: Duration = .seconds(3)
    ) {
        self.endpoint = endpoint
        self.pairingSecret = pairingSecret
        self.commandTimeout = commandTimeout
        self.heartbeatInterval = heartbeatInterval
    }
}

// Internal constructor boundary allows deterministic transport-failure tests without binding sockets.
protocol ControlTransport: Sendable {
    func exchange(_ request: URLRequest) async throws -> (Data, URLResponse)
}

private final class HTTPControlTransport: ControlTransport, Sendable {
    let session: URLSession

    init(timeout: TimeInterval) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Controls the agent independently of any test framework.
/// Use the same API from hosted XCTest/Swift Testing tests or an XCTest UI-test runner.
/// UI actions and application-specific progress synchronization belong to the calling tests.
public actor TestRig {
    private let configuration: RigConfiguration
    private let transport: any ControlTransport
    public private(set) var capabilities: [Capability] = []

    private init(configuration: RigConfiguration, transport: (any ControlTransport)? = nil) throws {
        try Pairing.validateSecret(configuration.pairingSecret)
        guard ["http", "https"].contains(configuration.endpoint.scheme),
            configuration.endpoint.host != nil,
            configuration.endpoint.user == nil, configuration.endpoint.password == nil,
            configuration.endpoint.query == nil, configuration.endpoint.fragment == nil,
            ["", "/"].contains(configuration.endpoint.path),
            configuration.commandTimeout > 0, configuration.commandTimeout <= 60,
            configuration.heartbeatInterval >= .milliseconds(100),
            configuration.heartbeatInterval <= .seconds(5)
        else {
            throw RigFailure(
                "configuration",
                """
                Use an HTTP(S) agent origin, timeout 0...60s, heartbeat 0.1...5s. Do not use the conditioned \
                traffic port.
                """
            )
        }
        self.configuration = configuration
        self.transport = transport ?? HTTPControlTransport(timeout: configuration.commandTimeout)
    }

    public static func connect(configuration: RigConfiguration) async throws -> TestRig {
        try await connect(configuration: configuration, transport: nil)
    }

    static func connect(
        configuration: RigConfiguration,
        transport: (any ControlTransport)?
    ) async throws -> TestRig {
        let rig = try TestRig(configuration: configuration, transport: transport)
        let snapshot = try await rig.send(Command(.discover))
        await rig.setCapabilities(snapshot.capabilities)
        return rig
    }

    private func setCapabilities(_ capabilities: [Capability]) {
        self.capabilities = capabilities
    }

    public func require(_ capability: Capability) throws {
        guard capabilities.contains(capability) else {
            throw RigFailure(
                "unsupported",
                "Agent does not support \(capability.rawValue); no simulation fallback is available."
            )
        }
    }

    public func beginSession(clientName: String = "Xcode tests") async throws -> RigSession {
        let snapshot = try await send(Command(.begin, clientName: clientName))
        guard let id = snapshot.active?.id else {
            throw RigFailure("protocol", "Agent did not return a session ID.")
        }
        let session = RigSession(rig: self, id: id)
        await session.startHeartbeat(interval: configuration.heartbeatInterval)
        return session
    }

    public func inspect() async throws -> AgentSnapshot {
        try await send(Command(.inspect))
    }

    /// Retry this exact value after a lost response. Mutating or re-encoding a command with a new ID is a new action.
    @discardableResult
    public func send(_ command: Command) async throws -> AgentSnapshot {
        try command.validate()
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(command)
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent("v1/command"))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            Pairing.sign(data, secret: configuration.pairingSecret, domain: "request-v1"),
            forHTTPHeaderField: "X-Rig-Signature"
        )
        // A single retry uses identical serialized bytes. Cancellation never triggers retries.
        for attempt in 0...1 {
            do {
                let (body, response) = try await transport.exchange(request)
                guard body.count <= 2_000_000, let http = response as? HTTPURLResponse,
                    http.statusCode == 200,
                    Pairing.verify(
                        http.value(forHTTPHeaderField: "X-Rig-Signature") ?? "",
                        data: body,
                        secret: configuration.pairingSecret,
                        domain: "reply-v1"
                    )
                else {
                    throw RigFailure(
                        "authentication",
                        "Untrusted agent response. Verify pairing and control endpoint."
                    )
                }
                let reply = try JSONDecoder().decode(Reply.self, from: body)
                if let failure = reply.failure {
                    if failure.code == "busy", attempt == 0 {
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    throw failure
                }
                guard reply.commandID == command.id, let snapshot = reply.snapshot else {
                    throw RigFailure("protocol", "Reply command ID or snapshot is missing.")
                }
                return snapshot
            } catch let error as URLError {
                if Task.isCancelled || error.code == .cancelled {
                    throw CancellationError()
                }
                if attempt == 0 {
                    continue
                }
                throw RigFailure(
                    error.code == .timedOut ? "timeout" : "unavailable",
                    """
                    Agent unreachable or acknowledgement lost. Inspect state before issuing a different \
                    action; the lease restores conditions after disconnection.
                    """
                )
            }
        }
        throw RigFailure("busy", "Agent busy; retry the identical command.")
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public actor RigSession {
    public nonisolated let id: UUID
    private let rig: TestRig
    private var heartbeat: Task<Void, Never>?
    private var closed = false
    public private(set) var heartbeatFailure: String?

    init(rig: TestRig, id: UUID) {
        self.rig = rig
        self.id = id
    }

    deinit {
        heartbeat?.cancel()
    }

    func startHeartbeat(interval: Duration) {
        heartbeat = Task { [weak self, rig, id] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    _ = try await rig.send(Command(.heartbeat, sessionID: id))
                } catch {
                    if !Task.isCancelled {
                        await self?.recordHeartbeatFailure(error.localizedDescription)
                    }
                    break
                }
            }
        }
    }

    private func recordHeartbeatFailure(_ message: String) {
        heartbeatFailure = message
    }

    private func checkOpen() throws {
        guard !closed else {
            throw RigFailure("closed", "Begin a new session.")
        }
    }

    public func setNetwork(_ conditions: NetworkConditions) async throws {
        try checkOpen()
        try await rig.require(.tcpBandwidth)
        _ = try await rig.send(Command(.set, sessionID: id, conditions: conditions))
    }

    /// Returns after active sockets are closed and new connections are rejected.
    /// Agent restores unpaced forwarding after the duration, including after SDK termination.
    public func interrupt(for duration: Duration) async throws {
        try checkOpen()
        try await rig.require(.interrupt)
        guard duration > .zero, duration <= .seconds(300) else {
            throw RigFailure("invalid", "Interruption must be >0 and <=300 seconds.")
        }
        let parts = duration.components
        let milliseconds = Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        _ = try await rig.send(
            Command(.interrupt, sessionID: id, durationMilliseconds: milliseconds)
        )
    }

    public func restore() async throws {
        try checkOpen()
        _ = try await rig.send(Command(.restore, sessionID: id))
    }

    public func close() async throws {
        if closed {
            return
        }
        _ = try await rig.send(Command(.close, sessionID: id))
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
    }
}
