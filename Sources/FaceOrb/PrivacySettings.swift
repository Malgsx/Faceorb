import FaceOrbCore
import SwiftUI

struct PrivacySettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var windows: AppWindows
    var showCutoffs = false
    @State private var confirmDelete = false
    @State private var confirmClear = false

    var body: some View {
        Form {
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
                Text("Face detection (Apple Vision) and recognition (SFace) run on this Mac, not a cloud service. Optional phone access sends requested previews and photo files to your device over your configured private HTTPS connection. Album downloads only fetch the web-size copies the gallery already shows.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Web app in your browser", isOn: Binding(get: { model.webAppEnabled }, set: { model.webAppEnabled = $0 }))
                if let url = model.webURL {
                    Button("Open in browser") { model.openWebApp() }
                    Text("Served at 127.0.0.1:\(url.port ?? 0), locked with a private key. Phone access is off unless you configure a trusted HTTPS proxy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Phone setup…") { windows.showPhoneSetup() }
                if model.phoneURL != nil {
                    Button("Disable phone access") { model.disablePhoneAccess() }
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
}
