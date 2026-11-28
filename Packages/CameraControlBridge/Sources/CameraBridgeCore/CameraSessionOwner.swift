import CameraBridgeClient
import Foundation

struct CameraSessionLease: Equatable, Sendable {
    let id: String
    let epoch: UInt64
    let defaultOpen: CanonDefaultOpen?
}

extension HTTPRequest {
    static func canon(_ endpoint: String, parameters: [String: String], method: String = "GET") -> HTTPRequest {
        var components = URLComponents()
        components.queryItems = parameters.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return HTTPRequest(method: method, target: "/-wvhttp-01-/" + endpoint + (method == "GET" && !query.isEmpty ? "?" + query : ""),
                           headers: ["content-type": "application/x-www-form-urlencoded"], body: method == "POST" ? Data(query.utf8) : Data())
    }
}

extension HTTPResponse {
    var cameraControlLost: Bool {
        guard status == 200 else { return false }
        let code = headers["livescope-status"]?.split(whereSeparator: \.isWhitespace).first
        return code == "501" || code == "301"
    }

    var canonFields: [String: String] {
        BridgeCameraReply(status: status, headers: headers, body: String(decoding: body, as: UTF8.self)).fields
    }

    fileprivate var canonSucceeded: Bool {
        status == 200 && headers["livescope-status"]?.split(whereSeparator: \.isWhitespace).first == "0"
    }
}

/// Only this owner opens, renews or closes camera sessions. App and controller
/// lifetimes are independent of the single privilege held by the bridge.
actor CameraSessionOwner {
    private let send: @Sendable (HTTPRequest) async throws -> HTTPResponse
    private var active: CameraSessionLease?
    private var retired: CameraSessionLease?
    private var confirmRetirement = false
    private var opening: Task<OpenedSession, Error>?
    private var renewing: Task<Void, Error>?
    private var epoch: UInt64 = 0
    private var needsStop = false
    private var stopped = false
    private var nextClaim: TimeInterval = 0
    private var retryAfter: TimeInterval = 0

    private struct OpenedSession: Sendable {
        let lease: CameraSessionLease
        let renewAfter: TimeInterval
    }

    init(upstream: Upstream) {
        send = { try await upstream.send($0) }
    }

    // Used by session lifecycle tests to delay and fail individual camera replies.
    init(send: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.send = send
    }

    func acquire() async throws -> CameraSessionLease {
        guard !stopped else { throw BridgeFailure("Camera session owner stopped", status: 503) }
        if let active { return active }
        let attempt: Task<OpenedSession, Error>
        if let opening {
            attempt = opening
        } else {
            guard ProcessInfo.processInfo.systemUptime >= retryAfter else {
                throw BridgeFailure("Camera session reconnect pending", status: 503)
            }
            let previous = retired
            if !confirmRetirement { retired = nil }
            attempt = Task { [send, epoch, needsStop, confirmRetirement] in
                if let previous {
                    let close = try? await send(.canon("close.cgi", parameters: ["s": previous.id]))
                    if confirmRetirement, close?.canonSucceeded != true, close?.sessionExpired != true {
                        throw BridgeFailure("Previous camera session closure unconfirmed", status: 503)
                    }
                }
                let reply = try await send(.canon("open.cgi", parameters: ["s.priority": "0"]))
                guard reply.canonSucceeded, let id = reply.canonFields["s"], !id.isEmpty else {
                    throw BridgeFailure("Camera session open failed", status: 502)
                }
                do {
                    let claim = try await send(.canon("claim.cgi", parameters: ["s": id]))
                    let renewAfter = try Self.renewalInterval(claim)
                    if needsStop {
                        let stop = try await send(Self.stopRequest(id))
                        guard stop.canonSucceeded else { throw BridgeFailure("Camera recovery stop unconfirmed", status: 502) }
                    }
                    var descriptor = CanonDefaultOpen(reply.canonFields)
                    if descriptor != nil {
                        let request = HTTPRequest.canon("info.cgi", parameters: [
                            "s": id, "item": "c.1.pan.speed,c.1.tilt.speed", "timeout": "1"
                        ])
                        if let info = try? await send(request), info.canonSucceeded {
                            descriptor?.axisSpeeds = info.canonFields.filter { CanonDefaultOpen.axisSpeedKeys.contains($0.key) }
                        }
                    }
                    let lease = CameraSessionLease(id: id, epoch: epoch, defaultOpen: descriptor)
                    return OpenedSession(lease: lease, renewAfter: renewAfter)
                } catch {
                    _ = try? await send(.canon("close.cgi", parameters: ["s": id]))
                    throw error
                }
            }
            opening = attempt
        }
        let startedEpoch = epoch
        do {
            let result = try await attempt.value
            guard !stopped, epoch == startedEpoch else {
                throw BridgeFailure("Camera session changed during connection", status: 503)
            }
            if active == nil {
                active = result.lease
                retired = nil
                confirmRetirement = false
                needsStop = false
                nextClaim = ProcessInfo.processInfo.systemUptime + result.renewAfter
                opening = nil
            }
            return result.lease
        } catch {
            if startedEpoch == epoch, opening != nil {
                epoch &+= 1
                opening = nil
                retryAfter = ProcessInfo.processInfo.systemUptime + 1
            }
            throw error
        }
    }

    func requireConfirmedClosure(of lease: CameraSessionLease) {
        if active == lease { confirmRetirement = true }
    }

    /// Epoch comparison also fences delayed 501 responses from an older
    /// connection when the device has already returned a replacement ID.
    @discardableResult
    func invalidate(_ lease: CameraSessionLease) -> Bool {
        guard active == lease else { return false }
        active = nil
        retired = lease
        renewing = nil
        epoch &+= 1
        needsStop = true
        return true
    }

    func maintain(forceClaim: Bool = false) async throws -> CameraSessionLease {
        let previous = active
        let lease = try await acquire()
        guard lease == active else { throw BridgeFailure("Camera session changed", status: 503) }
        let claim: Task<Void, Error>
        if let renewing {
            claim = renewing
        } else {
            guard (forceClaim && previous == lease) || ProcessInfo.processInfo.systemUptime >= nextClaim else { return lease }
            claim = Task { try await self.renew(lease) }
            renewing = claim
        }
        try await claim.value
        guard lease == active else { throw BridgeFailure("Camera session changed", status: 503) }
        return lease
    }

    private func renew(_ lease: CameraSessionLease) async throws {
        guard lease == active else { throw BridgeFailure("Camera session changed", status: 503) }
        do {
            let response = try await send(.canon("claim.cgi", parameters: ["s": lease.id]))
            let interval = try Self.renewalInterval(response)
            guard lease == active else { throw BridgeFailure("Camera session changed", status: 503) }
            nextClaim = ProcessInfo.processInfo.systemUptime + interval
            renewing = nil
        } catch {
            invalidate(lease)
            throw error
        }
    }

    private static func renewalInterval(_ claim: HTTPResponse) throws -> TimeInterval {
        let privilege = claim.canonFields["s.control"]?.split(separator: ":", maxSplits: 1)
        guard claim.canonSucceeded, privilege?.first == "enabled" else {
            throw BridgeFailure("Camera control privilege unavailable", status: 503)
        }
        if let privilege, privilege.count == 2, let milliseconds = Double(privilege[1]), milliseconds > 0 {
            return min(3, max(0.25, milliseconds / 2000))
        }
        return 3
    }

    private static func stopRequest(_ id: String) -> HTTPRequest {
        .canon("control.cgi", parameters: [
            "s": id, "pan": "stop", "tilt": "stop", "zoom": "stop", "focus.action": "stop"
        ])
    }

    @discardableResult
    func shutdown() async -> Bool {
        guard !stopped else { return false }
        stopped = true
        epoch &+= 1
        let pending = opening
        let lastRenewal = renewing
        let closing = active ?? retired
        opening = nil; active = nil; retired = nil; renewing = nil
        _ = try? await lastRenewal?.value
        var stoppedAxes = !needsStop
        if let closing {
            let reply = try? await send(Self.stopRequest(closing.id))
            stoppedAxes = reply?.canonSucceeded == true
            _ = try? await send(.canon("close.cgi", parameters: ["s": closing.id]))
        }
        if let pending, let opened = try? await pending.value {
            _ = try? await send(.canon("close.cgi", parameters: ["s": opened.lease.id]))
            stoppedAxes = true
        }
        return stoppedAxes
    }
}
