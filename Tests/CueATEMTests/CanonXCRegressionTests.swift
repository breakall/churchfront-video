import XCTest
import CueATEM

final class CanonXCRegressionTests: XCTestCase {
    func testJoystickReleaseAndSpeedLimitsMatchCanonWireValues() {
        XCTAssertEqual(CanonXC.movement(pan: -1, tilt: 0),
                       ["pan": "left", "pan.speed": "3010", "tilt": "stop"])
        XCTAssertEqual(CanonXC.rawMovement(pan: 1, tilt: -12000),
                       ["pan": "right", "pan.speed": "20", "tilt": "down", "tilt.speed": "10000"])
        XCTAssertEqual(CanonXC.rawMovement(pan: 0, tilt: 0), ["pan": "stop", "tilt": "stop"])
        XCTAssertEqual(CanonXC.zoomParameters(-0.5), ["zoom": "wide", "zoom.speed": "31"])
        XCTAssertEqual(CanonXC.zoomParameters(0), ["zoom": "stop"])
    }

    func testCameraSnapshotPreservesExposureOnlyPresetsAndWhiteBalance() {
        let fields = CanonXC.parse("""
        p.1.name.utf8:=Morning
        p.1.content.ptz==disabled
        p.2.name.utf8:=Old
        p.2.content==disabled
        c.1.wb:=kelvin
        c.1.wb.kelvin==4800
        c.1.me.gain:=12
        c.1.me.gain.list:=0,6,12
        c.1.me.shutter.mode:=auto
        """)
        let presets = CanonXC.presets(fields)
        XCTAssertEqual(presets.names, [1: "Morning"])
        XCTAssertEqual(presets.exposureOnly, [1])
        let exposure = CanonXC.exposure(fields)
        XCTAssertTrue(exposure.shutterAuto)
        XCTAssertEqual(exposure.gainList, [0, 6, 12])
        XCTAssertEqual(CanonXC.exposureParameters(exposure.value),
                       ["exp": "manual", "me.gain.mode": "manual", "me.gain": "12",
                        "wb": "kelvin", "wb.kelvin": "4800"])
        XCTAssertNil(CanonXC.position(fields))
    }
}
