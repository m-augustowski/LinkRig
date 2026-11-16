import Darwin
import Foundation
import RigAgentCore
import RigProtocol

@main
struct AgentMain {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.contains("--help") {
                print(
                    """
                    rig-agent [--bind 127.0.0.1] [--control-port 49170] [--traffic-port 49171] --upstream-host \
                    HOST --upstream-port PORT [--pairing-file PATH]
                    """
                )
                return
            }

            func value(_ name: String, _ fallback: String? = nil) throws -> String {
                if let i = args.firstIndex(of: name), i + 1 < args.count {
                    return args[i + 1]
                }
                if let fallback {
                    return fallback
                }
                throw RigFailure("arguments", "Missing \(name); use --help.")
            }

            func port(_ name: String, _ fallback: String? = nil) throws -> UInt16 {
                guard let port = UInt16(try value(name, fallback)), port > 0 else {
                    throw RigFailure("arguments", "Invalid \(name).")
                }
                return port
            }
            let path = try value("--pairing-file", ".connectionrig.pairing")
            let url = URL(fileURLWithPath: path)
            guard !FileManager.default.fileExists(atPath: path) else {
                throw RigFailure(
                    "pairing",
                    "Pairing file exists. Remove it explicitly to rotate credentials before starting."
                )
            }
            let secret = Pairing.generateSecret()
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw RigFailure("pairing", "Cannot exclusively create pairing file.")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: Data(secret.utf8))
            try handle.close()
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            let runtime = try AgentRuntime(
                secret: secret,
                listenHost: value("--bind", "127.0.0.1"),
                controlPort: port("--control-port", "49170"),
                trafficPort: port("--traffic-port", "49171"),
                upstreamHost: value("--upstream-host"),
                upstreamPort: port("--upstream-port")
            )
            let ports = try await runtime.start()
            print(
                """
                ConnectionRig ready. Control \(ports.control), traffic \(ports.traffic). Pairing file: \
                \(url.path). No USB tunnel configured.
                """
            )
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let stream = AsyncStream<Void> { continuation in
                let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
                let terminate = DispatchSource.makeSignalSource(signal: SIGTERM)
                interrupt.setEventHandler {
                    continuation.yield(())
                    continuation.finish()
                }
                terminate.setEventHandler {
                    continuation.yield(())
                    continuation.finish()
                }
                interrupt.resume()
                terminate.resume()
                continuation.onTermination = { _ in
                    interrupt.cancel()
                    terminate.cancel()
                }
            }
            for await _ in stream {
                break
            }
            try await runtime.stop()
        } catch {
            fputs("ConnectionRig: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
