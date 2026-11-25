import Foundation

/// Translate camera info incrementally. Fixed-length snapshots and MIME parts are emitted
/// with their updated lengths. A long-running stream only retains the current line or part.
struct ControllerInformationStream {
    private let view: ControllerSessionView
    private var response: HTTPResponse?
    private var discoveryHeader: Data?
    private var fixedLength: Int?
    private var boundary: String?
    private var pending = Data()
    private var chunked = false
    private var chunkInput = Data()
    private var chunkRemaining: Int?
    private var expectChunkTerminator = false
    private var seen = Set<String>()
    private(set) var finished = false
    private static let limit = 2_097_152
    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)

    init(view: ControllerSessionView) { self.view = view }

    mutating func begin(_ bytes: Data, status: Int, headers: [String: String], done: Bool, rawHeader: Data? = nil) throws -> Data {
        let reply = HTTPResponse(status: status, headers: headers)
        response = reply
        if reply.sessionExpired || (300..<400).contains(status) {
            finished = true
            let translated = view.reply(reply)
            if let discoveryHeader, translated.body == reply.body, translated.headers == reply.headers {
                return discoveryHeader + reply.body
            }
            return translated.wire()
        }
        if let encoding = headers["transfer-encoding"] {
            guard encoding.lowercased() == "chunked", headers["content-length"] == nil else {
                throw HTTPError(502, "Unexpected information transfer encoding")
            }
            chunked = true
        } else if let length = headers["content-length"] {
            guard let value = Int(length), (0...Self.limit).contains(value) else {
                throw HTTPError(502, "Invalid information length")
            }
            fixedLength = value
            if view.sessionID == nil, status == 200, headers["livescope-status"] == "0",
               headers["content-type"]?.lowercased().hasPrefix("text/plain") == true {
                discoveryHeader = rawHeader
            }
        }
        if let type = headers["content-type"], type.lowercased().hasPrefix("multipart/") {
            let token = type.split(separator: ";").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.lowercased().hasPrefix("boundary=") }
            guard let token else { throw HTTPError(502, "Missing information boundary") }
            let marker = String(token.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !marker.isEmpty, marker.count <= 70 else { throw HTTPError(502, "Invalid information boundary") }
            boundary = "--" + marker
        }
        guard fixedLength == nil || boundary != nil else { return try append(bytes, done: done) }
        var output = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Response")\r\n".utf8)
        let skip: Set<String> = ["content-length", "transfer-encoding", "connection", "keep-alive", "location", "content-location", "trailer"]
        for (key, value) in headers where !skip.contains(key) {
            output.append(Data("\(key): \(value)\r\n".utf8))
        }
        output.append(Data("Connection: close\r\n\r\n".utf8))
        output.append(try append(bytes, done: done))
        return output
    }

    mutating func append(_ bytes: Data, done: Bool) throws -> Data {
        guard !finished, var reply = response else { return Data() }
        if let length = fixedLength, boundary == nil {
            pending.append(bytes)
            guard pending.count <= length, !done || pending.count == length else { throw HTTPError(502, "Invalid information length") }
            guard pending.count == length else { return Data() }
            finished = true
            reply.body = pending
            let translated = view.reply(reply)
            if let discoveryHeader, translated.body == reply.body, translated.headers == reply.headers {
                return discoveryHeader + reply.body
            }
            return translated.wire()
        }
        let decoded = chunked ? try decodeChunks(bytes, eof: done) : bytes
        let complete = done || finished
        pending.append(decoded)
        guard pending.count <= Self.limit else { throw HTTPError(502, "Information frame exceeds limit") }
        if let boundary { return try multipart(boundary, complete: complete) }
        if reply.status != 200 || reply.headers["livescope-status"] != "0" {
            let data = pending; pending.removeAll(keepingCapacity: false); return data
        }
        var result = Data()
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
            if let translated = view.renderLine(line, seen: &seen) { result.append(Data((translated + "\r\n").utf8)) }
            pending.removeSubrange(...newline)
        }
        if complete {
            if !pending.isEmpty, let translated = view.renderLine(String(decoding: pending, as: UTF8.self), seen: &seen) {
                result.append(Data((translated + "\r\n").utf8))
            }
            for line in view.missingFields(seen: seen) { result.append(Data((line + "\r\n").utf8)) }
            pending.removeAll(); finished = true
        }
        return result
    }

    private mutating func decodeChunks(_ bytes: Data, eof: Bool) throws -> Data {
        chunkInput.append(bytes)
        var output = Data()
        while !chunkInput.isEmpty {
            if expectChunkTerminator {
                guard chunkInput.count >= 2 else { break }
                guard chunkInput.starts(with: Self.crlf) else { throw HTTPError(502, "Invalid information chunk") }
                chunkInput.removeFirst(2); expectChunkTerminator = false
            }
            if chunkRemaining == nil {
                guard let lineEnd = chunkInput.range(of: Self.crlf) else {
                    if chunkInput.count > 1024 { throw HTTPError(502, "Invalid information chunk header") }
                    break
                }
                let line = String(decoding: chunkInput[..<lineEnd.lowerBound], as: UTF8.self)
                guard let value = line.split(separator: ";").first, let size = Int(value, radix: 16), size >= 0 else {
                    throw HTTPError(502, "Invalid information chunk size")
                }
                chunkInput.removeSubrange(..<lineEnd.upperBound)
                if size == 0 { finished = true; break }
                chunkRemaining = size
            }
            if let remaining = chunkRemaining {
                let count = min(remaining, chunkInput.count)
                output.append(chunkInput.prefix(count)); chunkInput.removeFirst(count)
                if remaining == count { chunkRemaining = nil; expectChunkTerminator = true }
                else { chunkRemaining = remaining - count }
            }
        }
        if eof && !finished { throw HTTPError(502, "Truncated information chunks") }
        return output
    }

    private mutating func multipart(_ marker: String, complete: Bool) throws -> Data {
        var result = Data()
        while !pending.isEmpty {
            while pending.starts(with: Self.crlf) { pending.removeFirst(2) }
            if pending.starts(with: Data((marker + "--").utf8)) {
                result.append(Data((marker + "--\r\n").utf8)); pending.removeAll(); finished = true; break
            }
            guard let end = pending.range(of: Self.headerEnd) else { break }
            let lines = String(decoding: pending[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            guard lines.first == marker else { throw HTTPError(502, "Invalid information MIME boundary") }
            var partHeaders: [String: String] = [:]
            for line in lines.dropFirst() {
                let kv = line.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { throw HTTPError(502, "Invalid information MIME headers") }
                partHeaders[String(kv[0]).lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
            }
            guard let length = partHeaders["content-length"].flatMap(Int.init), (0...Self.limit).contains(length) else {
                throw HTTPError(502, "Invalid information MIME length")
            }
            let bodyStart = end.upperBound
            guard pending.distance(from: bodyStart, to: pending.endIndex) >= length else { break }
            let bodyEnd = pending.index(bodyStart, offsetBy: length)
            let part = HTTPResponse(status: 200, headers: ["livescope-status":"0", "content-type":"text/plain"], body: Data(pending[bodyStart..<bodyEnd]))
            let translated = view.reply(part).body
            result.append(Data((marker + "\r\n").utf8))
            for line in lines.dropFirst() where !line.lowercased().hasPrefix("content-length:") { result.append(Data((line + "\r\n").utf8)) }
            result.append(Data("Content-Length: \(translated.count)\r\n\r\n".utf8))
            result.append(translated); result.append(Self.crlf)
            pending.removeSubrange(..<bodyEnd)
        }
        if complete && !pending.isEmpty { throw HTTPError(502, "Truncated information MIME part") }
        return result
    }
}
