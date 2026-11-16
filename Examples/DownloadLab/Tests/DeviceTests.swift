import ConnectionRig
import Testing
import XCTest

@testable import DownloadLab

private struct DownloadOutcome {
    let verified: Bool
    let attempt: Int
}

/// Exercises the model directly; the visible app's Download button is not used by this test.
@MainActor
private func deviceFlow() async throws -> DownloadOutcome {
    let env = ProcessInfo.processInfo.environment
    guard let origin = env["RIG_CONTROL_URL"], let url = URL(string: origin),
        let secret = env["RIG_PAIRING_SECRET"], let download = env["RIG_DOWNLOAD_URL"],
        let endpoint = URL(string: download)
    else {
        throw XCTSkip(
            """
            Set RIG_CONTROL_URL, RIG_DOWNLOAD_URL and RIG_PAIRING_SECRET in the test scheme. Physical run \
            requires explicit authorization.
            """
        )
    }
    let rig = try await TestRig.connect(configuration: .init(endpoint: url, pairingSecret: secret))
    let session = try await rig.beginSession(clientName: "DownloadLab iPhone")
    do {
        try await session.setNetwork(
            .init(downloadKBps: 1000, uploadKBps: 200, chunkDelayMilliseconds: 5)
        )
        let model = DownloadModel()
        let transfer = Task {
            try await model.download(
                endpoint: endpoint,
                expectedBytes: 8_388_608,
                expectedSHA256: "bdf23837181f5808331800c1ae2b4f7d7a839536b10d58491471c50dde23833a"
            )
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(40))
            while model.received < 4_194_304 {
                if .now >= deadline {
                    throw RigFailure("progress", "Did not reach 50 percent within 40 seconds.")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await session.setNetwork(
                .init(downloadKBps: 100, uploadKBps: 50, chunkDelayMilliseconds: 50)
            )
            try await session.interrupt(for: .seconds(3))
            try await withTaskCancellationHandler {
                try await transfer.value
            } onCancel: {
                transfer.cancel()
            }
            let outcome = DownloadOutcome(verified: model.verified, attempt: model.attempt)
            try await session.close()
            return outcome
        } catch {
            transfer.cancel()
            _ = try? await transfer.value
            throw error
        }
    } catch {
        try? await session.close()
        throw error
    }
}

final class DeviceXCTests: XCTestCase {
    @MainActor
    func testRecovery() async throws {
        let outcome = try await deviceFlow()
        XCTAssertTrue(outcome.verified)
        XCTAssertGreaterThan(outcome.attempt, 1)
    }
}

struct DeviceSwiftTests {
    @Test(
        .enabled(
            if: ["RIG_CONTROL_URL", "RIG_DOWNLOAD_URL", "RIG_PAIRING_SECRET"]
                .allSatisfy { ProcessInfo.processInfo.environment[$0] != nil },
            "Requires explicitly configured device acceptance"
        )
    )
    @MainActor
    func recovery() async throws {
        let outcome = try await deviceFlow()
        #expect(outcome.verified)
        #expect(outcome.attempt > 1)
    }
}
