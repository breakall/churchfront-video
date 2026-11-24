import Foundation
import CameraBridgeClient

/// Captures a lease before async work; queued commands never inherit a newer lease.
final class CameraBridgeConnection: @unchecked Sendable {
    private struct Pending {
        let command: BridgeCommand
        let lease: BridgeLease
        let done: ((BridgeCameraReply?) -> Void)?
        // A position, preset or mixed control is an ordering barrier. Only replace
        // continuous direction samples for exactly the same set of axes.
        let continuousAxes: Set<String>?
    }

    private static func continuousAxes(of command: BridgeCommand) -> Set<String>? {
        guard command.method == "GET", command.endpoint == "control.cgi" else { return nil }
        let parameters = command.parameters
        var axes = Set<String>()
        for (key, value) in parameters {
            switch key {
            case "pan" where ["left", "right", "stop"].contains(value),
                 "tilt" where ["up", "down", "stop"].contains(value),
                 "zoom" where ["tele", "wide", "stop"].contains(value):
                axes.insert(key)
            case "pan.speed", "tilt.speed", "zoom.speed":
                guard parameters[String(key.dropLast(6))] != nil else { return nil }
            default: return nil
            }
        }
        return axes.isEmpty ? nil : axes
    }
    private let client: BridgeClient
    private let expectedConfiguration: String?
    private let expectedBuild: String?
    private let lock = NSLock()
    private var currentLease: BridgeLease?
    private var authorized = false
    private var active = true
    private var pending: [Pending] = []
    private var sending = false
    private var endedLease: BridgeLease?
    private var pollTask: Task<Void, Never>?
    var onStatus: ((BridgeStatus) -> Void)?
    var onFailure: ((String, String) -> Void)?

    init(url: URL, token: String, configurationID: String? = nil, helperBuild: String? = nil) {
        client = BridgeClient(baseURL: url, token: token)
        expectedConfiguration = configurationID; expectedBuild = helperBuild
    }

    private func snapshot() -> BridgeLease? { lock.withLock { active ? currentLease : nil } }
    var commandFence: String? {
        snapshot().map { "\($0.connection):\($0.generation)" }
    }

    private func matches(_ lease: BridgeLease) -> Bool { snapshot() == lease }

    @discardableResult
    private func replace(_ next: BridgeLease, expected: BridgeLease) -> Bool {
        lock.withLock {
            guard active, currentLease == expected || currentLease == next, next.connection == expected.connection,
                  next.generation >= expected.generation else { return false }
            currentLease = next
            return true
        }
    }

    /// Ignore older replies, including their callbacks; helper restart/lease loss fails closed.
    @discardableResult
    private func observe(_ status: BridgeStatus, expected: BridgeLease) -> Bool {
        guard status.version == 1 else {
            fail("The helper interface version is unsupported.", expected: expected)
            return false
        }
        let accepted = lock.withLock {
            guard active, currentLease == expected else { return false }
            guard status.connection == expected.connection, status.generation >= expected.generation else { return false }
            currentLease = BridgeLease(connection: expected.connection, generation: status.generation)
            authorized = status.authorized
            return true
        }
        if accepted { onStatus?(status) }
        else if matches(expected), status.connection != expected.connection {
            fail("The bridge app connection ended. Start the bridge connection again.", expected: expected)
        }
        return accepted
    }

    private func fail(_ why: String, expected: BridgeLease) {
        guard matches(expected) else { return }
        onFailure?(why, "\(expected.connection):\(expected.generation)")
    }

    func connect() async throws {
        if expectedConfiguration != nil || expectedBuild != nil {
            let existing = try await client.status()
            guard existing.version == 1, expectedConfiguration.map({ $0 == existing.configurationID }) ?? true,
                  expectedBuild.map({ $0 == existing.helperBuild }) ?? true else {
                throw CameraBridgeSetupError("The running helper differs from this setup or application build. Restart the bridge to apply this setup.")
            }
        }
        let lease = try await client.connect()
        guard lease.version == 1 else { throw CameraBridgeSetupError("The helper interface version is unsupported.") }
        lock.withLock { if active { currentLease = lease } }
        let status = try await client.status()
        guard observe(status, expected: lease) else { throw CameraBridgeSetupError("The bridge connection changed while connecting.") }
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let expected = self.snapshot() else { return }
                var requestLease = expected
                do {
                    let status = try await self.client.status()
                    if self.observe(status, expected: expected), let lease = self.snapshot() {
                        requestLease = lease
                        _ = self.observe(try await self.client.heartbeat(lease), expected: lease)
                    }
                } catch {
                    if (error as? BridgeFailure)?.status != 409 {
                        // A newer lease can overtake a failed poll. Keep polling it.
                        self.fail(error.localizedDescription, expected: requestLease)
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        lock.withLock {
            if active { pollTask = poll } else { poll.cancel() }
        }
    }

    func authorize(_ done: @escaping (String?) -> Void) {
        guard let lease = snapshot() else { done("The bridge is not connected."); return }
        Task {
            do {
                let next = try await client.start(lease)
                guard next.version == 1 else { throw CameraBridgeSetupError("The helper interface version is unsupported.") }
                guard replace(next, expected: lease) else { done("The bridge connection changed before tracking could start."); return }
                let status = try await client.status()
                guard observe(status, expected: next), status.authorized, status.generation == next.generation else {
                    done("Manual control took over before tracking could start."); return
                }
                done(nil)
            } catch { done(error.localizedDescription) }
        }
    }

    func revoke() {
        let lease = lock.withLock { active && authorized ? currentLease : nil }
        guard let lease else { return }
        Task {
            do {
                let next = try await client.stop(lease)
                if replace(next, expected: lease) {
                    _ = observe(try await client.status(), expected: next)
                }
            } catch {
                // A stale stop is never retried with a newer generation.
                if (error as? BridgeFailure)?.status != 409 { fail(error.localizedDescription, expected: lease) }
            }
        }
    }

    func send(_ parameters: [String: String], purpose: String, endpoint: String = "control.cgi",
              method: String = "GET", done: ((BridgeCameraReply?) -> Void)? = nil) {
        var startSender = false
        var overflowLease: BridgeLease?
        var superseded: Pending?
        let enqueued = lock.withLock {
            guard active, let lease = currentLease else { return false }
            let command = BridgeCommand(lease: lease, purpose: purpose, parameters: parameters, endpoint: endpoint, method: method)
            let axes = Self.continuousAxes(of: command)
            if let axes {
                for index in pending.indices.reversed() {
                    let older = pending[index]
                    guard older.lease == lease, let oldAxes = older.continuousAxes else { break }
                    // Interleaved manual zoom and joystick commands use different purposes.
                    // Independent manual axes can coalesce across one another; a switch
                    // between automatic and manual operation must retain its order.
                    let samePurpose = older.command.purpose == purpose
                    let manualPurposes = ["manual", "manualMove"]
                    guard samePurpose || (manualPurposes.contains(purpose) &&
                                          manualPurposes.contains(older.command.purpose)) else { break }
                    if oldAxes == axes && samePurpose {
                        superseded = pending.remove(at: index)
                        break
                    }
                    if !oldAxes.isDisjoint(with: axes) { break }
                }
            }
            guard pending.count < 64 else { overflowLease = lease; return false }
            pending.append(Pending(command: command, lease: lease, done: done, continuousAxes: axes))
            if !sending { sending = true; startSender = true }
            return true
        }
        superseded?.done?(nil)
        guard enqueued else {
            done?(nil)
            if let lease = overflowLease {
                fail("The app command queue is full. Tracking was disconnected for safety.", expected: lease)
                invalidate()
                Task { await disconnect() }
            }
            return
        }
        if startSender { Task { await drain() } }
    }

    private func drain() async {
        while true {
            let next = lock.withLock { () -> Pending? in
                guard active, !pending.isEmpty else { sending = false; return nil }
                return pending.removeFirst()
            }
            guard let next else { return }
            guard matches(next.lease) else { next.done?(nil); continue }
            do {
                let reply = try await client.send(next.command)
                guard matches(next.lease) else { next.done?(nil); continue }
                if reply.status == 200, reply.livescopeStatus == "0" { next.done?(reply) }
                else {
                    fail("The camera rejected a bridge command (HTTP \(reply.status), camera \(reply.livescopeStatus ?? "unknown")).", expected: next.lease)
                    next.done?(nil)
                }
            } catch {
                if (error as? BridgeFailure)?.status != 409 { fail(error.localizedDescription, expected: next.lease) }
                next.done?(nil)
            }
        }
    }

    /// End local admission synchronously before a route can be rebound.
    func invalidate() {
        let abandoned = lock.withLock { () -> [Pending] in
            if active { endedLease = currentLease }
            let abandoned = pending
            active = false; authorized = false; currentLease = nil; pending.removeAll()
            pollTask?.cancel()
            pollTask = nil
            return abandoned
        }
        abandoned.forEach { $0.done?(nil) }
    }

    func disconnect() async {
        invalidate()
        let lease = lock.withLock { let old = endedLease; endedLease = nil; return old }
        if let lease { _ = try? await client.disconnect(lease) }
    }
}
