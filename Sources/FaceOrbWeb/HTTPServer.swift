import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A deliberately small HTTP/1.1 server for the local web app: loopback only, one request per
/// connection, no TLS (traffic never leaves the Mac). Plain BSD sockets so it builds on macOS and Linux.
public final class HTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        public var path: String
        public var query: [String: String]
        public var headers: [String: String]   // lower-cased names
        public var body: Data

        public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
            self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
        }
    }

    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status; self.headers = headers; self.body = body
        }
        public static func text(_ s: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> Response {
            Response(status: status, headers: ["Content-Type": type], body: Data(s.utf8))
        }
        public static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
            return Response(status: status, headers: ["Content-Type": "application/json"], body: data)
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response

    private let handler: Handler
    private var listenFD: Int32 = -1
    public private(set) var port: UInt16 = 0
    public var maxBodyBytes = 40 * 1024 * 1024

    public init(handler: @escaping Handler) { self.handler = handler }

    /// Binds 127.0.0.1. Tries `preferredPort` first (so bookmarks keep working), then any free port.
    @discardableResult
    public func start(preferredPort: UInt16 = 0) throws -> UInt16 {
        for candidate in Set([preferredPort, 0]).sorted(by: >) {
            if let bound = try? bind(candidate) { port = bound; break }
        }
        guard listenFD >= 0 else { throw POSIXError(.EADDRINUSE) }
        let fd = listenFD
        let thread = Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard let server = self, server.listenFD >= 0 else { if client >= 0 { close(client) }; return }
                if client < 0 { continue }
                Thread { server.serve(client) }.start()
            }
        }
        thread.name = "faceorb-http"
        thread.start()
        return port
    }

    public func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
    }

    private func bind(_ port: UInt16) throws -> UInt16 {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if !os(Linux)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glue.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0, listen(fd, 64) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenFD = fd
        return UInt16(bigEndian: bound.sin_port)
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if !os(Linux)
        var noSigPipe: Int32 = 1   // a browser closing early must not kill the app
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
        guard let request = readRequest(fd) else { return }

        // Bridge to async: this is a plain thread, so waiting here never blocks Swift's task pool.
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        let handler = self.handler
        Task.detached {
            box.value = await handler(request)
            done.signal()
        }
        done.wait()
        write(box.value ?? .text("error", status: 500), to: fd)
    }

    private final class ResponseBox: @unchecked Sendable { var value: Response? }

    private func readRequest(_ fd: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { return nil }
            buffer.append(chunk, count: n)
            headerEnd = buffer.range(of: separator)
            if buffer.count > 64 * 1024 && headerEnd == nil { return nil }
        }
        guard let end = headerEnd, let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(buffer[end.upperBound...])
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maxBodyBytes else { return nil }
        while body.count < length {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { return nil }
            body.append(chunk, count: n)
        }
        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: comps?.path ?? target, query: query, headers: headers, body: body)
    }

    private func write(_ r: Response, to fd: Int32) {
        var head = "HTTP/1.1 \(r.status) \(Self.reason(r.status))\r\n"
        var headers = r.headers
        headers["Content-Length"] = String(r.body.count)
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        out.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                #if os(Linux)
                let n = send(fd, raw.baseAddress! + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let n = send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                #endif
                if n <= 0 { return }
                sent += n
            }
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 302: "Found"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        default: "Error"
        }
    }
}

/// `bind` is shadowed by our method name inside the class.
private enum Glue {
    static func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        #if canImport(Glibc)
        Glibc.bind(fd, addr, len)
        #else
        Darwin.bind(fd, addr, len)
        #endif
    }
}
