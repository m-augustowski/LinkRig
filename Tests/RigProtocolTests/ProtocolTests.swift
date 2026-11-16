import Foundation
import Testing

@testable import ConnectionRig
@testable import RigProtocol

@Test
func commandRoundTripAndValidation() throws {
    let command = Command(
        .set,
        sessionID: UUID(),
        conditions: .init(downloadKBps: 100, uploadKBps: 20, chunkDelayMilliseconds: 50)
    )
    #expect(try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(command)) == command)
    try command.validate()
    for rate in [0, -1, 1_000_001] {
        #expect(throws: RigFailure.self) { try NetworkConditions(downloadKBps: rate).validate() }
    }
    #expect(throws: RigFailure.self) {
        try NetworkConditions(chunkDelayMilliseconds: -1).validate()
    }
    #expect(throws: RigFailure.self) {
        try NetworkConditions(chunkDelayMilliseconds: 10_001).validate()
    }
    for duration in [0, -1, 300_001] {
        #expect(throws: RigFailure.self) {
            try Command(.interrupt, sessionID: UUID(), durationMilliseconds: duration).validate()
        }
    }
    var version = Command(.discover)
    version.version = 2
    #expect(throws: RigFailure.self) { try version.validate() }
    #expect(throws: RigFailure.self) { try Command(.set).validate() }
}

@Test
func signaturesRejectTamperingAndReflection() throws {
    let secret = Pairing.generateSecret()
    try Pairing.validateSecret(secret)
    let data = Data("request".utf8)
    let signature = Pairing.sign(data, secret: secret, domain: "request-v1")
    #expect(Pairing.verify(signature, data: data, secret: secret, domain: "request-v1"))
    #expect(
        !Pairing.verify(
            signature,
            data: Data("tampered".utf8),
            secret: secret,
            domain: "request-v1"
        )
    )
    #expect(!Pairing.verify(signature, data: data, secret: secret, domain: "reply-v1"))
    #expect(
        !Pairing.verify(
            signature,
            data: data,
            secret: Pairing.generateSecret(),
            domain: "request-v1"
        )
    )
    #expect(throws: RigFailure.self) { try Pairing.validateSecret("short") }
}

// Explicit injected transports test SDK semantics. They do not validate real networking.
actor ScriptedTransport: ControlTransport {
    enum Mode: Sendable {
        case lostReply
        case timeout
        case cancellation
        case unavailable
        case forged
    }

    let mode: Mode
    let secret: String
    var bodies: [Data] = []

    init(_ mode: Mode, secret: String) {
        self.mode = mode
        self.secret = secret
    }

    func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        bodies.append(request.httpBody!)
        switch mode {
        case .timeout:
            throw URLError(.timedOut)
        case .unavailable:
            throw URLError(.cannotConnectToHost)
        case .cancellation:
            throw CancellationError()
        case .lostReply:

            if bodies.count == 1 {
                throw URLError(.networkConnectionLost)
            }
        case .forged:
            break
        }
        let command = try JSONDecoder().decode(Command.self, from: request.httpBody!)
        let reply = try JSONEncoder()
            .encode(Reply(commandID: command.id, snapshot: .init(active: nil, completed: [])))
        let signature = Pairing.sign(
            reply,
            secret: mode == .forged ? Pairing.generateSecret() : secret,
            domain: "reply-v1"
        )
        return (
            reply,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-Rig-Signature": signature]
            )!
        )
    }
}

@Test
func sdkRetriesIdenticalBytesAndRejectsUnsupported() async throws {
    let secret = Pairing.generateSecret()
    let transport = ScriptedTransport(.lostReply, secret: secret)
    let config = RigConfiguration(
        endpoint: URL(string: "http://localhost:49170")!,
        pairingSecret: secret
    )
    let rig = try await TestRig.connect(configuration: config, transport: transport)
    let bodies = await transport.bodies
    #expect(bodies.count == 2)
    #expect(bodies[0] == bodies[1])
    do {
        try await rig.require(.ble)
        Issue.record("BLE unexpectedly supported")
    } catch let error as RigFailure {
        #expect(error.code == "unsupported")
    }
}

@Test
func sdkMapsTimeoutUnavailableAndCancellationAndRejectsForgedReplies() async throws {
    let secret = Pairing.generateSecret()
    let config = RigConfiguration(
        endpoint: URL(string: "http://localhost:49170")!,
        pairingSecret: secret
    )
    for (mode, expected) in [
        (ScriptedTransport.Mode.timeout, "timeout"), (.unavailable, "unavailable"),
        (.forged, "authentication"),
    ] {
        do {
            _ = try await TestRig.connect(
                configuration: config,
                transport: ScriptedTransport(mode, secret: secret)
            )
            Issue.record("Unexpected connection success")
        } catch let error as RigFailure {
            #expect(error.code == expected)
        }
    }
    let transport = ScriptedTransport(.cancellation, secret: secret)
    do {
        _ = try await TestRig.connect(configuration: config, transport: transport)
        Issue.record("Cancellation ignored")
    } catch is CancellationError {
    }
    #expect(await transport.bodies.count == 1)
}
