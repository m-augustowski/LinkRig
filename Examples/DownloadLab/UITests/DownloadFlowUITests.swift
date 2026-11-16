import ConnectionRig
import XCTest

/// Drives the visible application while the same SDK controls its routed TCP traffic.
final class DownloadFlowUITests: XCTestCase {
    @MainActor
    func testDownloadRecoversAfterSlowdownAndInterruption() async throws {
        continueAfterFailure = false

        let environment = ProcessInfo.processInfo.environment
        guard let control = environment["RIG_CONTROL_URL"], let controlURL = URL(string: control),
            let secret = environment["RIG_PAIRING_SECRET"], let download = environment["RIG_DOWNLOAD_URL"]
        else {
            throw XCTSkip("Configure RIG_CONTROL_URL, RIG_DOWNLOAD_URL and RIG_PAIRING_SECRET in this UI-test scheme.")
        }

        let rig = try await TestRig.connect(configuration: .init(endpoint: controlURL, pairingSecret: secret))
        let session = try await rig.beginSession(clientName: "DownloadLab UI test")
        let app = XCUIApplication()
        // Only the data endpoint belongs to the application. The pairing secret stays in the test runner.
        app.launchEnvironment["RIG_DOWNLOAD_URL"] = download

        do {
            try await session.setNetwork(.init(downloadKBps: 512, uploadKBps: 200))
            app.launch()
            defer {
                app.terminate()
            }

            let startButton = app.buttons["download.start"]
            XCTAssertTrue(startButton.waitForExistence(timeout: 10), "Download action did not appear.")
            startButton.tap()

            // Real application progress determines when to change conditions; no fixed injection sleeps.
            _ = try await waitForReceivedBytes(2_097_152, in: app, timeout: .seconds(40))
            try await session.setNetwork(.init(downloadKBps: 64, uploadKBps: 50, chunkDelayMilliseconds: 20))
            let afterSlowdown = try receivedBytes(in: app)
            _ = try await waitForReceivedBytes(afterSlowdown + 131_072, in: app, timeout: .seconds(20))

            XCTAssertEqual(try attempt(in: app), 1, "The original transfer should still be active before interruption.")
            try await session.interrupt(for: .seconds(3))
            try await waitForVerification(in: app, timeout: .seconds(90))

            XCTAssertGreaterThan(try attempt(in: app), 1, "The application did not retry the interrupted transfer.")
            XCTAssertEqual(try receivedBytes(in: app), 8_388_608)
            XCTAssertEqual(app.staticTexts["downloadState"].label, "Verified")
            try await session.close()
        } catch {
            try? await session.close()
            throw error
        }
    }

    @MainActor
    private func receivedBytes(in app: XCUIApplication) throws -> Int {
        try integerValue(identifier: "download.receivedBytes", in: app)
    }

    @MainActor
    private func attempt(in app: XCUIApplication) throws -> Int {
        try integerValue(identifier: "download.attempt", in: app)
    }

    @MainActor
    private func integerValue(identifier: String, in app: XCUIApplication) throws -> Int {
        let element = app.staticTexts[identifier]
        guard element.exists, let value = element.value as? String, let number = Int(value) else {
            throw RigFailure("uiState", "Application did not expose a numeric accessibility value for \(identifier).")
        }
        return number
    }

    @MainActor
    private func waitForReceivedBytes(
        _ minimum: Int,
        in app: XCUIApplication,
        timeout: Duration
    ) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while .now < deadline {
            try Task.checkCancellation()
            try checkDownloadState(in: app)
            let received = try receivedBytes(in: app)
            if received >= minimum {
                return received
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RigFailure("progress", "Application did not reach \(minimum) bytes within the progress deadline.")
    }

    @MainActor
    private func waitForVerification(in app: XCUIApplication, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while .now < deadline {
            try Task.checkCancellation()
            try checkDownloadState(in: app)
            if app.staticTexts["downloadState"].label == "Verified" {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RigFailure("recovery", "Application did not verify its recovered download before the deadline.")
    }

    @MainActor
    private func checkDownloadState(in app: XCUIApplication) throws {
        guard app.state == .runningForeground else {
            throw RigFailure(
                "uiState",
                "Application is not in the foreground. Check launch and one-time permission setup."
            )
        }
        let state = app.staticTexts["downloadState"].label
        if state.hasPrefix("Failed") || state == "Cancelled" {
            throw RigFailure("download", state)
        }
    }
}
