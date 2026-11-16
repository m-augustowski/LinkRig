import CryptoKit
import Foundation

public struct RigFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        "\(code): \(message)"
    }
}

public struct NetworkConditions: Codable, Sendable, Equatable {
    /// Decimal kilobytes/second (1 KB = 1000 bytes), per TCP connection and direction.
    /// nil means unpaced. Latency is delivery delay per relay chunk, NOT measured RTT.
    public var downloadKBps: Int?
    public var uploadKBps: Int?
    public var chunkDelayMilliseconds: Int

    public init(downloadKBps: Int? = nil, uploadKBps: Int? = nil, chunkDelayMilliseconds: Int = 0) {
        self.downloadKBps = downloadKBps
        self.uploadKBps = uploadKBps
        self.chunkDelayMilliseconds = chunkDelayMilliseconds
    }

    public func validate() throws {
        for rate in [downloadKBps, uploadKBps].compactMap({ $0 }) {
            guard (1...1_000_000).contains(rate) else {
                throw RigFailure(
                    "invalid",
                    "Rates must be 1...1000000 decimal KB/s; use nil to restore."
                )
            }
        }
        guard (0...10_000).contains(chunkDelayMilliseconds) else {
            throw RigFailure("invalid", "Chunk delay must be 0...10000 ms.")
        }
    }
}

public enum Capability: String, Codable, Sendable, CaseIterable {
    case tcpBandwidth
    case chunkDelay
    case interrupt
    case blockNewConnections
    case packetLoss
    case radioControl
    case usb
    case ble

    public static let relay: [Self] = [
        .tcpBandwidth, .chunkDelay, .interrupt, .blockNewConnections,
    ]
}

public enum Operation: String, Codable, Sendable {
    case discover
    case begin
    case set
    case interrupt
    case restore
    case heartbeat
    case close
    case inspect
}

public struct Command: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var id: UUID
    public var issuedAt: Date
    public var operation: Operation
    public var sessionID: UUID?
    public var clientName: String?
    public var conditions: NetworkConditions?
    public var durationMilliseconds: Int?
    public var requiredCapability: Capability?

    public init(
        _ operation: Operation,
        sessionID: UUID? = nil,
        conditions: NetworkConditions? = nil,
        durationMilliseconds: Int? = nil,
        clientName: String? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        issuedAt = Date()
        self.operation = operation
        self.sessionID = sessionID
        self.conditions = conditions
        self.durationMilliseconds = durationMilliseconds
        self.clientName = clientName
    }

    public func validate() throws {
        guard version == 1 else {
            throw RigFailure("version", "Use control protocol version 1.")
        }
        if operation == .set {
            guard let conditions else {
                throw RigFailure("invalid", "set requires conditions.")
            }
            try conditions.validate()
        }
        if operation == .interrupt {
            guard let durationMilliseconds, (1...300_000).contains(durationMilliseconds) else {
                throw RigFailure("invalid", "Interruption must be 1...300000 ms.")
            }
        }
        let sessionOperations: [Operation] = [.set, .interrupt, .restore, .heartbeat, .close]
        guard sessionOperations.contains(operation) == (sessionID != nil),
            (operation == .set) == (conditions != nil),
            (operation == .interrupt) == (durationMilliseconds != nil),
            clientName == nil || operation == .begin
        else {
            throw RigFailure("schema", "Command fields do not match its operation.")
        }
        if let clientName,
            clientName.isEmpty || clientName.count > 100
                || clientName.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        {
            throw RigFailure("invalid", "Client name must be 1...100 printable characters.")
        }
    }
}

public struct TimelineEvent: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public let commandID: UUID?
    public let kind: String
    public let detail: String

    public init(commandID: UUID? = nil, kind: String, detail: String) {
        self.commandID = commandID
        self.kind = kind
        self.detail = detail
    }
}

public struct SessionReport: Codable, Sendable, Identifiable {
    public let id: UUID
    public let client: String
    public let startedAt: Date
    public var endedAt: Date?
    public var requested: NetworkConditions
    public var applied: NetworkConditions
    public var blockedUntil: Date?
    public var events: [TimelineEvent]

    public init(id: UUID, client: String) {
        self.id = id
        self.client = client
        startedAt = Date()
        requested = .init()
        applied = .init()
        events = []
    }
}

public struct AgentSnapshot: Codable, Sendable {
    public let engine: String
    public let capabilities: [Capability]
    public let active: SessionReport?
    public let completed: [SessionReport]

    public init(active: SessionReport?, completed: [SessionReport]) {
        engine = "Network TCP relay v1"
        capabilities = Capability.relay
        self.active = active
        self.completed = completed
    }
}

public struct Reply: Codable, Sendable {
    public let commandID: UUID
    public let snapshot: AgentSnapshot?
    public let failure: RigFailure?

    public init(commandID: UUID, snapshot: AgentSnapshot? = nil, failure: RigFailure? = nil) {
        self.commandID = commandID
        self.snapshot = snapshot
        self.failure = failure
    }
}

public enum Pairing {
    public static func generateSecret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    public static func validateSecret(_ secret: String) throws {
        guard let bytes = Data(base64Encoded: secret), bytes.count == 32 else {
            throw RigFailure(
                "pairing",
                "Pairing secret must be 32 random bytes encoded as Base64. Copy it from the Mac setup screen."
            )
        }
    }

    public static func sign(_ data: Data, secret: String, domain: String) -> String {
        let key = SymmetricKey(data: Data(base64Encoded: secret) ?? Data())
        return Data(HMAC<SHA256>.authenticationCode(for: Data(domain.utf8) + data, using: key))
            .base64EncodedString()
    }

    public static func verify(
        _ signature: String,
        data: Data,
        secret: String,
        domain: String
    ) -> Bool {
        guard let mac = Data(base64Encoded: signature), let bytes = Data(base64Encoded: secret)
        else {
            return false
        }
        return HMAC<SHA256>
            .isValidAuthenticationCode(
                mac,
                authenticating: Data(domain.utf8) + data,
                using: SymmetricKey(data: bytes)
            )
    }
}
