import ConnectionRig
import RigAgentCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class CompanionModel {
    var bind = "127.0.0.1"
    var upstream = "127.0.0.1"
    var upstreamPort = "8080"
    var secret = Pairing.generateSecret()
    var status = "Stopped"
    var failure: String?
    var snapshot: AgentSnapshot?
    var runtime: AgentRuntime?
    var polling: Task<Void, Never>?

    func start() async {
        do {
            guard let port = UInt16(upstreamPort), port > 0 else {
                throw RigFailure("setup", "Enter an upstream TCP port.")
            }
            let runtime = try AgentRuntime(
                secret: secret,
                listenHost: bind,
                upstreamHost: upstream,
                upstreamPort: port
            )
            _ = try await runtime.start()
            self.runtime = runtime
            status = "Listening"
            failure = nil
            polling = Task { [weak self, agent = runtime.agent] in
                while !Task.isCancelled {
                    self?.snapshot = await agent.snapshot()
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        break
                    }
                }
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    func stop() async {
        do {
            try await runtime?.stop()
            runtime = nil
            polling?.cancel()
            status = "Stopped"
            secret = Pairing.generateSecret()
        } catch {
            failure = error.localizedDescription
        }
    }

    func restore() async {
        guard let runtime, let id = snapshot?.active?.id else {
            return
        }
        do {
            let command = try JSONEncoder().encode(Command(.restore, sessionID: id))
            let reply = await runtime.agent.handle(
                body: command,
                signature: Pairing.sign(command, secret: secret, domain: "request-v1")
            )
            if let error = reply.failure {
                throw error
            }
            snapshot = reply.snapshot
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct ReportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.json]
    }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        .init(regularFileWithContents: data)
    }
}

@main
struct RigCompanionApp: App {
    @State private var model = CompanionModel()

    var body: some Scene {
        WindowGroup("ConnectionRig") {
            CompanionView(model: model)
                .frame(minWidth: 850, minHeight: 600)
        }
        MenuBarExtra("ConnectionRig", systemImage: "network") {
            Text(model.status)
            Button("Restore conditions") {
                Task { await model.restore() }
            }
            Button("Stop agent") {
                Task { await model.stop() }
            }
        }
    }
}

struct CompanionView: View {
    @Bindable var model: CompanionModel
    @State private var selection = "Setup"
    @State private var export = false
    @State private var document = ReportDocument()

    var body: some View {
        NavigationSplitView {
            List(
                ["Setup", "Active session", "Completed sessions"],
                id: \.self,
                selection: $selection
            ) { name in
                Label(
                    name,
                    systemImage: name == "Setup"
                        ? "gearshape" : name == "Active session" ? "waveform.path" : "clock"
                )
            }
            .navigationTitle("ConnectionRig")
            Text("Native TCP relay · v1")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(selection)
                            .font(.largeTitle.bold())
                        Spacer()
                        Label(
                            model.status,
                            systemImage: model.runtime == nil ? "circle" : "checkmark.circle.fill"
                        )
                        .foregroundStyle(model.runtime == nil ? Color.secondary : Color.green)
                    }
                    if let failure = model.failure {
                        GroupBox("Action failed") {
                            Text(failure)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    if selection == "Setup" {
                        setup
                    } else if selection == "Active session" {
                        active
                    } else {
                        completed
                    }
                }
                .padding(28)
                .frame(maxWidth: 1000, alignment: .leading)
            }
        }
        .fileExporter(
            isPresented: $export,
            document: document,
            contentType: .json,
            defaultFilename: "connectionrig-session"
        ) { result in
            if case .failure(let error) = result {
                model.failure = error.localizedDescription
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Route test traffic") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Listen IP", text: $model.bind)
                    TextField("Upstream host", text: $model.upstream)
                    TextField("Upstream port", text: $model.upstreamPort)
                    Text(
                        """
                        Control: port 49170 → authenticated agent\nData: port 49171 → native relay → \
                        configured upstream
                        """
                    )
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                }
                .padding(8)
                .disabled(model.runtime != nil)
            }
            GroupBox("Pair test runner") {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("Pairing secret", text: $model.secret)
                        .disabled(true)
                    Button("Copy secret") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.secret, forType: .string)
                    }
                    Text(
                        """
                        Secret rotates when stopped. Commands and replies are HMAC authenticated. Use only a \
                        trusted test LAN; control metadata is not encrypted.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            GroupBox("Readiness and scope") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "TCP pacing, chunk delay, socket interruption",
                        systemImage: "checkmark.circle"
                    )
                    Label(
                        "USB routing and physical iPhone acceptance unverified",
                        systemImage: "exclamationmark.triangle"
                    )
                    Text(
                        """
                        Set Listen IP to the Mac's LAN address for a phone. Inject the relay endpoint into the \
                        app. Connecting USB does not route traffic. Startup confirms listeners; upstream \
                        reachability must be checked by a download.
                        """
                    )
                }
                .padding(8)
            }
            HStack {
                Button("Start agent") {
                    Task { await model.start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.runtime != nil)
                Button("Stop agent") {
                    Task { await model.stop() }
                }
                .disabled(model.runtime == nil)
            }
        }
    }

    @ViewBuilder
    private var active: some View {
        if let session = model.snapshot?.active {
            Text(session.client)
                .font(.title2)
            GroupBox("Confirmed applied conditions") { conditions(session.applied) }
            if session.requested != session.applied {
                GroupBox("Requested conditions") { conditions(session.requested) }
            }
            if let until = session.blockedUntil {
                Label(
                    "Connections blocked until \(until.formatted(date: .omitted, time: .standard))",
                    systemImage: "pause.circle"
                )
                .foregroundStyle(.orange)
            }
            Button("Restore normal forwarding") {
                Task { await model.restore() }
            }
            .buttonStyle(.borderedProminent)
            Text("Session timeline")
                .font(.headline)
            ForEach(session.events.reversed()) { event in
                HStack(alignment: .top) {
                    Text(event.date.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(event.kind.capitalized).bold()
                        Text(event.detail)
                            .font(.callout)
                    }
                }
                .padding(.vertical, 4)
            }
        } else {
            ContentUnavailableView(
                "Waiting for a test session",
                systemImage: "cable.connector",
                description: Text(
                    "Pair the SDK with the control endpoint. A disconnected test's conditions expire with its lease."
                )
            )
        }
    }

    private func conditions(_ value: NetworkConditions) -> some View {
        HStack(spacing: 24) {
            metric("Download", value.downloadKBps.map { "\($0) KB/s" } ?? "Unpaced")
            metric("Upload", value.uploadKBps.map { "\($0) KB/s" } ?? "Unpaced")
            metric("Chunk delay", "\(value.chunkDelayMilliseconds) ms")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
        }
    }

    @ViewBuilder
    private var completed: some View {
        if model.snapshot?.completed.isEmpty != false {
            ContentUnavailableView(
                "No completed sessions",
                systemImage: "clock",
                description: Text(
                    "Up to 10 reports are held in memory. Export before stopping the app."
                )
            )
        }
        ForEach(model.snapshot?.completed.reversed() ?? []) { report in
            GroupBox(report.client) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(report.startedAt.formatted())
                        Text("\(report.events.count) events · \(report.id.uuidString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Export JSON") {
                        do {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            document = ReportDocument(data: try encoder.encode(report))
                            export = true
                        } catch {
                            model.failure = error.localizedDescription
                        }
                    }
                }
                .padding(8)
            }
        }
    }
}
