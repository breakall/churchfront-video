import Foundation
import ServiceManagement
import Darwin

/// An isolated owning application for exercising the real SMAppService path.
/// Compiled with the production CameraBridgeClient sources by the bench harness.
@main
struct ServiceBenchRegistrar {
    static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let action = arguments.first,
                  Bundle.main.bundleURL.pathExtension == "app",
                  let plist = Bundle.main.object(forInfoDictionaryKey: "CameraBridgeBenchAgentPlist") as? String,
                  Bundle.main.bundleIdentifier?.hasPrefix("com.churchfront.cuevideo.camera-bridge.bench.") == true,
                  (plist.hasPrefix("com.churchfront.cuevideo.camera-bridge.bench.") ||
                   plist == "com.churchfront.cuevideo.camera-bridge.plist") else {
                throw BenchError("Run from the isolated bench application bundle.")
            }
            let service = SMAppService.agent(plistName: plist)
            switch action {
            case "register": try service.register()
            case "unregister": try await service.unregister()
            case "status": break
            case "hold-app":
                guard arguments.count == 3 else { throw BenchError("hold-app requires helper-ready and app-ready paths") }
                try await holdApp(helperReady: arguments[1], appReady: arguments[2])
                return
            default: throw BenchError("Expected register, unregister, status or hold-app")
            }
            try emit(["action": action, "status": statusName(service.status),
                      "bundle": Bundle.main.bundleURL.path, "pid": ProcessInfo.processInfo.processIdentifier])
        } catch {
            let detail = error as NSError
            try? emit(["error": detail.localizedDescription, "domain": detail.domain, "code": detail.code])
            exit(1)
        }
    }

    static func holdApp(helperReady: String, appReady: String) async throws {
        struct Ready: Decodable { let app_url: String; let token_file: String }
        let ready = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: URL(fileURLWithPath: helperReady)))
        guard let url = URL(string: ready.app_url), url.host == "127.0.0.1", url.scheme == "http" else {
            throw BenchError("The service bench accepts only loopback helper addresses")
        }
        let token = try String(contentsOfFile: ready.token_file, encoding: .utf8)
        let client = BridgeClient(baseURL: url, token: token)
        let session = BenchAppSession(client: client, lease: try await client.connect())
        let heartbeats = Task {
            while !Task.isCancelled {
                await session.heartbeat()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let signals = AsyncStream<Void> { continuation in
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            term.setEventHandler { continuation.yield(()); continuation.finish() }
            interrupt.setEventHandler { continuation.yield(()); continuation.finish() }
            term.resume(); interrupt.resume()
            continuation.onTermination = { _ in term.cancel(); interrupt.cancel() }
        }
        let state = ["event": "app_ready", "pid": ProcessInfo.processInfo.processIdentifier] as [String: Any]
        try JSONSerialization.data(withJSONObject: state).write(to: URL(fileURLWithPath: appReady), options: .atomic)
        try emit(state)
        for await _ in signals { break }
        heartbeats.cancel()
        await session.disconnect()
    }
}

private actor BenchAppSession {
    let client: BridgeClient
    var lease: BridgeLease
    init(client: BridgeClient, lease: BridgeLease) { self.client = client; self.lease = lease }
    func heartbeat() async {
        guard let status = try? await client.status(), status.connection == lease.connection else { return }
        lease = BridgeLease(connection: lease.connection, generation: status.generation)
        _ = try? await client.heartbeat(lease)
    }
    func disconnect() async {
        if let status = try? await client.status(), status.connection == lease.connection {
            lease = BridgeLease(connection: lease.connection, generation: status.generation)
        }
        _ = try? await client.disconnect(lease)
    }
}

private struct BenchError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
