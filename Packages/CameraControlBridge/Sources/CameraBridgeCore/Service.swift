import Foundation
import Darwin
import CameraBridgeClient
import CryptoKit
import MachO

public final class BridgeService {
    private var controller: HTTPListener?
    private var app: HTTPListener?
    private var diagnosticsRefresh: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var lockDescriptor: Int32 = -1
    private let configuration: BridgeConfiguration
    public init(configuration: BridgeConfiguration) throws {
        guard let url = URL(string: configuration.cameraURL), ["http", "https"].contains(url.scheme ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["", "/"].contains(url.path), (1...65535).contains(url.port ?? 80),
              configuration.requestTimeout.isFinite, (0.1...10).contains(configuration.requestTimeout),
              configuration.leaseTimeout.isFinite, (1...30).contains(configuration.leaseTimeout),
              !configuration.controllerAddress.isEmpty, !configuration.tokenFile.isEmpty,
              configuration.appPort == 0 || configuration.appPort != configuration.controllerPort else {
            throw BridgeFailure("Invalid bridge configuration", status: 400)
        }
        self.configuration = configuration
    }
    public func start(configurationFile: URL? = nil) async throws -> [String: String] {
        let token = try loadToken()
        let lockPath = configuration.tokenFile + ".lock"
        lockDescriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw BridgeFailure("Bridge is already running or cannot lock configuration", status: 409) }
        let recoveryURL = URL(fileURLWithPath: configuration.tokenFile + ".recovery")
        let recovering = FileManager.default.fileExists(atPath: recoveryURL.path)
        let marker = try JSONSerialization.data(withJSONObject: ["version": 1, "configuration_id": configuration.identity])
        try marker.write(to: recoveryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
        // launchd may supply only a name in argv[0]. Resolve the loaded process
        // image instead; hashing empty data would hide a broken build agreement.
        var pathSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &pathSize)
        guard pathSize > 0 else { throw BridgeFailure("Cannot locate the running helper executable", status: 500) }
        var path = [CChar](repeating: 0, count: Int(pathSize))
        guard _NSGetExecutablePath(&path, &pathSize) == 0 else {
            throw BridgeFailure("Cannot locate the running helper executable", status: 500)
        }
        let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        let identity = "protocol1:" + SHA256.hash(data: try Data(contentsOf: executable)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let logPath = configuration.diagnosticsFile ?? URL(fileURLWithPath: configuration.tokenFile).deletingLastPathComponent().appendingPathComponent("bridge-diagnostics.jsonl").path
        let diagnostics = Diagnostics(enabled: configuration.diagnosticsEnabled, path: logPath,
                                      helperBuild: identity, configurationID: configuration.identity)
        let bridge = Bridge(configuration: configuration, token: token, diagnostics: diagnostics, helperBuild: identity, recovering: recovering)
        let controller = HTTPListener(), app = HTTPListener()
        self.controller = controller; self.app = app
        controller.handler = { request in await bridge.physical(request) }
        controller.streamHandler = { request, client in await bridge.streamInformation(request, client: client) }
        app.handler = { request in await bridge.app(request) }
        let controllerPort = try await controller.start(host: configuration.listenHost, port: configuration.controllerPort,
                                                        allowedSource: configuration.controllerAddress)
        let appPort = try await app.start(host: "127.0.0.1", port: configuration.appPort, allowedSource: "127.0.0.1")
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { await bridge.expire() }
            }
        }
        if let configurationFile {
            // Config is atomically replaced by Setup. Refresh the one live preference off
            // the forwarding and heartbeat paths, even after the UI quits.
            let expectedIdentity = configuration.identity
            diagnosticsRefresh = Task.detached(priority: .utility) {
                var lastUpdate: Date?
                while !Task.isCancelled {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: configurationFile.path),
                       let modified = attributes[.modificationDate] as? Date, modified != lastUpdate,
                       let data = try? Data(contentsOf: configurationFile),
                       let updated = try? JSONDecoder().decode(BridgeConfiguration.self, from: data),
                       updated.identity == expectedIdentity {
                        diagnostics.setEnabled(updated.diagnosticsEnabled)
                        lastUpdate = modified
                    }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
        }
        diagnostics.record("helper_started", generation: 0, origin: "helper")
        let host = configuration.listenHost.contains(":") ? "[\(configuration.listenHost)]" : configuration.listenHost
        return ["controller_url": "http://\(host):\(controllerPort)", "app_url": "http://127.0.0.1:\(appPort)", "token_file": configuration.tokenFile,
                "configuration_id": configuration.identity, "helper_build": identity]
    }
    public func stop() {
        diagnosticsRefresh?.cancel(); timer?.cancel(); controller?.stop(); app?.stop()
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor); lockDescriptor = -1 }
    }
    deinit { stop() }
    private func loadToken() throws -> String {
        let url = URL(fileURLWithPath: configuration.tokenFile)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let created = Darwin.open(configuration.tokenFile, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if created >= 0 {
            let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
            let bytes = Array(token.utf8)
            let written = bytes.withUnsafeBytes { Darwin.write(created, $0.baseAddress, $0.count) }
            Darwin.close(created)
            guard written == bytes.count else { throw BridgeFailure("Could not write helper credentials", status: 500) }
        } else if errno != EEXIST { throw BridgeFailure("Cannot create helper credentials", status: 500) }
        let descriptor = Darwin.open(configuration.tokenFile, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BridgeFailure("Cannot read helper credentials", status: 500) }
        defer { Darwin.close(descriptor) }
        var details = stat()
        guard fstat(descriptor, &details) == 0, details.st_uid == getuid(), details.st_mode & S_IFMT == S_IFREG,
              details.st_mode & 0o077 == 0, details.st_size >= 32, details.st_size <= 256 else { throw BridgeFailure("Helper token must be private, owned by this user, and 32–256 bytes", status: 400) }
        var bytes = [UInt8](repeating: 0, count: Int(details.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count, let token = String(bytes: bytes, encoding: .utf8), !token.contains("\r"), !token.contains("\n") else { throw BridgeFailure("Invalid helper credentials", status: 400) }
        return token
    }
}
