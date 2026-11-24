import Foundation

/// Logging has its own bounded queue. Neither disk latency nor failure joins the control queue.
final class Diagnostics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "camera-bridge.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var drops = 0
    let enabled: Bool
    private let path: String?
    private let helperBuild: String
    private let configurationID: String
    init(enabled: Bool, path: String?, helperBuild: String, configurationID: String) {
        self.enabled = enabled; self.path = path; self.helperBuild = helperBuild; self.configurationID = configurationID
    }
    var dropped: Int { lock.lock(); defer { lock.unlock() }; return drops }
    func record(_ decision: String, generation: UInt64, origin: String, endpoint: String = "", status: Int? = nil,
                requestID: String? = nil, parameters: [String: String] = [:], livescope: String? = nil,
                queueDepth: Int? = nil, queueWaitMs: Double? = nil, durationMs: Double? = nil) {
        guard enabled else { return }
        lock.lock()
        guard pending < 256 else { drops += 1; lock.unlock(); return }
        pending += 1; lock.unlock()
        let event = Event(time: Date().timeIntervalSince1970, monotonic: ProcessInfo.processInfo.systemUptime,
                          pid: ProcessInfo.processInfo.processIdentifier, generation: generation,
                          origin: origin, endpoint: endpoint, decision: decision, status: status,
                          requestID: requestID, parameters: Self.sanitized(parameters), livescope: livescope,
                          queueDepth: queueDepth, queueWaitMs: queueWaitMs, durationMs: durationMs,
                          helperBuild: helperBuild, configurationID: configurationID)
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            guard let path else { return }
            do {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 1_048_576 {
                    let older = path + ".2", previous = path + ".1"
                    try? FileManager.default.removeItem(atPath: older)
                    if FileManager.default.fileExists(atPath: previous) { try FileManager.default.moveItem(atPath: previous, toPath: older) }
                    try FileManager.default.moveItem(atPath: path, toPath: previous)
                }
                if !FileManager.default.fileExists(atPath: path) {
                    guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                var data = try JSONEncoder().encode(event); data.append(10)
                try file.write(contentsOf: data)
            } catch { lock.lock(); drops += 1; lock.unlock() }
        }
    }
    private struct Event: Encodable {
        var time: Double; var monotonic: Double; var pid: Int32; var generation: UInt64
        var origin: String; var endpoint: String; var decision: String; var status: Int?
        var requestID: String?; var parameters: [String: String]; var livescope: String?
        var queueDepth: Int?; var queueWaitMs: Double?; var durationMs: Double?
        var helperBuild: String; var configurationID: String
    }
    private static func sanitized(_ parameters: [String: String]) -> [String: String] {
        var safe = [String: String]()
        for (raw, value) in parameters {
            let key = raw.hasPrefix("c.1.") ? String(raw.dropFirst(4)) : raw
            let numeric = ["pan", "tilt", "zoom", "pan.speed", "tilt.speed", "zoom.speed", "p", "t", "s.priority"].contains(key) && Int(value) != nil
            let words: [String: Set<String>] = ["pan": ["left", "right", "stop"], "tilt": ["up", "down", "stop"],
                "zoom": ["tele", "wide", "stop"], "focus": ["auto", "manual"], "focus.action": ["near", "far", "stop", "one_shot"],
                "cmd": ["start", "stop", "cancel", "prepare", "delete"], "all": ["enabled", "disabled"]]
            if numeric || words[key]?.contains(value) == true { safe[key] = value }
        }
        return safe
    }
}
