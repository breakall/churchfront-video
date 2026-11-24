import XCTest
import CameraBridgeCore
import CameraBridgeClient

final class LiveDiagnosticsTests: XCTestCase {
    func testPersistedLoggingPreferenceUpdatesTheRunningHelperOnItsExistingLease() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("helper.json")
        let tokenFile = dir.appendingPathComponent("token")
        var config = BridgeConfiguration(cameraURL: "http://127.0.0.1:1", controllerPort: 0, appPort: 0,
                                         tokenFile: tokenFile.path, leaseTimeout: 10)
        try JSONEncoder().encode(config).write(to: file, options: .atomic)
        let service = try BridgeService(configuration: config)
        defer { service.stop() }
        let ready = try await service.start(configurationFile: file)
        let url = try XCTUnwrap(ready["app_url"].flatMap(URL.init(string:)))
        let app = BridgeClient(baseURL: url, token: try String(contentsOf: tokenFile, encoding: .utf8))
        let lease = try await app.connect()
        for desired in [false, true] {
            config.diagnosticsEnabled = desired
            try JSONEncoder().encode(config).write(to: file, options: .atomic)
            let deadline = ContinuousClock.now + .seconds(2)
            var status = try await app.status()
            while status.diagnosticsEnabled != desired, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                status = try await app.status()
            }
            XCTAssertEqual(status.diagnosticsEnabled, desired)
            XCTAssertEqual(status.connection, lease.connection)
            XCTAssertEqual(status.generation, lease.generation)
            XCTAssertEqual(status.configurationID, ready["configuration_id"])
        }
    }
}
