import Foundation
import Network

extension Upstream {
    /// One bounded chunk is in flight; no stream joins the movement queue.
    func stream(_ request: HTTPRequest, to client: NWConnection, view: ControllerSessionView? = nil,
                diagnostic: @escaping @Sendable (String, Int?, String?, DiagnosticDetails, String?) -> Void = { _, _, _, _, _ in },
                observe: @escaping @Sendable (HTTPResponse) async -> Void) async throws {
        let tls = url.scheme == "https"
        let connection = NWConnection(host: NWEndpoint.Host(url.host!), port: NWEndpoint.Port(rawValue: UInt16(url.port ?? (tls ? 443 : 80)))!, using: tls ? .tls : .tcp)
        let queue = DispatchQueue(label: "camera-bridge.information-stream")
        let bytes = wire(request)
        let began = ProcessInfo.processInfo.systemUptime
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var transform = view.map { ControllerInformationStream(view: $0) }
            var finished = false, sentHeaders = false, header = Data(), snapshot: Data? = Data()
            var upstreamBytes = 0, downstreamBytes = 0
            var responseStatus: Int?, responseLivescope: String?, firstByteMs: Double?
            var responseDetails = DiagnosticDetails.request(request)
            let idle = DispatchSource.makeTimerSource(queue: queue)
            idle.schedule(deadline: .now() + timeout)
            func finish(_ result: Result<Void, Error>, _ reason: String) {
                guard !finished else { return }; finished = true
                responseDetails.sentHeaders = sentHeaders
                responseDetails.upstreamBytes = upstreamBytes; responseDetails.downstreamBytes = downstreamBytes
                responseDetails.firstByteMs = firstByteMs
                diagnostic("information_stream_finished", responseStatus, responseLivescope, responseDetails, reason)
                idle.setEventHandler(handler: nil); idle.cancel()
                connection.stateUpdateHandler = nil; connection.cancel()
                if case .failure(let error) = result, !sentHeaders {
                    let response = HTTPResponse(status: (error as? HTTPError)?.status ?? 502)
                    client.send(content: response.wire(), completion: .contentProcessed { _ in continuation.resume(with: result) })
                } else { continuation.resume(with: result) }
            }
            idle.setEventHandler { finish(.failure(HTTPError(504, "Information stream timed out")), sentHeaders ? "idle_timeout" : "header_timeout") }
            idle.resume()
            // Read-only streams contain no further requests. EOF means the downstream client left.
            client.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                if complete || error != nil { queue.async { finish(.success(()), error == nil ? "downstream_eof" : "downstream_error") } }
            }
            func observeSnapshot(_ data: Data, done: Bool) {
                guard var candidate = snapshot else { return }
                candidate.append(data)
                if candidate.count > 65536 { snapshot = nil; return }
                snapshot = candidate
                if let reply = try? Self.parse(candidate, complete: done) {
                    snapshot = nil
                    let snapshotDetails = DiagnosticDetails.response(reply, request: request, cameraHost: url.host)
                    responseDetails.controlState = snapshotDetails.controlState
                    responseDetails.originRelation = snapshotDetails.originRelation
                    diagnostic("information_snapshot", reply.status, reply.headers["livescope-status"], responseDetails, nil)
                    Task { await observe(reply) }
                }
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    guard !finished else { return }
                    let data = data ?? Data()
                    upstreamBytes = min(2_147_483_647, upstreamBytes + data.count)
                    if !data.isEmpty && firstByteMs == nil { firstByteMs = (ProcessInfo.processInfo.systemUptime - began) * 1000 }
                    observeSnapshot(data, done: done)
                    if !sentHeaders {
                        header.append(data)
                        guard header.count <= 98304 else { finish(.failure(HTTPError(502, "Information headers exceed limit")), "header_limit"); return }
                        guard let split = header.range(of: Data("\r\n\r\n".utf8)) else {
                            if header.count > 32768 || done || error != nil { finish(.failure(HTTPError(502, "Malformed information response")), header.count > 32768 ? "header_limit" : "malformed_headers") }
                            else { receive() }
                            return
                        }
                        guard split.lowerBound <= 32768,
                              let text = String(data: header[..<split.lowerBound], encoding: .utf8),
                              text.hasPrefix("HTTP/1.") else { finish(.failure(HTTPError(502, "Malformed information response")), "malformed_headers"); return }
                        let lines = text.components(separatedBy: "\r\n")
                        responseStatus = lines.first.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) }
                        var headers = [String: String]()
                        for line in lines.dropFirst() {
                            let pair = line.split(separator: ":", maxSplits: 1)
                            if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
                        }
                        responseLivescope = headers["livescope-status"]
                        let type = headers["content-type"]?.lowercased()
                        responseDetails.contentType = type == nil ? "missing" : type!.hasPrefix("text/") ? "text" : type!.hasPrefix("multipart/") ? "multipart" : type!.hasPrefix("application/json") ? "json" : "other"
                        responseDetails.firstByteMs = firstByteMs
                        diagnostic("information_response", responseStatus, responseLivescope, responseDetails, nil)
                        sentHeaders = true
                        let initial: Data
                        do {
                            initial = try transform?.begin(Data(header[split.upperBound...]), status: responseStatus ?? 502, headers: headers, done: done, rawHeader: Data(header[..<split.upperBound])) ?? header
                        } catch { sentHeaders = false; finish(.failure(error), "malformed_headers"); return }
                        header.removeAll(keepingCapacity: false)
                        idle.schedule(deadline: .now() + 120)
                        client.send(content: initial, completion: .contentProcessed { sendError in
                            queue.async {
                                if let sendError { finish(.failure(sendError), "downstream_error"); return }
                                downstreamBytes = min(2_147_483_647, downstreamBytes + initial.count)
                                if done || transform?.finished == true { finish(.success(()), "upstream_eof") }
                                else if let error { finish(.failure(error), "upstream_error") }
                                else { receive() }
                            }
                        })
                    } else {
                        idle.schedule(deadline: .now() + 120)
                        let output: Data
                        do { output = try transform?.append(data, done: done) ?? data }
                        catch { finish(.failure(error), "upstream_error"); return }
                        client.send(content: output, completion: .contentProcessed { sendError in
                            queue.async {
                                if let sendError { finish(.failure(sendError), "downstream_error"); return }
                                downstreamBytes = min(2_147_483_647, downstreamBytes + output.count)
                                if done || transform?.finished == true { finish(.success(()), "upstream_eof") }
                                else if let error { finish(.failure(error), "upstream_error") }
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
                        if let error { finish(.failure(error), "upstream_error") } else { receive() }
                    })
                case .failed(let error): finish(.failure(error), "upstream_error")
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
}
