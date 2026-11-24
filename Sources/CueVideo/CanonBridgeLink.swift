import Foundation
import CueATEM

/// The managed camera has no direct write/claim session, including while the helper is unavailable.
final class CanonBridgeLink: PTZLink {
    let camera: PTZCamera
    private let connection: () -> CameraBridgeConnection?
    private let queue: DispatchQueue
    private let reads: URLSession
    private var timer: DispatchSourceTimer?
    private var stopped = true
    private var lastInfo = Date.distantPast
    var onState: ((Bool) -> Void)?
    var onPresets: (([Int: String]) -> Void)?
    var onModel: ((String) -> Void)?
    var onExposurePresets: ((Set<Int>) -> Void)?
    var onExposure: ((CameraExposure) -> Void)?
    var onControl: ((Bool) -> Void)?

    init(camera: PTZCamera, connection: @escaping () -> CameraBridgeConnection?, queue: DispatchQueue) {
        self.camera = camera; self.connection = connection; self.queue = queue
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.httpMaximumConnectionsPerHost = 2
        reads = URLSession(configuration: configuration)
    }

    func start() {
        stopped = false
        readInfo()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.onControl?(self.connection() != nil)
            if Date().timeIntervalSince(self.lastInfo) > 60 { self.readInfo() }
        }
        timer.resume(); self.timer = timer
    }

    func stop() {
        stopped = true
        timer?.cancel(); timer = nil
        reads.invalidateAndCancel()
        onState?(false); onControl?(false)
    }

    private func issue(_ parameters: [String: String], tracking: Bool = false, manualMove: Bool = false, done: (() -> Void)? = nil) {
        guard !stopped else { return }
        connection()?.send(parameters, purpose: tracking ? "tracking" : manualMove ? "manualMove" : "manual") { [weak self] reply in
            guard reply != nil, let self else { return }
            self.queue.async { if !self.stopped { done?() } }
        }
    }

    private func movement(pan: Double, tilt: Double) -> [String: String] {
        func speed(_ value: Double) -> String { String(min(10000, Int(10 + value * value * 3000))) }
        var parameters = ["pan": pan == 0 ? "stop" : pan < 0 ? "left" : "right",
                          "tilt": tilt == 0 ? "stop" : tilt > 0 ? "up" : "down"]
        if pan != 0 { parameters["pan.speed"] = speed(pan) }
        if tilt != 0 { parameters["tilt.speed"] = speed(tilt) }
        return parameters
    }

    private func rawMovement(pan: Int, tilt: Int) -> [String: String] {
        var parameters = ["pan": pan == 0 ? "stop" : pan < 0 ? "left" : "right",
                          "tilt": tilt == 0 ? "stop" : tilt > 0 ? "up" : "down"]
        if pan != 0 { parameters["pan.speed"] = String(min(10000, max(20, abs(pan)))) }
        if tilt != 0 { parameters["tilt.speed"] = String(min(10000, max(20, abs(tilt)))) }
        return parameters
    }

    func drive(pan: Double, tilt: Double) { issue(movement(pan: pan, tilt: tilt), manualMove: true) }
    func driveRaw(pan: Int, tilt: Int) { issue(rawMovement(pan: pan, tilt: tilt), manualMove: true) }
    func trackDrive(pan: Double, tilt: Double) { issue(movement(pan: pan, tilt: tilt), tracking: true) }
    func trackDriveRaw(pan: Int, tilt: Int) { issue(rawMovement(pan: pan, tilt: tilt), tracking: true) }

    private func zoomParameters(_ value: Double) -> [String: String] {
        value == 0 ? ["zoom": "stop"] : ["zoom": value > 0 ? "tele" : "wide",
                                            "zoom.speed": String(min(127, Int(1 + abs(value) * 60)))]
    }
    func zoom(_ value: Double) { issue(zoomParameters(value)) }
    func trackZoom(_ value: Double) { issue(zoomParameters(value), tracking: true) }
    func autoFocus(_ on: Bool) { issue(["focus": on ? "auto" : "manual"]) }
    func focusOnce() { issue(["focus.action": "one_shot"]) }
    func home() { issue(["pan": "0", "tilt": "0"], manualMove: true) }
    func recall(_ number: Int) { issue(["p": String(number)], manualMove: true) }
    func store(_ number: Int) {} // Existing Canon app preset storage is unsupported.
    func goTo(_ position: PTZPosition) {
        issue(["pan": String(position.pan), "tilt": String(position.tilt), "zoom": String(position.zoom)], manualMove: true)
    }

    func deletePreset(_ number: Int, _ done: @escaping (String?) -> Void) {
        done("Deleting camera presets through the bridge is not available in this build. No direct camera claim was made.")
    }

    func readPosition(_ done: @escaping (PTZPosition?) -> Void) {
        read(item: "c.1.pan,c.1.tilt,c.1.zoom") { values in
            guard let pan = values["c.1.pan"].flatMap(Int.init), let tilt = values["c.1.tilt"].flatMap(Int.init),
                  let zoom = values["c.1.zoom"].flatMap(Int.init) else { done(nil); return }
            done(PTZPosition(pan: pan, tilt: tilt, zoom: zoom))
        }
    }

    private func readInfo() {
        lastInfo = Date()
        read { [weak self] values in
            guard let self else { return }
            self.onState?(!values.isEmpty)
            self.onControl?(self.connection() != nil)
            if let model = values["s.hardware"] { self.onModel?(model) }
            var presets: [Int: String] = [:]
            var exposureOnly = Set<Int>()
            for (key, value) in values where key.hasPrefix("p.") && key.hasSuffix(".name.utf8") && !value.isEmpty {
                guard let number = Int(key.dropFirst(2).dropLast(10)), values["p.\(number).content"] != "disabled" else { continue }
                presets[number] = value
                if values["p.\(number).content.ptz"] == "disabled" { exposureOnly.insert(number) }
            }
            self.onPresets?(presets); self.onExposurePresets?(exposureOnly)
            self.onExposure?(Self.exposure(values))
        }
    }

    private func read(item: String? = nil, done: @escaping ([String: String]) -> Void) {
        guard !stopped else { done([:]); return }
        var url = URLComponents()
        url.scheme = "http"; url.host = camera.host; url.port = Int(camera.port)
        url.path = "/-wvhttp-01-/info.cgi"
        if let item { url.queryItems = [URLQueryItem(name: "item", value: item)] }
        guard let address = url.url else { done([:]); return }
        reads.dataTask(with: address) { [weak self] data, response, _ in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            var fields: [String: String] = [:]
            if http?.statusCode == 200, http?.value(forHTTPHeaderField: "Livescope-Status")?.hasPrefix("0") != false,
               let data {
                for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                    if let range = line.range(of: ":=") ?? line.range(of: "==") {
                        fields[String(line[..<range.lowerBound])] = String(line[range.upperBound...])
                    }
                }
            }
            self.queue.async { if !self.stopped { done(fields) } }
        }.resume()
    }

    private static func exposure(_ fields: [String: String]) -> CameraExposure {
        func list(_ key: String) -> [Int] { (fields["c.1.\(key).list"] ?? "").split(separator: ",").compactMap { Int($0) } }
        var result = CameraExposure()
        result.value = PTZExposure(gain: fields["c.1.me.gain"].flatMap(Int.init),
            shutter: fields["c.1.me.shutter"].flatMap(Int.init), iris: fields["c.1.me.diaphragm"].flatMap(Int.init),
            wb: fields["c.1.wb"], kelvin: fields["c.1.wb.kelvin"].flatMap(Int.init))
        let automatic = fields["c.1.exp"] == "auto"
        result.gainAuto = automatic || fields["c.1.me.gain.mode"] == "auto"
        result.shutterAuto = automatic || fields["c.1.me.shutter.mode"] == "auto"
        result.irisAuto = automatic || fields["c.1.me.diaphragm.mode"] == "auto"
        result.gainList = list("me.gain"); result.shutterList = list("me.shutter")
        result.irisList = list("me.diaphragm"); result.kelvinList = list("wb.kelvin")
        return result
    }

    func readExposure() { read { [weak self] fields in self?.onExposure?(Self.exposure(fields)) } }
    func autoExposure() {} // Matches the existing Canon link's supported behavior.
    func setExposure(_ exposure: PTZExposure) {
        var values: [String: String] = exposure.hasExposure ? ["exp": "manual"] : [:]
        if let gain = exposure.gain { values["me.gain.mode"] = "manual"; values["me.gain"] = String(gain) }
        if let shutter = exposure.shutter { values["me.shutter.mode"] = "speed"; values["me.shutter"] = String(shutter) }
        if let iris = exposure.iris { values["me.diaphragm.mode"] = "manual"; values["me.diaphragm"] = String(iris) }
        if let kelvin = exposure.kelvin, exposure.wb == nil || exposure.wb == "kelvin" {
            values["wb"] = "kelvin"; values["wb.kelvin"] = String(kelvin)
        } else if let mode = exposure.wb { values["wb"] = mode }
        if !values.isEmpty {
            issue(values) { [weak self] in
                self?.queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.readExposure()
                }
            }
        }
    }
}
