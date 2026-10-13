import XCTest
@testable import FaceOrbWeb
import FaceOrbCore
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class WebAppIconTests: XCTestCase {
    private func api() throws -> WebAPI {
        let api = WebAPI(backend: HeadlessBackend(lib: Library()), token: "local")
        api.port = 4000
        api.configurePhoneAccess(PhoneAccessConfiguration(origin: try PhoneAccessOrigin("https://mac.example"), token: "phone"))
        return api
    }

    func testOnlyBrandingIsAvailableWithoutAuthentication() async throws {
        let api = try api()
        let local = ["host": "127.0.0.1:4000"]
        let phone = ["host": "mac.example", "x-forwarded-proto": "https"]
        for headers in [local, phone] {
            for (path, dimensions) in [
                ("/apple-touch-icon.png", [0, 0, 0, 180, 0, 0, 0, 180]),
                ("/icon-512.png", [0, 0, 2, 0, 0, 0, 2, 0]),
                ("/faceorb-icon.png", [0, 0, 4, 0, 0, 0, 4, 0])
            ] {
                let icon = await api.handle(HTTPServer.Request(method: "GET", path: path, headers: headers))
                XCTAssertEqual(icon.status, 200)
                XCTAssertEqual(icon.headers["Content-Type"], "image/png")
                XCTAssertEqual(icon.headers["Content-Length"], String(icon.body.count))
                XCTAssertEqual(icon.body.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
                XCTAssertEqual(icon.body.dropFirst(16).prefix(8), Data(dimensions.map(UInt8.init)))
                XCTAssertNil(icon.headers["Set-Cookie"])
                XCTAssertEqual(icon.headers["Referrer-Policy"], "no-referrer")
                XCTAssertEqual(icon.headers["X-Content-Type-Options"], "nosniff")
                XCTAssertEqual(icon.headers["Cache-Control"], headers == phone ? "no-store" : "public, max-age=86400")
            }
            for path in ["/", "/api/state", "/img", "/download", "/export.csv", "/Resources/faceorb-icon.png"] {
                let response = await api.handle(HTTPServer.Request(method: "GET", path: path, headers: headers))
                XCTAssertEqual(response.status, 403, path)
            }
            let post = await api.handle(HTTPServer.Request(method: "POST", path: "/faceorb-icon.png", headers: headers))
            XCTAssertEqual(post.status, 400)
            XCTAssertNil(post.headers["Set-Cookie"])
        }
    }

    func testIconsKeepHostHTTPSAndPrivateProxyChecks() async throws {
        let api = try api()
        for headers in [
            ["host": "evil.example", "x-forwarded-host": "mac.example", "x-forwarded-proto": "https"],
            ["host": "127.0.0.1:4001"],
            ["host": "mac.example"],
            ["host": "mac.example", "x-forwarded-proto": "http"],
            ["host": "mac.example", "x-forwarded-proto": "https", "tailscale-funnel-request": "?1"]
        ] {
            for path in ["/apple-touch-icon.png", "/icon-512.png", "/faceorb-icon.png", "/manifest.webmanifest"] {
                let response = await api.handle(HTTPServer.Request(method: "GET", path: path, headers: headers))
                XCTAssertEqual(response.status, 403)
            }
        }
        api.configurePhoneAccess(nil)
        let disabled = await api.handle(
            HTTPServer.Request(
                method: "GET", path: "/apple-touch-icon.png",
                headers: ["host": "mac.example", "x-forwarded-proto": "https"]))
        XCTAssertEqual(disabled.status, 403)
    }

    func testHomeScreenMetadataWithoutInAppIconNavigation() {
        for html in [WebAppPage.html, WebAPI.lockedPage, WebAPI.phoneLockedPage] {
            XCTAssertTrue(html.contains(WebAppIcon.head))
            XCTAssertTrue(html.contains("sizes=\"180x180\""))
        }
        XCTAssertFalse(WebAppPage.html.contains("href=\"/faceorb-icon.png\""))
        XCTAssertTrue(WebAppPage.html.contains("Open as Web App"))
        XCTAssertTrue(WebAppPage.html.contains("apple-mobile-web-app-capable\" content=\"yes\""))
        XCTAssertTrue(WebAppPage.html.contains("rel=\"manifest\""))
    }

    func testPublicManifestUsesCleanStandaloneURLs() async throws {
        let api = try api()
        let response = await api.handle(
            HTTPServer.Request(
                method: "GET", path: "/manifest.webmanifest",
                headers: ["host": "mac.example", "x-forwarded-proto": "https"]))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/manifest+json")
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")
        XCTAssertNil(response.headers["Set-Cookie"])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(manifest["name"] as? String, "FaceOrb")
        XCTAssertEqual(manifest["display"] as? String, "standalone")
        for key in ["id", "start_url", "scope"] { XCTAssertEqual(manifest[key] as? String, "/") }
        let icons = try XCTUnwrap(manifest["icons"] as? [[String: String]])
        XCTAssertEqual(icons.first?["src"], "/icon-512.png")
        XCTAssertEqual(icons.first?["sizes"], "512x512")
        XCTAssertFalse(WebAppIcon.manifest.contains("?"))
        XCTAssertFalse(WebAppIcon.manifest.contains("token"))
    }

    func testIconHEADHasCorrectLengthOverHTTP() async throws {
        let api = try api()
        let server = HTTPServer { await api.handle($0) }
        api.port = try server.start()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(api.port)/apple-touch-icon.png")!
        let (image, get) = try await session.data(from: url)
        XCTAssertEqual((get as? HTTPURLResponse)?.statusCode, 200)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (body, response) = try await session.data(for: request)
        let head = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Length"), String(image.count))
        XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertNil(head.value(forHTTPHeaderField: "Set-Cookie"))
    }
}
