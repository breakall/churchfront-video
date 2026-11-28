import XCTest
import CueATEM
import CameraBridgeClient
@testable import CameraBridgeCore
@testable import CueVideo

/// The fake button vocabulary lives here only. Both bridge listeners, the app
/// connection, status polling, and the Churchfront tracker are the real implementations.
final class CameraBridgeControllerTrackingTests: XCTestCase {
    private actor Camera {
        var requests = [HTTPRequest]()
        var delayNextInfo = false
        func delayInfo() { delayNextInfo = true }
        func reply(_ request: HTTPRequest) async -> HTTPResponse {
            requests.append(request)
            var body = ""
            switch request.path {
            case "/-wvhttp-01-/open.cgi": body = "s:=camera-session\r\n"
            case "/-wvhttp-01-/claim.cgi": body = "s.control:=enabled:5000\r\n"
            case "/-wvhttp-01-/info.cgi" where delayNextInfo:
                delayNextInfo = false
                try? await Task.sleep(for: .milliseconds(300))
            default: break
            }
            return ControllerSessionView.xc("0", body)
        }
    }

    private struct Rig {
        let camera = Camera()
        let upstream = HTTPListener(), controller = HTTPListener(), app = HTTPListener()
        let bridge: Bridge
        let physicalURL: URL, appURL: URL
        init(intercept: Bool) async throws {
            let recorder = camera
            upstream.handler = { await recorder.reply($0) }
            let port = try await upstream.start(host: "127.0.0.1", port: 0, allowedSource: "127.0.0.1")
            var config = BridgeConfiguration(cameraURL: "http://127.0.0.1:\(port)", tokenFile: "unused")
            config.nativeTrackingControl = intercept
            let helper = Bridge(configuration: config, token: "fixture", diagnostics: Diagnostics(enabled: false,
                path: nil, helperBuild: "test", configurationID: config.identity), helperBuild: "test", recovering: false,
                trackingPressMapping: { method, path, params in
                    guard method == "GET", path == "/-wvhttp-01-/control.cgi", let press = params["test.press"] else { return nil }
                    return ControllerTrackingPress(rawValue: press)
                })
            bridge = helper
            controller.handler = { await helper.physical($0) }
            app.handler = { await helper.app($0) }
            let controllerPort = try await controller.start(host: "127.0.0.1", port: 0, allowedSource: "127.0.0.1")
            let appPort = try await app.start(host: "127.0.0.1", port: 0, allowedSource: "127.0.0.1")
            physicalURL = URL(string: "http://127.0.0.1:\(controllerPort)/-wvhttp-01-/control.cgi")!
            appURL = URL(string: "http://127.0.0.1:\(appPort)")!
        }
        func send(_ query: String, expect code: String = "0", file: StaticString = #filePath, line: UInt = #line) async throws {
            let url = URL(string: physicalURL.absoluteString + "?" + query)!
            let (_, response) = try await URLSession.shared.data(from: url)
            let result = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "livescope-status")
            XCTAssertEqual(result?.components(separatedBy: " ").first, code, file: file, line: line)
        }
        func close() async {
            await bridge.shutdown()
            controller.stop(); app.stop(); upstream.stop()
        }
    }

    @MainActor private func waitFor(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for handoff", file: file, line: line); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor func testPressesControlRealTrackerAndNeverReachCamera() async throws {
        let rig = try await Rig(intercept: true)
        let runtime = CameraBridgeRuntime()
        let tracker = AutoTracker.shared
        var camera = PTZCamera()
        camera.proto = .canonXC; camera.host = "127.0.0.1"; camera.port = 1
        runtime.onTrackingRevoked = { tracker.stop($0, revoke: false) }
        defer { tracker.stop(camera.id, revoke: false) }
        let connection = CameraBridgeConnection(url: rig.appURL, token: "fixture")
        try await rig.send("test.press=start", expect: "408")
        try await runtime.attach(connection, to: camera)
        XCTAssertFalse(tracker.isTracking(camera.id))

        try await rig.send("test.press=start")
        try await waitFor { await rig.bridge.status().appTrackingActive == true }
        let first = try XCTUnwrap(tracker.sessions[camera.id]?.id)
        let firstGrant = await rig.bridge.status().generation
        try await rig.send("test.press=start")
        let repeatedGrant = await rig.bridge.status().generation
        XCTAssertEqual(firstGrant, repeatedGrant)
        XCTAssertEqual(tracker.sessions[camera.id]?.id, first)
        let client = BridgeClient(baseURL: rig.appURL, token: "fixture")
        let status = try await client.status()
        let lease = BridgeLease(connection: try XCTUnwrap(status.connection), generation: status.generation)
        _ = try await client.send(BridgeCommand(lease: lease, purpose: "tracking", parameters: ["pan": "left"]))
        try await rig.send("test.press=stop")
        try await waitFor { !tracker.isTracking(camera.id) }
        let writes = await rig.camera.requests.filter { $0.path.hasSuffix("control.cgi") }
        XCTAssertEqual(try writes.map { try $0.parameters["pan"] }, ["left", "stop"])
        try await rig.send("test.press=stop")

        // Stop must win even when it overtakes a Start's camera readiness check.
        await rig.camera.delayInfo()
        async let interrupted: Void = rig.send("test.press=start", expect: "408")
        try await waitFor { await !rig.camera.delayNextInfo }
        try await rig.send("test.press=stop")
        try await interrupted
        XCTAssertFalse(tracker.isTracking(camera.id))

        try await rig.send("test.press=start")
        try await waitFor { tracker.isTracking(camera.id) }
        try await rig.send("pan=right")
        try await waitFor { !tracker.isTracking(camera.id) }
        try await rig.send("test.press=start", expect: "408")
        try await rig.send("pan=stop")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(tracker.isTracking(camera.id))
        try await rig.send("test.press=start")
        try await waitFor { await rig.bridge.status().appTrackingActive == true }
        let reframed = try XCTUnwrap(tracker.sessions[camera.id]?.id)
        XCTAssertNotEqual(reframed, first)
        func person(_ x: Double) -> TrackedPerson {
            let box = CGRect(x: x - 0.05, y: 0.25, width: 0.1, height: 0.5)
            return TrackedPerson(box: box, core: box, eye: CGPoint(x: x, y: 0.33))
        }
        tracker.finishFrame([person(0.15), person(0.5)], camera: camera.id, session: reframed)
        XCTAssertEqual(tracker.sessions[camera.id]?.target?.eye.x, 0.5)
        try await rig.send("test.press=stop")
        try await waitFor { !tracker.isTracking(camera.id) }
        await connection.disconnect()
        try await rig.send("test.press=start", expect: "408")
        let requests = await rig.camera.requests
        XCTAssertFalse(try requests.contains { try $0.parameters["test.press"] != nil })
        await rig.close()
    }

    func testDisabledMappingForwardsBothPressesToCamera() async throws {
        let rig = try await Rig(intercept: false)
        try await rig.send("test.press=start")
        try await rig.send("test.press=stop")
        let requests = await rig.camera.requests
        XCTAssertEqual(try requests.compactMap { try $0.parameters["test.press"] }, ["start", "stop"])
        let status = await rig.bridge.status()
        XCTAssertFalse(status.authorized)
        XCTAssertNil(status.controllerTrackingPress)
        await rig.close()
    }
}
