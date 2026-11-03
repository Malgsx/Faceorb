import FaceOrbCore
import SwiftUI

struct PrivacySettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    var showCutoffs = false
    @State private var confirmDelete = false
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Version", value: version)
                if updater.canUpdate {
                    HStack {
                        Button("Check for Updates") { updater.check(force: true) }
                            .disabled(updater.checking || updater.state == .updating)
                        if updater.checking { ProgressView().controlSize(.small) }
                        Spacer()
                        if updater.updateAvailable {
                            Button("Update") { updater.update() }
                                .buttonStyle(.borderedProminent)
                                .disabled(updater.state == .updating || model.activity.isBusy)
                        }
                    }
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This copy wasn't installed with install.sh or built from a checkout, so it can't update itself. Run the installer again to get the latest version.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if showCutoffs {
                Section("Cutoffs") { CutoffControls() }
            }
            Section {
                LabeledContent("Photos", value: "\(model.lib.photos.count)")
                LabeledContent("Faces found", value: "\(model.faceCount)")
                LabeledContent("Face signatures stored", value: "\(model.signatureCount)")
                LabeledContent("Your reference faces", value: "\(model.lib.references.filter(\.positive).count)")
                Button("Show data folder in Finder") { model.revealData() }
            } header: {
                Text("What FaceOrb keeps")
            } footer: {
                // Grouped-form footers right-align wrapped lines on macOS; keep it a left-aligned paragraph.
                Text("Face detection (Apple Vision) and recognition (SFace) run on this Mac. FaceOrb never uploads photos or face data. Album downloads only fetch the web-size copies the gallery already shows.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Web app in your browser", isOn: Binding(get: { model.webAppEnabled }, set: { model.webAppEnabled = $0 }))
                if let url = model.webURL {
                    Button("Open in browser") { model.openWebApp() }
                    Toggle("Phones on the same Wi-Fi", isOn: Binding(get: { model.phoneAccessEnabled }, set: { model.phoneAccessEnabled = $0 }))
                    Text(model.phoneAccessEnabled
                         ? "Served on port \(url.port ?? 0) to this Mac and to phones on your network that have the key from the Phone QR code. The connection isn't encrypted, so use it on networks you trust."
                         : "Served at 127.0.0.1:\(url.port ?? 0), reachable only from this Mac, and locked with a key that only the menu bar's link carries.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Web app")
            }

            Section("Other people's faces") {
                Toggle("Forget other people's faces after each scan", isOn: Binding(
                    get: { model.lib.settings.forgetBystandersAutomatically },
                    set: { model.setAutoForget($0) }))
                Button("Forget other people's faces now") { model.forgetBystanders() }
                    .disabled(!model.isEnrolled)
                Text("Keeps signatures only for faces that might be you. You can still review, but \"Pick yourself\" will only show what's left.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Reset") {
                Button("Forget my face and decisions") { model.forgetMe() }
                if confirmClear {
                    HStack {
                        Text("Remove all \(model.lib.photos.count) photos? FaceOrb keeps your face.")
                        Spacer()
                        Button("Cancel") { confirmClear = false }
                        Button("Clear", role: .destructive) { model.clearPhotos(); confirmClear = false }
                    }
                } else {
                    Button("Clear all photos and start over…") { confirmClear = true }
                        .disabled(model.lib.photos.isEmpty || model.activity.isBusy)
                }
                if confirmDelete {
                    HStack {
                        Text("Delete every photo copy, face signature and decision?")
                        Spacer()
                        Button("Cancel") { confirmDelete = false }
                        Button("Delete", role: .destructive) { model.deleteEverything(); confirmDelete = false }
                    }
                } else {
                    Button("Delete all FaceOrb data…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard let build = updater.builtVersion, !build.isEmpty else { return short }
        return "\(short) (\(build.prefix(7)))"
    }

    private var updateStatus: String {
        if updater.state == .updating {
            return updater.rebuilds ? "Rebuilding… FaceOrb will reopen by itself." : "Downloading… FaceOrb will reopen by itself."
        }
        if case .failed(let message) = updater.state { return message }
        if updater.checking { return "Checking…" }
        if updater.updateAvailable { return "A new version is available." }
        guard let checked = updater.lastChecked else { return "Not checked yet." }
        let time = checked.formatted(date: .omitted, time: .shortened)
        if updater.lastCheckFailed {
            return updater.rebuilds ? "Couldn't read the checkout at \(time)." : "Couldn't reach GitHub at \(time). Check your connection and try again."
        }
        return "FaceOrb is up to date. Checked at \(time)."
    }
}
