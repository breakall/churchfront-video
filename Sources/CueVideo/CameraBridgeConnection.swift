import Foundation
import CameraBridgeClient

/// Captures a lease before async work; queued commands never inherit a newer lease.
final class CameraBridgeConnection: @unchecked Sendable {
    private struct Pending {
        let command: BridgeCommand
        let lease: BridgeLease
        let done: ((BridgeCameraReply?) -> Void)?
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
            guard active, currentLease == expected, next.connection == expected.connection,
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
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let expected = self.snapshot() else { return }
                do {
                    let status = try await self.client.status()
                    if self.observe(status, expected: expected), let lease = self.snapshot() {
                        _ = self.observe(try await self.client.heartbeat(lease), expected: lease)
                    }
                } catch {
                    if (error as? BridgeFailure)?.status != 409 {
                        self.fail(error.localizedDescription, expected: expected)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
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
        let enqueued = lock.withLock {
            guard active, let lease = currentLease else { return false }
            guard pending.count < 64 else { overflowLease = lease; return false }
            let command = BridgeCommand(lease: lease, purpose: purpose, parameters: parameters, endpoint: endpoint, method: method)
            pending.append(Pending(command: command, lease: lease, done: done))
            if !sending { sending = true; startSender = true }
            return true
        }
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
            return abandoned
        }
        pollTask?.cancel()
        abandoned.forEach { $0.done?(nil) }
    }

    func disconnect() async {
        invalidate()
        let lease = lock.withLock { let old = endedLease; endedLease = nil; return old }
        if let lease { _ = try? await client.disconnect(lease) }
    }
}
