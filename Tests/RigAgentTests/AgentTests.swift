import ConnectionRig
import Foundation
import RigProtocol
import Testing

@testable import RigAgentCore

actor RecordingEngine: NetworkEngine {
    var applied = NetworkConditions()
    var blocked = false
    var applyCount = 0

    func apply(_ conditions: NetworkConditions) {
        applied = conditions
        applyCount += 1
    }

    func interrupt() {
        blocked = true
    }

    func restore() {
        applied = .init()
        blocked = false
    }
}

func send(_ command: Command, to agent: Agent, secret: String) async throws -> Reply {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = try encoder.encode(command)
    return await agent.handle(
        body: body,
        signature: Pairing.sign(body, secret: secret, domain: "request-v1")
    )
}

@Test
func authenticationDuplicatesCapabilitiesAndIsolation() async throws {
    let secret = Pairing.generateSecret()
    let engine = RecordingEngine()
    let agent = try Agent(engine: engine, secret: secret)
    let denied = try await send(Command(.begin), to: agent, secret: Pairing.generateSecret())
    #expect(denied.failure?.code == "authentication")
    #expect(await agent.snapshot().active == nil)
    let begin = Command(.begin)
    let reply = try await send(begin, to: agent, secret: secret)
    let id = try #require(reply.snapshot?.active?.id)
    let duplicate = try await send(begin, to: agent, secret: secret)
    #expect(duplicate.snapshot?.active?.id == id)
    #expect(
        try await send(Command(.begin), to: agent, secret: secret).failure?.code == "sessionBusy"
    )
    let set = Command(.set, sessionID: id, conditions: .init(downloadKBps: 100))
    #expect(try await send(set, to: agent, secret: secret).failure == nil)
    #expect(try await send(set, to: agent, secret: secret).failure == nil)
    #expect(await engine.applyCount == 1)
    var conflict = set
    conflict.conditions = .init(downloadKBps: 20)
    #expect(try await send(conflict, to: agent, secret: secret).failure?.code == "conflict")
    var unsupported = Command(.discover)
    unsupported.requiredCapability = .radioControl
    #expect(try await send(unsupported, to: agent, secret: secret).failure?.code == "unsupported")
    var old = Command(.restore, sessionID: id)
    old.issuedAt = Date().addingTimeInterval(-90)
    #expect(try await send(old, to: agent, secret: secret).failure?.code == "expired")
    #expect(
        try await send(Command(.close, sessionID: id), to: agent, secret: secret).failure == nil
    )
    #expect(
        try await send(Command(.close, sessionID: id), to: agent, secret: secret).failure == nil
    )
    #expect(await agent.snapshot().completed.count == 1)
    #expect(await engine.applied == NetworkConditions())
}

@Test
func scheduledRestorationAndLeaseExpiry() async throws {
    let secret = Pairing.generateSecret()
    let engine = RecordingEngine()
    let agent = try Agent(engine: engine, secret: secret, leaseSeconds: 0.3)
    let begin = try await send(Command(.begin), to: agent, secret: secret)
    let id = try #require(begin.snapshot?.active?.id)
    _ = try await send(
        Command(.interrupt, sessionID: id, durationMilliseconds: 30),
        to: agent,
        secret: secret
    )
    #expect(await engine.blocked)
    try await Task.sleep(for: .milliseconds(50))
    await agent.tick()
    #expect(await engine.blocked == false)
    _ = try await send(
        Command(.set, sessionID: id, conditions: .init(uploadKBps: 1)),
        to: agent,
        secret: secret
    )
    try await Task.sleep(for: .milliseconds(350))
    await agent.tick()
    #expect(await agent.snapshot().active == nil)
    #expect(await engine.applied == NetworkConditions())
    #expect(
        await agent.snapshot().completed.first?.events
            .contains(where: { $0.detail == "Lease expired" }) == true
    )
}

@Test
func shutdownRestores() async throws {
    let secret = Pairing.generateSecret()
    let engine = RecordingEngine()
    let agent = try Agent(engine: engine, secret: secret)
    let begin = try await send(Command(.begin), to: agent, secret: secret)
    let id = try #require(begin.snapshot?.active?.id)
    _ = try await send(
        Command(.interrupt, sessionID: id, durationMilliseconds: 1000),
        to: agent,
        secret: secret
    )
    try await agent.shutdown()
    #expect(await engine.blocked == false)
    #expect(await agent.snapshot().active == nil)
}

actor RejectingEngine: NetworkEngine {
    func apply(_ conditions: NetworkConditions) throws {
        throw RigFailure("executionDenied", "Test engine refused application")
    }

    func interrupt() throws {
        throw RigFailure("executionDenied", "Test engine refused interruption")
    }

    func restore() {
    }
}

@Test
func failedApplicationIsNeverAcknowledgedAsApplied() async throws {
    let secret = Pairing.generateSecret()
    let agent = try Agent(engine: RejectingEngine(), secret: secret)
    let begin = try await send(Command(.begin), to: agent, secret: secret)
    let id = try #require(begin.snapshot?.active?.id)
    let result = try await send(
        Command(.set, sessionID: id, conditions: .init(downloadKBps: 10)),
        to: agent,
        secret: secret
    )
    #expect(result.failure?.code == "executionDenied")
    #expect(result.snapshot == nil)
    let snapshot = await agent.snapshot()
    #expect(snapshot.active?.requested.downloadKBps == 10)
    #expect(snapshot.active?.applied.downloadKBps == nil)
    #expect(snapshot.active?.events.contains(where: { $0.kind == "applied" }) == false)
    let interrupted = try await send(
        Command(.interrupt, sessionID: id, durationMilliseconds: 100),
        to: agent,
        secret: secret
    )
    #expect(interrupted.failure?.code == "executionDenied")
    #expect(await agent.snapshot().active?.blockedUntil == nil)
}
