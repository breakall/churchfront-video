import Foundation
import Network

/// One request per connection, with no redirects, retries, credential store or cookie store.
final class Upstream: @unchecked Sendable {
    let url: URL
    let timeout: Double
    private let queue = DispatchQueue(label: "camera-bridge.upstream")
    init(url: URL, timeout: Double) { self.url = url; self.timeout = timeout }

    func wire(_ request: HTTPRequest, keepAlive: Bool = false) -> Data {
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let excluded = Set(["host", "connection", "content-length", "transfer-encoding", "keep-alive", "proxy-connection", "proxy-authorization", "upgrade", "te", "trailer"])
        let persistence = keepAlive ? "keep-alive" : "close"
        var wire = Data("\(request.method) \(request.target) HTTP/1.1\r\nHost: \(url.host!):\(port)\r\nConnection: \(persistence)\r\n".utf8)
        for (key, value) in request.headers where !excluded.contains(key) { wire.append(Data("\(key): \(value)\r\n".utf8)) }
        wire.append(Data("Content-Length: \(request.body.count)\r\n\r\n".utf8)); wire.append(request.body)
        return wire
    }

    func send(_ request: HTTPRequest, preserveWire: Bool = false) async throws -> HTTPResponse {
        let tls = url.scheme == "https"
        let host = url.host!
        let port = url.port ?? (tls ? 443 : 80)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: tls ? .tls : .tcp)
        let bytes = wire(request, keepAlive: preserveWire)
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let deadline = DispatchWorkItem {
                guard !finished else { return }; finished = true
                connection.stateUpdateHandler = nil; connection.cancel()
                continuation.resume(throwing: HTTPError(504, "Camera response timed out; command outcome may be unknown"))
            }
            func finish(_ result: Result<HTTPResponse, Error>) {
                guard !finished else { return }; finished = true; deadline.cancel()
                connection.stateUpdateHandler = nil; connection.cancel()
                continuation.resume(with: result)
            }
            func receive(_ buffer: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    var buffer = buffer; if let data { buffer.append(data) }
                    do {
                        if var reply = try Self.parse(buffer, complete: done) {
                            // Preserve validated fixed-length session replies used by Canon firmware.
                            // Other framing continues through the existing serializer.
                            if preserveWire, reply.headers["content-length"] != nil {
                                reply.originalWire = buffer
                            }
                            finish(.success(reply))
                            return
                        }
                        if let error { finish(.failure(error)); return }
                        if done { finish(.failure(HTTPError(502, "Incomplete camera response"))); return }
                        receive(buffer)
                    } catch { finish(.failure(error)) }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) } else { receive(Data()) }
                    })
                case .failed(let error): finish(.failure(error))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
            connection.start(queue: queue)
        }
    }

    static func parse(_ data: Data, complete: Bool) throws -> HTTPResponse? {
        guard data.count <= 2_097_152 else { throw HTTPError(502, "Camera response exceeds bounded buffer") }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 32768 || complete { throw HTTPError(502, "Malformed camera response") }; return nil
        }
        guard let text = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw HTTPError(502, "Invalid camera headers") }
        let lines = text.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]),
              200...599 ~= status else { throw HTTPError(502, "Invalid camera status") }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw HTTPError(502, "Invalid camera header") }
            let key = pair[0].lowercased(), value = pair[1].trimmingCharacters(in: .whitespaces)
            if headers[key] != nil && ["content-length", "transfer-encoding"].contains(key) { throw HTTPError(502, "Ambiguous camera framing") }
            headers[key] = value
        }
        let body = Data(data[split.upperBound...])
        if let encoding = headers["transfer-encoding"] {
            guard encoding.lowercased() == "chunked", headers["content-length"] == nil else { throw HTTPError(502, "Unsupported camera framing") }
            guard let decoded = try chunks(body) else { return nil }
            return HTTPResponse(status: status, headers: headers, body: decoded)
        }
        if let field = headers["content-length"] {
            guard let length = Int(field), 0...2_097_152 ~= length else { throw HTTPError(502, "Invalid camera length") }
            guard body.count >= length else { return nil }
            guard body.count == length else { throw HTTPError(502, "Unexpected camera response data") }
        } else if !complete && status != 204 && status != 304 { return nil }
        return HTTPResponse(status: status, headers: headers, body: body)
    }
    private static func chunks(_ data: Data) throws -> Data? {
        var index = data.startIndex, result = Data()
        let newline = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let line = data.range(of: newline, in: index..<data.endIndex),
                  let text = String(data: data[index..<line.lowerBound], encoding: .ascii),
                  let number = text.split(separator: ";", maxSplits: 1).first,
                  let size = Int(number, radix: 16), size >= 0 else { return nil }
            index = line.upperBound
            if size == 0 {
                guard data.count - index >= 2 else { return nil }
                return result
            }
            guard size <= 2_097_152 else { throw HTTPError(502, "Chunk exceeds bounded buffer") }
            guard data.count - index >= size + 2 else { return nil }
            result.append(data[index..<index + size]); index += size
            guard data[index..<index+2] == newline else { throw HTTPError(502, "Invalid chunk framing") }; index += 2
        }
        return nil
    }
}
