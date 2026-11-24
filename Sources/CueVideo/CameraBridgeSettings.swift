import Foundation
import CueATEM

/// One bridge connection for the booth's single Canon camera.
struct CameraBridgeSettings: Codable, Equatable {
    var enabled = false
    var listenHost = "127.0.0.1"
    var controllerAddress = "127.0.0.1"
    var controllerPort: UInt16 = 18080
    var appPort: UInt16 = 18082
    var nativeTrackingControl = false
    var diagnosticsEnabled = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, listenHost, controllerAddress, controllerPort, appPort, nativeTrackingControl, diagnosticsEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        listenHost = try values.decodeIfPresent(String.self, forKey: .listenHost) ?? "127.0.0.1"
        controllerAddress = try values.decodeIfPresent(String.self, forKey: .controllerAddress) ?? "127.0.0.1"
        controllerPort = try values.decodeIfPresent(UInt16.self, forKey: .controllerPort) ?? 18080
        appPort = try values.decodeIfPresent(UInt16.self, forKey: .appPort) ?? 18082
        nativeTrackingControl = try values.decodeIfPresent(Bool.self, forKey: .nativeTrackingControl) ?? false
        diagnosticsEnabled = try values.decodeIfPresent(Bool.self, forKey: .diagnosticsEnabled) ?? true
    }

    func camera(in cameras: [PTZCamera]) throws -> PTZCamera {
        let canon = cameras.filter { $0.proto == .canonXC && !$0.host.isEmpty }
        guard canon.count == 1 else {
            throw CameraBridgeSetupError("Set up exactly one Canon HTTP camera before starting the bridge.")
        }
        guard !listenHost.isEmpty, !controllerAddress.isEmpty, controllerPort != 0, appPort != 0,
              controllerPort != appPort else {
            throw CameraBridgeSetupError("Enter the Mac listener address, RC-IP100 address, and two different nonzero ports.")
        }
        guard !nativeTrackingControl else {
            throw CameraBridgeSetupError("Native tracking interception needs controller verification and is not available in this build.")
        }
        return canon[0]
    }
}

struct CameraBridgeSetupError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
