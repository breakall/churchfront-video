import XCTest
import Network
import CameraBridgeClient
import CueATEM
@testable import CueVideo

/// Scripted HTTP replies test the real app client without reproducing helper arbitration.
final class BridgeReplyFixture {
    let listener: NWListener
    let queue = DispatchQueue(label: "camera-bridge.reply-fixture")
    let handle: (String, [String: Any]) -> ([String: Any], Double)
    private var connections: [NWConnection] = []
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }

    init(handle: @escaping (String, [String: Any]) -> ([String: Any], Double)) throws {
        self.handle = handle
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.read(connection, buffered: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success else { throw CameraBridgeSetupError("Fixture did not start") }
    }

    private func read(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            var bytes = buffered; bytes.append(data)
            guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete { self.read(connection, buffered: bytes) }; return
            }
            let header = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            guard bytes.count >= separator.upperBound + length else { self.read(connection, buffered: bytes); return }
            let path = header.components(separatedBy: "\r\n")[0].split(separator: " ")[1]
            let action = String(path.split(separator: "/").last!)
            let body = bytes.subdata(in: separator.upperBound..<(separator.upperBound + length))
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let (response, delay) = self.handle(action, object)
            let payload = try! JSONSerialization.data(withJSONObject: response)
            let prefix = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
            self.queue.asyncAfter(deadline: .now() + delay) {
                connection.send(content: prefix + payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}

final class CameraBridgeAdapterTests: XCTestCase {
    private func lease(_ generation: Int) -> [String: Any] { ["version": 1, "connection": "app-test", "generation": generation] }
    private func status(_ generation: Int, authorized: Bool) -> [String: Any] {
        ["version": 1, "generation": generation, "connection": "app-test", "authorized": authorized,
         "heldAxes": [], "health": "ready", "manualTakeover": false, "nativeTrackingSupported": false,
         "diagnosticsEnabled": true, "droppedDiagnosticEvents": 0,
         "configurationID": "fixture-configuration", "helperBuild": "fixture-build", "recoveryRequired": false]
    }

    func testBridgeSettingsDefaultsAndSavedDiagnosticOptOut() throws {
        let defaults = try JSONDecoder().decode(CueConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(defaults.cameraBridge.enabled)
        XCTAssertFalse(defaults.cameraBridge.nativeTrackingControl)
        XCTAssertTrue(defaults.cameraBridge.diagnosticsEnabled)
        var edited = defaults
        edited.cameraBridge.diagnosticsEnabled = false
        XCTAssertFalse(try JSONDecoder().decode(CueConfig.self, from: JSONEncoder().encode(edited)).cameraBridge.diagnosticsEnabled)
    }

    func testBridgeSetupRejectsAmbiguousCameraConfigurationAndUnverifiedNativeMapping() throws {
        var settings = CameraBridgeSettings()
        var camera = PTZCamera(); camera.proto = .canonXC; camera.host = "127.0.0.1"
        XCTAssertEqual(try settings.camera(in: [camera]).id, camera.id)
        XCTAssertThrowsError(try settings.camera(in: []))
        XCTAssertThrowsError(try settings.camera(in: [camera, camera]))
        settings.nativeTrackingControl = true
        XCTAssertThrowsError(try settings.camera(in: [camera]))
    }

    func testAppCommandsPreserveFIFOOrderThroughTheActualHTTPClient() async throws {
        let lock = NSLock()
        var received: [Int] = []
        let fixture = try BridgeReplyFixture { action, body in
            switch action {
            case "connect", "disconnect", "stop": return (self.lease(0), 0)
            case "status", "heartbeat": return (self.status(0, authorized: false), 0)
            case "command":
                let parameters = body["parameters"] as! [String: String]
                lock.withLock { received.append(Int(parameters["sequence"]!)!) }
                return (["status": 200, "headers": ["livescope-status": "0"], "body": ""], 0.002)
            default: return ([:], 0)
            }
        }
        defer { fixture.stop() }
        let connection = CameraBridgeConnection(url: fixture.url, token: "fixture-token")
        try await connection.connect()
        let completed = expectation(description: "All commands returned")
        completed.expectedFulfillmentCount = 32
        for number in 0..<32 {
            connection.send(["sequence": String(number)], purpose: "manual") { _ in completed.fulfill() }
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(lock.withLock { received }, Array(0..<32))
        await connection.disconnect()
    }

    func testDelayedUnauthorizedPollCannotDisableANewerAuthorization() async throws {
        let lock = NSLock()
        var generation = 0
        var polls = 0
        var callbacks: [Bool] = []
        let stalePoll = expectation(description: "Old poll is waiting")
        let fixture = try BridgeReplyFixture { action, _ in
            switch action {
            case "connect": return (self.lease(0), 0)
            case "start": generation = 1; return (self.lease(1), 0)
            case "status":
                polls += 1
                if polls == 2 { stalePoll.fulfill(); return (self.status(0, authorized: false), 0.3) }
                return (self.status(generation, authorized: generation == 1), 0)
            case "heartbeat", "disconnect": return (self.status(generation, authorized: generation == 1), 0)
            default: return (self.lease(generation), 0)
            }
        }
        defer { fixture.stop() }
        let connection = CameraBridgeConnection(url: fixture.url, token: "fixture-token")
        connection.onStatus = { status in lock.withLock { callbacks.append(status.authorized) } }
        try await connection.connect()
        await fulfillment(of: [stalePoll], timeout: 3)
        let started = expectation(description: "New authorization succeeded")
        connection.authorize { why in XCTAssertNil(why); started.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        try await Task.sleep(for: .milliseconds(400))
        let values = lock.withLock { callbacks }
        XCTAssertEqual(values.first, false)
        XCTAssertTrue(values.dropFirst().allSatisfy { $0 })
        XCTAssertTrue(connection.commandFence?.hasSuffix(":1") == true)
        await connection.disconnect()
    }

    func testJoystickReframeWhileFollowingStartsOnTheNewCenteredPerson() throws {
        try verifyReframedTarget(afterLoss: false)
    }

    func testJoystickReframeAfterLosingPersonStartsOnTheNewCenteredPerson() throws {
        try verifyReframedTarget(afterLoss: true)
    }

    private func verifyReframedTarget(afterLoss: Bool) throws {
        let tracker = AutoTracker.shared
        let oldStart = tracker.authorizeStart, oldRevoke = tracker.revokeAuthorization
        var camera = PTZCamera()
        camera.proto = .canonXC
        camera.host = "127.0.0.1"
        camera.port = 1
        defer {
            tracker.stop(camera.id, revoke: false)
            tracker.authorizeStart = oldStart
            tracker.revokeAuthorization = oldRevoke
        }
        var joystickHeld = false
        tracker.authorizeStart = { _, done in done(joystickHeld ? "Manual control" : nil) }
        tracker.revokeAuthorization = nil
        func person(_ x: Double) -> TrackedPerson {
            let box = CGRect(x: x - 0.08, y: 0.25, width: 0.16, height: 0.55)
            return TrackedPerson(box: box, core: box, eye: CGPoint(x: x, y: 0.33))
        }
        let original = person(0.46)
        let now = Date()
        tracker.start(camera)
        let old = try XCTUnwrap(tracker.sessions[camera.id]?.id)
        tracker.finishFrame([original], camera: camera.id, session: old, at: now)
        XCTAssertEqual(tracker.sessions[camera.id]?.target?.eye, original.eye)
        if afterLoss {
            tracker.finishFrame([], camera: camera.id, session: old, at: now.addingTimeInterval(6))
            XCTAssertEqual(tracker.sessions[camera.id]?.phase, .lost)
        } else {
            XCTAssertEqual(tracker.sessions[camera.id]?.phase, .following)
        }

        joystickHeld = true
        tracker.stop(camera.id, revoke: false)
        tracker.start(camera)
        XCTAssertFalse(tracker.isTracking(camera.id))
        joystickHeld = false
        XCTAssertFalse(tracker.isTracking(camera.id))
        tracker.start(camera)
        let fresh = try XCTUnwrap(tracker.sessions[camera.id]?.id)
        XCTAssertNotEqual(old, fresh)
        // Vision completes a pre-takeover frame after the new Track press.
        tracker.finishFrame([original], camera: camera.id, session: old)
        XCTAssertEqual(tracker.sessions[camera.id]?.phase, .starting)
        XCTAssertNil(tracker.sessions[camera.id]?.target)

        let newCenter = person(0.52)
        tracker.finishFrame([person(0.12), newCenter], camera: camera.id, session: fresh)
        XCTAssertEqual(tracker.sessions[camera.id]?.target?.eye, newCenter.eye)
        XCTAssertEqual(tracker.sessions[camera.id]?.phase, .following)
    }

    func testTrackingStartWaitsForAuthorizationAndReportsRejection() {
        let tracker = AutoTracker.shared
        let oldStart = tracker.authorizeStart, oldRevoke = tracker.revokeAuthorization
        defer { tracker.stopAll(); tracker.authorizeStart = oldStart; tracker.revokeAuthorization = oldRevoke }
        tracker.stopAll()
        var camera = PTZCamera(); camera.proto = .sonyUDP
        var completion: ((String?) -> Void)?
        tracker.authorizeStart = { id, done in XCTAssertEqual(id, camera.id); completion = done }
        var error: String?
        tracker.start(camera) { error = $0 }
        XCTAssertNotNil(completion)
        XCTAssertFalse(tracker.isTracking(camera.id))
        completion?("Bridge rejected start")
        XCTAssertEqual(error, "Bridge rejected start")
        XCTAssertFalse(tracker.isTracking(camera.id))
    }

    func testStoppingPendingStartPreventsItsLateAuthorizationFromStartingTracking() {
        let tracker = AutoTracker.shared
        let oldStart = tracker.authorizeStart, oldRevoke = tracker.revokeAuthorization
        defer { tracker.stopAll(); tracker.authorizeStart = oldStart; tracker.revokeAuthorization = oldRevoke }
        tracker.stopAll()
        var camera = PTZCamera(); camera.proto = .sonyUDP
        var completion: ((String?) -> Void)?
        var revoked = 0
        tracker.authorizeStart = { _, done in completion = done }
        tracker.revokeAuthorization = { id in XCTAssertEqual(id, camera.id); revoked += 1 }
        tracker.start(camera)
        tracker.stop(camera.id)
        XCTAssertEqual(revoked, 1)
        completion?(nil)
        XCTAssertEqual(revoked, 2)
        XCTAssertFalse(tracker.isTracking(camera.id))
    }

    func testSupersedingPendingStartDoesNotRevokeTheNewRequest() {
        let tracker = AutoTracker.shared
        let oldStart = tracker.authorizeStart, oldRevoke = tracker.revokeAuthorization
        defer { tracker.stopAll(); tracker.authorizeStart = oldStart; tracker.revokeAuthorization = oldRevoke }
        tracker.stopAll()
        var camera = PTZCamera(); camera.proto = .sonyUDP
        var completions: [(String?) -> Void] = []
        var revoked = 0
        tracker.authorizeStart = { _, done in completions.append(done) }
        tracker.revokeAuthorization = { _ in revoked += 1 }
        tracker.start(camera)
        tracker.start(camera)
        completions[0](nil)
        XCTAssertEqual(revoked, 0)
        completions[1]("Bridge rejected start")
        XCTAssertFalse(tracker.isTracking(camera.id))
    }

    func testFailedExistingTrackingStartReleasesItsNewAuthorization() {
        let tracker = AutoTracker.shared
        let oldStart = tracker.authorizeStart, oldRevoke = tracker.revokeAuthorization
        defer { tracker.stopAll(); tracker.authorizeStart = oldStart; tracker.revokeAuthorization = oldRevoke }
        tracker.stopAll()
        var camera = PTZCamera(); camera.proto = .sonyUDP
        var revoked = 0
        tracker.authorizeStart = { _, done in done(nil) }
        tracker.revokeAuthorization = { _ in revoked += 1 }
        var error: String?
        tracker.start(camera) { error = $0 }
        XCTAssertNotNil(error)
        XCTAssertEqual(revoked, 1)
    }

    func testMismatchedRunningConfigurationIsRejectedBeforeOpeningAnAppLease() async throws {
        let lock = NSLock()
        var opened = false
        let fixture = try BridgeReplyFixture { action, _ in
            if action == "connect" { lock.withLock { opened = true } }
            return (self.status(0, authorized: false), 0)
        }
        defer { fixture.stop() }
        let connection = CameraBridgeConnection(url: fixture.url, token: "fixture-token", configurationID: "different-config")
        do { try await connection.connect(); XCTFail("Mismatched helper configuration was accepted") }
        catch { XCTAssertFalse(lock.withLock { opened }) }
    }

    func testInvalidationDiscardsQueuedCommandsBeforeAConnectionIsRebound() async throws {
        let lock = NSLock()
        var commands = 0
        let first = expectation(description: "First command is in flight")
        let fixture = try BridgeReplyFixture { action, _ in
            switch action {
            case "connect": return (self.lease(0), 0)
            case "command":
                lock.withLock { commands += 1 }
                first.fulfill()
                return (["status": 200, "headers": ["livescope-status": "0"], "body": ""], 0.2)
            default: return (self.status(0, authorized: false), 0)
            }
        }
        defer { fixture.stop() }
        let connection = CameraBridgeConnection(url: fixture.url, token: "fixture-token")
        try await connection.connect()
        let completed = expectation(description: "Both requests completed or discarded")
        completed.expectedFulfillmentCount = 2
        connection.send(["pan": "right"], purpose: "manual") { _ in completed.fulfill() }
        await fulfillment(of: [first], timeout: 3)
        connection.send(["pan": "stop"], purpose: "manual") { _ in completed.fulfill() }
        connection.invalidate()
        XCTAssertNil(connection.commandFence)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(lock.withLock { commands }, 1)
        await connection.disconnect()
    }

    func testAFullCommandQueueClosesAdmissionAndDisconnectsInsteadOfDroppingOnlyTheStop() async throws {
        let first = expectation(description: "First command is in flight")
        let disconnected = expectation(description: "Overflow ends helper lease")
        let fixture = try BridgeReplyFixture { action, _ in
            switch action {
            case "connect": return (self.lease(0), 0)
            case "command":
                first.fulfill()
                return (["status": 200, "headers": ["livescope-status": "0"], "body": ""], 0.3)
            case "disconnect": disconnected.fulfill(); return (self.status(1, authorized: false), 0)
            default: return (self.status(0, authorized: false), 0)
            }
        }
        defer { fixture.stop() }
        let connection = CameraBridgeConnection(url: fixture.url, token: "fixture-token")
        try await connection.connect()
        connection.send(["pan": "right"], purpose: "manual")
        await fulfillment(of: [first], timeout: 3)
        for number in 0..<65 { connection.send(["p": String(number + 1)], purpose: "manualMove") }
        XCTAssertNil(connection.commandFence)
        await fulfillment(of: [disconnected], timeout: 3)
    }

    func testCanonAdapterSeparatesTrackingSoftwareMovementAndSoftwareFocusZoom() async throws {
        let lock = NSLock()
        var purposes: [String] = []
        let forwarded = expectation(description: "Adapter commands reached helper interface")
        forwarded.expectedFulfillmentCount = 9
        let fixture = try BridgeReplyFixture { action, body in
            switch action {
            case "connect": return (self.lease(0), 0)
            case "command":
                lock.withLock { purposes.append(body["purpose"] as! String) }
                forwarded.fulfill()
                return (["status": 200, "headers": ["livescope-status": "0"], "body": ""], 0)
            default: return (self.status(0, authorized: false), 0)
            }
        }
        defer { fixture.stop() }
        let connection = CameraBridgeConnection(url: fixture.url, token: "fixture-token")
        try await connection.connect()
        var camera = PTZCamera()
        camera.proto = .canonXC; camera.host = "127.0.0.1"; camera.port = UInt16(fixture.url.port!)
        let queue = DispatchQueue(label: "camera-bridge.adapter-test")
        let link = CanonBridgeLink(camera: camera, connection: { connection }, queue: queue)
        queue.sync {
            link.start()
            link.trackDriveRaw(pan: 100, tilt: 0)
            link.trackZoom(0)
            link.drive(pan: 0.1, tilt: 0)
            link.home()
            link.recall(1)
            link.goTo(PTZPosition(pan: 0, tilt: 0, zoom: 4000))
            link.zoom(0.1)
            link.focusOnce()
            link.setExposure(PTZExposure(gain: 50))
        }
        await fulfillment(of: [forwarded], timeout: 3)
        XCTAssertEqual(lock.withLock { purposes }, ["tracking", "tracking", "manualMove", "manualMove", "manualMove", "manualMove", "manual", "manual", "manual"])
        queue.sync { link.stop() }
        await connection.disconnect()
    }

    func testDiagnosticExportIncludesBothRotatedJournalsAndCurrentSanitizedEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, decision) in [("diagnostics.jsonl.2", "oldest"), ("diagnostics.jsonl.1", "previous"), ("diagnostics.jsonl", "current")] {
            let event: [String: Any] = ["decision": decision, "parameters": ["pan": "right"], "generation": 4]
            var data = try JSONSerialization.data(withJSONObject: event)
            data.append(10)
            try data.write(to: directory.appendingPathComponent(name))
        }
        let events = CameraBridgeRuntime.diagnosticEvents(in: directory) as! [[String: Any]]
        XCTAssertEqual(events.compactMap { $0["decision"] as? String }, ["oldest", "previous", "current"])
        XCTAssertEqual(events.count, 3)
    }

    func testDiagnosticExportBoundsReadsFromAnOversizedJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var data = Data("{\"decision\":\"retained\"}\n".utf8)
        data.append(Data(repeating: 32, count: 2_097_152))
        data.append(Data("\n{\"decision\":\"beyond-cap\"}\n".utf8))
        try data.write(to: directory.appendingPathComponent("diagnostics.jsonl"))
        let events = CameraBridgeRuntime.diagnosticEvents(in: directory) as! [[String: Any]]
        XCTAssertEqual(events.compactMap { $0["decision"] as? String }, ["retained"])
    }
}
