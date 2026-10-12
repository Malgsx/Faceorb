import FaceOrbCore
import FaceOrbKit
import FaceOrbWeb
import Foundation

/// Lets the web app drive the same AppModel the menu bar uses, so both always agree.
final class AppBackend: FaceOrbBackend, @unchecked Sendable {
    private weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    struct Gone: LocalizedError { var errorDescription: String? { "FaceOrb is quitting." } }

    func snapshot() async -> BackendSnapshot {
        await MainActor.run {
            guard let m = model else { return BackendSnapshot(lib: Library()) }
            return BackendSnapshot(lib: m.lib, busy: m.activity.isBusy, activity: m.activity.label,
                                   fraction: m.activity.fraction, error: m.lastError)
        }
    }

    func perform(_ action: BackendAction) async throws -> String? {
        try await MainActor.run {
            guard let m = model else { throw Gone() }
            m.notice = nil
            switch action {
            case .decide(let id, let v, let face): m.decide(id, v, faceID: face)
            case .undo(let id): m.undo(id)
            case .decideMany(let ids, let v): m.decide(ids, v)
            case .undoMany(let ids): m.undo(ids)
            case .enroll(let id):
                if !m.enroll(clusterID: id) { return "That person is gone; refresh." }
            case .thresholds(let a, let r): m.setThresholds(auto: a, review: r)
            case .autoForget(let on): m.setAutoForget(on)
            case .forgetOthers: m.forgetBystanders()
            case .forgetMe: m.forgetMe()
            case .deleteAll: m.deleteEverything()
            case .clearPhotos(let keepMe): m.clearPhotos(keepMe: keepMe)
            case .cancel: m.cancel()
            case .importLink(let link):
                guard !m.activity.isBusy else { return "FaceOrb is busy. Try again when it finishes." }
                m.importLink(link)
                return m.lastError ?? "Importing… you can watch progress here or in the menu bar."
            case .importFolder(let path):
                guard !m.activity.isBusy else { return "FaceOrb is busy. Try again when it finishes." }
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    return "No folder at \(path)."
                }
                m.importFolder(url)
                return m.lastError ?? "Scanning \(url.lastPathComponent)…"
            case .export(let options, let folder):
                let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
                m.export(options, to: url)
                return m.lastError ?? "Saving \(m.exportPlan(options).count) photos to \(url.lastPathComponent)…"
            case .deleteLastExport:
                guard m.lastExport != nil else { return "Nothing to delete." }
                m.deleteLastExport()
                return m.lastError ?? m.notice
            }
            return m.notice
        }
    }

    func image(photoID: String, maxPixel: Int) async -> (Data, String)? {
        guard let path = await MainActor.run(body: { model?.photo(photoID)?.localPath }) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let cg = Images.load(URL(fileURLWithPath: path), maxPixel: maxPixel),
                  let jpeg = Images.jpegData(cg) else { return nil }
            return (jpeg, "image/jpeg")
        }.value
    }

    func enrollSelfie(_ imageData: Data) async throws -> Bool {
        guard let m = await MainActor.run(body: { model }) else { throw Gone() }
        return try await m.enrollSelfie(data: imageData)
    }
}
