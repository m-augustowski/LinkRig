import CryptoKit
import Foundation
import Observation

/// Example application helper, deliberately separate from the testing SDK.
/// Recovery strategy: discard a failed attempt and restart the complete GET, with bounded retries.
@MainActor
@Observable
public final class DownloadModel {
    public private(set) var received = 0
    public private(set) var attempt = 0
    public private(set) var state = "Ready"
    public private(set) var verified = false
    private var running = false

    public init() {
    }

    public func download(
        endpoint: URL,
        expectedBytes: Int,
        expectedSHA256: String,
        configuration: URLSessionConfiguration = .ephemeral,
        maximumAttempts: Int = 30
    ) async throws {
        guard expectedBytes > 0, (1...100).contains(maximumAttempts),
            expectedSHA256.count == 64, expectedSHA256.allSatisfy({ $0.isHexDigit }),
            configuration.identifier == nil
        else {
            throw DownloadError.configuration
        }
        guard !running else {
            throw DownloadError.alreadyRunning
        }
        running = true
        defer {
            running = false
        }
        verified = false
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        do {
            for current in 1...maximumAttempts {
                try Task.checkCancellation()
                attempt = current
                received = 0
                state = "Downloading"
                do {
                    var request = URLRequest(url: endpoint)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 10
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw DownloadError.response
                    }
                    var digest = SHA256()
                    var chunk = Data()
                    var total = 0
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        total += 1
                        guard total <= expectedBytes else {
                            throw DownloadError.integrity
                        }
                        if chunk.count >= 16_384 {
                            digest.update(data: chunk)
                            chunk.removeAll(keepingCapacity: true)
                            received = total
                        }
                    }
                    digest.update(data: chunk)
                    received = total
                    let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
                    guard total == expectedBytes, actual == expectedSHA256.lowercased() else {
                        throw DownloadError.integrity
                    }
                    verified = true
                    state = "Verified"
                    return
                } catch {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    // Integrity errors are terminal; they must never be disguised as transport retries.
                    if case DownloadError.integrity = error {
                        throw error
                    }
                    if current == maximumAttempts {
                        throw error
                    }
                    state = "Retrying from byte zero"
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
        } catch {
            state = Task.isCancelled ? "Cancelled" : "Failed: \(error.localizedDescription)"
            throw error
        }
    }
}

public enum DownloadError: Error {
    case response
    case integrity
    case alreadyRunning
    case configuration
}
