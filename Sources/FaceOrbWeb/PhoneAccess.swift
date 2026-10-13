import Foundation

public struct PhoneAccessOrigin: Equatable, Sendable {
    public let url: URL
    public let authority: String

    public init(_ address: String) throws {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
            var parts = URLComponents(string: text),
            parts.scheme?.lowercased() == "https",
            let host = parts.host?.lowercased(), !host.isEmpty,
            host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:[]").contains($0) }),
            parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty || parts.path == "/",
            parts.port.map({ (1...65535).contains($0) }) ?? true
        else {
            throw InvalidAddress()
        }
        parts.scheme = "https"
        parts.host = host
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { throw InvalidAddress() }
        self.url = url
        self.authority = host + (parts.port.map { ":\($0)" } ?? "")
    }

    public func accepts(host: String) -> Bool {
        let value = host.lowercased()
        return value == authority || (url.port == nil && value == authority + ":443")
    }

    public func accepts(origin: String) -> Bool {
        guard let parsed = try? PhoneAccessOrigin(origin) else { return false }
        return parsed == self
    }

    public func launchURL(token: String) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.path = "/"
        parts.queryItems = [URLQueryItem(name: "t", value: token)]
        return parts.url!
    }

    public struct InvalidAddress: LocalizedError {
        public var errorDescription: String? {
            "Enter only an HTTPS address, such as https://your-mac.your-tailnet.ts.net, without a path, login, query or fragment."
        }
    }
}

public struct PhoneAccessConfiguration: Sendable {
    public let origin: PhoneAccessOrigin
    public let token: String
    public let connectionID: String

    public init(origin: PhoneAccessOrigin, token: String, connectionID: String = WebAPI.makeToken()) {
        self.origin = origin
        self.token = token
        self.connectionID = connectionID
    }
}

public enum PhoneAccessCredentials {
    public static func load(at root: URL, rotate: Bool = false) throws -> String {
        let file = root.appendingPathComponent("phone-token")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !rotate, let key = try? String(contentsOf: file, encoding: .utf8),
            key.count == 32, key.allSatisfy({ "abcdefghijkmnopqrstuvwxyz23456789".contains($0) })
        {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return key
        }
        let key = WebAPI.makeToken()
        try Data(key.utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return key
    }

    public static func remove(at root: URL) throws {
        let file = root.appendingPathComponent("phone-token")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
