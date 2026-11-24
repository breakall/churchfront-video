import Foundation
import Network

struct HTTPRequest: Sendable {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data
    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
    var parameters: [String: String] {
        get throws {
            var values = [String: String]()
            let query = target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            guard let form = String(data: body, encoding: .utf8) else { throw HTTPError(400, "Invalid form encoding") }
            for text in [query, form] where !text.isEmpty {
                for part in text.split(separator: "&", omittingEmptySubsequences: false) {
                    let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let first = pair.first, !first.isEmpty,
                          let key = String(first).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                          let value = (pair.count == 2 ? String(pair[1]) : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                          values[key] == nil else { throw HTTPError(400, "Ambiguous form parameters") }
                    values[key] = value
                }
            }
            return values
        }
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json"],
                     body: (try? JSONEncoder().encode(value)) ?? Data())
    }
    func wire() -> Data {
        var data = Data("HTTP/1.1 \(status) Response\r\n".utf8)
        let excluded = Set(["connection", "content-length", "transfer-encoding", "keep-alive", "proxy-connection", "trailer"])
        for (key, value) in headers where !excluded.contains(key.lowercased()) && !value.contains("\r") && !value.contains("\n") {
            data.append(Data("\(key): \(value)\r\n".utf8))
        }
        data.append(Data("Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)); data.append(body)
        return data
    }
}

struct HTTPError: Error {
    var status: Int; var message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

final class HTTPListener: @unchecked Sendable {
    private final class StartState: @unchecked Sendable { var completed = false }
    private final class Deadline: @unchecked Sendable {
        private let timer: DispatchSourceTimer
        init(queue: DispatchQueue, action: @escaping @Sendable () -> Void) {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 10)
            timer.setEventHandler(handler: action)
            timer.resume()
        }
        func cancel() { timer.cancel() }
    }
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "camera-bridge.listener")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    var handler: (@Sendable (HTTPRequest) async -> HTTPResponse)?
    var streamHandler: (@Sendable (HTTPRequest, NWConnection) async -> Void)?
    func start(host: String, port: UInt16, allowedSource: String) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let startState = StartState() // All listener callbacks are confined to queue.
            listener.stateUpdateHandler = { state in
                if !startState.completed, case .ready = state {
                    startState.completed = true; listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                } else if !startState.completed, case .failed(let error) = state {
                    startState.completed = true; listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                let source: String
                if case .hostPort(let host, _) = connection.endpoint { source = "\(host)" } else { source = "" }
                guard source == allowedSource || (allowedSource == "127.0.0.1" && source == "::ffff:127.0.0.1"),
                      self.connections.count < 64 else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                self.connections[id] = connection
                connection.start(queue: self.queue)
                let deadline = Deadline(queue: self.queue) { [weak self] in connection.cancel(); self?.connections.removeValue(forKey: id) }
                self.receive(connection, buffer: Data()) { [weak self] request in
                    Task {
                        let response: HTTPResponse
                        do {
                            let request = try request.get()
                            if request.path == "/-wvhttp-01-/info.cgi", let stream = self?.streamHandler {
                                deadline.cancel()
                                await stream(request, connection)
                                connection.cancel()
                                self?.queue.async { [weak self] in self?.connections.removeValue(forKey: id) }
                                return
                            }
                            response = await self?.handler?(request) ?? HTTPResponse(status: 503)
                        }
                        catch let error as HTTPError { response = .json(["error": error.message], status: error.status) }
                        catch { response = HTTPResponse(status: 400) }
                        connection.send(content: response.wire(), completion: .contentProcessed { _ in
                            deadline.cancel(); connection.cancel()
                            self?.queue.async { [weak self] in self?.connections.removeValue(forKey: id) }
                        })
                    }
                }
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, buffer: Data,
                         completion: @escaping (Result<HTTPRequest, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            var buffer = buffer; if let data { buffer.append(data) }
            do {
                if let request = try Self.parse(buffer) { completion(.success(request)); return }
                if done || error != nil { completion(.failure(HTTPError(400, "Incomplete request"))); return }
                self?.receive(connection, buffer: buffer, completion: completion)
            } catch { completion(.failure(error)) }
        }
    }
    static func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 131072 else { throw HTTPError(413, "Request too large") }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { throw HTTPError(431, "Headers too large") }; return nil
        }
        guard end.lowerBound <= 16384, let header = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw HTTPError(400, "Invalid headers") }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "POST"].contains(String(first[0])), first[1].hasPrefix("/"),
              !first[1].hasPrefix("//"), ["HTTP/1.1", "HTTP/1.0"].contains(String(first[2])) else { throw HTTPError(400, "Invalid request line") }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw HTTPError(400, "Invalid header") }
            let key = parts[0].lowercased()
            guard headers[key] == nil else { throw HTTPError(400, "Duplicate header") }
            headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw HTTPError(400, "Unsupported request framing") }
        guard let length = Int(headers["content-length"] ?? "0"), 0...65536 ~= length else { throw HTTPError(413, "Invalid body size") }
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        guard body.count == length else { throw HTTPError(400, "Pipelining not supported") }
        return HTTPRequest(method: String(first[0]), target: String(first[1]), headers: headers, body: Data(body))
    }
    func stop() { queue.async { [self] in listener?.cancel(); connections.values.forEach { $0.cancel() }; connections.removeAll() } }
}
