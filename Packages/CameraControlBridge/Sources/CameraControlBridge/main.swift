import Foundation
import Darwin
import CameraBridgeCore
import CameraBridgeClient

@main
struct Main {
    static func main() async {
        do {
            let configuration = try parse(Array(CommandLine.arguments.dropFirst()))
            let service = try BridgeService(configuration: configuration)
            let urls = try await service.start()
            var ready: [String: Any] = urls
            ready["version"] = 1; ready["pid"] = ProcessInfo.processInfo.processIdentifier
            let data = try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
            if let path = configuration.readyFile {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            FileHandle.standardOutput.write(data + Data([10]))
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGPIPE, SIG_IGN)
            let stream = AsyncStream<Void> { continuation in
                let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
                let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
                terminate.setEventHandler { continuation.yield(()); continuation.finish() }
                interrupt.setEventHandler { continuation.yield(()); continuation.finish() }
                terminate.resume(); interrupt.resume()
                continuation.onTermination = { _ in terminate.cancel(); interrupt.cancel() }
            }
            for await _ in stream { break }
            service.stop()
        } catch {
            FileHandle.standardError.write(Data("camera-control-bridge: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func parse(_ arguments: [String]) throws -> BridgeConfiguration {
        if arguments == ["--config-user"] {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return try JSONDecoder().decode(BridgeConfiguration.self, from: Data(contentsOf: base.appendingPathComponent("CueVideo/CameraBridge/helper.json")))
        }
        if arguments.count == 2, arguments[0] == "--config" {
            return try JSONDecoder().decode(BridgeConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        }
        var options = [String: String](), enabled = true, index = 0
        let accepted = Set(["--camera-url", "--listen-host", "--controller-port", "--app-port", "--controller-address", "--token-file", "--ready-file", "--diagnostics-file", "--request-timeout", "--lease-timeout"])
        while index < arguments.count {
            let key = arguments[index]
            if key == "--no-diagnostics" { enabled = false; index += 1; continue }
            guard accepted.contains(key), index + 1 < arguments.count, options[key] == nil else { throw BridgeFailure("Invalid command-line arguments", status: 400) }
            options[key] = arguments[index + 1]; index += 2
        }
        guard let camera = options["--camera-url"], let token = options["--token-file"],
              let controllerPort = UInt16(options["--controller-port"] ?? "18080"),
              let appPort = UInt16(options["--app-port"] ?? "18082"),
              let timeout = Double(options["--request-timeout"] ?? "2"),
              let lease = Double(options["--lease-timeout"] ?? "3") else { throw BridgeFailure("Require --camera-url and --token-file with valid numeric options", status: 400) }
        return BridgeConfiguration(cameraURL: camera, listenHost: options["--listen-host"] ?? "127.0.0.1",
                                   controllerPort: controllerPort, appPort: appPort,
                                   controllerAddress: options["--controller-address"] ?? "127.0.0.1", tokenFile: token,
                                   readyFile: options["--ready-file"], diagnosticsFile: options["--diagnostics-file"],
                                   diagnosticsEnabled: enabled, requestTimeout: timeout, leaseTimeout: lease)
    }
}
