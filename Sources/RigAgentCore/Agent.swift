import Foundation
import RigProtocol

public actor Agent {
    private let engine: any NetworkEngine
    public let secret: String
    private let leaseSeconds: Double
    private var leaseDeadline: ContinuousClock.Instant?
    private var restoreDeadline: ContinuousClock.Instant?
    private var active: SessionReport?
    private var completed: [SessionReport] = []
    private var cache: [UUID: (Data, Reply, Date)] = [:]
    private var busy = false

    public init(engine: any NetworkEngine, secret: String, leaseSeconds: Double = 15) throws {
        try Pairing.validateSecret(secret)
        guard leaseSeconds >= 0.1, leaseSeconds <= 3600 else {
            throw RigFailure("invalid", "Lease must be 0.1...3600 seconds.")
        }
        self.engine = engine
        self.secret = secret
        self.leaseSeconds = leaseSeconds
    }

    public func snapshot() -> AgentSnapshot {
        .init(active: active, completed: completed)
    }

    public func handle(body: Data, signature: String) async -> Reply {
        guard Pairing.verify(signature, data: body, secret: secret, domain: "request-v1") else {
            return Reply(
                commandID: UUID(),
                failure: RigFailure("authentication", "Pair again using the Mac's current secret.")
            )
        }
        guard let command = try? JSONDecoder().decode(Command.self, from: body) else {
            return Reply(
                commandID: UUID(),
                failure: RigFailure("schema", "Expected a versioned ConnectionRig command.")
            )
        }
        guard !busy else {
            return Reply(
                commandID: command.id,
                failure: RigFailure(
                    "busy",
                    "Retry the identical command after the in-flight operation finishes."
                )
            )
        }
        busy = true
        defer {
            busy = false
        }
        cache = cache.filter { $0.value.2.timeIntervalSinceNow > -60 }
        if let (previous, reply, _) = cache[command.id] {
            guard previous == body else {
                return Reply(
                    commandID: command.id,
                    failure: RigFailure("conflict", "Command ID reused with different bytes.")
                )
            }
            return reply
        }
        let reply: Reply
        do {
            guard abs(command.issuedAt.timeIntervalSinceNow) < 60 else {
                throw RigFailure(
                    "expired",
                    "Synchronize clocks and issue a new command; no action applied."
                )
            }
            try command.validate()
            if let required = command.requiredCapability, !Capability.relay.contains(required) {
                throw RigFailure(
                    "unsupported",
                    "Engine does not support \(required.rawValue). No fallback applied."
                )
            }
            try await maintain()
            try await execute(command)
            reply = Reply(commandID: command.id, snapshot: snapshot())
        } catch {
            if active?.id == command.sessionID {
                event("rejected", (error as? RigFailure)?.code ?? "engine", id: command.id)
            }
            reply = Reply(
                commandID: command.id,
                failure: error as? RigFailure
                    ?? RigFailure(
                        "engine",
                        "Execution failed; inspect agent status and restore. \(error.localizedDescription)"
                    )
            )
        }
        if cache.count < 256 {
            cache[command.id] = (body, reply, command.issuedAt)
        }
        // Fail closed at capacity rather than evicting IDs still valid within replay window.
        // Successful ordinary sessions stay far below this bound; heartbeat entries age out after 60 seconds.
        return reply
    }

    private func event(_ kind: String, _ detail: String, id: UUID? = nil) {
        active?.events.append(.init(commandID: id, kind: kind, detail: detail))
        if (active?.events.count ?? 0) > 200 {
            active?.events.removeFirst()
        }
    }

    private func execute(_ command: Command) async throws {
        if cache.count >= 256 {
            throw RigFailure(
                "capacity",
                "Wait 60 seconds for the replay window to clear, then retry."
            )
        }
        switch command.operation {
        case .discover, .inspect:
            return
        case .begin:

            guard active == nil else {
                throw RigFailure(
                    "sessionBusy",
                    "MVP supports one active session. Close or wait for its lease to expire."
                )
            }
            try await engine.restore()
            active = SessionReport(id: UUID(), client: command.clientName ?? "Test client")
            leaseDeadline = .now.advanced(by: .seconds(leaseSeconds))
            event("began", "Session opened", id: command.id)
        default:

            // Close is idempotent for a known completed session.
            if command.operation == .close,
                completed.contains(where: { $0.id == command.sessionID })
            {
                return
            }
            guard let active, active.id == command.sessionID else {
                throw RigFailure("session", "Session missing or expired. Begin a new session.")
            }
            switch command.operation {
            case .set:

                self.active?.requested = command.conditions!
                event("requested", "Network conditions requested", id: command.id)
                guard restoreDeadline == nil else {
                    throw RigFailure(
                        "blocked",
                        "Restore or wait for interruption to finish before setting conditions."
                    )
                }
                try await engine.apply(command.conditions!)
                self.active?.applied = command.conditions!
                event("applied", "Network conditions installed in relay", id: command.id)
            case .interrupt:

                try await engine.interrupt()
                let duration = command.durationMilliseconds!
                restoreDeadline = .now.advanced(by: .milliseconds(duration))
                self.active?.blockedUntil = Date().addingTimeInterval(Double(duration) / 1000)
                event(
                    "interrupted",
                    "Active relay sockets closed; new relay connections rejected",
                    id: command.id
                )
            case .restore:

                try await restore(id: command.id)
            case .close:

                try await finish(reason: "Client closed session", id: command.id)
            case .heartbeat:
                break
            default:
                break
            }
            if self.active != nil {
                leaseDeadline = .now.advanced(by: .seconds(leaseSeconds))
            }
        }
    }

    private func restore(id: UUID? = nil) async throws {
        try await engine.restore()
        restoreDeadline = nil
        active?.blockedUntil = nil
        active?.requested = .init()
        active?.applied = .init()
        event("restored", "Unpaced forwarding restored", id: id)
    }

    private func finish(reason: String, id: UUID? = nil) async throws {
        try await restore(id: id)
        event("closed", reason, id: id)
        active?.endedAt = Date()
        if let active {
            completed.append(active)
            if completed.count > 10 {
                completed.removeFirst()
            }
        }
        active = nil
        leaseDeadline = nil
    }

    private func maintain() async throws {
        if let deadline = leaseDeadline, deadline <= .now {
            try await finish(reason: "Lease expired")
        } else if let deadline = restoreDeadline, deadline <= .now {
            try await restore()
        }
    }

    /// Called by runtime every 50 ms. Monotonic deadlines survive wall clock changes.
    public func tick() async {
        guard !busy else {
            return
        }
        busy = true
        defer {
            busy = false
        }
        do {
            try await maintain()
        } catch {
            event("error", "Scheduled restoration failed; retrying")
        }
    }

    public func shutdown() async throws {
        guard !busy else {
            throw RigFailure("busy", "Command in progress; retry shutdown.")
        }
        busy = true
        defer {
            busy = false
        }
        if active != nil {
            try await finish(reason: "Agent shutdown")
        } else {
            try await engine.restore()
        }
    }
}
