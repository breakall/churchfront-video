import Foundation

/// Canon XC command parameters and camera fields shared by direct and bridged control.
public enum CanonXC {
    /// Canon replies with "key:=value" lines ("key==value" while a value is changing).
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let l = String(line)
            if let r = l.range(of: ":=") ?? l.range(of: "==") { out[String(l[..<r.lowerBound])] = String(l[r.upperBound...]) }
        }
        return out
    }

    public static func movement(pan: Double, tilt: Double) -> [String: String] {
        func speed(_ value: Double) -> String { String(min(10000, Int(10 + value * value * 3000))) }
        var parameters = ["pan": pan == 0 ? "stop" : pan < 0 ? "left" : "right",
                          "tilt": tilt == 0 ? "stop" : tilt > 0 ? "up" : "down"]
        if pan != 0 { parameters["pan.speed"] = speed(pan) }
        if tilt != 0 { parameters["tilt.speed"] = speed(tilt) }
        return parameters
    }

    public static func rawMovement(pan: Int, tilt: Int) -> [String: String] {
        var parameters = ["pan": pan == 0 ? "stop" : pan < 0 ? "left" : "right",
                          "tilt": tilt == 0 ? "stop" : tilt > 0 ? "up" : "down"]
        if pan != 0 { parameters["pan.speed"] = String(min(10000, max(20, abs(pan)))) }
        if tilt != 0 { parameters["tilt.speed"] = String(min(10000, max(20, abs(tilt)))) }
        return parameters
    }

    public static func zoomParameters(_ value: Double) -> [String: String] {
        value == 0 ? ["zoom": "stop"] : ["zoom": value > 0 ? "tele" : "wide",
                                            "zoom.speed": String(min(127, Int(1 + abs(value) * 60)))]
    }
    public static func exposure(_ fields: [String: String]) -> CameraExposure {
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

    public static func exposureParameters(_ exposure: PTZExposure) -> [String: String] {
        var values: [String: String] = exposure.hasExposure ? ["exp": "manual"] : [:]
        if let gain = exposure.gain { values["me.gain.mode"] = "manual"; values["me.gain"] = String(gain) }
        if let shutter = exposure.shutter { values["me.shutter.mode"] = "speed"; values["me.shutter"] = String(shutter) }
        if let iris = exposure.iris { values["me.diaphragm.mode"] = "manual"; values["me.diaphragm"] = String(iris) }
        if let kelvin = exposure.kelvin, exposure.wb == nil || exposure.wb == "kelvin" {
            values["wb"] = "kelvin"; values["wb.kelvin"] = String(kelvin)
        } else if let mode = exposure.wb { values["wb"] = mode }
        return values
    }

    public static func presets(_ values: [String: String]) -> (names: [Int: String], exposureOnly: Set<Int>) {
        var presets: [Int: String] = [:]
        var exposureOnly = Set<Int>()
        for (key, value) in values where key.hasPrefix("p.") && key.hasSuffix(".name.utf8") && !value.isEmpty {
            guard let number = Int(key.dropFirst(2).dropLast(10)), values["p.\(number).content"] != "disabled" else { continue }
            presets[number] = value
            if values["p.\(number).content.ptz"] == "disabled" { exposureOnly.insert(number) }
        }
        return (presets, exposureOnly)
    }

    public static func position(_ values: [String: String]) -> PTZPosition? {
        guard let pan = values["c.1.pan"].flatMap(Int.init),
              let tilt = values["c.1.tilt"].flatMap(Int.init),
              let zoom = values["c.1.zoom"].flatMap(Int.init) else { return nil }
        return PTZPosition(pan: pan, tilt: tilt, zoom: zoom)
    }

    static func query(_ parameters: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
}
