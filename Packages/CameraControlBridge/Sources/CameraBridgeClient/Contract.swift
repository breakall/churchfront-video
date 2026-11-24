import Foundation
import CryptoKit

public struct BridgeLease: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var connection: String
    public var generation: UInt64
    public init(connection: String, generation: UInt64) {
        self.connection = connection; self.generation = generation
    }
}

public struct BridgeStatus: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var generation: UInt64
    public var authorized: Bool
    public var heldAxes: [String]
    public var health: String
    public var manualTakeover: Bool
    public var nativeTrackingSupported: Bool = false
    public var diagnosticsEnabled: Bool
    public var droppedDiagnosticEvents: Int
    public var connection: String?
    public var configurationID: String = ""
    public var helperBuild: String = ""
    public var recoveryRequired: Bool = false
    public init(generation: UInt64, authorized: Bool, heldAxes: [String], health: String,
                manualTakeover: Bool, diagnosticsEnabled: Bool, droppedDiagnosticEvents: Int = 0,
                connection: String? = nil, configurationID: String = "", helperBuild: String = "", recoveryRequired: Bool = false) {
        self.generation = generation; self.authorized = authorized; self.heldAxes = heldAxes
        self.health = health; self.manualTakeover = manualTakeover
        self.diagnosticsEnabled = diagnosticsEnabled; self.droppedDiagnosticEvents = droppedDiagnosticEvents
        self.connection = connection
        self.configurationID = configurationID; self.helperBuild = helperBuild
        self.recoveryRequired = recoveryRequired
    }
}

public struct BridgeCommand: Codable, Sendable {
    public var version: Int = 1
    public var connection: String
    public var generation: UInt64
    public var purpose: String
    public var endpoint: String
    public var method: String
    public var parameters: [String: String]
    public init(lease: BridgeLease, purpose: String, parameters: [String: String],
                endpoint: String = "control.cgi", method: String = "GET") {
        connection = lease.connection; generation = lease.generation
        self.purpose = purpose; self.parameters = parameters; self.endpoint = endpoint; self.method = method
    }
}

public struct BridgeCameraReply: Codable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: String
    public init(status: Int, headers: [String: String], body: String) {
        self.status = status; self.headers = headers; self.body = body
    }
    public var livescopeStatus: String? { headers["livescope-status"] }
    public var fields: [String: String] {
        var values = [String: String]()
        for line in body.split(whereSeparator: \.isNewline) {
            for separator in [":=", "=="] {
                if let range = line.range(of: separator) {
                    values[String(line[..<range.lowerBound])] = String(line[range.upperBound...]); break
                }
            }
        }
        return values
    }
}

public struct BridgeFailure: Codable, Error, LocalizedError, Sendable {
    public var error: String
    public var status: Int
    public init(_ error: String, status: Int) { self.error = error; self.status = status }
    public var errorDescription: String? { error }
}

public struct BridgeConfiguration: Codable, Sendable, Equatable {
    public var cameraURL: String
    public var listenHost: String
    public var controllerPort: UInt16
    public var appPort: UInt16
    public var controllerAddress: String
    public var tokenFile: String
    public var readyFile: String?
    public var diagnosticsFile: String?
    public var diagnosticsEnabled: Bool
    public var requestTimeout: Double
    public var leaseTimeout: Double
    public var identity: String {
        let fields: [String: Any] = ["version": 1, "cameraURL": cameraURL, "listenHost": listenHost,
            "controllerPort": controllerPort, "appPort": appPort, "controllerAddress": controllerAddress,
            "requestTimeout": requestTimeout, "leaseTimeout": leaseTimeout]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public init(cameraURL: String, listenHost: String = "127.0.0.1", controllerPort: UInt16 = 18080,
                appPort: UInt16 = 18082, controllerAddress: String = "127.0.0.1", tokenFile: String,
                readyFile: String? = nil, diagnosticsFile: String? = nil, diagnosticsEnabled: Bool = true,
                requestTimeout: Double = 2, leaseTimeout: Double = 3) {
        self.cameraURL = cameraURL; self.listenHost = listenHost; self.controllerPort = controllerPort
        self.appPort = appPort; self.controllerAddress = controllerAddress; self.tokenFile = tokenFile
        self.readyFile = readyFile; self.diagnosticsFile = diagnosticsFile; self.diagnosticsEnabled = diagnosticsEnabled
        self.requestTimeout = requestTimeout; self.leaseTimeout = leaseTimeout
    }
}
