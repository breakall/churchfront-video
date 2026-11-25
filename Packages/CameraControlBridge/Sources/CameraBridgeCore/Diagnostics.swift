import Foundation

/// Only classified metadata crosses the logging boundary; never raw protocol values.
struct DiagnosticDetails: Encodable, Sendable {
    var method: String?; var authScheme: String?; var sessionPresent: Bool?; var framing: String?
    var contentLength: Int?; var contentType: String?; var controlState: String?; var originRelation: String?
    var sentHeaders: Bool?; var upstreamBytes: Int?; var downstreamBytes: Int?; var firstByteMs: Double?
    var recoveryRequired: Bool?; var pendingPhysical: Bool?; var heldControls: Bool?

    static func request(_ request: HTTPRequest) -> Self {
        let auth = request.headers["authorization"]?.split(separator: " ").first.map { $0.lowercased() }
        return Self(method: request.method, authScheme: auth ?? "none",
                    sessionPresent: (try? request.parameters["s"]) != nil,
                    framing: request.headers["transfer-encoding"] != nil ? "unsupported" : request.headers["content-length"] != nil ? "content_length" : "none",
                    contentLength: request.body.count)
    }
    static func response(_ reply: HTTPResponse, request: HTTPRequest, cameraHost: String?) -> Self {
        var details = Self.request(request)
        let type = reply.headers["content-type"]?.lowercased()
        details.contentType = type == nil ? "missing" : type!.hasPrefix("text/") ? "text" : type!.hasPrefix("multipart/") ? "multipart" : type!.hasPrefix("application/json") ? "json" : "other"
        var fields = [String: String]()
        // Observe only the existing bounded snapshot; multipart bodies are not decoded here.
        for line in String(decoding: reply.body.prefix(65536), as: UTF8.self).split(whereSeparator: \.isNewline) {
            for separator in [":=", "=="] {
                if let split = line.range(of: separator) {
                    let key = String(line[..<split.lowerBound])
                    if ["s.control", "s.origin"].contains(key) { fields[key] = String(line[split.upperBound...]) }
                    break
                }
            }
        }
        if let control = fields["s.control"] {
            let parts = control.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count <= 2, let first = parts.first, ["enabled", "disabled", "waiting", "none"].contains(String(first)),
               parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy({ $0.isASCII && $0.isNumber })) {
                details.controlState = String(first)
            } else { details.controlState = "other" }
        } else { details.controlState = "missing" }
        if let origin = fields["s.origin"], let advertised = URL(string: origin), let host = advertised.host {
            let listener = request.headers["host"].flatMap { URL(string: "http://" + $0)?.host }
            details.originRelation = host == cameraHost ? "camera" : host == listener ? "listener" : "other"
        } else { details.originRelation = fields["s.origin"] == nil ? "missing" : "other" }
        return details
    }
    func sanitized() -> Self {
        var safe = self
        func choice(_ value: String?, _ allowed: Set<String>) -> String? { value.map { allowed.contains($0) ? $0 : "other" } }
        safe.method = choice(method, ["GET", "POST"])
        safe.authScheme = choice(authScheme, ["none", "basic", "digest", "bearer"])
        safe.framing = choice(framing, ["none", "content_length", "unsupported"])
        safe.contentType = choice(contentType, ["text", "multipart", "json", "missing"])
        safe.controlState = choice(controlState, ["enabled", "disabled", "waiting", "none", "missing"])
        safe.originRelation = choice(originRelation, ["camera", "listener", "other", "missing"])
        safe.contentLength = contentLength.map { min(max($0, 0), 2_097_152) }
        safe.upstreamBytes = upstreamBytes.map { min(max($0, 0), 2_147_483_647) }
        safe.downstreamBytes = downstreamBytes.map { min(max($0, 0), 2_147_483_647) }
        safe.firstByteMs = firstByteMs.flatMap { $0.isFinite && $0 >= 0 ? min($0, 120_000) : nil }
        return safe
    }
}

/// Logging has its own bounded queue. Neither disk latency nor failure joins the control queue.
final class Diagnostics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "camera-bridge.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var drops = 0
    private var captureEnabled: Bool
    var enabled: Bool { lock.withLock { captureEnabled } }
    func setEnabled(_ enabled: Bool) { lock.withLock { captureEnabled = enabled } }
    private let path: String?
    private let helperBuild: String
    private let configurationID: String
    init(enabled: Bool, path: String?, helperBuild: String, configurationID: String) {
        self.captureEnabled = enabled; self.path = path; self.helperBuild = helperBuild; self.configurationID = configurationID
    }
    var dropped: Int { lock.lock(); defer { lock.unlock() }; return drops }
    func record(_ decision: String, generation: UInt64, origin: String, endpoint: String = "", status: Int? = nil,
                requestID: String? = nil, parameters: [String: String] = [:], livescope: String? = nil,
                queueDepth: Int? = nil, queueWaitMs: Double? = nil, durationMs: Double? = nil,
                reason: String? = nil, details: DiagnosticDetails? = nil) {
        lock.lock()
        guard captureEnabled else { lock.unlock(); return }
        guard pending < 256 else { drops += 1; lock.unlock(); return }
        pending += 1; lock.unlock()
        let event = Event(time: Date().timeIntervalSince1970, monotonic: ProcessInfo.processInfo.systemUptime,
                          pid: ProcessInfo.processInfo.processIdentifier, generation: generation,
                          origin: origin, endpoint: Self.safeEndpoint(endpoint), decision: decision, status: status.flatMap { (100...599).contains($0) ? $0 : nil },
                          requestID: requestID, parameters: Self.sanitized(parameters), livescope: Self.safeLivescope(livescope),
                          queueDepth: queueDepth, queueWaitMs: queueWaitMs, durationMs: durationMs,
                          helperBuild: helperBuild, configurationID: configurationID,
                          reason: reason.map { Self.reasons.contains($0) ? $0 : "other" }, details: details?.sanitized())
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
        var schemaVersion = 2
        var time: Double; var monotonic: Double; var pid: Int32; var generation: UInt64
        var origin: String; var endpoint: String; var decision: String; var status: Int?
        var requestID: String?; var parameters: [String: String]; var livescope: String?
        var queueDepth: Int?; var queueWaitMs: Double?; var durationMs: Double?
        var helperBuild: String; var configurationID: String
        var reason: String?; var details: DiagnosticDetails?
    }
    private static let reasons: Set<String> = ["source_denied", "connection_limit", "request_deadline", "request_too_large", "header_limit", "invalid_headers", "invalid_request_line", "duplicate_header", "unsupported_framing", "invalid_body_size", "pipelining", "incomplete_request", "invalid_form", "stream_limit", "upstream_eof", "downstream_eof", "upstream_error", "downstream_error", "idle_timeout", "header_timeout", "malformed_headers", "unauthorized", "recovery_required", "held_controls", "pending_physical", "route_unready", "manual_takeover", "stale_lease", "tracking_disabled", "invalid_operation", "protocol_version", "superseded", "camera_unavailable", "other"]
    private static func safeEndpoint(_ value: String) -> String {
        let allowed: Set<String> = ["", "/-wvhttp-01-/open.cgi", "/-wvhttp-01-/close.cgi", "/-wvhttp-01-/claim.cgi", "/-wvhttp-01-/yield.cgi", "/-wvhttp-01-/info.cgi", "/-wvhttp-01-/control.cgi", "/-wvhttp-01-/preset/set", "/-wvhttp-01-/trace/set", "/-wvhttp-01-/trace/control", "/bridge/status", "/bridge/connect", "/bridge/disconnect", "/bridge/start", "/bridge/stop", "/bridge/heartbeat", "/bridge/command"]
        return allowed.contains(value) ? value : "other"
    }
    private static func safeLivescope(_ value: String?) -> String? {
        guard let value else { return nil }
        guard let first = value.split(separator: " ").first, first.count <= 3, first.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(first), (0...999).contains(number) else { return "other" }
        return String(number)
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
