import Foundation
import CameraBridgeClient
import Network

actor Bridge {
    private let upstream: Upstream
    private let diagnostics: Diagnostics
    private let token: String
    private let leaseTimeout: Double
    private let configurationID: String
    private let helperBuild: String
    private var connection: String?
    private var generation: UInt64 = 0
    private var authorized = false
    private var manualTakeover = false
    private var health = "ready"
    private var held = Set<String>()
    private var pendingPhysicalActions = 0
    private var activeStreams = 0
    private var recovering: Bool
    private var recoveryAxes = Set<String>()
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var cameraSession: String?
    private var appAxes = Set<String>()
    private var jobs = [Job]()
    private var draining = false
    private enum JobOrigin: String {
        case controller, tracking, manual, manualMove, stop, session, read

        var movesAppAxes: Bool {
            switch self {
            case .tracking, .manual, .manualMove: return true
            case .controller, .stop, .session, .read: return false
            }
        }
    }

    private struct Job {
        var request: HTTPRequest
        var origin: JobOrigin
        var generation: UInt64
        var connection: String?
        var requestID: String
        var enqueued: Double
        var neutralizeAppAxes: Bool
        var continuation: CheckedContinuation<HTTPResponse, Error>
    }

    init(configuration: BridgeConfiguration, token: String, diagnostics: Diagnostics, helperBuild: String, recovering: Bool) {
        upstream = Upstream(url: URL(string: configuration.cameraURL)!, timeout: configuration.requestTimeout)
        self.token = token; self.diagnostics = diagnostics; leaseTimeout = configuration.leaseTimeout
        configurationID = configuration.identity; self.helperBuild = helperBuild
        self.recovering = recovering
        if recovering {
            recoveryAxes = ["pan", "tilt", "zoom", "focus"]
            held = recoveryAxes.union(["recovery"])
            manualTakeover = true
        }
    }
    func status() -> BridgeStatus {
        BridgeStatus(generation: generation, authorized: authorized, heldAxes: held.sorted(), health: health,
                     manualTakeover: manualTakeover, diagnosticsEnabled: diagnostics.enabled,
                     droppedDiagnosticEvents: diagnostics.dropped, connection: connection,
                     configurationID: configurationID, helperBuild: helperBuild, recoveryRequired: recovering)
    }
    private func revoke(_ decision: String, manual: Bool = false) {
        authorized = false; generation &+= 1
        if manual { manualTakeover = true }
        diagnostics.record(decision, generation: generation, origin: manual ? "controller" : "app")
    }
    func expire() async {
        guard connection != nil, ProcessInfo.processInfo.systemUptime - lastHeartbeat > leaseTimeout else { return }
        revoke("lease_expired"); connection = nil
        try? await stopAppMotion()
    }
    func physical(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path.hasPrefix("/-wvhttp-01-/"), !request.target.contains("#") else { return HTTPResponse(status: 404) }
        do {
            let parameters = try request.parameters
            let action = isPhysicalAction(request.path, parameters)
            if action {
                revoke("manual_takeover", manual: true)
                pendingPhysicalActions += 1
                updateHeld(request, releasing: false)
            }
            defer { if action { pendingPhysicalActions -= 1 } }
            if request.path.hasSuffix("info.cgi") {
                let reply = try await upstream.send(request)
                observe(reply, request: request)
                rememberPhysicalSession(reply, request: request)
                return reply
            }
            return try await enqueue(request, origin: .controller)
        } catch {
            if !(error is BridgeFailure), (error as? HTTPError)?.status ?? 502 >= 500 {
                health = "unavailable"; revoke("camera_route_failed")
            }
            return failure(error, origin: "controller")
        }
    }
    func streamInformation(_ request: HTTPRequest, client: NWConnection) async {
        guard activeStreams < 16, (try? request.parameters) != nil else {
            let response = HTTPResponse(status: activeStreams >= 16 ? 503 : 400)
            await withCheckedContinuation { continuation in
                client.send(content: response.wire(), completion: .contentProcessed { _ in continuation.resume() })
            }
            return
        }
        activeStreams += 1
        let epoch = generation
        let requestID = UUID().uuidString, began = ProcessInfo.processInfo.systemUptime
        diagnostics.record("information_stream_opened", generation: generation, origin: "controller", endpoint: request.path, requestID: requestID)
        defer { activeStreams -= 1 }
        do {
            try await upstream.stream(request, to: client) { [weak self] reply in
                await self?.observeStream(reply, request: request, generation: epoch)
            }
            diagnostics.record("information_stream_closed", generation: generation, origin: "controller", endpoint: request.path,
                               requestID: requestID, durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
        } catch {
            health = "unavailable"; revoke("information_route_failed")
            diagnostics.record("information_stream_failed", generation: generation, origin: "controller", endpoint: request.path, status: 502,
                               requestID: requestID, durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
        }
    }
    private func observeStream(_ reply: HTTPResponse, request: HTTPRequest, generation epoch: UInt64) {
        guard generation == epoch else { return }
        observe(reply, request: request); rememberPhysicalSession(reply, request: request)
    }
    private func isPhysicalAction(_ path: String, _ parameters: [String: String]) -> Bool {
        if ["/-wvhttp-01-/preset/set", "/-wvhttp-01-/trace/set", "/-wvhttp-01-/trace/control"].contains(path) { return true }
        guard path == "/-wvhttp-01-/control.cgi" else { return false }
        let keys = parameters.keys.map { $0.hasPrefix("c.1.") ? String($0.dropFirst(4)) : $0 }
        return keys.contains { ["pan", "tilt", "zoom", "focus", "focus.action", "focus.value", "p"].contains($0) }
    }
    func app(_ request: HTTPRequest) async -> HTTPResponse {
        guard authenticated(request.headers["authorization"] ?? "") else { return .json(BridgeFailure("Unauthorized helper client", status: 401), status: 401) }
        do {
            await expire()
            if request.path == "/bridge/status", request.method == "GET" { return .json(status()) }
            guard request.method == "POST" else { throw BridgeFailure("Use POST", status: 405) }
            let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:]
            guard object["version"] as? Int == 1 else { throw BridgeFailure("Unsupported helper protocol version", status: 426) }
            if request.path == "/bridge/connect" {
                revoke("app_connected")
                let identity = UUID().uuidString
                connection = identity; lastHeartbeat = ProcessInfo.processInfo.systemUptime
                let lease = BridgeLease(connection: identity, generation: generation)
                try? await stopAppMotion()
                guard connection == lease.connection, generation == lease.generation else { throw BridgeFailure("App connection superseded", status: 409) }
                return .json(lease)
            }
            guard let identity = object["connection"] as? String, identity == connection,
                  let incoming = object["generation"] as? UInt64, incoming == generation else { throw BridgeFailure("Stale app lease", status: 409) }
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            switch request.path {
            case "/bridge/heartbeat": return .json(status())
            case "/bridge/disconnect":
                revoke("app_disconnected"); connection = nil; try await stopAppMotion(); return .json(status())
            case "/bridge/start":
                guard pendingPhysicalActions == 0 else { throw BridgeFailure("Physical action is pending", status: 409) }
                let checkedConnection = connection, checkedGeneration = generation
                // Canon session-scoped info is a differential long poll. A sessionless
                // snapshot always returns the current axis and trace completion state.
                let inspection = makeRequest("info.cgi", parameters: [:])
                let snapshot = try await upstream.send(inspection)
                guard snapshot.status == 200, snapshot.headers["livescope-status"] == "0" else { throw BridgeFailure("Camera route is not ready", status: 409) }
                guard checkedConnection == connection, checkedGeneration == generation else { throw BridgeFailure("Start interrupted by takeover", status: 409) }
                observe(snapshot, request: inspection)
                guard pendingPhysicalActions == 0, held.isEmpty, health == "ready" else { throw BridgeFailure("Physical controls or camera route are not ready", status: 409) }
                if !authorized {
                    let identity = connection!, epoch = generation
                    try await ensureSession()
                    guard identity == connection, epoch == generation, held.isEmpty, pendingPhysicalActions == 0 else { throw BridgeFailure("Start interrupted by takeover", status: 409) }
                    generation &+= 1; authorized = true; manualTakeover = false
                    diagnostics.record("tracking_authorized", generation: generation, origin: "app")
                }
                return .json(BridgeLease(connection: connection!, generation: generation))
            case "/bridge/stop":
                revoke("tracking_stopped")
                let lease = BridgeLease(connection: identity, generation: generation)
                try await stopAppMotion()
                guard connection == lease.connection, generation == lease.generation else { throw BridgeFailure("Stop lease superseded", status: 409) }
                return .json(lease)
            case "/bridge/command":
                let command = try JSONDecoder().decode(BridgeCommand.self, from: request.body)
                guard let origin = JobOrigin(rawValue: command.purpose), origin == .read || origin.movesAppAxes else {
                    throw BridgeFailure("Unsupported command purpose", status: 400)
                }
                let read = origin == .read
                let endpoints = read ? ["info.cgi"] : ["control.cgi", "preset/set", "trace/set", "trace/control"]
                guard endpoints.contains(command.endpoint), ["GET", "POST"].contains(command.method),
                      command.parameters["s"] == nil else { throw BridgeFailure("Unsupported app camera operation", status: 400) }
                if !read {
                    guard pendingPhysicalActions == 0, held.isEmpty, health == "ready", !manualTakeover || origin == .manual || origin == .manualMove else { throw BridgeFailure("Physical controller has priority", status: 409) }
                    if origin == .tracking, !authorized { throw BridgeFailure("Tracking is disabled", status: 409) }
                }
                var parameters = command.parameters
                if let cameraSession { parameters["s"] = cameraSession }
                let cameraRequest = makeRequest(command.endpoint, parameters: parameters, method: command.method)
                let reply: HTTPResponse
                if read {
                    let epoch = generation
                    reply = try await upstream.send(cameraRequest)
                    if epoch == generation { observe(reply, request: cameraRequest) }
                }
                else {
                    let neutralize = origin == .manualMove && authorized
                    if origin == .manualMove { authorized = false }
                    reply = try await enqueue(cameraRequest, origin: origin, neutralizeAppAxes: neutralize)
                }
                return .json(BridgeCameraReply(status: reply.status, headers: reply.headers, body: String(decoding: reply.body, as: UTF8.self)))
            default: throw BridgeFailure("Unknown helper operation", status: 404)
            }
        } catch { return failure(error, origin: "app") }
    }
    private func authenticated(_ value: String) -> Bool {
        let expected = Array(("Bearer " + token).utf8), candidate = Array(value.utf8)
        guard expected.count == candidate.count else { return false }
        return zip(expected, candidate).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private func ensureSession() async throws {
        let epoch = generation
        if let cached = cameraSession {
            // Reconfirm this same camera session only at the operator's explicit start.
            let reply = try await enqueue(makeRequest("claim.cgi", parameters: ["s": cached]), origin: .session)
            if controlGranted(reply), generation == epoch, cameraSession == cached { return }
            // 501 definitively identifies an expired camera session. Physical
            // takeover or a changed session still invalidates this start.
            guard reply.headers["livescope-status"] == "501", generation == epoch, cameraSession == nil else {
                throw BridgeFailure("Camera control unavailable or superseded", status: 409)
            }
        }
        let reply = try await enqueue(makeRequest("open.cgi", parameters: ["s.priority": "0"]), origin: .session)
        guard reply.status == 200, reply.headers["livescope-status"] == "0", let session = fields(reply)["s"] else { throw BridgeFailure("Camera session unavailable", status: 502) }
        do {
            guard epoch == generation else { throw BridgeFailure("Session open superseded", status: 409) }
            let claim = try await enqueue(makeRequest("claim.cgi", parameters: ["s": session]), origin: .session)
            guard controlGranted(claim) else {
                throw BridgeFailure("Camera control unavailable", status: 409)
            }
            guard epoch == generation else { throw BridgeFailure("Session claim superseded", status: 409) }
            cameraSession = session
        } catch {
            // Only the just-opened private session is closed, never the RC-IP100's.
            _ = try? await enqueue(makeRequest("close.cgi", parameters: ["s": session]), origin: .session)
            throw error
        }
    }
    private func controlGranted(_ reply: HTTPResponse) -> Bool {
        // XC may append the remaining privilege duration, e.g. enabled:20000.
        reply.status == 200 && reply.headers["livescope-status"] == "0" &&
            fields(reply)["s.control"]?.split(separator: ":", maxSplits: 1).first == "enabled"
    }

    private func enqueue(_ request: HTTPRequest, origin: JobOrigin, neutralizeAppAxes: Bool = false) async throws -> HTTPResponse {
        guard jobs.count < 128 else { throw BridgeFailure("Bridge command queue full", status: 503) }
        return try await withCheckedThrowingContinuation { continuation in
            let job = Job(request: request, origin: origin, generation: generation, connection: connection,
                          requestID: UUID().uuidString, enqueued: ProcessInfo.processInfo.systemUptime,
                          neutralizeAppAxes: neutralizeAppAxes, continuation: continuation)
            if origin == .controller, let index = jobs.firstIndex(where: { $0.origin != .controller }) { jobs.insert(job, at: index) }
            else { jobs.append(job) }
            diagnostics.record("enqueued", generation: generation, origin: origin.rawValue, endpoint: request.path,
                               requestID: job.requestID, parameters: (try? request.parameters) ?? [:], queueDepth: jobs.count)
            if !draining { draining = true; Task { await drain() } }
        }
    }
    private func obsolete(_ job: Job) -> Bool {
        job.origin != .controller && (job.generation != generation || job.connection != connection ||
            (job.origin == .tracking && !authorized))
    }

    // Called only by the serial camera writer. A controller axis already admitted
    // for takeover must never be stopped as part of cleaning up app movement.
    private func neutralizeAppMotion() async throws {
        let axes = appAxes.subtracting(held)
        guard !axes.isEmpty else { return }
        do {
            let stopped = try await upstream.send(stopRequest(for: axes))
            guard stopped.status == 200, stopped.headers["livescope-status"] == "0" else {
                throw BridgeFailure("Camera could not confirm the movement stop", status: 502)
            }
            appAxes.subtract(axes)
            if appAxes.isEmpty { held.remove("unresolvedAppMotion") }
        } catch {
            held.insert("unresolvedAppMotion")
            throw error
        }
    }

    private func drain() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            let started = ProcessInfo.processInfo.systemUptime
            let queueWait = (started - job.enqueued) * 1000
            if obsolete(job) {
                diagnostics.record("stale_discarded", generation: generation, origin: job.origin.rawValue, endpoint: job.request.path,
                                   status: 409, requestID: job.requestID, queueDepth: jobs.count, queueWaitMs: queueWait)
                job.continuation.resume(throwing: BridgeFailure("Obsolete app command discarded", status: 409)); continue
            }
            diagnostics.record("dispatched", generation: generation, origin: job.origin.rawValue, endpoint: job.request.path,
                               requestID: job.requestID, parameters: (try? job.request.parameters) ?? [:], queueDepth: jobs.count, queueWaitMs: queueWait)
            do {
                if (job.origin == .controller && isPhysicalAction(job.request.path, (try? job.request.parameters) ?? [:]) || job.neutralizeAppAxes), !appAxes.isEmpty {
                    do {
                        try await neutralizeAppMotion()
                    } catch {
                        if job.origin != .controller { throw error }
                        diagnostics.record("app_motion_cleanup_failed", generation: generation, origin: "controller", status: 502)
                    }
                    // Cleanup awaited a camera reply. A physical action, disconnect,
                    // or explicit stop can revoke this job during that suspension.
                    if obsolete(job) {
                        job.continuation.resume(throwing: BridgeFailure("Superseded during camera cleanup", status: 409))
                        continue
                    }
                }
                // Track starts before the first suspension so a concurrent stop sees
                // the possibly moving axes. Only a confirmed stop clears an axis.
                let axesBeforeDispatch = appAxes
                if job.origin.movesAppAxes { updateAppAxes(job.request, acknowledged: false) }
                let reply = try await upstream.send(job.request)
                observe(reply, request: job.request)
                if job.origin == .controller, reply.status == 200, reply.headers["livescope-status"] == "0" {
                    rememberPhysicalSession(reply, request: job.request)
                    updateHeld(job.request)
                    if let parameters = try? job.request.parameters {
                        for key in parameters.keys {
                            let normalized = key.hasPrefix("c.1.") ? String(key.dropFirst(4)) : key
                            if ["pan", "tilt", "zoom"].contains(normalized) { appAxes.remove(normalized) }
                            if normalized == "focus.action" { appAxes.remove("focus") }
                        }
                        if appAxes.isEmpty { held.remove("unresolvedAppMotion") }
                    }
                } else if job.origin.movesAppAxes || job.origin == .stop {
                    if reply.status == 200, reply.headers["livescope-status"] == "0" {
                        updateAppAxes(job.request, acknowledged: true)
                    } else if job.origin == .stop {
                        held.insert("unresolvedAppMotion")
                        throw BridgeFailure("Camera rejected the movement stop", status: 502)
                    } else if reply.status == 200, reply.headers["livescope-status"] != nil {
                        // A definitive camera rejection did not apply the new motion.
                        // All upstream axis writes pass through this single drain.
                        appAxes = axesBeforeDispatch
                    }
                }
                diagnostics.record("forwarded", generation: generation, origin: job.origin.rawValue, endpoint: job.request.path, status: reply.status,
                                   requestID: job.requestID, parameters: (try? job.request.parameters) ?? [:], livescope: reply.headers["livescope-status"],
                                   queueDepth: jobs.count, queueWaitMs: queueWait,
                                   durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
                job.continuation.resume(returning: reply)
            } catch {
                health = "unavailable"; revoke("camera_route_failed")
                // A timed-out app move may already be moving the real camera.
                // Send only a scoped stop; never replay the movement request.
                if job.origin.movesAppAxes {
                    do { try await neutralizeAppMotion() }
                    catch { diagnostics.record("app_motion_cleanup_failed", generation: generation, origin: job.origin.rawValue, status: 502) }
                } else if job.origin == .stop {
                    held.insert("unresolvedAppMotion")
                }
                diagnostics.record("forward_failed", generation: generation, origin: job.origin.rawValue, endpoint: job.request.path, status: 502,
                                   requestID: job.requestID, queueDepth: jobs.count, queueWaitMs: queueWait,
                                   durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
                job.continuation.resume(throwing: error)
            }
        }
        draining = false
    }
    private func stopAppMotion() async throws {
        let axes = appAxes.subtracting(held)
        guard !axes.isEmpty else { return }
        _ = try await enqueue(stopRequest(for: axes), origin: .stop)
    }
    private func stopRequest(for axes: Set<String>) -> HTTPRequest {
        var parameters = Dictionary(uniqueKeysWithValues: axes.map { ($0 == "focus" ? "focus.action" : $0, "stop") })
        if let cameraSession { parameters["s"] = cameraSession }
        return makeRequest("control.cgi", parameters: parameters)
    }
    private func updateAppAxes(_ request: HTTPRequest, acknowledged: Bool) {
        guard let parameters = try? request.parameters else { return }
        for axis in ["pan", "tilt", "zoom", "focus"] {
            if let value = parameters[axis == "focus" ? "focus.action" : axis] {
                if ["stop", "one_shot"].contains(value) {
                    if acknowledged { appAxes.remove(axis) }
                } else {
                    appAxes.insert(axis)
                }
            }
        }
        if appAxes.isEmpty { held.remove("unresolvedAppMotion") }
    }
    private func makeRequest(_ endpoint: String, parameters: [String: String], method: String = "GET") -> HTTPRequest {
        var components = URLComponents()
        components.queryItems = parameters.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return HTTPRequest(method: method, target: "/-wvhttp-01-/" + endpoint + (method == "GET" && !query.isEmpty ? "?" + query : ""),
                           headers: ["content-type": "application/x-www-form-urlencoded"], body: method == "POST" ? Data(query.utf8) : Data())
    }
    private func fields(_ reply: HTTPResponse) -> [String: String] {
        BridgeCameraReply(status: reply.status, headers: reply.headers, body: String(decoding: reply.body, as: UTF8.self)).fields
    }
    private func observe(_ reply: HTTPResponse, request: HTTPRequest) {
        if reply.headers["livescope-status"] == "501", let usedSession = (try? request.parameters)?["s"],
           cameraSession == usedSession {
            cameraSession = nil
            health = "unavailable"
            if authorized { revoke("camera_session_expired") }
        }
        guard reply.status == 200, reply.headers["livescope-status"] == "0" else { return }
        health = "ready"
        let values = fields(reply), parameters = try? request.parameters
        if request.path.hasSuffix("claim.cgi"), controlGranted(reply) { cameraSession = parameters?["s"] }
        if request.path.hasSuffix("close.cgi"), parameters?["s"] == cameraSession { cameraSession = nil }
        if request.path.hasSuffix("info.cgi") {
            if ["idle", "prepared"].contains(values["t.status"] ?? "") { held.remove("tracePlayback") }
            if ["c.1.pan.status", "c.1.tilt.status", "c.1.zoom.status"].allSatisfy({ values[$0] == "0" }) { held.remove("position") }
            if recovering, recoveryAxes.isEmpty,
               ["idle", "prepared"].contains(values["t.status"] ?? ""),
               ["c.1.pan.status", "c.1.tilt.status", "c.1.zoom.status"].allSatisfy({ values[$0] == "0" }) {
                recovering = false; held.remove("recovery")
                diagnostics.record("recovery_releases_confirmed", generation: generation, origin: "controller")
            }
        }
    }
    private func rememberPhysicalSession(_ reply: HTTPResponse, request: HTTPRequest) {
        guard reply.status == 200, reply.headers["livescope-status"] == "0",
              !request.path.hasSuffix("close.cgi"), !request.path.hasSuffix("yield.cgi"),
              let session = (try? request.parameters)?["s"] else { return }
        cameraSession = session
    }
    private func updateHeld(_ request: HTTPRequest, releasing: Bool = true) {
        guard let input = try? request.parameters else { return }
        let parameters = Dictionary(input.map { ($0.key.hasPrefix("c.1.") ? String($0.key.dropFirst(4)) : $0.key, $0.value) }, uniquingKeysWith: { _, new in new })
        if request.path.hasSuffix("control.cgi") {
            for axis in ["pan", "tilt", "zoom"] {
                if let action = parameters[axis] {
                    if action == "stop" { if releasing { held.remove(axis); recoveryAxes.remove(axis) } }
                    else if Int(action) != nil { held.insert("position") }
                    else { held.insert(axis) }
                }
            }
            if let focus = parameters["focus.action"] {
                if ["near", "far"].contains(focus) { held.insert("focus") }
                else if releasing {
                    if !recovering || focus == "stop" { held.remove("focus") }
                    if focus == "stop" { recoveryAxes.remove("focus") }
                }
            }
            if parameters["p"] != nil { held.insert("position") }
        }
        if request.path.hasSuffix("trace/set") {
            if parameters["cmd"] == "start" { held.insert("traceRecord") }
            else if releasing && ["stop", "cancel"].contains(parameters["cmd"] ?? "") { held.remove("traceRecord") }
        }
        if request.path.hasSuffix("trace/control") {
            if parameters["cmd"] == "stop" { if releasing { held.remove("tracePlayback") } }
            else { held.insert("tracePlayback") }
        }
    }
    private func failure(_ error: Error, origin: String) -> HTTPResponse {
        let failure: BridgeFailure
        if let known = error as? BridgeFailure { failure = known }
        else if let http = error as? HTTPError { failure = BridgeFailure(http.message, status: http.status) }
        else { failure = BridgeFailure("Camera connection failed; command was not replayed", status: 502) }
        diagnostics.record("request_failed", generation: generation, origin: origin, status: failure.status)
        return .json(failure, status: failure.status)
    }
}
