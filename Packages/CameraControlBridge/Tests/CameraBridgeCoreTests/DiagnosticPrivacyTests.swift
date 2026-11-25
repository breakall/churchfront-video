import XCTest
@testable import CameraBridgeCore

final class DiagnosticPrivacyTests: XCTestCase {
    func testUntrustedMetadataCannotEscapeCentralDiagnosticSanitization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("diagnostics.jsonl")
        let logger = Diagnostics(enabled: true, path: file.path, helperBuild: "test", configurationID: "test")
        let secret = "PRIVATE_SENTINEL_MUST_NOT_APPEAR"
        logger.record("request_failed", generation: 1, origin: "controller",
                      endpoint: "/private/\(secret)?password=\(secret)",
                      status: 401, parameters: ["s": secret, "password": secret,
                                                "authorization": secret, "name": secret,
                                                "pan": secret, "pan.speed": "100"],
                      livescope: "501 \(secret)", reason: secret,
                      details: DiagnosticDetails(method: secret, authScheme: secret,
                                                 sessionPresent: true, framing: secret,
                                                 contentLength: Int.max, contentType: secret,
                                                 controlState: secret, originRelation: secret,
                                                 firstByteMs: .infinity))
        let deadline = ContinuousClock.now + .seconds(2)
        var data = Data()
        while ContinuousClock.now < deadline {
            data = (try? Data(contentsOf: file)) ?? Data()
            if data.last == 10 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(data.isEmpty)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(event["schemaVersion"] as? Int, 2)
        XCTAssertEqual(event["livescope"] as? String, "501")
        XCTAssertEqual(event["endpoint"] as? String, "other")
        XCTAssertEqual(event["reason"] as? String, "other")
        XCTAssertEqual(event["parameters"] as? [String: String], ["pan.speed": "100"])
        let details = try XCTUnwrap(event["details"] as? [String: Any])
        XCTAssertEqual(details["sessionPresent"] as? Bool, true)
        XCTAssertLessThan(try XCTUnwrap(details["contentLength"] as? Int), Int.max)
        XCTAssertNil(details["firstByteMs"])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
