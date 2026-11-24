import XCTest
import CueATEM

/// Only the new adapter seam is under test; no camera or tracking algorithm is reproduced.
final class BridgeAdapterRoutingTests: XCTestCase {
    private var savedCameraPreferences: Data?

    override func setUp() {
        savedCameraPreferences = UserDefaults.standard.data(forKey: "ptzCameras")
    }

    override func tearDown() {
        if let savedCameraPreferences {
            UserDefaults.standard.set(savedCameraPreferences, forKey: "ptzCameras")
        } else {
            UserDefaults.standard.removeObject(forKey: "ptzCameras")
        }
    }

    func testQueuedSoftwareStopDoesNotInheritANewBridgeGeneration() {
        let entered = expectation(description: "first manual call reached adapter")
        let drained = expectation(description: "queue drained")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var generation = "first"
        let link = RecordingBridgeLink()
        link.manual = { pan, _ in
            if pan == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
            } else {
                XCTFail("A queued stop inherited the new authorization")
            }
        }
        var camera = PTZCamera()
        camera.proto = .canonXC
        let ptz = PTZController(load: false, linkFactory: { _, _ in link })
        ptz.commandFence = { _ in lock.withLock { generation } }
        ptz.cameras = [camera]
        ptz.drive(x: 1, y: 0, camera: camera.id)
        wait(for: [entered], timeout: 2)
        ptz.stopDrive(camera: camera.id)
        link.tracking = { _, _ in XCTFail("A queued tracking move inherited the new authorization") }
        ptz.trackDriveRaw(pan: 500, tilt: 0, camera: camera.id)
        lock.withLock { generation = "after takeover and explicit restart" }
        link.zoomed = { drained.fulfill() }
        ptz.trackZoom(0, camera: camera.id)
        release.signal()
        wait(for: [drained], timeout: 2)
    }

    func testManagedCameraUsesItsAdapterAndPreservesTrackingPurpose() {
        let tracking = expectation(description: "tracking request reached adapter")
        let manual = expectation(description: "manual request reached adapter")
        let link = RecordingBridgeLink()
        link.tracking = { pan, tilt in
            XCTAssertEqual(pan, 120)
            XCTAssertEqual(tilt, -40)
            tracking.fulfill()
        }
        link.manual = { pan, tilt in
            XCTAssertEqual(pan, 1)
            XCTAssertEqual(tilt, 0)
            manual.fulfill()
        }
        var camera = PTZCamera()
        camera.proto = .canonXC
        camera.host = "invalid.example"
        let ptz = PTZController(load: false, linkFactory: { configured, _ in
            XCTAssertEqual(configured.id, camera.id)
            return link
        })
        ptz.cameras = [camera]
        ptz.trackDriveRaw(pan: 120, tilt: -40, camera: camera.id)
        ptz.drive(x: 1, y: 0, camera: camera.id)
        wait(for: [tracking, manual], timeout: 2)
    }
}

private final class RecordingBridgeLink: PTZLink {
    var onState: ((Bool) -> Void)?
    var onPresets: (([Int: String]) -> Void)?
    var onModel: ((String) -> Void)?
    var onExposurePresets: ((Set<Int>) -> Void)?
    var onExposure: ((CameraExposure) -> Void)?
    var onControl: ((Bool) -> Void)?
    var tracking: ((Int, Int) -> Void)?
    var manual: ((Double, Double) -> Void)?
    var zoomed: (() -> Void)?
    func start() { onState?(true) }
    func stop() { onState?(false) }
    func drive(pan: Double, tilt: Double) { manual?(pan, tilt) }
    func driveRaw(pan: Int, tilt: Int) { XCTFail("tracking lost its command purpose") }
    func trackDriveRaw(pan: Int, tilt: Int) { tracking?(pan, tilt) }
    func zoom(_ value: Double) { zoomed?() }
    func autoFocus(_ on: Bool) {}
    func focusOnce() {}
    func home() {}
    func recall(_ number: Int) {}
    func store(_ number: Int) {}
    func readPosition(_ done: @escaping (PTZPosition?) -> Void) { done(nil) }
    func goTo(_ position: PTZPosition) {}
    func deletePreset(_ number: Int, _ done: @escaping (String?) -> Void) { done("unsupported") }
    func readExposure() {}
    func setExposure(_ exposure: PTZExposure) {}
    func autoExposure() {}
}
