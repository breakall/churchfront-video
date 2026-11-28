import Foundation
import XCTest
@testable import CameraBridgeCore

final class ControllerSessionTests: XCTestCase {
    func testBareHardwareOpenMatchesCanonBodyWithLocalIdentity() throws {
        let fields = ["s": "camera-secret", "s.origin": "192.0.2.20:80",
                      "s.authority.audio": "disabled", "s.authority.control": "enabled",
                      "s.authority.video": "enabled", "v": "jpg:1280x720:6:14980"]
        let camera = try XCTUnwrap(CanonDefaultOpen(fields))
        var sessions = ControllerSessions(host: "192.0.2.10", port: 18080)
        let request = HTTPRequest.canon("open.cgi", parameters: [:])
        let reply = try XCTUnwrap(try sessions.localReply(for: request, defaultOpen: camera))
        let body = String(decoding: reply.body, as: UTF8.self)
        let first = try XCTUnwrap(body.split(separator: "\n").first)
        XCTAssertTrue(first.hasPrefix("s:="))
        let id = String(first.dropFirst(3))
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotEqual(id, fields["s"])
        XCTAssertEqual(body, "s:=\(id)\ns.authority.audio:=disabled\ns.authority.control:=enabled\ns.authority.video:=enabled\ns.origin:=192.0.2.10:18080\ns.duration==0\ns.priority:=0\nv:=jpg:1280x720:6:14980\n")
        let claim = HTTPRequest.canon("claim.cgi", parameters: ["s": id])
        XCTAssertEqual(try sessions.localReply(for: claim)?.headers["livescope-status"], "0")
    }

    func testControllerReceivesItsSessionSpeedSettingsAndAcknowledgedUpdates() throws {
        let speed = "c.1.pan.speed.dir"
        let tilt = "c.1.tilt.speed.dir"
        var camera = try XCTUnwrap(CanonDefaultOpen([
            "s.authority.audio": "disabled", "s.authority.control": "enabled",
            "s.authority.video": "enabled", "v": "jpg:1280x720:6:14980"
        ]))
        camera.axisSpeeds = [speed: "10000", tilt: "10000"]
        var sessions = ControllerSessions(host: "127.0.0.1", port: 18080)
        let opened = try XCTUnwrap(try sessions.localReply(for: .canon("open.cgi", parameters: [:]), defaultOpen: camera))
        let id = try XCTUnwrap(opened.canonFields["s"])
        let info = HTTPRequest.canon("info.cgi", parameters: ["s": id, "item": "c,c.1.tilt!"])
        let snapshot = ControllerSessionView.xc("0", "c.1.pan.speed.max:=10000\n")
        let initial = try sessions.view(for: info).reply(snapshot)
        XCTAssertEqual(initial.canonFields[speed], "10000")
        XCTAssertFalse(initial.body.contains(13), "Canon LF status framing survives translation")
        sessions.observeControlReply([speed: "312", "unrelated": "ignored"], session: id)
        let fields = try sessions.view(for: info).reply(snapshot).canonFields
        XCTAssertEqual(fields[speed], "312")
        XCTAssertNil(fields[tilt])
        XCTAssertNil(fields["unrelated"])
        XCTAssertNil(try sessions.view(for: .canon("info.cgi", parameters: [:])).reply(snapshot).canonFields[speed])
    }

    private let scoped = ControllerSessionView(sessionID: "virtual-id", origin: "192.0.2.1:8080", control: "enabled",
                                              priority: 0, infoItems: "s,c.1", isInfo: true)

    func testRepeatedInfoItemsSurviveScopedTranslation() throws {
        let request = HTTPRequest(method: "POST", target: "/-wvhttp-01-/info.cgi?item=c&item=s&",
                                  headers: [:], body: Data("s=virtual-id&item=p".utf8))
        XCTAssertEqual(try request.parameters["item"], "c,s,p")
        let snapshot = try request.withCameraSession(nil)
        XCTAssertNil(try snapshot.parameters["s"])
        XCTAssertEqual(try snapshot.parameters["item"], "c,s,p")
        let translated = try request.withCameraSession("private+.id")
        XCTAssertEqual(try translated.parameters["s"], "private+.id")
        var duplicate = request
        duplicate.body.append(Data("&s=second".utf8))
        XCTAssertThrowsError(try duplicate.withCameraSession(nil))
    }

    func testChunkedMultipartStatusRewritesIdentityAndLengthsAcrossFragmentation() throws {
        let body = "s:=camera-id\r\ns.origin:=192.0.2.10:80\r\ns.control:=disabled\r\nc.1.focus:=auto\r\n"
        let part = "--frame\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let mime = part + "\r\n--frame--\r\n"
        let encoded = String(mime.utf8.count, radix: 16) + "\r\n" + mime + "\r\n0\r\n\r\n"
        var stream = ControllerInformationStream(view: scoped)
        var output = try stream.begin(Data(), status: 200, headers: ["transfer-encoding":"chunked",
                                      "content-type":"multipart/x-mixed-replace; boundary=frame", "livescope-status":"0"], done: false)
        for byte in encoded.utf8 { output.append(try stream.append(Data([byte]), done: false)) }
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertFalse(text.contains("camera-id"))
        XCTAssertFalse(text.contains("192.0.2.10:80"))
        XCTAssertTrue(text.contains("s:=virtual-id\r\n"))
        XCTAssertTrue(text.contains("s.control:=enabled\r\n"))
        XCTAssertTrue(text.contains("s.origin:=192.0.2.1:8080\r\n"))
        let framing = try XCTUnwrap(text.range(of: "--frame\r\n"))
        let partStart = try XCTUnwrap(text.range(of: "\r\n\r\n", range: framing.upperBound..<text.endIndex))
        let partEnd = try XCTUnwrap(text.range(of: "\r\n--frame--", range: partStart.upperBound..<text.endIndex))
        let translated = text[partStart.upperBound..<partEnd.lowerBound]
        XCTAssertTrue(text[framing.upperBound..<partStart.lowerBound].contains("Content-Length: \(translated.utf8.count)"))
        XCTAssertTrue(stream.finished)
    }
}
