import SwiftUI

@main
struct DownloadLabApp: App {
    @State private var model = DownloadModel()
    @State private var endpoint =
        ProcessInfo.processInfo.environment["RIG_DOWNLOAD_URL"] ?? "http://127.0.0.1:49171/file"
    @State private var task: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("Controlled test download") {
                        TextField("Relay URL", text: $endpoint)
                            .accessibilityIdentifier("download.endpoint")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        ProgressView(value: Double(model.received), total: 8_388_608)
                        Text(model.state)
                            .accessibilityIdentifier("downloadState")
                        Text("\(model.received) bytes")
                            .monospacedDigit()
                            .accessibilityIdentifier("download.receivedBytes")
                            .accessibilityValue(String(model.received))
                        Text("Attempt \(model.attempt)")
                            .monospacedDigit()
                            .accessibilityIdentifier("download.attempt")
                            .accessibilityValue(String(model.attempt))
                        Button("Download 8 MiB fixture") {
                            guard let url = URL(string: endpoint) else {
                                return
                            }
                            task = Task {
                                try? await model.download(
                                    endpoint: url,
                                    expectedBytes: 8_388_608,
                                    expectedSHA256:
                                        "bdf23837181f5808331800c1ae2b4f7d7a839536b10d58491471c50dde23833a"
                                )
                            }
                        }
                        .accessibilityIdentifier("download.start")
                        .disabled(
                            task != nil && model.state != "Verified"
                                && !model.state.hasPrefix("Failed") && model.state != "Cancelled"
                        )
                        Button("Cancel") {
                            task?.cancel()
                            task = nil
                        }
                        .accessibilityIdentifier("download.cancel")
                    }
                    Section("Explicit recovery") {
                        Text(
                            """
                            An interrupted GET restarts from byte zero, up to 30 attempts. Completion requires \
                            the expected byte count and SHA-256. This sample keeps only a hash buffer, not \
                            the downloaded file.
                            """
                        )
                    }
                    Section("Routing") {
                        Text(
                            """
                            Use the Mac's reachable LAN address and relay port. USB deployment alone does not \
                            route this transfer. Local network permission is required.
                            """
                        )
                    }
                }
                .navigationTitle("Download Lab")
            }
        }
    }
}
