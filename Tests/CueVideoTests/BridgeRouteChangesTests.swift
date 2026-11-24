import XCTest
import CueATEM
import CameraBridgeClient
@testable import CueVideo

final class BridgeRouteChangesTests: XCTestCase {
    @MainActor
    func testDiagnosticsOnlyApplyPersistsPreferenceWithoutInvalidatingAttachedRoute() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = CameraBridgeRuntime(helperDirectory: directory)
        defer { runtime.prepareToQuit() }
        var camera = PTZCamera()
        camera.proto = .canonXC
        camera.host = "127.0.0.1"
        var settings = CameraBridgeSettings()
        settings.enabled = true
        runtime.configure(settings, cameras: [camera])
        var revocations: [UUID] = []
        runtime.onTrackingRevoked = { revocations.append($0) }
        for enabled in [false, true] {
            settings.diagnosticsEnabled = enabled
            runtime.configure(settings, cameras: [camera])
            XCTAssertTrue(revocations.isEmpty)
            let written = try Data(contentsOf: directory.appendingPathComponent("helper.json"))
            XCTAssertEqual(try JSONDecoder().decode(BridgeConfiguration.self, from: written).diagnosticsEnabled, enabled)
        }
    }

    @MainActor
    func testInvalidAndNotYetObservedCanonCamerasUseOnlyTheBridge() {
        let runtime = CameraBridgeRuntime()
        // The synchronous routing decision must precede the async service lifecycle.
        // Cancel that lifecycle before yielding so the test never registers a service.
        defer { runtime.prepareToQuit() }
        let queue = DispatchQueue(label: "camera.route.test")
        var settings = CameraBridgeSettings()
        settings.enabled = true
        runtime.configure(settings, cameras: [])
        var first = PTZCamera()
        first.proto = .canonXC
        first.host = "127.0.0.1"
        var second = PTZCamera()
        second.proto = .canonXC
        second.host = "127.0.0.2"
        // The PTZ factory can run before the editor reports its new camera list.
        XCTAssertTrue(runtime.adapter(for: first, queue: queue) is CanonBridgeLink)
        runtime.configure(settings, cameras: [first, second])
        XCTAssertTrue(runtime.isManaged(second.id))
        XCTAssertTrue(runtime.adapter(for: second, queue: queue) is CanonBridgeLink)
        var denial: String?
        runtime.authorizeTracking(second.id) { denial = $0 }
        XCTAssertNotNil(denial)
        XCTAssertNil(runtime.currentConnection())
    }
}
