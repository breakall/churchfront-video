import Foundation

/// Authenticated local helper interface. Camera routing and ownership stay in the helper.
public actor BridgeClient {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL; self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func connect() async throws -> BridgeLease {
        try await request("connect", body: ["version": 1])
    }
    public func start(_ lease: BridgeLease) async throws -> BridgeLease { try await request("start", value: lease) }
    public func stop(_ lease: BridgeLease) async throws -> BridgeLease { try await request("stop", value: lease) }
    public func disconnect(_ lease: BridgeLease) async throws -> BridgeStatus { try await request("disconnect", value: lease) }
    public func heartbeat(_ lease: BridgeLease, trackingActive: Bool? = nil) async throws -> BridgeStatus {
        struct Heartbeat: Encodable {
            let version: Int
            let connection: String
            let generation: UInt64
            let trackingActive: Bool?
        }
        return try await request("heartbeat", value: Heartbeat(version: lease.version, connection: lease.connection,
                                                               generation: lease.generation, trackingActive: trackingActive))
    }
    public func status() async throws -> BridgeStatus { try await request("status", body: nil) }
    public func send(_ command: BridgeCommand) async throws -> BridgeCameraReply { try await request("command", value: command) }

    private func request<T: Decodable, V: Encodable>(_ action: String, value: V) async throws -> T {
        try await perform(action, data: JSONEncoder().encode(value))
    }
    private func request<T: Decodable>(_ action: String, body: [String: Int]?) async throws -> T {
        try await perform(action, data: body.map { try JSONEncoder().encode($0) })
    }
    private func perform<T: Decodable>(_ action: String, data: Data?) async throws -> T {
        guard baseURL.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(baseURL.host ?? "") else {
            throw BridgeFailure("Helper address must be loopback HTTP", status: 400)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("bridge/" + action))
        request.httpMethod = data == nil ? "GET" : "POST"
        request.httpBody = data
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, payload.count <= 2_097_152 else {
            throw BridgeFailure("Invalid helper response", status: 502)
        }
        guard http.statusCode == 200 else {
            throw (try? JSONDecoder().decode(BridgeFailure.self, from: payload))
                ?? BridgeFailure("Helper refused request", status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: payload)
    }
}
