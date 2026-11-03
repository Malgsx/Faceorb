import AppKit
import CryptoKit
import Foundation

/// Updates FaceOrb in one of two ways, decided by what build-app.sh stamped into Info.plist:
/// - Built from a checkout (a clone, or an install that built from source): rebuilds from that
///   checkout when its source fingerprint differs from the running build's.
/// - Downloaded (install.sh's prebuilt app): downloads the newer build CI published, when the
///   published version.txt differs from the running build's fingerprint.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case updating
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var updateAvailable = false

    /// The checkout this app was built from, or nil for a build without one (updates are then hidden).
    let sourceDir: URL?
    let builtVersion: String?
    /// Where CI publishes prebuilt builds, for an app that was downloaded rather than built here.
    let releaseURL: URL?
    private var checking = false
    private var lastRemoteCheck = Date.distantPast
    private var timer: Timer?

    var canUpdate: Bool { sourceDir != nil || releaseURL != nil }
    /// True when updating means rebuilding from source (slow) rather than downloading.
    var rebuilds: Bool { sourceDir != nil }
    var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FaceOrb/update.log")
    }

    init(bundle: Bundle = .main) {
        builtVersion = bundle.object(forInfoDictionaryKey: "FaceOrbSourceVersion") as? String
        sourceDir = (bundle.object(forInfoDictionaryKey: "FaceOrbSourceDir") as? String)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scripts/build-app.sh").path) ? $0 : nil }
        releaseURL = sourceDir != nil ? nil : (bundle.object(forInfoDictionaryKey: "FaceOrbUpdateURL") as? String).flatMap(URL.init(string:))
        guard canUpdate else { return }
        check()
        // A checkout is cheap to check; the published version is on GitHub, so ask it less often.
        timer = Timer.scheduledTimer(withTimeInterval: sourceDir != nil ? 60 : 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// Compares the checkout with the running build. Cheap: a few git commands off the main thread.
    func check() {
        guard !checking, state != .updating else { return }
        if let base = releaseURL {
            // Opening the dropdown checks too; at most every few minutes.
            guard Date().timeIntervalSince(lastRemoteCheck) > 300 else { return }
            checking = true
            lastRemoteCheck = Date()
            Task {
                var req = URLRequest(url: base.appendingPathComponent("version.txt"))
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let published = try? await URLSession.shared.data(for: req)
                checking = false
                guard let (data, resp) = published, (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !version.isEmpty { updateAvailable = version != builtVersion }
            }
            return
        }
        guard let dir = sourceDir else { return }
        checking = true
        Task {
            let current = await Task.detached {
                try? Self.run("/bin/bash", [dir.appendingPathComponent("scripts/source-fingerprint.sh").path], in: dir)
            }.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            checking = false
            if let current, !current.isEmpty { updateAvailable = current != builtVersion }
        }
    }

    /// Rebuilds with scripts/build-app.sh (or downloads the published build), then relaunches into it.
    func update() {
        guard state != .updating else { return }
        if let base = releaseURL {
            state = .updating
            Task {
                do {
                    let app = try await Task.detached { try await Self.downloadPublishedApp(from: base) }.value
                    relaunch(at: app)
                } catch {
                    state = .failed(error.localizedDescription)
                }
            }
            return
        }
        guard let dir = sourceDir else { return }
        state = .updating
        let log = logURL
        Task {
            let result = await Task.detached { () -> Result<Void, Error> in
                do {
                    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try Self.run("/bin/bash", [dir.appendingPathComponent("scripts/build-app.sh").path], in: dir, log: log)
                    return .success(())
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success:
                relaunch(at: dir.appendingPathComponent("build/FaceOrb.app"))
            case .failure(let error):
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Quits and reopens the app at `url` (by default this one) once this process has exited.
    /// A copy installed elsewhere (install.sh puts one in ~/Applications) is replaced by `url` first.
    func relaunch(at url: URL? = nil) {
        let app = (url ?? Bundle.main.bundleURL).path
        let installed = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits up to 30s for this process to exit; if the quit was cancelled, it opens nothing.
        p.arguments = ["-c", "i=0; while kill -0 \(pid) 2>/dev/null; do i=$((i+1)); [ $i -gt 150 ] && exit 0; sleep 0.2; done; "
            + "if [ \"$0\" != \"$1\" ]; then /bin/rm -rf \"$1\" && /usr/bin/ditto \"$0\" \"$1\" || exit 1; fi; /usr/bin/open \"$1\"",
            app, installed]
        do { try p.run() } catch {
            state = .failed("Couldn't relaunch: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
        // Still running: the quit was cancelled, so don't leave the UI stuck on "Rebuilding".
        if state == .updating { state = .failed("The new version is built. Quit and reopen FaceOrb to use it.") }
    }

    func dismissError() { if case .failed = state { state = .idle } }

    struct DownloadFailed: LocalizedError {
        var errorDescription: String?
    }

    /// Downloads the published FaceOrb.zip, checks it against its published SHA-256, and unpacks it
    /// into a temporary folder. Returns the app inside.
    nonisolated static func downloadPublishedApp(from base: URL) async throws -> URL {
        func fetch(_ name: String) async throws -> Data {
            var req = URLRequest(url: base.appendingPathComponent(name))
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw DownloadFailed(errorDescription: "Couldn't download the update (\(name)).")
            }
            return data
        }
        let zip = try await fetch("FaceOrb.zip")
        let expected = String(decoding: try await fetch("FaceOrb.zip.sha256"), as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw DownloadFailed(errorDescription: "The downloaded update didn't match its checksum. Try again later.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("faceorb-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("FaceOrb.zip")
        try zip.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", file.path, dir.path]
        try p.run()
        p.waitUntilExit()
        let app = dir.appendingPathComponent("FaceOrb.app")
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw DownloadFailed(errorDescription: "Couldn't unpack the update.")
        }
        return app
    }

    struct CommandFailed: LocalizedError {
        var status: Int32
        var tail: String
        var errorDescription: String? { tail.isEmpty ? "The build failed (exit \(status))." : "The build failed: \(tail)" }
    }

    /// Runs a command and returns its output. With `log`, output goes to that file instead and
    /// the last line is reported on failure.
    nonisolated static func run(_ tool: String, _ args: [String], in dir: URL, log: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        // Apps launched from Finder get a bare PATH; the build needs git, swift and the Xcode tools.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let out: FileHandle
        let pipe = Pipe()
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            out = try FileHandle(forWritingTo: log)
            p.standardOutput = out
            p.standardError = out
        } else {
            out = pipe.fileHandleForWriting
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
        }
        do { try p.run() } catch {
            if log != nil { try? out.close() }
            throw error
        }
        let data = log == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        p.waitUntilExit()
        if log != nil { try? out.close() }
        guard p.terminationStatus == 0 else {
            let text = log.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n")
            let last = lines.last { $0.contains("error:") } ?? lines.last
            throw CommandFailed(status: p.terminationStatus, tail: String(last ?? "").trimmingCharacters(in: .whitespaces))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
