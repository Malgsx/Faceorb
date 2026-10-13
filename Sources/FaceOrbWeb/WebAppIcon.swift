import Foundation

enum WebAppIcon {
    static let head = """
        <meta name="apple-mobile-web-app-title" content="FaceOrb">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="mobile-web-app-capable" content="yes">
        <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
        <link rel="icon" type="image/png" href="/apple-touch-icon.png">
        <link rel="manifest" href="/manifest.webmanifest">
        """

    static let manifest = """
        {
          "id": "/",
          "name": "FaceOrb",
          "short_name": "FaceOrb",
          "start_url": "/",
          "scope": "/",
          "display": "standalone",
          "background_color": "#141416",
          "theme_color": "#141416",
          "icons": [{"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"}]
        }
        """

    private static let bundle =
        Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("FaceOrb_FaceOrbWeb.bundle"))
        } ?? Bundle.module

    private static let touchIcon = load("apple-touch-icon")
    private static let appIcon = load("icon-512")
    private static let shortcutIcon = load("faceorb-icon")

    static func response(for request: HTTPServer.Request) -> HTTPServer.Response? {
        let data: Data?
        let type: String
        switch request.path {
        case "/apple-touch-icon.png": data = touchIcon; type = "image/png"
        case "/icon-512.png": data = appIcon; type = "image/png"
        case "/faceorb-icon.png": data = shortcutIcon; type = "image/png"
        case "/manifest.webmanifest": data = Data(manifest.utf8); type = "application/manifest+json"
        default: return nil
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            return .text("GET or HEAD required", status: 400)
        }
        guard let data else { return .text("Icon unavailable", status: 404) }
        return HTTPServer.Response(
            headers: [
                "Content-Type": type,
                "Content-Length": String(data.count),
                "Cache-Control": "public, max-age=86400"
            ],
            body: request.method == "HEAD" ? Data() : data)
    }

    private static func load(_ name: String) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Resources") else { return nil }
        return try? Data(contentsOf: url)
    }
}
