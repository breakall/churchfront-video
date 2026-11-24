import Foundation
import Combine
import CueATEM
import CameraBridgeClient
import ServiceManagement
import AppKit
import UniformTypeIdentifiers
import CryptoKit

/// App lifecycle and settings adapter. The helper owns every authorization decision.
// UI/lifecycle fields stay on the main queue; the PTZ queue uses only locked accessors.
final class CameraBridgeRuntime: ObservableObject, @unchecked Sendable {
    static let shared = CameraBridgeRuntime()
    static let serviceName = "com.churchfront.cuevideo.camera-bridge.plist"
    @Published private(set) var message = "Bridge is off."
    @Published private(set) var status: BridgeStatus?
    @Published private(set) var running = false
    var onTrackingRevoked: ((UUID) -> Void)?
    private let lock = NSLock()
    private var connection: CameraBridgeConnection?
    private var managed: Set<UUID> = []
    private var camera: PTZCamera?
    private var settings = CameraBridgeSettings()
    private var revision = UUID()
    private var lifecycle: Task<Void, Never>?
    private var configurationID: String?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueVideo/CameraBridge", isDirectory: true)
    }

    func isManaged(_ id: UUID) -> Bool { lock.withLock { managed.contains(id) } }
    func currentConnection() -> CameraBridgeConnection? { lock.withLock { connection } }
    func commandFence(_ id: UUID) -> String? {
        isManaged(id) ? currentConnection()?.commandFence : nil
    }

    func adapter(for camera: PTZCamera, queue: DispatchQueue) -> PTZLink? {
        guard isManaged(camera.id) else { return nil }
        return CanonBridgeLink(camera: camera, connection: { [weak self] in self?.currentConnection() }, queue: queue)
    }

    func configure(_ next: CameraBridgeSettings, cameras: [PTZCamera]) {
        precondition(Thread.isMainThread)
        let selected = try? next.camera(in: cameras)
        let sameRoute = camera?.id == selected?.id && camera?.host == selected?.host &&
            camera?.port == selected?.port && camera?.proto == selected?.proto
        guard settings != next || !sameRoute else { camera = selected; return }
        let wasEnabled = settings.enabled
        revision = UUID()
        let expected = revision
        let outgoing = invalidateConnection()
        settings = next
        camera = selected
        if next.enabled {
            // Misconfiguration fails closed for Canon cameras instead of opening direct sessions.
            lock.withLock { managed.formUnion(cameras.filter { $0.proto == .canonXC }.map(\.id)) }
        }
        refreshRoutes()
        let previous = lifecycle
        previous?.cancel()
        lifecycle = Task { @MainActor [weak self] in
            guard let self else { return }
            await previous?.value
            if let outgoing { await outgoing.disconnect() }
            guard self.revision == expected, !Task.isCancelled else { return }
            await self.detach(expected: expected)
            guard self.revision == expected, !Task.isCancelled else { return }
            if !next.enabled {
                if wasEnabled {
                    guard await self.unregister(expected: expected) else { return }
                }
                guard self.revision == expected, !Task.isCancelled else { return }
                self.lock.withLock { self.managed.removeAll() }
                self.message = "Bridge is off."
                self.refreshRoutes()
                return
            }
            do {
                let selected = try next.camera(in: cameras)
                if wasEnabled {
                    guard await self.unregister(expected: expected) else { return }
                }
                guard self.revision == expected, !Task.isCancelled else { return }
                try self.writeConfiguration(camera: selected)
                try self.register()
                try await self.attach(expected: expected)
            } catch {
                guard self.revision == expected else { return }
                self.message = error.localizedDescription
            }
        }
    }

    func startBridge() {
        precondition(Thread.isMainThread)
        guard settings.enabled, let camera else { message = "Enable the bridge and configure one Canon camera first."; return }
        revision = UUID()
        let expected = revision
        let outgoing = invalidateConnection()
        let previous = lifecycle
        previous?.cancel()
        lifecycle = Task { @MainActor in
            await previous?.value
            if let outgoing { await outgoing.disconnect() }
            guard revision == expected, !Task.isCancelled else { return }
            await detach(expected: expected)
            guard revision == expected, !Task.isCancelled else { return }
            do {
                guard await unregister(expected: expected) else { return }
                guard revision == expected, !Task.isCancelled else { return }
                try writeConfiguration(camera: camera)
                try register()
                try await attach(expected: expected)
            } catch { if revision == expected { message = error.localizedDescription } }
        }
    }

    func stopBridge() {
        precondition(Thread.isMainThread)
        revision = UUID()
        let expected = revision
        let outgoing = invalidateConnection()
        let previous = lifecycle
        previous?.cancel()
        lifecycle = Task { @MainActor in
            await previous?.value
            if let outgoing { await outgoing.disconnect() }
            guard revision == expected, !Task.isCancelled else { return }
            await detach(expected: expected)
            guard revision == expected, !Task.isCancelled else { return }
            if await unregister(expected: expected), revision == expected {
                message = "Bridge stopped. Physical forwarding is off."
            }
        }
    }

    /// App quit releases only the app connection, never unregisters the helper.
    func prepareToQuit() {
        precondition(Thread.isMainThread)
        revision = UUID()
        let expected = revision
        let outgoing = invalidateConnection()
        let previous = lifecycle
        previous?.cancel()
        lifecycle = Task { @MainActor in
            await previous?.value
            if let outgoing { await outgoing.disconnect() }
            await detach(expected: expected)
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "camera-bridge-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let events = Self.diagnosticEvents(in: Self.directory)
            var report: [String: Any] = ["schemaVersion": 1, "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
                "cameraAlias": "camera-1", "bridgeInterfaceVersion": 1,
                "settings": ["enabled": settings.enabled, "diagnosticsEnabled": settings.diagnosticsEnabled,
                             "nativeTrackingControl": settings.nativeTrackingControl], "events": events]
            if let status {
                var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as! [String: Any]
                value.removeValue(forKey: "connection")
                value["connectionAlias"] = status.connection == nil ? "none" : "app-1"
                report["status"] = value
            }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
            message = "Diagnostic report exported."
        } catch { message = "Could not export diagnostics: \(error.localizedDescription)" }
    }

    /// Read only the helper's three retained sanitized journals, oldest first.
    /// Each file is capped independently so a damaged log cannot grow the export without bound.
    static func diagnosticEvents(in directory: URL) -> [Any] {
        var events: [Any] = []
        for name in ["diagnostics.jsonl.2", "diagnostics.jsonl.1", "diagnostics.jsonl"] {
            guard let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(name)) else { continue }
            let data = (try? handle.read(upToCount: 2_097_152)) ?? Data()
            try? handle.close()
            events += String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8))
            }
        }
        return events
    }

    func authorizeTracking(_ id: UUID, done: @escaping (String?) -> Void) {
        guard isManaged(id) else { done(nil); return }
        guard let connection = currentConnection() else {
            message = "Tracking cannot start because the bridge is unavailable."
            done(message); return
        }
        connection.authorize { [weak self, weak connection] why in
            let acceptedFence = connection?.commandFence
            DispatchQueue.main.async {
                guard let self, let connection, self.currentConnection() === connection,
                      connection.commandFence == acceptedFence else {
                    done("The bridge connection changed before tracking could start."); return
                }
                if let why { self.message = why }
                done(why)
            }
        }
    }

    func revokeTracking(_ id: UUID) {
        if isManaged(id) { currentConnection()?.revoke() }
    }

    private func register() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/camera-control-bridge").path) else {
            throw CameraBridgeSetupError("Build the application bundle before starting the background bridge.")
        }
        let service = SMAppService.agent(plistName: Self.serviceName)
        if service.status == .requiresApproval {
            throw CameraBridgeSetupError("Allow Churchfront Video in System Settings > General > Login Items, then start the bridge.")
        }
        if service.status != .enabled { try service.register() }
    }

    private func unregister(expected: UUID) async -> Bool {
        do {
            let service = SMAppService.agent(plistName: Self.serviceName)
            if service.status != .notRegistered { try await service.unregister() }
            return revision == expected && !Task.isCancelled
        } catch {
            if revision == expected { message = "The bridge could not be stopped: \(error.localizedDescription)" }
            return false
        }
    }

    private func writeConfiguration(camera: PTZCamera) throws {
        var address = URLComponents()
        address.scheme = "http"; address.host = camera.host; address.port = Int(camera.port)
        guard let url = address.url else { throw CameraBridgeSetupError("The camera address is invalid.") }
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let configuration = BridgeConfiguration(cameraURL: url.absoluteString, listenHost: settings.listenHost,
            controllerPort: settings.controllerPort, appPort: settings.appPort,
            controllerAddress: settings.controllerAddress, tokenFile: directory.appendingPathComponent("app-token").path,
            readyFile: directory.appendingPathComponent("ready.json").path,
            diagnosticsFile: directory.appendingPathComponent("diagnostics.jsonl").path,
            diagnosticsEnabled: settings.diagnosticsEnabled)
        let data = try JSONEncoder().encode(configuration)
        configurationID = configuration.identity
        let config = directory.appendingPathComponent("helper.json")
        try data.write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    }

    private struct Ready: Decodable {
        var version: Int
        var app_url: String
        var token_file: String
        var configuration_id: String
        var helper_build: String
    }

    private func attach(expected: UUID) async throws {
        message = "Connecting to the bridge…"
        var lastError: Error = CameraBridgeSetupError("The helper has not started. Check background-item approval in System Settings.")
        for _ in 0..<40 {
            guard !Task.isCancelled, revision == expected else { return }
            do {
                let ready = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: Self.directory.appendingPathComponent("ready.json")))
                guard ready.version == 1, let url = URL(string: ready.app_url),
                      ready.token_file == Self.directory.appendingPathComponent("app-token").path,
                      ready.configuration_id == configurationID else {
                    throw CameraBridgeSetupError("The helper and application connection metadata do not agree.")
                }
                let token = try String(contentsOfFile: ready.token_file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/camera-control-bridge")
                let build = "protocol1:" + SHA256.hash(data: try Data(contentsOf: executable)).prefix(12)
                    .map { String(format: "%02x", $0) }.joined()
                guard ready.helper_build == build else {
                    throw CameraBridgeSetupError("Restart the bridge to use the helper included in this application build.")
                }
                let next = CameraBridgeConnection(url: url, token: token, configurationID: configurationID, helperBuild: build)
                next.onStatus = { [weak self, weak next] status in
                    DispatchQueue.main.async {
                        guard let self, self.revision == expected, self.currentConnection() === next,
                              next?.commandFence == status.connection.map({ "\($0):\(status.generation)" }) else { return }
                        let previous = self.status
                        self.status = status
                        self.running = true
                        self.message = status.recoveryRequired ? "Bridge restarted. Release pan, tilt, zoom and focus on the physical controller before enabling tracking. Move and release each control if it does not send an idle stop." :
                            status.health != "ready" ? "Camera route unavailable. Tracking is off." :
                            status.authorized ? "Tracking has control." : status.manualTakeover ? "Manual control. Tracking is off." : "Bridge ready. Tracking is off."
                        let revoked = previous?.authorized == true ||
                            (status.manualTakeover && previous?.generation != status.generation)
                        if !status.authorized, revoked, let id = self.camera?.id { self.onTrackingRevoked?(id) }
                    }
                }
                next.onFailure = { [weak self, weak next] why, fence in
                    DispatchQueue.main.async {
                        guard let self, self.revision == expected, self.currentConnection() === next,
                              next?.commandFence == fence || next?.commandFence == nil else { return }
                        self.message = "Bridge unavailable: \(why)"
                        self.recover(expected: expected)
                    }
                }
                lock.withLock { connection = next }
                do { try await next.connect() }
                catch {
                    lock.withLock { if connection === next { connection = nil } }
                    await next.disconnect()
                    throw error
                }
                guard revision == expected, currentConnection() === next, !Task.isCancelled else {
                    await next.disconnect(); return
                }
                running = true
                return
            } catch { lastError = error }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw lastError
    }

    private func detach(expected: UUID) async {
        guard revision == expected else { return }
        let old = invalidateConnection()
        if let old { await old.disconnect() }
    }

    private func invalidateConnection() -> CameraBridgeConnection? {
        let old = lock.withLock { let old = connection; connection = nil; return old }
        old?.invalidate()
        status = nil
        running = false
        if let id = camera?.id { onTrackingRevoked?(id) }
        return old
    }

    /// Reattach only; a healthy physical helper is never restarted by IPC recovery.
    private func recover(expected: UUID) {
        guard revision == expected, settings.enabled else { return }
        let outgoing = invalidateConnection()
        let previous = lifecycle
        previous?.cancel()
        lifecycle = Task { @MainActor [weak self] in
            guard let self else { return }
            await previous?.value
            if let outgoing { await outgoing.disconnect() }
            var delay = 0.5
            while self.revision == expected, self.settings.enabled, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard self.revision == expected, !Task.isCancelled else { return }
                do {
                    try await self.attach(expected: expected)
                    return
                } catch {
                    guard self.revision == expected else { return }
                    self.message = "Bridge connection unavailable. Retrying with tracking off. \(error.localizedDescription)"
                    delay = min(5, delay * 2)
                }
            }
        }
    }

    private func refreshRoutes() {
        Booth.shared.ptz.linkFactory = { camera, queue in Self.shared.adapter(for: camera, queue: queue) }
    }
}
