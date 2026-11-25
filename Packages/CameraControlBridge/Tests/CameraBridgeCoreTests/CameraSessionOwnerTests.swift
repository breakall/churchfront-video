import XCTest
@testable import CameraBridgeCore

final class CameraSessionOwnerTests: XCTestCase {
    private actor Camera {
        var opens = 0
        var rejectNextStop = false
        var commands = [[String: String]]()
        var closed = [String]()
        var claims = 0
        var privilegeMilliseconds = 20000

        func useShortPrivilege() { privilegeMilliseconds = 500 }

        func rejectStop() { rejectNextStop = true }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            var body = ""
            var code = "0"
            let values = try request.parameters
            switch request.path {
            case "/-wvhttp-01-/open.cgi":
                opens += 1
                let id = "controller-independent-\(opens)"
                try await Task.sleep(nanoseconds: 20_000_000)
                body = "s:=\(id)\r\n"
            case "/-wvhttp-01-/claim.cgi":
                claims += 1
                body = "s.control:=enabled:\(privilegeMilliseconds)\r\n"
            case "/-wvhttp-01-/control.cgi":
                commands.append(values)
                if rejectNextStop {
                    rejectNextStop = false
                    code = "403 Invalid Parameter Value"
                }
            case "/-wvhttp-01-/close.cgi":
                if let id = values["s"] { closed.append(id) }
            default:
                XCTFail("Unexpected camera request")
            }
            return HTTPResponse(status: 200, headers: ["livescope-status": code], body: Data(body.utf8))
        }
    }

    func testConcurrentAcquireAndExpiryUseOneSessionAndOneConfirmedStop() async throws {
        let camera = Camera()
        let owner = CameraSessionOwner { try await camera.send($0) }
        async let first = owner.acquire()
        async let second = owner.maintain()
        let (original, concurrent) = try await (first, second)
        XCTAssertEqual(original, concurrent)
        let initialCommands = await camera.commands
        XCTAssertEqual(initialCommands, [])

        let invalidated = await owner.invalidate(original)
        XCTAssertTrue(invalidated)
        async let retry = owner.maintain()
        async let fresh = owner.acquire()
        let (replacement, same) = try await (retry, fresh)
        XCTAssertEqual(replacement, same)
        XCTAssertNotEqual(original.epoch, replacement.epoch)
        let staleInvalidation = await owner.invalidate(original)
        XCTAssertFalse(staleInvalidation)
        let commands = await camera.commands
        XCTAssertEqual(commands, [["s": replacement.id, "pan": "stop", "tilt": "stop", "zoom": "stop", "focus.action": "stop"]])
        let neutralShutdown = await owner.shutdown()
        XCTAssertTrue(neutralShutdown)
        let afterShutdown = await camera.commands
        XCTAssertEqual(afterShutdown.last, commands.first)
        let closed = await camera.closed
        XCTAssertEqual(closed, [original.id, replacement.id])
    }

    func testPeriodicMaintenanceRenewsShortPrivilegeWithoutOpeningAnotherSession() async throws {
        let camera = Camera()
        await camera.useShortPrivilege()
        let owner = CameraSessionOwner { try await camera.send($0) }
        let first = try await owner.maintain(forceClaim: true)
        _ = try await owner.maintain()
        let initialClaims = await camera.claims
        XCTAssertEqual(initialClaims, 1)
        try await Task.sleep(nanoseconds: 275_000_000)
        let renew = try await owner.maintain()
        XCTAssertEqual(renew, first)
        let claims = await camera.claims
        XCTAssertEqual(claims, 2)
        let explicitStart = try await owner.maintain(forceClaim: true)
        XCTAssertEqual(explicitStart, first)
        let forcedClaims = await camera.claims
        XCTAssertEqual(forcedClaims, 3)
        let opens = await camera.opens
        XCTAssertEqual(opens, 1)
        await owner.shutdown()
    }

    func testFailedRecoveryStopKeepsFenceUntilRetrySucceeds() async throws {
        let camera = Camera()
        let owner = CameraSessionOwner { try await camera.send($0) }
        let first = try await owner.acquire()
        await owner.invalidate(first)
        await camera.rejectStop()
        do {
            _ = try await owner.acquire()
            XCTFail("Rejected neutralization published a new camera session")
        } catch {}
        let closed = await camera.closed
        XCTAssertEqual(closed.count, 2)
        try await Task.sleep(nanoseconds: 1_050_000_000)
        let next = try await owner.acquire()
        let commands = await camera.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.last?["s"], next.id)
        XCTAssertEqual(commands.last?["focus.action"], "stop")
        await owner.shutdown()
    }
}
