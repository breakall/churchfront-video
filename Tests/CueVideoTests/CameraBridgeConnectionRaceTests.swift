import XCTest
@testable import CueVideo

final class CameraBridgeConnectionRaceTests: XCTestCase {
    private func lease(_ generation: Int) -> [String: Any] {
        ["version": 1, "connection": "test", "generation": generation]
    }

    private func status(_ generation: Int) -> [String: Any] {
        lease(generation).merging([
            "authorized": generation == 1, "heldAxes": [], "health": "ready", "manualTakeover": false,
            "nativeTrackingSupported": false, "diagnosticsEnabled": true, "droppedDiagnosticEvents": 0,
            "configurationID": "fixture", "helperBuild": "fixture", "recoveryRequired": false
        ]) { first, _ in first }
    }

    func testPollCanObserveAuthorizedGenerationBeforeStartReply() async throws {
        var generation = 0
        let pollSawStart = expectation(description: "Poll observed the start before its reply")
        var observed = false
        let fixture = try BridgeReplyFixture { action, _ in
            if action == "connect" { return (self.lease(0), 0) }
            if action == "start" {
                generation = 1
                return (self.lease(1), 0.5)
            }
            if action == "heartbeat", generation == 1, !observed {
                observed = true
                pollSawStart.fulfill()
            }
            return (self.status(generation), 0)
        }
        defer { fixture.stop() }
        let connection = CameraBridgeConnection(url: fixture.url, token: "fixture")
        try await connection.connect()
        let started = expectation(description: "Operator start succeeds")
        connection.authorize { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        await fulfillment(of: [pollSawStart, started], timeout: 3, enforceOrder: true)
        await connection.disconnect()
    }

    func testHeartbeatFailureAfterPollAdvancesGenerationReportsCurrentFence() async throws {
        var statusReads = 0
        let fixture = try BridgeReplyFixture { action, _ in
            if action == "connect" { return (self.lease(0), 0) }
            if action == "status" {
                statusReads += 1
                return (self.status(statusReads == 1 ? 0 : 1), 0)
            }
            if action == "heartbeat" { return ([:], 0) }  // Malformed reply for the newly observed lease.
            return (self.status(1), 0)
        }
        defer { fixture.stop() }
        let connection = CameraBridgeConnection(url: fixture.url, token: "fixture")
        let failure = expectation(description: "Runtime receives failure for active generation")
        connection.onFailure = { _, fence in
            XCTAssertEqual(fence, "test:1")
            failure.fulfill()
        }
        try await connection.connect()
        await fulfillment(of: [failure], timeout: 3)
        await connection.disconnect()
    }

    func testQueuedDirectionSamplesCoalescePerAxisButPreservePresetBarrierAndCallbacks() async throws {
        let first = expectation(description: "First command in flight")
        var received: [[String: String]] = []
        let fixture = try BridgeReplyFixture { action, body in
            if action == "connect" { return (self.lease(0), 0) }
            if action == "command" {
                received.append(body["parameters"] as! [String: String])
                if received.count == 1 { first.fulfill() }
                return (["status": 200, "headers": ["livescope-status": "0"], "body": ""], received.count == 1 ? 0.5 : 0)
            }
            return (self.status(0), 0)
        }
        defer { fixture.stop() }
        let connection = CameraBridgeConnection(url: fixture.url, token: "fixture")
        try await connection.connect()
        connection.send(["p": "1"], purpose: "manualMove")
        await fulfillment(of: [first], timeout: 3)
        let commands: [([String: String], String, Bool)] = [
            (["pan": "right", "tilt": "stop"], "manualMove", false),
            (["zoom": "wide"], "manual", true),
            (["pan": "left", "tilt": "stop"], "manualMove", true),
            (["p": "2"], "manualMove", true),
            (["pan": "right"], "manualMove", false),
            (["pan": "stop"], "manualMove", true),
            (["pan": "left"], "manual", true),
            (["pan": "right"], "tracking", true)
        ]
        let callbacks = expectation(description: "Every submitted command completes once")
        callbacks.expectedFulfillmentCount = commands.count
        for (parameters, purpose, forwarded) in commands {
            connection.send(parameters, purpose: purpose) { reply in
                XCTAssertEqual(reply != nil, forwarded)
                callbacks.fulfill()
            }
        }
        await fulfillment(of: [callbacks], timeout: 3)
        let actual = fixture.queue.sync { received }
        XCTAssertEqual(actual, [["p": "1"], ["zoom": "wide"], ["pan": "left", "tilt": "stop"],
                                ["p": "2"], ["pan": "stop"], ["pan": "left"], ["pan": "right"]])
        await connection.disconnect()
    }
}
