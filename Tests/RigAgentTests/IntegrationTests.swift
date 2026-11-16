import ConnectionRig
import CryptoKit
import DownloadExample
import Foundation
import Network
import Testing

@testable import RigAgentCore

actor Fixture {
    let server: TCPServer
    let payload: Data
    var requests = 0

    init(size: Int = 1_048_576) throws {
        server = try TCPServer()
        payload = Data((0..<size).map { UInt8($0 % 251) })
    }

    func start() async throws -> UInt16 {
        try await server.start { socket in
            do {
                var request = Data()
                while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                    guard let chunk = try await socket.read() else {
                        return
                    }
                    request.append(chunk)
                }
                await self.countRequest()
                let bytes = self.payload
                try await socket.write(
                    Data(
                        "HTTP/1.1 200 OK\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                            .utf8
                    )
                )
                for offset in stride(from: 0, to: bytes.count, by: 16_384) {
                    try await socket.write(
                        bytes.subdata(in: offset..<min(offset + 16_384, bytes.count))
                    )
                }
                try await socket.finishWrite()
            } catch {
            }
        }
    }

    func countRequest() {
        requests += 1
    }

    func stop() async {
        await server.stop()
    }

    func hash() -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
func waitForProgress(_ model: DownloadModel, _ minimum: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while model.received < minimum {
        guard .now < deadline else {
            throw RigFailure("test", "Progress deadline exceeded: \(model.state)")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func makeRig(_ port: UInt16, secret: String, timeout: Double = 2) async throws -> TestRig {
    try await TestRig.connect(
        configuration: .init(
            endpoint: URL(string: "http://127.0.0.1:\(port)")!,
            pairingSecret: secret,
            commandTimeout: timeout
        )
    )
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func liveTransferThrottleInterruptBlockAndRecover() async throws {
    let fixture = try Fixture()
    let upstream = try await fixture.start()
    let secret = Pairing.generateSecret()
    let runtime = try AgentRuntime(
        secret: secret,
        controlPort: 0,
        trafficPort: 0,
        upstreamHost: "127.0.0.1",
        upstreamPort: upstream
    )
    let ports = try await runtime.start()
    do {
        let rig = try await makeRig(ports.control, secret: secret)
        #expect(await rig.capabilities == Capability.relay)
        let session = try await rig.beginSession(clientName: "Host integration")
        try await session.setNetwork(.init(downloadKBps: 512))
        let model = DownloadModel()
        let endpoint = URL(string: "http://127.0.0.1:\(ports.traffic)/file")!
        let hash = await fixture.hash()
        let transfer = Task {
            try await model.download(
                endpoint: endpoint,
                expectedBytes: 1_048_576,
                expectedSHA256: hash
            )
        }
        defer {
            transfer.cancel()
        }
        try await waitForProgress(model, 32_768)
        try await session.setNetwork(.init(downloadKBps: 64))
        // URLSession and TCP may still hold bytes forwarded under the previous limit.
        // Drain additional progress, then measure a window large enough to distinguish 64 from 512 KB/s.
        let afterChange = model.received
        try await waitForProgress(model, afterChange + 131_072)
        let startBytes = model.received
        let start = ContinuousClock.now
        try await waitForProgress(model, startBytes + 262_144)
        let elapsed = start.duration(to: .now)
        #expect(elapsed > .seconds(2))
        #expect(elapsed < .seconds(8))
        #expect(await fixture.requests == 1)
        try await session.interrupt(for: .milliseconds(600))
        // Separate control port still responds while data path is blocked.
        let during = try await rig.inspect()
        #expect(during.active?.blockedUntil != nil)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForResource = 0.2
        let blockedClient = URLSession(configuration: sessionConfig)
        do {
            _ = try await blockedClient.data(from: endpoint)
            Issue.record("A new relay connection succeeded during interruption")
        } catch {
            // Expected real transport failure, not an HTTP error stub.
        }
        blockedClient.invalidateAndCancel()
        // Direct upstream remains available: restrictions are scoped to relay traffic.
        let (direct, _) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(upstream)/file")!
        )
        #expect(direct.count == 1_048_576)
        try await withTaskCancellationHandler {
            try await transfer.value
        } onCancel: {
            transfer.cancel()
        }
        #expect(model.verified)
        #expect(model.attempt > 1)
        #expect(try await rig.inspect().active?.applied == NetworkConditions())
        try await session.close()
        try await session.close()
        let report = try await rig.inspect()
        #expect(report.completed.count == 1)
        #expect(report.completed[0].events.contains(where: { $0.kind == "interrupted" }))
        try await runtime.stop()
        await fixture.stop()
    } catch {
        try? await runtime.stop()
        await fixture.stop()
        throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func sdkUnavailableAuthenticationCancellationAndTimeout() async throws {
    let secret = Pairing.generateSecret()
    let silent = try TCPServer()
    let port = try await silent.start { socket in
        // Hold until cancellation to exercise an actual network timeout.
        do {
            while try await socket.read() != nil {
            }
        } catch {
        }
    }
    do {
        _ = try await makeRig(port, secret: secret, timeout: 0.1)
        Issue.record("Silent server unexpectedly acknowledged")
    } catch let error as RigFailure {
        #expect(error.code == "timeout")
    }
    let cancellation = Task { try await makeRig(port, secret: secret, timeout: 5) }
    cancellation.cancel()
    do {
        _ = try await cancellation.value
        Issue.record("Cancelled connection succeeded")
    } catch is CancellationError {
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
    }
    await silent.stop()
    do {
        _ = try await makeRig(port, secret: secret, timeout: 0.1)
        Issue.record("Stopped agent was available")
    } catch let error as RigFailure {
        #expect(error.code == "unavailable" || error.code == "timeout")
    }
    let engine = RecordingEngine()
    let agent = try Agent(engine: engine, secret: secret)
    let server = try ControlServer(agent: agent)
    let control = try await server.start()
    do {
        _ = try await makeRig(control, secret: Pairing.generateSecret())
        Issue.record("Wrong pairing authenticated")
    } catch let error as RigFailure {
        #expect(error.code == "authentication")
    }
    await server.stop()
}

@Test(.timeLimit(.minutes(1)))
func directionalUploadPacingAndChunkDelay() async throws {
    let sink = try TCPServer()
    let serverPort = try await sink.start { socket in
        do {
            var count = 0
            while count < 131_072 {
                guard let bytes = try await socket.read() else {
                    return
                }
                count += bytes.count
            }
            try await socket.write(Data("OK".utf8))
            try await socket.finishWrite()
        } catch {
        }
    }
    let relay = try TCPRelay(upstreamHost: "127.0.0.1", upstreamPort: serverPort)
    let port = try await relay.start()
    do {
        try await relay.apply(.init(uploadKBps: 64, chunkDelayMilliseconds: 20))
        let client = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
        client.start(queue: .global())
        let start = ContinuousClock.now
        try await client.write(Data(repeating: 42, count: 131_072))
        let reply = try await client.read()
        let elapsed = start.duration(to: .now)
        #expect(reply == Data("OK".utf8))
        #expect(elapsed > .seconds(1.5))
        #expect(elapsed < .seconds(6))
        client.cancel()
        await relay.stop()
        await sink.stop()
    } catch {
        await relay.stop()
        await sink.stop()
        throw error
    }
}
