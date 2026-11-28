import Foundation
import CameraBridgeClient
import Network

actor Bridge {
    private let upstream: Upstream
    private let diagnostics: Diagnostics
    private let token: String
    private let leaseTimeout: Double
    private let configurationID: String
    private let trackingPressMapping: ControllerTrackingPress.Mapping?
    private let interceptTracking: Bool
    private var controllerPress: ControllerTrackingPress?
    private var appTrackingActive = false
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
    private var awaitingStartupFocusMode: Bool
    private var recoveryAxes = Set<String>()
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private let sessionOwner: CameraSessionOwner
    private var sessions: ControllerSessions
    private var currentLease: CameraSessionLease?
    private var uncertainPhysicalWrite: (lease: CameraSessionLease, claim: UInt64)?
    private var routeEpoch: UInt64 = 0
    private var routeLost = false
    private var lastMaintenance = -Double.infinity
    private var releaseClaims = [String: UInt64]()
    private var stopping = false
    private var appAxes = Set<String>()
    private var jobs = [Job]()
    private var draining = false
    private enum JobOrigin: String {
        case controller, tracking, manual, manualMove, stop, session, verify, read

        var movesAppAxes: Bool {
            switch self {
            case .tracking, .manual, .manualMove: return true
            case .controller, .stop, .session, .verify, .read: return false
            }
        }
    }

    private struct Job {
        var request: HTTPRequest
        var origin: JobOrigin
        var generation: UInt64
        var routeEpoch: UInt64
        var controllerClaim: UInt64?
        var connection: String?
        var requestID: String
        var enqueued: Double
        var neutralizeAppAxes: Bool
        var continuation: CheckedContinuation<HTTPResponse, Error>
    }

    init(configuration: BridgeConfiguration, token: String, diagnostics: Diagnostics, helperBuild: String, recovering: Bool,
         trackingPressMapping: ControllerTrackingPress.Mapping? = ControllerTrackingPress.rcIP100Mapping) {
        self.trackingPressMapping = trackingPressMapping
        interceptTracking = configuration.nativeTrackingControl == true
        upstream = Upstream(url: URL(string: configuration.cameraURL)!, timeout: configuration.requestTimeout)
        sessionOwner = CameraSessionOwner(upstream: upstream)
        sessions = ControllerSessions(host: configuration.listenHost, port: configuration.controllerPort)
        self.token = token; self.diagnostics = diagnostics; leaseTimeout = configuration.leaseTimeout
        configurationID = configuration.identity; self.helperBuild = helperBuild
        awaitingStartupFocusMode = recovering
        self.recovering = recovering
        if recovering {
            recoveryAxes = ["pan", "tilt", "zoom", "focus"]
            held = recoveryAxes.union(["recovery"])
            manualTakeover = true
        }
    }
    func bindController(port: UInt16) { sessions.port = port }

    func maintain() async {
        let now = ProcessInfo.processInfo.systemUptime
        guard !stopping, now - lastMaintenance >= 1 else { return }
        lastMaintenance = now
        _ = try? await enqueue(makeRequest("claim.cgi", parameters: [:]), origin: .session)
    }

    func shutdown() async {
        stopping = true
        routeEpoch &+= 1
        revoke("helper_stopping")
        // Wait for an admitted camera write before closing its session.
        while draining { try? await Task.sleep(for: .milliseconds(10)) }
        await sessionOwner.shutdown()
    }

    func status() -> BridgeStatus {
        var value = BridgeStatus(generation: generation, authorized: authorized, heldAxes: held.sorted(), health: health,
                     manualTakeover: manualTakeover, diagnosticsEnabled: diagnostics.enabled,
                     droppedDiagnosticEvents: diagnostics.dropped, connection: connection,
                     configurationID: configurationID, helperBuild: helperBuild, recoveryRequired: recovering)
        value.controllerTrackingPress = controllerPress
        value.nativeTrackingSupported = trackingPressMapping != nil
        value.appTrackingActive = authorized && appTrackingActive
        return value
    }
    private func revoke(_ decision: String, manual: Bool = false) {
        controllerPress = nil
        appTrackingActive = false
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
            if request.path == "/-wvhttp-01-/open.cgi", try request.parameters.isEmpty, currentLease == nil {
                // A controller may select this slot before the first maintenance tick.
                _ = try? await enqueue(makeRequest("claim.cgi", parameters: [:]), origin: .session)
            }
            if let reply = try sessions.localReply(for: request, defaultOpen: currentLease?.defaultOpen) {
                diagnostics.record("controller_session_reply", generation: generation, origin: "controller", endpoint: request.path,
                                   status: reply.status, livescope: reply.headers["livescope-status"])
                return reply
            }
            let view = try sessions.view(for: request)
            let parameters = try request.parameters
            if interceptTracking, let press = trackingPressMapping?(request.method, request.path, parameters) {
                if view.sessionID != nil, view.control != "enabled" { return ControllerSessionView.xc("301 No Control Privilege") }
                return await handleTrackingPress(press)
            }
            // Even firmware that omits the session ID must not carry a pending write
            // into a new owner’s claim. Capture the listener's ownership at admission.
            let claim = ControllerSessions.controlledEndpoints.contains(request.path) ? sessions.ownershipGeneration : nil
            let action = isPhysicalAction(request.path, parameters)
            if action {
                revoke("manual_takeover", manual: true)
                pendingPhysicalActions += 1
                rememberAxisIntent(parameters)
                if routeLost { updateHeld(request, releasing: false) }
            }
            defer { if action { pendingPhysicalActions -= 1 } }
            if request.path.hasSuffix("info.cgi") {
                let snapshot = try request.withCameraSession(nil)
                let discovery = (request.isDiscoverySnapshot || request.isControllerStatusPoll) && request.permitsDiscoveryReuse
                let reply = try await upstream.send(snapshot, preserveWire: discovery)
                observe(reply, request: snapshot)
                let translated = view.reply(reply)
                if discovery, reply.status == 200, reply.headers["connection"]?.lowercased() == "keep-alive",
                   reply.headers == translated.headers, reply.body == translated.body {
                    return reply
                }
                return translated
            }
            if routeLost { return view.reply(HTTPResponse(status: 200, headers: ["livescope-status": "408 Conflict"])) }
            let reply = try await enqueue(request, origin: .controller, controllerClaim: claim)
            return view.reply(reply)
        } catch {
            if !(error is BridgeFailure), (error as? HTTPError)?.status ?? 502 >= 500 {
                health = "unavailable"; revoke("camera_route_failed")
            }
            return failure(error, origin: "controller")
        }
    }
    func streamInformation(_ request: HTTPRequest, client: NWConnection) async {
        let view: ControllerSessionView
        let snapshot: HTTPRequest
        do {
            guard activeStreams < 16 else { throw HTTPError(503, "Stream limit") }
            if let reply = try sessions.localReply(for: request) {
                await sendInformation(reply, to: client)
                return
            }
            view = try sessions.view(for: request)
            snapshot = try request.withCameraSession(nil)
        } catch {
            let status = (error as? HTTPError)?.status ?? 400
            diagnostics.record("information_stream_rejected", generation: generation, origin: "controller", endpoint: request.path,
                               reason: status == 503 ? "stream_limit" : "invalid_form", details: DiagnosticDetails.request(request))
            await sendInformation(HTTPResponse(status: status), to: client)
            return
        }
        activeStreams += 1
        sessions.trackStream(client, for: view.sessionID)
        let epoch = generation
        let requestID = UUID().uuidString, began = ProcessInfo.processInfo.systemUptime
        let streamDiagnostics = diagnostics
        diagnostics.record("information_stream_opened", generation: generation, origin: "controller", endpoint: request.path, requestID: requestID)
        defer { activeStreams -= 1; sessions.untrackStream(client) }
        do {
            try await upstream.stream(snapshot, to: client, view: view, diagnostic: { event, status, livescope, details, reason in
                streamDiagnostics.record(event, generation: epoch, origin: "controller", endpoint: request.path, status: status,
                                   requestID: requestID, livescope: livescope,
                                   durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000, reason: reason, details: details)
            }) { [weak self] reply in
                await self?.observeStream(reply, request: snapshot, generation: epoch)
            }
            diagnostics.record("information_stream_closed", generation: generation, origin: "controller", endpoint: request.path,
                               requestID: requestID, durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
        } catch {
            health = "unavailable"; revoke("information_route_failed")
            diagnostics.record("information_stream_failed", generation: generation, origin: "controller", endpoint: request.path, status: 502,
                               requestID: requestID, durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            // Revoking authorization rejects the tracker's later stop as well as
            // its moves. Stop still-app-owned axes here, through the same fenced
            // writer, so a failed status stream cannot leave the last move running.
            // A subsequent physical takeover invalidates this queued cleanup.
            try? await stopAppMotion()
        }
    }
    private func sendInformation(_ reply: HTTPResponse, to client: NWConnection) async {
        await withCheckedContinuation { continuation in
            client.send(content: reply.wire(), completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private func observeStream(_ reply: HTTPResponse, request: HTTPRequest, generation epoch: UInt64) {
        guard generation == epoch else { return }
        observe(reply, request: request)
    }
    private func isPhysicalAction(_ path: String, _ parameters: [String: String]) -> Bool {
        if ["/-wvhttp-01-/preset/set", "/-wvhttp-01-/trace/set", "/-wvhttp-01-/trace/control"].contains(path) { return true }
        guard path == "/-wvhttp-01-/control.cgi" else { return false }
        let keys = parameters.keys.map { $0.hasPrefix("c.1.") ? String($0.dropFirst(4)) : $0 }
        return keys.contains { ["pan", "tilt", "zoom", "focus", "focus.action", "focus.value", "p"].contains($0) }
    }
    // A classified press terminates here, including rejections and app/route failures.
    private func handleTrackingPress(_ press: ControllerTrackingPress) async -> HTTPResponse {
        guard connection != nil, !stopping, ProcessInfo.processInfo.systemUptime - lastHeartbeat <= leaseTimeout else {
            return ControllerSessionView.xc("408 Conflict")
        }
        do {
            switch press {
            case .start:
                // A held axis at receipt cannot turn this press into a delayed restart.
                guard held.isDisjoint(with: ["pan", "tilt", "zoom", "focus"]) else {
                    return ControllerSessionView.xc("408 Conflict")
                }
                if !authorized { _ = try await authorizeTracking(controllerClaim: sessions.ownershipGeneration) }
            case .stop:
                revoke("controller_tracking_stopped")
                controllerPress = .stop
                try await stopAppMotion()
            }
            return ControllerSessionView.xc("0")
        } catch {
            return ControllerSessionView.xc("408 Conflict")
        }
    }

    private func authorizeTracking(controllerClaim: UInt64? = nil) async throws -> BridgeLease {
        guard pendingPhysicalActions == 0 else { throw BridgeFailure("Physical action is pending", status: 409) }
        guard let checkedConnection = connection else { throw BridgeFailure("App unavailable", status: 409) }
        let checkedGeneration = generation
        // Canon session-scoped info is a differential long poll. A sessionless
        // snapshot always returns the current axis and trace completion state.
        let inspection = makeRequest("info.cgi", parameters: [:])
        let snapshot = try await upstream.send(inspection)
        guard snapshot.status == 200, snapshot.headers["livescope-status"] == "0" else { throw BridgeFailure("Camera route is not ready", status: 409) }
        guard checkedConnection == connection, checkedGeneration == generation,
              controllerClaim == nil || controllerClaim == sessions.ownershipGeneration else {
            throw BridgeFailure("Start interrupted by takeover", status: 409)
        }
        observe(snapshot, request: inspection)
        guard pendingPhysicalActions == 0, held.isEmpty, health == "ready" else { throw BridgeFailure("Physical controls or camera route are not ready", status: 409) }
        if !authorized {
            _ = try await enqueue(makeRequest("claim.cgi", parameters: [:]), origin: .verify)
            guard checkedConnection == connection, checkedGeneration == generation, held.isEmpty, pendingPhysicalActions == 0,
                  controllerClaim == nil || controllerClaim == sessions.ownershipGeneration else { throw BridgeFailure("Start interrupted by takeover", status: 409) }
            controllerPress = controllerClaim == nil ? nil : .start
            appTrackingActive = false
            generation &+= 1; authorized = true; manualTakeover = false
            diagnostics.record("tracking_authorized", generation: generation, origin: "app")
        }
        return BridgeLease(connection: checkedConnection, generation: generation)
    }

    func app(_ request: HTTPRequest) async -> HTTPResponse {
        guard authenticated(request.headers["authorization"] ?? "") else {
            diagnostics.record("request_failed", generation: generation, origin: "app", endpoint: request.path, status: 401, reason: "unauthorized")
            return .json(BridgeFailure("Unauthorized helper client", status: 401), status: 401)
        }
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
            case "/bridge/heartbeat":
                if let active = object["trackingActive"] as? Bool { appTrackingActive = authorized && active }
                return .json(status())
            case "/bridge/disconnect":
                revoke("app_disconnected"); connection = nil; try await stopAppMotion(); return .json(status())
            case "/bridge/start":
                return .json(try await authorizeTracking())
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
                let parameters = command.parameters
                let cameraRequest = makeRequest(command.endpoint, parameters: parameters, method: command.method)
                let reply: HTTPResponse
                if read {
                    let epoch = generation
                    reply = try await upstream.send(cameraRequest)
                    if epoch == generation { observe(reply, request: cameraRequest) }
                }
                else {
                    let neutralize = origin == .manualMove && authorized
                    if origin == .manualMove { authorized = false; controllerPress = nil; appTrackingActive = false }
                    reply = try await enqueue(cameraRequest, origin: origin, neutralizeAppAxes: neutralize)
                }
                return .json(BridgeCameraReply(status: reply.status, headers: reply.headers, body: String(decoding: reply.body, as: UTF8.self)))
            default: throw BridgeFailure("Unknown helper operation", status: 404)
            }
        } catch { return failure(error, origin: "app", endpoint: request.path) }
    }
    private func authenticated(_ value: String) -> Bool {
        let expected = Array(("Bearer " + token).utf8), candidate = Array(value.utf8)
        guard expected.count == candidate.count else { return false }
        return zip(expected, candidate).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    // Camera recovery stops motion, but a controller still holding a joystick
    // retains priority. Only release axes whose latest physical input was stop.
    private func rememberAxisIntent(_ parameters: [String: String]) {
        for axis in ["pan", "tilt", "zoom", "focus"] {
            let key = axis == "focus" ? "focus.action" : axis
            guard let value = parameters[key] ?? parameters["c.1." + key] else { continue }
            if value == "stop" { releaseClaims[axis] = sessions.ownershipGeneration }
            else { releaseClaims.removeValue(forKey: axis) }
        }
    }

    private func lostRoute(duringInactiveStart: Bool = false) {
        guard !routeLost else { return }
        // Keep the operator's outstanding physical intent through camera recovery.
        // The queued writes themselves will be discarded when the route epoch changes.
        for job in jobs where job.origin == .controller &&
            (job.controllerClaim == nil || job.controllerClaim == sessions.ownershipGeneration) {
            updateHeld(job.request, releasing: false)
        }
        routeLost = true
        health = "unavailable"
        currentLease = nil
        routeEpoch &+= 1
        if duringInactiveStart && !authorized {
            // The explicit Start still verifies its connection, generation and physical holds.
            diagnostics.record("camera_session_expired", generation: generation, origin: "helper")
        } else {
            revoke("camera_session_expired")
        }
        lastMaintenance = -Double.infinity
    }

    private func accept(_ lease: CameraSessionLease) {
        if currentLease == nil, !routeLost {
            diagnostics.record("camera_session_ready", generation: generation, origin: "helper")
        }
        currentLease = lease
        if routeLost {
            appAxes.removeAll()
            held.remove("unresolvedAppMotion")
            let releasedAxes = releaseClaims.compactMap { axis, claim in
                claim == sessions.ownershipGeneration ? axis : nil
            }
            held.subtract(releasedAxes)
            recoveryAxes.subtract(releasedAxes)
            routeLost = false
            diagnostics.record("camera_session_recovered", generation: generation, origin: "helper")
        }
        health = "ready"
    }

    private func enqueue(_ request: HTTPRequest, origin: JobOrigin, neutralizeAppAxes: Bool = false,
                         controllerClaim: UInt64? = nil) async throws -> HTTPResponse {
        guard !stopping else { throw BridgeFailure("Helper is stopping", status: 503) }
        guard jobs.count < 128 else { throw BridgeFailure("Bridge command queue full", status: 503) }
        return try await withCheckedThrowingContinuation { continuation in
            let job = Job(request: request, origin: origin, generation: generation, routeEpoch: routeEpoch, controllerClaim: controllerClaim, connection: connection,
                          requestID: UUID().uuidString, enqueued: ProcessInfo.processInfo.systemUptime,
                          neutralizeAppAxes: neutralizeAppAxes, continuation: continuation)
            if origin == .session { jobs.insert(job, at: 0) }
            else if origin == .controller, let index = jobs.firstIndex(where: { $0.origin != .controller && $0.origin != .session }) { jobs.insert(job, at: index) }
            else { jobs.append(job) }
            diagnostics.record("enqueued", generation: generation, origin: origin.rawValue, endpoint: request.path,
                               requestID: job.requestID, parameters: (try? request.parameters) ?? [:], queueDepth: jobs.count)
            if !draining { draining = true; Task { await drain() } }
        }
    }
    private func obsolete(_ job: Job) -> Bool {
        stopping || job.routeEpoch != routeEpoch || (job.origin != .session && job.origin != .controller && (job.generation != generation || job.connection != connection ||
            (job.origin == .tracking && !authorized)))
    }

    // Called only by the serial camera writer. A controller axis already admitted
    // for takeover must never be stopped as part of cleaning up app movement.
    private func neutralizeAppMotion() async throws {
        let axes = appAxes.subtracting(held)
        guard !axes.isEmpty else { return }
        do {
            guard let lease = currentLease else { throw BridgeFailure("Camera session unavailable", status: 502) }
            let stopped = try await upstream.send(try stopRequest(for: axes).withCameraSession(lease.id))
            if stopped.cameraControlLost { _ = await sessionOwner.invalidate(lease); lostRoute() }
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

    // Only the serial writer may retire a camera session. A timeout can leave a
    // request executing on the camera even after its HTTP connection has closed.
    private func retireUncertainWriteAfterTakeover() async {
        guard let uncertain = uncertainPhysicalWrite,
              uncertain.claim != sessions.ownershipGeneration else { return }
        uncertainPhysicalWrite = nil
        guard currentLease == uncertain.lease else { return }
        lostRoute()
        _ = await sessionOwner.invalidate(uncertain.lease)
    }

    private func drain() async {
        while !jobs.isEmpty {
            await retireUncertainWriteAfterTakeover()
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
                if job.origin == .session || job.origin == .verify {
                    let lease: CameraSessionLease
                    do {
                        lease = try await sessionOwner.maintain(forceClaim: job.origin == .verify)
                    } catch {
                        guard job.origin == .verify, !authorized, !obsolete(job) else { throw error }
                        lostRoute(duringInactiveStart: true)
                        lease = try await sessionOwner.acquire()
                    }
                    accept(lease)
                    job.continuation.resume(returning: HTTPResponse(status: 200))
                    continue
                }
                let lease = try await sessionOwner.acquire()
                accept(lease)
                guard !obsolete(job) else {
                    job.continuation.resume(throwing: BridgeFailure("Superseded during session setup", status: 409))
                    continue
                }
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
                if job.origin == .controller, let denied = try sessions.localReply(for: job.request) {
                    job.continuation.resume(returning: denied)
                    continue
                }
                // The same local session can yield and reclaim while this write is queued.
                if let claim = job.controllerClaim, claim != sessions.ownershipGeneration {
                    job.continuation.resume(returning: ControllerSessionView.xc("301 No Control Privilege"))
                    continue
                }
                let translated = try job.request.withCameraSession(lease.id)
                // Pending physical actions already block app writes. Count the axes as
                // physically owned only once this command can actually reach the camera.
                if job.origin == .controller { updateHeld(job.request, releasing: false) }
                let reply: HTTPResponse
                do {
                    reply = try await upstream.send(translated)
                } catch {
                    if let claim = job.controllerClaim {
                        await sessionOwner.requireConfirmedClosure(of: lease)
                        uncertainPhysicalWrite = (lease, claim)
                        await retireUncertainWriteAfterTakeover()
                    }
                    throw error
                }
                if reply.sessionExpired || (reply.cameraControlLost && (job.origin != .controller || isPhysicalAction(job.request.path, (try? job.request.parameters) ?? [:]))) {
                    _ = await sessionOwner.invalidate(lease)
                    lostRoute()
                }
                observe(reply, request: translated)
                if job.origin == .controller, reply.status == 200, reply.headers["livescope-status"] == "0" {
                    // The camera may acknowledge an old owner's stop after a new controller
                    // session opens. It settled that camera write, but cannot release the
                    // operator interlock for the new claim. Holds were set before dispatch.
                    if job.controllerClaim == nil || job.controllerClaim == sessions.ownershipGeneration {
                        updateHeld(job.request)
                        if job.request.path == "/-wvhttp-01-/control.cgi" {
                            sessions.observeControlReply(reply.canonFields, session: try job.request.parameters["s"])
                        }
                    }
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
                                   durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                   details: DiagnosticDetails.response(reply, request: job.request, cameraHost: upstream.url.host))
                job.continuation.resume(returning: reply)
            } catch {
                if job.origin == .session || job.origin == .verify { lostRoute() }
                else { health = "unavailable"; revoke("camera_route_failed") }
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
        let parameters = Dictionary(uniqueKeysWithValues: axes.map { ($0 == "focus" ? "focus.action" : $0, "stop") })
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
        .canon(endpoint, parameters: parameters, method: method)
    }
    private func fields(_ reply: HTTPResponse) -> [String: String] {
        BridgeCameraReply(status: reply.status, headers: reply.headers, body: String(decoding: reply.body, as: UTF8.self)).fields
    }
    private func observe(_ reply: HTTPResponse, request: HTTPRequest) {
        guard reply.status == 200, reply.headers["livescope-status"] == "0" else { return }
        if !routeLost { health = "ready" }
        let values = fields(reply)
        if request.path.hasSuffix("info.cgi") {
            if ["idle", "prepared"].contains(values["t.status"] ?? "") { held.remove("tracePlayback") }
            if ["c.1.pan.status", "c.1.tilt.status", "c.1.zoom.status"].allSatisfy({ values[$0] == "0" }) { held.remove("position") }
            // Auto mode resolves only the unknown focus state inherited at startup.
            // A physical near/far command still requires its own acknowledged stop.
            if awaitingStartupFocusMode, pendingPhysicalActions == 0, values["c.1.focus"] == "auto" {
                recoveryAxes.remove("focus")
                held.remove("focus")
                awaitingStartupFocusMode = false
            }
            if recovering, recoveryAxes.isEmpty,
               ["idle", "prepared"].contains(values["t.status"] ?? ""),
               ["c.1.pan.status", "c.1.tilt.status", "c.1.zoom.status"].allSatisfy({ values[$0] == "0" }) {
                recovering = false; held.remove("recovery")
                diagnostics.record("recovery_releases_confirmed", generation: generation, origin: "controller")
            }
        }
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
                if ["near", "far"].contains(focus) {
                    awaitingStartupFocusMode = false
                    held.insert("focus")
                }
                else if releasing {
                    if !recovering || focus == "stop" { held.remove("focus") }
                    if focus == "stop" {
                        awaitingStartupFocusMode = false
                        recoveryAxes.remove("focus")
                    }
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
    private func failure(_ error: Error, origin: String, endpoint: String = "") -> HTTPResponse {
        let failure: BridgeFailure
        if let known = error as? BridgeFailure { failure = known }
        else if let http = error as? HTTPError { failure = BridgeFailure(http.message, status: http.status) }
        else { failure = BridgeFailure("Camera connection failed; command was not replayed", status: 502) }
        let reason: String
        switch failure.error {
        case "Stale app lease": reason = "stale_lease"
        case "Tracking is disabled": reason = "tracking_disabled"
        case "Physical action is pending": reason = "pending_physical"
        case "Physical controls or camera route are not ready", "Physical controller has priority":
            reason = recovering ? "recovery_required" : pendingPhysicalActions > 0 ? "pending_physical" : !held.isEmpty ? "held_controls" : health != "ready" ? "route_unready" : "manual_takeover"
        case "Unsupported helper protocol version": reason = "protocol_version"
        case "Camera route is not ready": reason = "route_unready"
        case "Start interrupted by takeover", "App connection superseded", "Stop lease superseded": reason = "superseded"
        default: reason = failure.status >= 500 ? "camera_unavailable" : "invalid_operation"
        }
        diagnostics.record("request_failed", generation: generation, origin: origin, endpoint: endpoint, status: failure.status,
                           reason: reason, details: DiagnosticDetails(recoveryRequired: recovering, pendingPhysical: pendingPhysicalActions > 0, heldControls: !held.isEmpty))
        return .json(failure, status: failure.status)
    }
}
