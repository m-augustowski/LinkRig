import Foundation
import Network
import RigProtocol

public actor ControlServer {
    private let server: TCPServer
    private let agent: Agent

    public init(agent: Agent, host: String = "127.0.0.1", port: UInt16 = 0) throws {
        self.agent = agent
        server = try TCPServer(host: host, port: port)
    }

    public func start() async throws -> UInt16 {
        try await server.start { socket in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.serve(socket) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    socket.cancel()
                }
                await group.next()
                group.cancelAll()
                socket.cancel()
            }
        }
    }

    public func stop() async {
        await server.stop()
    }

    private func serve(_ socket: NWConnection) async {
        do {
            var buffer = Data()
            let separator = Data("\r\n\r\n".utf8)
            while buffer.range(of: separator) == nil {
                guard let chunk = try await socket.read(maximum: 4096) else {
                    return
                }
                buffer.append(chunk)
                guard buffer.count <= 8192 else {
                    return
                }
            }
            let boundary = buffer.range(of: separator)!
            guard let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else {
                return
            }
            let lines = header.components(separatedBy: "\r\n")
            guard lines.first == "POST /v1/command HTTP/1.1" else {
                return
            }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else {
                    return
                }
                let key = pieces[0].lowercased()
                guard fields[key] == nil else {
                    return
                }
                fields[key] = pieces[1].trimmingCharacters(in: .whitespaces)
            }
            guard fields["transfer-encoding"] == nil,
                let size = Int(fields["content-length"] ?? ""), (1...65_536).contains(size)
            else {
                return
            }
            var body = Data(buffer[boundary.upperBound...])
            while body.count < size {
                guard let chunk = try await socket.read(maximum: size - body.count) else {
                    return
                }
                body.append(chunk)
            }
            guard body.count == size else {
                return
            }
            let reply = await agent.handle(body: body, signature: fields["x-rig-signature"] ?? "")
            let data = try JSONEncoder().encode(reply)
            let signature = Pairing.sign(data, secret: agent.secret, domain: "reply-v1")
            let response =
                """
                HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \
                \(data.count)\r\nX-Rig-Signature: \(signature)\r\nCache-Control: no-store\r\nConnection: \
                close\r\n\r\n
                """
            try await socket.write(Data(response.utf8) + data)
        } catch {
            // No request data or credentials are logged.
        }
    }
}

/// Shared by CLI and UI. Window lifetime does not determine service lifetime.
public actor AgentRuntime {
    public nonisolated let agent: Agent
    public nonisolated let relay: TCPRelay
    private let control: ControlServer
    private var maintenance: Task<Void, Never>?

    public init(
        secret: String,
        listenHost: String = "127.0.0.1",
        controlPort: UInt16 = 49170,
        trafficPort: UInt16 = 49171,
        upstreamHost: String,
        upstreamPort: UInt16
    ) throws {
        let relay = try TCPRelay(
            listenHost: listenHost,
            port: trafficPort,
            upstreamHost: upstreamHost,
            upstreamPort: upstreamPort
        )
        self.relay = relay
        agent = try Agent(engine: relay, secret: secret)
        control = try ControlServer(agent: agent, host: listenHost, port: controlPort)
    }

    public func start() async throws -> (control: UInt16, traffic: UInt16) {
        let traffic = try await relay.start()
        do {
            let port = try await control.start()
            maintenance = Task { [agent] in
                while !Task.isCancelled {
                    await agent.tick()
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        break
                    }
                }
            }
            return (port, traffic)
        } catch {
            await relay.stop()
            throw error
        }
    }

    public func stop() async throws {
        await control.stop()
        maintenance?.cancel()
        maintenance = nil
        // Socket closure releases all forwarding state even if a command is racing shutdown.
        await relay.stop()
        try await agent.shutdown()
    }
}
