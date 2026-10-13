import AppKit
import CoreImage
import FaceOrbWeb
import SwiftUI

struct PhoneAccessView: View {
    enum Connection: String, CaseIterable {
        case tailscale = "Tailscale (recommended)"
        case proxy = "My own HTTPS proxy"
    }

    @EnvironmentObject var model: AppModel
    @State private var connection: Connection = .tailscale
    @State private var address = ""
    @State private var error: String?
    @State private var showPairing = false
    @State private var confirmReset = false

    private var backend: String { "http://127.0.0.1:\(model.webURL?.port ?? Int(AppModel.webPort))" }
    private var tailscaleTool: String {
        let paths = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { "\"\($0)\"" } ?? "tailscale"
    }
    private var serveCommand: String { "\(tailscaleTool) serve --bg \(backend)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use FaceOrb on your phone").font(.title2.bold())
                    Text("Review and save photos in Safari. Face recognition stays on your Mac, which must remain awake with FaceOrb running.")
                        .foregroundStyle(.secondary)
                    Label(
                        model.phoneURL == nil ? "Mac-only access" : "Phone access configured",
                        systemImage: model.phoneURL == nil ? "lock" : "iphone")
                }
                if !model.webAppEnabled {
                    Text("The web app is off. Enable it to configure phone access.")
                    Button("Turn on the web app") { model.webAppEnabled = true }
                } else if model.webURL == nil {
                    Text("The web app couldn't start.").foregroundStyle(.red)
                    Button("Retry") { model.startWebApp() }
                } else {
                    setup
                    pairing
                }
                Divider()
                Text(
                    "Mac-only is the default. No router port forwarding, public tunnel or unencrypted Wi-Fi link is needed. Phone access gives full control of this library, including reset and deletion—pair only your own trusted devices."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onAppear { address = model.phoneAddress }
        .onChange(of: model.phoneURL) { _, _ in showPairing = false }
        .onChange(of: model.phoneConnectionReady) { _, ready in if !ready { showPairing = false } }
        .alert("Replace the phone link?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Replace link", role: .destructive) {
                do { try model.resetPhoneLink(); error = nil } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Existing phone links and browser sessions will stop working. Scan the new QR code on each device. Photos already saved to devices aren't deleted.")
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Choose a secure connection").font(.headline)
            Picker("Connection", selection: $connection) {
                ForEach(Connection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if connection == .tailscale {
                Text("Install Tailscale on your Mac and iPhone, sign both into your private network, then connect both devices.")
                HStack {
                    Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                    Link("Serve setup guide", destination: URL(string: "https://tailscale.com/kb/1312/serve")!)
                }
                Text("In Terminal on this Mac, run:")
                HStack {
                    Text(serveCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copy command") { copy(serveCommand) }
                }
                Text(
                    "Approve HTTPS in Tailscale if prompted. Paste the HTTPS address it prints below. Use private Serve, never public Funnel. If Serve already hosts another app, choose a dedicated HTTPS port rather than replacing it."
                )
                Text("Tailscale provides a publicly trusted HTTPS certificate. No certificate installation or Certificate Trust Settings changes are needed.")
                    .font(.callout)
                Text(
                    "Tailscale is optional third-party networking and needs an account. HTTPS certificate issuance publishes the Mac's certificate hostname, not your photos. FaceOrb doesn't install or configure Tailscale for you."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Run a trusted HTTPS reverse proxy on this Mac, reachable only through your private network or VPN.")
                Text("Use a certificate already trusted by both this Mac and Safari on your phone. FaceOrb doesn't install certificates or change trust settings.")
                Text(
                    "Forward the site root / to \(backend). Preserve the incoming Host header and set X-Forwarded-Proto: https after terminating TLS; strip any client-supplied forwarding headers. Don't use a subpath or expose it publicly."
                )
                .font(.callout)
                HStack {
                    Text(backend).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Copy backend") { copy(backend) }
                }
            }
            Text("2. Register your HTTPS address").font(.headline)
            TextField("https://your-mac.your-tailnet.ts.net", text: $address)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Phone HTTPS address")
            HStack {
                Button(model.phoneURL == nil ? "Enable phone access" : "Save address") {
                    do {
                        try model.enablePhoneAccess(address: address)
                        address = model.phoneAddress
                        error = nil
                        model.testPhoneConnection()
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                if model.phoneURL != nil {
                    Button("Disable phone access") {
                        model.disablePhoneAccess(); error = nil
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var pairing: some View {
        if let url = model.phoneURL {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Text("3. Pair your phone").font(.headline)
                if let status = model.phoneConnectionStatus { Text(status).font(.callout) }
                HStack {
                    Button(model.checkingPhoneConnection ? "Testing…" : "Test connection") { model.testPhoneConnection() }
                        .disabled(model.checkingPhoneConnection)
                    Button(showPairing ? "Hide pairing code" : "Show pairing code") { showPairing.toggle() }
                        .disabled(!model.phoneConnectionReady || model.checkingPhoneConnection)
                    Button("Replace phone link…") { confirmReset = true }
                }
                if showPairing && model.phoneConnectionReady {
                    HStack(alignment: .top, spacing: 20) {
                        if let image = qrCode(url) {
                            Image(nsImage: image).interpolation(.none).resizable()
                                .frame(width: 200, height: 200)
                                .accessibilityLabel("Private QR code to pair your phone")
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("With Tailscale connected on your iPhone, scan this code with Camera and open it in Safari. For your own proxy, connect to its private network instead.")
                            Button("Copy private phone link") { copy(url.absoluteString) }
                            Text("Keep this code and link private—they unlock your library. Safari removes the key from the address bar after connecting.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("In Safari, use Share → Add to Home Screen for a shortcut. Save selected offers the destinations available on your device.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(
                    "Disabling access blocks new phone requests; it doesn't stop your external proxy or erase saved photos. To stop Tailscale Serve, use its status/off commands for the port you configured."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func qrCode(_ url: URL) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let cg = CIContext().createCGImage(image, from: image.extent)
        else { return nil }
        let result = NSImage(size: NSSize(width: cg.width + 64, height: cg.height + 64))
        result.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: result.size).fill()
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            .draw(at: NSPoint(x: 32, y: 32), from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
    }
}
