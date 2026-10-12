import AppKit
import Foundation

/// Rebuilds and relaunches FaceOrb from the checkout it was built from.
/// build-app.sh stamps that folder and a source fingerprint into Info.plist; when the checkout's
/// fingerprint differs (a new commit or uncommitted edits), an update is available.
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
    private var checking = false
    private var timer: Timer?

    var canUpdate: Bool { sourceDir != nil }
    var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FaceOrb/update.log")
    }

    init(bundle: Bundle = .main) {
        builtVersion = bundle.object(forInfoDictionaryKey: "FaceOrbSourceVersion") as? String
        sourceDir = (bundle.object(forInfoDictionaryKey: "FaceOrbSourceDir") as? String)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scripts/build-app.sh").path) ? $0 : nil }
        guard sourceDir != nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// Compares the checkout with the running build. Cheap: a few git commands off the main thread.
    func check() {
        guard let dir = sourceDir, !checking, state != .updating else { return }
        checking = true
        Task {
            let current = await Task.detached {
                try? Self.run("/bin/bash", [dir.appendingPathComponent("scripts/source-fingerprint.sh").path], in: dir)
            }.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            checking = false
            if let current, !current.isEmpty { updateAvailable = current != builtVersion }
        }
    }

    /// Rebuilds with scripts/build-app.sh, then relaunches into the new build.
    func update() {
        guard let dir = sourceDir, state != .updating else { return }
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
