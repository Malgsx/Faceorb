import XCTest
@testable import FaceOrbWeb
import FaceOrbCore

final class PhoneAccessTests: XCTestCase {
    func api() throws -> WebAPI {
        let api = WebAPI(backend: HeadlessBackend(lib: Library()), token: "local")
        api.port = 4000
        api.configurePhoneAccess(PhoneAccessConfiguration(origin: try PhoneAccessOrigin("https://mac.example"), token: "phone", connectionID: "instance"))
        return api
    }

    var headers: [String: String] {
        ["host": "mac.example", "x-forwarded-proto": "https", "cookie": "__Host-faceorb-phone=phone"]
    }

    func testOriginsMustBeHTTPSRoots() throws {
        let origin = try PhoneAccessOrigin(" https://MAC.example:443/ ")
        XCTAssertEqual(origin.url.absoluteString, "https://mac.example")
        XCTAssertTrue(origin.accepts(host: "MAC.example:443"))
        XCTAssertFalse(origin.accepts(host: "mac.example.attacker"))
        XCTAssertFalse(origin.accepts(host: "mac.example:444"))
        XCTAssertTrue(origin.accepts(origin: "https://mac.example"))
        XCTAssertFalse(origin.accepts(origin: "http://mac.example"))
        let custom = try PhoneAccessOrigin("https://mac.example:8443")
        XCTAssertEqual(custom.authority, "mac.example:8443")
        XCTAssertFalse(custom.accepts(host: "mac.example"))
        XCTAssertEqual(custom.launchURL(token: "test key").absoluteString, "https://mac.example:8443/?t=test%20key")
        for value in [
            "http://mac.example", "https://", "https://mac.example/a", "https://user:pass@mac.example",
            "https://mac.example?t=secret", "https://mac.example#fragment", "https://mac.example:0",
            "https://mac.example:65536", "https://mac.example\n.evil", "https://mac.example%0d%0a.evil"
        ] {
            XCTAssertThrowsError(try PhoneAccessOrigin(value), value)
        }
    }

    func testPhoneBootstrapUsesIndependentSecureCookie() async throws {
        let api = try api()
        let response = await api.handle(
            HTTPServer.Request(
                method: "GET", path: "/", query: ["t": "phone"],
                headers: ["host": "mac.example", "x-forwarded-proto": "https"]))
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(response.headers["Location"], "/")
        XCTAssertEqual(response.headers["Set-Cookie"], "__Host-faceorb-phone=phone; Path=/; HttpOnly; SameSite=Strict; Secure")
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")
        XCTAssertEqual(response.headers["Referrer-Policy"], "no-referrer")
        let state = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: headers))
        XCTAssertEqual(state.status, 200)
        XCTAssertEqual(state.headers["Cache-Control"], "no-store")
        for cookie in ["faceorb=local", "__Host-faceorb-phone=local", "faceorb=phone"] {
            var h = headers; h["cookie"] = cookie
            let r = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: h))
            XCTAssertEqual(r.status, 403)
        }
        let local = await api.handle(
            HTTPServer.Request(
                method: "GET", path: "/api/state",
                headers: ["host": "127.0.0.1:4000", "cookie": "__Host-faceorb-phone=phone"]))
        XCTAssertEqual(local.status, 403)
    }

    func testProxyHeadersCannotOptInOrChangeHosts() async throws {
        let api = try api()
        for host in ["evil.example", "mac.example:80", "mac.example.attacker"] {
            var h = headers; h["host"] = host; h["x-forwarded-host"] = "mac.example"
            let r = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: h))
            XCTAssertEqual(r.status, 403)
        }
        for proto in ["http", "https,http", ""] {
            var h = headers; h["x-forwarded-proto"] = proto
            let r = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: h))
            XCTAssertEqual(r.status, 403)
        }
        var funnel = headers; funnel["tailscale-funnel-request"] = "?1"
        let publicRequest = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: funnel))
        XCTAssertEqual(publicRequest.status, 403)
        api.configurePhoneAccess(nil)
        let off = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: headers))
        XCTAssertEqual(off.status, 403)
    }

    func testPhoneWritesRequireMatchingOriginAndCustomHeader() async throws {
        let api = try api()
        let body = Data(#"{"confirm":true}"#.utf8)
        for origin in [nil, "null", "http://mac.example", "https://evil.example", "https://mac.example.attacker"] as [String?] {
            var h = headers; h["x-faceorb"] = "1"; h["origin"] = origin
            let r = await api.handle(HTTPServer.Request(method: "POST", path: "/api/clear-photos", headers: h, body: body))
            XCTAssertEqual(r.status, 403)
        }
        var h = headers; h["origin"] = "https://mac.example"
        let missing = await api.handle(HTTPServer.Request(method: "POST", path: "/api/clear-photos", headers: h, body: body))
        XCTAssertEqual(missing.status, 403)
        h["x-faceorb"] = "1"
        let accepted = await api.handle(HTTPServer.Request(method: "POST", path: "/api/clear-photos", headers: h, body: body))
        XCTAssertEqual(accepted.status, 200)
    }

    func testRotationRevokesPhoneWithoutRevokingLocalBrowser() async throws {
        let api = try api()
        api.configurePhoneAccess(PhoneAccessConfiguration(origin: try PhoneAccessOrigin("https://mac.example"), token: "new"))
        let old = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: headers))
        XCTAssertEqual(old.status, 403)
        let local = await api.handle(
            HTTPServer.Request(
                method: "GET", path: "/api/state",
                headers: ["host": "127.0.0.1:4000", "cookie": "faceorb=local"]))
        XCTAssertEqual(local.status, 200)
        var h = headers; h["cookie"] = "__Host-faceorb-phone=new"
        let new = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: h))
        XCTAssertEqual(new.status, 200)
    }

    func testConnectionProbeRevealsOnlyANonAuthorizingInstanceID() async throws {
        let api = try api()
        var h = headers; h["cookie"] = nil
        let probe = await api.handle(HTTPServer.Request(method: "GET", path: "/api/phone-status", headers: h))
        XCTAssertEqual(probe.status, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: probe.body) as? [String: String], ["instance": "instance"])
        for path in ["/api/state", "/img", "/download", "/"] {
            let r = await api.handle(HTTPServer.Request(method: "GET", path: path, headers: h))
            XCTAssertEqual(r.status, 403)
        }
        h["cookie"] = "__Host-faceorb-phone=instance"
        let wrong = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: h))
        XCTAssertEqual(wrong.status, 403)
        let query = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", query: ["t": "phone"], headers: h))
        XCTAssertEqual(query.status, 403)
    }

    func testPhoneCredentialsPersistRotateAndRemove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try PhoneAccessCredentials.load(at: root)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(try PhoneAccessCredentials.load(at: root), first)
        let file = root.appendingPathComponent("phone-token")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotEqual(try PhoneAccessCredentials.load(at: root, rotate: true), first)
        try Data("invalid\nkey".utf8).write(to: file)
        XCTAssertEqual(try PhoneAccessCredentials.load(at: root).count, 32)
        try PhoneAccessCredentials.remove(at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try PhoneAccessCredentials.remove(at: root)
    }

    func testPhoneOriginCannotShadowLocalAccess() async throws {
        let api = try api()
        api.configurePhoneAccess(PhoneAccessConfiguration(origin: try PhoneAccessOrigin("https://127.0.0.1:4000"), token: "phone"))
        let local = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: ["host": "127.0.0.1:4000", "cookie": "faceorb=local"]))
        XCTAssertEqual(local.status, 200)
        let phone = await api.handle(HTTPServer.Request(method: "GET", path: "/api/state", headers: ["host": "127.0.0.1:4000", "cookie": "__Host-faceorb-phone=phone"]))
        XCTAssertEqual(phone.status, 403)
    }
}
