import AppKit
import FaceOrbCore
import FaceOrbKit
import SwiftUI
import UniformTypeIdentifiers

enum ReviewSection: Hashable {
    case bucket(Bucket)
    case people
}

struct ReviewWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(model.section) }, set: { if let s = $0 { model.section = s } })) {
                Section("Photos") {
                    ForEach([Bucket.review, .mine, .others], id: \.self) { b in
                        Label(b.title, systemImage: b.symbol)
                            .badge(model.count(b))
                            .tag(ReviewSection.bucket(b))
                    }
                }
                Section("Setup") {
                    Label(model.isEnrolled ? "Who you are" : "Pick yourself", systemImage: "person.crop.square")
                        .tag(ReviewSection.people)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { StatusFooter().padding(10) }
        } detail: {
            switch model.section {
            case .people: EnrollView()
            case .bucket(let b):
                if !model.isEnrolled && !model.lib.photos.isEmpty { EnrollView() } else { PhotoGrid(bucket: b) }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Export list as CSV…", action: exportCSV)
                    Button("Save my photos…") { model.showExportSheet = true }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(model.count(.mine) == 0)
            }
        }
        .overlay(alignment: .bottom) { NoticeBanner() }
        .sheet(isPresented: $model.showExportSheet) { ExportSheet().environmentObject(model) }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "my-photos.csv"
        if panel.runModal() == .OK, let url = panel.url { model.exportCSV(to: url) }
    }
}

struct StatusFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let f = model.activity.fraction {
                ProgressView(value: f).controlSize(.small)
            }
            Text(model.activity.isBusy ? model.activity.label : "\(model.lib.photos.count) photos · \(model.faceCount) faces")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NoticeBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let error = model.lastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    if let last = model.lastExport, !last.files.isEmpty {
                        Button("Delete the \(last.files.count) copies that were saved") { model.deleteLastExport() }
                            .buttonStyle(.link)
                    }
                }
                Button { model.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 560)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 16)
        } else if let notice = model.notice {
            Text(notice)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 16)
                .task(id: notice) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    if model.notice == notice { model.notice = nil }
                }
        }
    }
}

// MARK: - Grid

struct PhotoGrid: View {
    @EnvironmentObject var model: AppModel
    var bucket: Bucket
    /// Multi-select: click picks one, Command-click toggles, Shift-click selects a range.
    @State private var selection: Set<String> = []
    /// The photo keyboard actions and Shift-click ranges start from.
    @State private var anchor: String?
    @State private var detail: String?
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.photos(in: bucket)
        VStack(spacing: 0) {
            header(count: items.count)
            Divider()
            if items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: bucket.symbol, description: Text(emptyText))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16, alignment: .top)], spacing: 20) {
                            ForEach(items, id: \.0.id) { photo, match in
                                PhotoCell(photo: photo, match: match, bucket: bucket, selected: selection.contains(photo.id),
                                          verdict: model.lib.verdicts[photo.id], showsCaption: true)
                                    .id(photo.id)
                                    .onTapGesture(count: 2) { detail = photo.id }
                                    .onTapGesture { click(photo.id, in: items); focused = true }
                            }
                        }
                        .padding(20)
                    }
                    .onChange(of: anchor) { if let a = anchor { proxy.scrollTo(a, anchor: .center) } }
                }
            }
            if selection.count > 1 {
                Divider()
                selectionBar(items)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(characters: .init(charactersIn: "aryu ")) { press in
            if press.modifiers.contains(.command) {
                // Command-A selects every photo in this list; other Command keys are menu shortcuts.
                guard press.characters == "a" else { return .ignored }
                selection = Set(items.map(\.0.id))
                return .handled
            }
            guard !selection.isEmpty else { return .ignored }
            switch press.characters {
            case "a", "y": act(.approved, in: items)
            case "r": act(.rejected, in: items)
            case "u": model.undo(Array(selection))
            case " ": guard let a = anchor else { return .ignored }; detail = a
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.rightArrow) { move(1, in: items); return .handled }
        .onKeyPress(.leftArrow) { move(-1, in: items); return .handled }
        .onKeyPress(.escape) {
            guard selection.count > 1 else { return .ignored }
            selection = anchor.map { [$0] } ?? []
            return .handled
        }
        .onAppear { select(items.first?.0.id); focused = true }
        .onChange(of: bucket) { select(model.photos(in: bucket).first?.0.id) }
        .sheet(item: Binding(get: { detail.map(IDBox.init) }, set: { detail = $0?.id })) { box in
            PhotoDetail(photoID: box.id) { detail = nil }
                .environmentObject(model)
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(bucket.title).font(.title2.weight(.semibold))
            Text("\(count)")
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            if bucket == .review && count > 0 {
                Text("Press A for me, R for not me. ⌘-click or ⇧-click to pick several.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ThresholdMenu()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var emptyTitle: String {
        switch bucket {
        case .review: "Nothing to review"
        case .mine: "No photos of you yet"
        case .others: "No other photos"
        }
    }

    private var emptyText: String {
        switch bucket {
        case .review: "Every photo is filed. Lower the review cutoff to double-check more."
        case .mine: "Import an album and pick yourself to get started."
        case .others: "Photos without you will show up here."
        }
    }

    private func selectionBar(_ items: [(Photo, PhotoMatch)]) -> some View {
        let anyDecided = selection.contains { model.lib.verdicts[$0] != nil }
        return HStack(spacing: 10) {
            Text("\(selection.count) selected").font(.callout.weight(.medium)).monospacedDigit()
            Button("Deselect") { select(anchor) }
                .buttonStyle(.link)
                .help("Keep only one photo selected (Esc)")
            Spacer()
            if anyDecided {
                Button { model.undo(Array(selection)) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .help("Clear the decision on the selected photos (U)")
            }
            Button { act(.rejected, in: items) } label: { Label("Not me", systemImage: "xmark") }
                .help("Mark all selected photos as not you (R)")
            Button { act(.approved, in: items) } label: { Label("That's me", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent)
                .help("Mark all selected photos as you (A)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func select(_ id: String?) {
        selection = id.map { [$0] } ?? []
        anchor = id
    }

    private func click(_ id: String, in items: [(Photo, PhotoMatch)]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if mods.contains(.shift), let a = anchor, let i = items.firstIndex(where: { $0.0.id == a }),
                  let j = items.firstIndex(where: { $0.0.id == id }) {
            selection.formUnion(items[min(i, j)...max(i, j)].map(\.0.id))
        } else {
            select(id)
        }
    }

    /// Decides every selected photo, then moves on to the next photo still in this list.
    private func act(_ verdict: Verdict, in items: [(Photo, PhotoMatch)]) {
        let ids = items.map(\.0.id)
        let chosen = ids.filter(selection.contains)
        guard let lastIdx = chosen.last.flatMap(ids.firstIndex(of:)) else { return }
        if chosen.count == 1 { model.decide(chosen[0], verdict) } else { model.decide(chosen, verdict) }
        let remaining = Set(model.photos(in: bucket).map(\.0.id))
        select(ids[(lastIdx + 1)...].first(where: remaining.contains) ?? ids.last(where: remaining.contains))
    }

    private func move(_ delta: Int, in items: [(Photo, PhotoMatch)]) {
        let ids = items.map(\.0.id)
        guard !ids.isEmpty else { return }
        let idx = anchor.flatMap { ids.firstIndex(of: $0) } ?? 0
        select(ids[min(max(idx + delta, 0), ids.count - 1)])
    }
}

struct IDBox: Identifiable { var id: String }

struct PhotoCell: View {
    @EnvironmentObject var model: AppModel
    var photo: Photo
    var match: PhotoMatch
    var bucket: Bucket
    var selected: Bool
    var verdict: Verdict?
    var height: CGFloat = 150
    var showsCaption = false
    @State private var image: NSImage?
    @State private var face: NSImage?
    @State private var loading = true
    @State private var hovering = false

    private let corner: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            if showsCaption {
                Text(photo.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(.isButton)
        .task(id: photo.localPath) {
            loading = true
            image = await ThumbnailCache.shared.thumbnail(path: photo.localPath)
            loading = false
            if bucket != .others, let fid = match.bestFaceID, let f = model.face(fid) {
                face = await ThumbnailCache.shared.face(path: photo.localPath, box: f.box)
            }
        }
        .help(photo.name)
    }

    /// Fixed-height frame, full column width. The photo fills it and is clipped, so portrait and
    /// landscape shots line up without distortion, and the frame is the same size while loading.
    private var thumbnail: some View {
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay { photoContent }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .topTrailing) { faceBadge }
            .overlay(alignment: .bottom) { controls }
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
            )
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    @ViewBuilder private var photoContent: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityLabel(photo.name)
        } else if loading {
            Rectangle().fill(.quaternary)
                .overlay { ProgressView().controlSize(.small) }
        } else {
            Rectangle().fill(.quaternary)
                .overlay {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Photo unavailable")
                }
        }
    }

    /// Close-up of the matched face: in group shots it's tiny in the thumbnail.
    /// The ring uses the verdict color so mine / not mine reads at a glance.
    @ViewBuilder private var faceBadge: some View {
        if let face, bucket != .others {
            let size = max(min(height * 0.36, 56), 30)
            Image(nsImage: face)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(ringColor, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .padding(6)
                .accessibilityHidden(true)
        }
    }

    private var ringColor: Color {
        switch verdict {
        case .approved: .green
        case .rejected: .red
        case nil: .white
        }
    }

    private var controls: some View {
        HStack {
            ScoreBadge(score: match.score, verdict: verdict)
            Spacer()
            if hovering || selected {
                if verdict != nil {
                    Button { model.undo(photo.id) } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                        .help("Undo decision (U)")
                        .accessibilityLabel("Undo decision")
                } else {
                    if bucket != .others {
                        Button { model.decide(photo.id, .rejected) } label: { Image(systemName: "xmark.circle.fill") }
                            .help("Not me (R)")
                            .accessibilityLabel("Not me")
                    }
                    if bucket != .mine {
                        Button { model.decide(photo.id, .approved) } label: { Image(systemName: "checkmark.circle.fill") }
                            .help("That's me (A)")
                            .accessibilityLabel("That's me")
                    }
                }
            }
        }
        .font(.title2)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .shadow(radius: 2)
        .padding(8)
    }
}

struct ScoreBadge: View {
    var score: Float
    var verdict: Verdict?
    var body: some View {
        Group {
            switch verdict {
            case .approved: Label("You", systemImage: "checkmark")
            case .rejected: Label("Not you", systemImage: "xmark")
            case nil: Text(score < 0 ? "no face" : "\(Int((max(score, 0) * 100).rounded()))%")
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }
}

struct ThresholdMenu: View {
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: { Label("Cutoffs", systemImage: "slider.horizontal.3") }
            .popover(isPresented: $shown) { CutoffControls().padding(16).frame(width: 320) }
    }
}

struct CutoffControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.lib.settings
        VStack(alignment: .leading, spacing: 10) {
            Text("Auto-file as mine at \(Int(s.autoThreshold * 100))% or more")
            Slider(value: Binding(get: { Double(s.autoThreshold) },
                                  set: { model.setThresholds(auto: Float($0), review: s.reviewThreshold) }), in: 0.3...0.9)
            Text("Ask me between \(Int(s.reviewThreshold * 100))% and \(Int(s.autoThreshold * 100))%")
            Slider(value: Binding(get: { Double(s.reviewThreshold) },
                                  set: { model.setThresholds(auto: s.autoThreshold, review: Float($0)) }), in: 0.15...Double(s.autoThreshold))
            Text("Scores are how closely a face matches yours. 50% is a confident match for this model.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Full-size view

/// Full photo with every detected face outlined. Clicking a face says "this one is me",
/// which also teaches FaceOrb which face to learn from in group shots.
struct PhotoDetail: View {
    @EnvironmentObject var model: AppModel
    var photoID: String
    var close: () -> Void
    @State private var image: NSImage?

    var body: some View {
        let photo = model.photo(photoID)
        let match = model.matches[photoID]
        VStack(spacing: 0) {
            HStack {
                Text(photo?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(photo?.name ?? "")
                Spacer()
                Button("Not me") { model.decide(photoID, .rejected); close() }
                Button("That's me") { model.decide(photoID, .approved); close() }.keyboardShortcut(.defaultAction)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityLabel(photo?.name ?? "Photo")
                        .overlay {
                            GeometryReader { geo in
                                ForEach(model.faces(in: photoID)) { face in
                                    let r = CGRect(x: face.box.x * geo.size.width, y: face.box.y * geo.size.height,
                                                   width: face.box.width * geo.size.width, height: face.box.height * geo.size.height)
                                    let best = face.id == match?.bestFaceID
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(best ? Color.yellow : .white.opacity(0.7), lineWidth: best ? 3 : 1.5)
                                        .contentShape(Rectangle())
                                        .frame(width: r.width, height: r.height)
                                        .position(x: r.midX, y: r.midY)
                                        .onTapGesture { model.decide(photoID, .approved, faceID: face.id); close() }
                                        .help("This is me")
                                }
                            }
                        }
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 20).padding(.top, 16)
            Text("Yellow is the face FaceOrb thinks is you. Click a different face if it picked the wrong one.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 760, minHeight: 600)
        .task {
            if let p = photo { image = await ThumbnailCache.shared.thumbnail(path: p.localPath, maxPixel: 1600) }
        }
    }
}
