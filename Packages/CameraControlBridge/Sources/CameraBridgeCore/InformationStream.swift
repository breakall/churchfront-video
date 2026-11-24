import Foundation
import Network

extension Upstream {
    /// Raw framing is preserved. One bounded chunk is in flight; no stream joins the movement queue.
    func stream(_ request: HTTPRequest, to client: NWConnection,
                observe: @escaping @Sendable (HTTPResponse) async -> Void) async throws {
        let tls = url.scheme == "https"
        let connection = NWConnection(host: NWEndpoint.Host(url.host!), port: NWEndpoint.Port(rawValue: UInt16(url.port ?? (tls ? 443 : 80)))!, using: tls ? .tls : .tcp)
        let queue = DispatchQueue(label: "camera-bridge.information-stream")
        let bytes = wire(request)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false, sentHeaders = false, header = Data(), snapshot: Data? = Data()
            let idle = DispatchSource.makeTimerSource(queue: queue)
            idle.schedule(deadline: .now() + timeout)
            func finish(_ result: Result<Void, Error>) {
                guard !finished else { return }; finished = true
                idle.setEventHandler(handler: nil); idle.cancel()
                connection.stateUpdateHandler = nil; connection.cancel()
                if case .failure(let error) = result, !sentHeaders {
                    let response = HTTPResponse(status: (error as? HTTPError)?.status ?? 502)
                    client.send(content: response.wire(), completion: .contentProcessed { _ in continuation.resume(with: result) })
                } else { continuation.resume(with: result) }
            }
            idle.setEventHandler { finish(.failure(HTTPError(504, "Information stream timed out"))) }
            idle.resume()
            // Read-only streams contain no further requests. EOF means the downstream client left.
            client.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                if complete || error != nil { queue.async { finish(.success(())) } }
            }
            func observeSnapshot(_ data: Data, done: Bool) {
                guard var candidate = snapshot else { return }
                candidate.append(data)
                if candidate.count > 65536 { snapshot = nil; return }
                snapshot = candidate
                if let reply = try? Self.parse(candidate, complete: done) {
                    snapshot = nil
                    Task { await observe(reply) }
                }
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    guard !finished else { return }
                    let data = data ?? Data()
                    observeSnapshot(data, done: done)
                    if !sentHeaders {
                        header.append(data)
                        guard header.count <= 98304 else { finish(.failure(HTTPError(502, "Information headers exceed limit"))); return }
                        guard let split = header.range(of: Data("\r\n\r\n".utf8)) else {
                            if header.count > 32768 || done || error != nil { finish(.failure(HTTPError(502, "Malformed information response"))) }
                            else { receive() }
                            return
                        }
                        guard split.lowerBound <= 32768,
                              let text = String(data: header[..<split.lowerBound], encoding: .utf8),
                              text.hasPrefix("HTTP/1.") else { finish(.failure(HTTPError(502, "Malformed information response"))); return }
                        sentHeaders = true
                        let initial = header; header.removeAll(keepingCapacity: false)
                        idle.schedule(deadline: .now() + 120)
                        client.send(content: initial, completion: .contentProcessed { sendError in
                            queue.async {
                                if let sendError { finish(.failure(sendError)) }
                                else if done { finish(.success(())) }
                                else if let error { finish(.failure(error)) }
                                else { receive() }
                            }
                        })
                    } else {
                        idle.schedule(deadline: .now() + 120)
                        client.send(content: data, completion: .contentProcessed { sendError in
                            queue.async {
                                if let sendError { finish(.failure(sendError)) }
                                else if done { finish(.success(())) }
                                else if let error { finish(.failure(error)) }
                                else { receive() }
                            }
                        })
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) } else { receive() }
                    })
                case .failed(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
}
