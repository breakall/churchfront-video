import XCTest
import CameraBridgeClient
import CameraBridgeCore

final class ConfigurationTests: XCTestCase {
    func testInvalidCameraRoutesAreRejectedBeforeNetworkStartup() {
        for route in ["", "file:///tmp/camera", "http://", "http://user:password@127.0.0.1", "http://127.0.0.1:0",
                      "http://127.0.0.1:65536", "http://127.0.0.1/path", "http://127.0.0.1?camera=elsewhere"] {
            XCTAssertThrowsError(try BridgeService(configuration: BridgeConfiguration(cameraURL: route, tokenFile: "/tmp/unused-token")), route)
        }
    }
    func testInvalidTimeoutsAndDuplicateListenersAreRejected() {
        for timeout in [Double.nan, Double.infinity, 0, 11] {
            XCTAssertThrowsError(try BridgeService(configuration: BridgeConfiguration(cameraURL: "http://127.0.0.1", tokenFile: "/tmp/unused-token", requestTimeout: timeout)))
        }
        XCTAssertThrowsError(try BridgeService(configuration: BridgeConfiguration(cameraURL: "http://127.0.0.1", controllerPort: 18080, appPort: 18080, tokenFile: "/tmp/unused-token")))
    }
    func testConfigurationIdentityTracksRoutingAndPolicyWithoutExportingPrivatePaths() {
        let original = BridgeConfiguration(cameraURL: "http://127.0.0.1:18081", tokenFile: "/private/token")
        var movedFiles = original
        movedFiles.tokenFile = "/different/token"; movedFiles.readyFile = "/different/ready"; movedFiles.diagnosticsFile = "/different/log"
        XCTAssertEqual(original.identity, movedFiles.identity)
        XCTAssertEqual(original.identity.count, 64)
        var newRoute = original; newRoute.cameraURL = "http://127.0.0.1:18083"
        XCTAssertNotEqual(original.identity, newRoute.identity)
        var interception = original
        interception.nativeTrackingControl = false
        XCTAssertEqual(interception.identity, original.identity)
        interception.nativeTrackingControl = true
        XCTAssertNotEqual(interception.identity, original.identity)
        if ControllerTrackingPress.rcIP100Mapping == nil {
            XCTAssertThrowsError(try BridgeService(configuration: interception))
        }
        var optOut = original; optOut.diagnosticsEnabled = false
        XCTAssertEqual(original.identity, optOut.identity, "Live diagnostic changes preserve the route identity")
    }
}
