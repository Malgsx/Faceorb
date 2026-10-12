import AppKit
import FaceOrbCore
import FaceOrbKit
import SwiftUI

/// "Who are you?" Either click your face among the people found in the album, or add selfies.
struct EnrollView: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        let people = model.people
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Which one is you?").font(compact ? .headline : .title2.weight(.semibold))
                    Text("FaceOrb grouped the faces it found into people. Click yours, or add 3 to 5 selfies instead. Only a 128-number face signature is kept, never the selfie.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button { addSelfies() } label: { Label("Add selfies…", systemImage: "person.crop.square.badge.camera") }
                    if model.isEnrolled {
                        Button("Start over", role: .destructive) { model.forgetMe() }
                    }
                }

                if model.pendingAnalysis > 0 {
                    Label("Still scanning \(model.pendingAnalysis) photos. More people will appear.", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: gridColumns, spacing: compact ? 12 : 16) {
                    ForEach(people) { person in
                        PersonTile(person: person, picked: isPicked(person), size: compact ? 72 : 104) {
                            model.enroll(cluster: person)
                            model.section = .bucket(.review)
                        }
                    }
                }
            }
            .padding(compact ? 16 : 20)
        }
    }

    /// Compact: four equal columns across the dropdown. Full window: adaptive columns.
    private var gridColumns: [GridItem] {
        compact
            ? Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
            : [GridItem(.adaptive(minimum: 120), spacing: 16)]
    }

    private func isPicked(_ c: PeopleClusterer.Cluster) -> Bool {
        let picked = Set(model.lib.references.compactMap(\.faceID))
        return c.faceIDs.contains(where: picked.contains)
    }

    private func addSelfies() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Pick a few clear photos of just you, from different angles."
        if panel.runModal() == .OK { model.enroll(selfies: panel.urls) }
    }
}

struct PersonTile: View {
    @EnvironmentObject var model: AppModel
    var person: PeopleClusterer.Cluster
    var picked: Bool
    var size: CGFloat = 104
    var action: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        // Same footprint while the crop loads, so the grid doesn't jump.
                        Rectangle().fill(.quaternary)
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(ringColor, lineWidth: picked ? 3 : 1.5))
                .overlay(alignment: .bottomTrailing) {
                    if picked {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: size * 0.3))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2))
                            .offset(x: 2, y: 2)
                    }
                }
                .scaleEffect(hovering ? 1.04 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                Text("In \(person.photoCount) photos")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PersonTilePressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel("Person in \(person.photoCount) photos")
        .accessibilityAddTraits(picked ? .isSelected : [])
        .task(id: person.id) {
            guard let face = model.face(person.id), let photo = model.photo(face.photoID) else { return }
            image = await ThumbnailCache.shared.face(path: photo.localPath, box: face.box)
        }
    }

    private var ringColor: Color {
        if picked { return .accentColor }
        return hovering ? Color(nsColor: .separatorColor) : .clear
    }
}

/// Press feedback for person tiles: a slight shrink and dim while the mouse is down.
struct PersonTilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
