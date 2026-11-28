import Foundation
import Network

extension HTTPRequest {
    /// Replace just the session field. Preserve controller form encoding, order, and repeated info items.
    func withCameraSession(_ session: String?) throws -> HTTPRequest {
        _ = try parameters
        var result = self
        var replaced = false
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let field = session.map { "s=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        func translate(_ form: Substring) -> String {
            form.split(separator: "&", omittingEmptySubsequences: false).compactMap { part -> String? in
                guard part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first
                    .flatMap({ String($0).removingPercentEncoding }) == "s" else { return String(part) }
                replaced = true
                return field
            }.joined(separator: "&")
        }
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query = targetParts.count == 2 ? translate(targetParts[1]) : ""
        let originalBody = String(decoding: body, as: UTF8.self)
        var form = translate(originalBody[...])
        if !replaced, let field {
            if method == "POST" { form += (form.isEmpty ? "" : "&") + field }
            else { query += (query.isEmpty ? "" : "&") + field }
        }
        result.target = path + (query.isEmpty ? "" : "?" + query)
        result.body = Data(form.utf8)
        return result
    }
}

struct ControllerSessionView: Sendable {
    let sessionID: String?
    let origin: String
    let control: String
    let priority: Int
    let infoItems: String?
    let isInfo: Bool
    var axisSpeeds: [String: String] = [:]

    static func xc(_ code: String, _ body: String = "") -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["livescope-status": code, "content-type": "text/plain; charset=utf-8",
                                             "cache-control": "no-cache, no-store", "server": "vb"],
                     body: Data(body.utf8))
    }

    private func value(for key: String) -> String? {
        switch key {
        case "s": return sessionID
        case "s.origin": return origin
        case "s.control": return sessionID == nil ? nil : control
        case "s.priority": return sessionID.map { _ in String(priority) }
        case "s.duration": return sessionID.map { _ in "0" }
        default: return nil
        }
    }

    private static let sessionKeys = ["s", "s.origin", "s.control", "s.priority", "s.duration"]

    /// Canon info.cgi item selectors are applied in order and support subtree exclusions.
    private func requested(_ key: String) -> Bool {
        guard let infoItems, !infoItems.isEmpty else { return true }
        let selectors = infoItems.split(separator: ",")
        var include = selectors.first?.hasSuffix("!") == true
        for selector in selectors {
            let excluded = selector.hasSuffix("!")
            let pattern = excluded ? String(selector.dropLast()) : String(selector)
            if pattern == "*" || pattern == key || key.hasPrefix(pattern.hasSuffix(".") ? pattern : pattern + ".") {
                include = !excluded
            }
        }
        return include
    }

    func renderLine(_ line: String, seen: inout Set<String>) -> String? {
        for separator in [":=", "=="] {
            guard let range = line.range(of: separator) else { continue }
            let key = String(line[..<range.lowerBound])
            if Self.sessionKeys.contains(key) {
                seen.insert(key)
                return value(for: key).map { key + separator + $0 }
            }
            if axisSpeeds[key] != nil { seen.insert(key) }
            break
        }
        return line
    }

    func missingFields(seen: Set<String>) -> [String] {
        guard isInfo, sessionID != nil else { return [] }
        return (Self.sessionKeys + axisSpeeds.keys.sorted()).compactMap { key in
            guard !seen.contains(key), requested(key), let value = value(for: key) ?? axisSpeeds[key] else { return nil }
            return key + ":=" + value
        }
    }

    func reply(_ response: HTTPResponse) -> HTTPResponse {
        if response.sessionExpired { return Self.xc("408 Conflict") }
        // Never send a redirect to the camera or expose a session in a redirect URL.
        if (300..<400).contains(response.status) { return HTTPResponse(status: 502) }
        var result = response
        result.originalWire = nil
        result.headers.removeValue(forKey: "location")
        result.headers.removeValue(forKey: "content-location")
        guard response.status == 200, response.headers["livescope-status"] == "0",
              response.headers["content-type"]?.lowercased().hasPrefix("text/") == true,
              let text = String(data: response.body, encoding: .utf8) else { return result }
        var seen = Set<String>()
        let rendered = text.split(whereSeparator: \.isNewline).compactMap { renderLine(String($0), seen: &seen) }
        if sessionID == nil && seen.isEmpty { return result }
        let fields = rendered + missingFields(seen: seen)
        let separator = text.contains("\r\n") ? "\r\n" : "\n"
        result.body = Data((fields.joined(separator: separator) + (fields.isEmpty ? "" : separator)).utf8)
        return result
    }
}

/// The CR-N500's default open uses LF lines and includes the negotiated video
/// descriptor before the client sends any claim or information request.
struct CanonDefaultOpen: Equatable, Sendable {
    let authorities: [String]
    let video: String
    var axisSpeeds: [String: String] = [:]

    // These settings belong to the Canon session. Unscoped camera snapshots
    // contain the ranges but omit the session's speed, ratio and mode values.
    static let axisSpeedKeys = Set(["pan", "tilt"].flatMap { axis in
        ["dir", "pos", "ratio.dir", "ratio.pos", "mode.dir", "mode.pos"].map { "c.1." + axis + ".speed." + $0 }
    })

    init?(_ fields: [String: String]) {
        let keys = ["s.authority.audio", "s.authority.control", "s.authority.video"]
        var authorities = [String]()
        for key in keys {
            guard let value = fields[key], ["enabled", "disabled"].contains(value) else { return nil }
            authorities.append(key + ":=" + value)
        }
        guard let video = fields["v"], video.utf8.count <= 128,
              video.range(of: #"^(jpg|h264|h265)(:[0-9x:]+)?$"#, options: .regularExpression) != nil else { return nil }
        self.authorities = authorities
        self.video = video
    }

    func body(id: String, origin: String, priority: Int) -> String {
        let fields = ["s:=" + id] + authorities + [
            "s.origin:=" + origin, "s.duration==0", "s.priority:=" + String(priority), "v:=" + video
        ]
        return fields.joined(separator: "\n") + "\n"
    }
}

struct ControllerSessions {
    private struct Session {
        var priority: Int
        var lastSeen: TimeInterval
        var axisSpeeds: [String: String]
    }

    mutating func observeControlReply(_ fields: [String: String], session id: String?) {
        guard let id, sessions[id] != nil else { return }
        sessions[id]?.axisSpeeds.merge(fields.filter { CanonDefaultOpen.axisSpeedKeys.contains($0.key) }) { _, new in new }
    }
    private var sessions: [String: Session] = [:]
    private var bareSessionID: String?
    private(set) var ownershipGeneration: UInt64 = 0
    private var owner: String? {
        didSet { if oldValue != owner { ownershipGeneration &+= 1 } }
    }
    static let controlledEndpoints: Set<String> = ["/-wvhttp-01-/control.cgi", "/-wvhttp-01-/preset/set",
                                                   "/-wvhttp-01-/trace/set", "/-wvhttp-01-/trace/control"]
    private var streams: [ObjectIdentifier: (id: String, client: NWConnection)] = [:]

    mutating func trackStream(_ client: NWConnection, for id: String?) {
        if let id { streams[ObjectIdentifier(client)] = (id, client) }
    }

    mutating func untrackStream(_ client: NWConnection) {
        streams.removeValue(forKey: ObjectIdentifier(client))
    }

    // A client whose claim state changed must reconnect for a fresh status view.
    // End only its current information poll; the virtual session remains usable.
    private func invalidateStreams(for id: String?) {
        guard let id else { return }
        for stream in streams.values where stream.id == id { stream.client.cancel() }
    }

    let host: String
    var port: UInt16
    init(host: String, port: UInt16) { self.host = host; self.port = port }

    func view(for request: HTTPRequest) throws -> ControllerSessionView {
        let params = try request.parameters
        let id = params["s"]
        return ControllerSessionView(sessionID: id, origin: (host.contains(":") ? "[\(host)]" : host) + ":\(port)",
                                     control: id != nil && id == owner ? "enabled" : "disabled",
                                     priority: id.flatMap { sessions[$0]?.priority } ?? 0,
                                     infoItems: params["item"], isInfo: request.path == "/-wvhttp-01-/info.cgi",
                                     axisSpeeds: id.flatMap { sessions[$0]?.axisSpeeds } ?? [:])
    }

    mutating func localReply(for request: HTTPRequest, defaultOpen: CanonDefaultOpen? = nil) throws -> HTTPResponse? {
        let params = try request.parameters
        let now = ProcessInfo.processInfo.systemUptime
        let id = params["s"]
        let endpoint = request.path
        let xc = ControllerSessionView.xc
        if endpoint == "/-wvhttp-01-/open.cgi" {
            guard let priority = Int(params["s.priority"] ?? params["priority"] ?? "0"), (0...50).contains(priority) else {
                return xc("403 Invalid Parameter Value", "")
            }
            // The listener admits one physical controller. Its bare open after a
            // reboot replaces its previous bare session, even if that session
            // raised priority and the power loss prevented a close.
            if params.isEmpty, let previous = bareSessionID {
                invalidateStreams(for: previous)
                sessions.removeValue(forKey: previous)
            }
            let activeStreams = Set(streams.values.map(\.id))
            sessions = sessions.filter { now - $0.value.lastSeen < 60 || activeStreams.contains($0.key) }
            if let owner, sessions[owner] == nil { self.owner = nil }
            guard sessions.count < 32 else { return xc("503 Too many clients", "") }
            let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let newID = String(uuid.prefix(4)) + "-" + uuid.suffix(8)
            sessions[newID] = Session(priority: priority, lastSeen: now, axisSpeeds: defaultOpen?.axisSpeeds ?? [:])
            if params.isEmpty { bareSessionID = newID }
            // One configured physical controller; XC controllers may send movement directly after open.
            if (owner.flatMap { sessions[$0]?.priority } ?? 0) <= priority {
                invalidateStreams(for: owner)
                owner = newID
            }
            let origin = try view(for: request).origin
            if params.isEmpty, let defaultOpen {
                return xc("0", defaultOpen.body(id: newID, origin: origin, priority: priority))
            }
            let control = owner == newID ? "enabled" : "disabled"
            return xc("0", "s:=\(newID)\r\ns.authority.audio:=disabled\r\ns.authority.control:=enabled\r\ns.authority.video:=enabled\r\ns.origin:=\(origin)\r\ns.duration:=0\r\ns.priority:=\(priority)\r\ns.control:=\(control)\r\n")
        }
        if let id {
            guard sessions[id] != nil else { return xc("501 Unknown Connection ID", "") }
            sessions[id]?.lastSeen = now
        }
        switch endpoint {
        case "/-wvhttp-01-/claim.cgi", "/-wvhttp-01-/yield.cgi", "/-wvhttp-01-/close.cgi", "/-wvhttp-01-/session.cgi":
            guard let id, var session = sessions[id] else { return xc("406 Parameter Missing", "") }
            if endpoint.hasSuffix("/close.cgi") {
                invalidateStreams(for: id)
                sessions.removeValue(forKey: id)
                if bareSessionID == id { bareSessionID = nil }
                if owner == id { owner = nil }
                return xc("0", "OK\r\n")
            }
            if endpoint.hasSuffix("/session.cgi") {
                if let raw = params["s.priority"] ?? params["priority"] {
                    guard let p = Int(raw), (0...50).contains(p) else { return xc("403 Invalid Parameter Value", "") }
                    if session.priority != p { invalidateStreams(for: id) }
                    session.priority = p; sessions[id] = session
                }
                return xc("0", "s.priority:=\(session.priority)\r\n")
            }
            if endpoint.hasSuffix("/yield.cgi") {
                if owner == id { invalidateStreams(for: id); owner = nil }
                return xc("0", "s.control:=disabled\r\n")
            }
            if owner != id, (owner.flatMap { sessions[$0]?.priority } ?? 0) <= session.priority {
                invalidateStreams(for: owner); invalidateStreams(for: id)
                owner = id
            }
            return xc("0", owner == id ? "s.control:=enabled\r\n" : "s.control:=waiting\r\n")
        default:
            if let id, id != owner, Self.controlledEndpoints.contains(endpoint) {
                return xc("301 No Control Privilege", "")
            }
            return nil
        }
    }
}
