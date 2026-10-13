import AppKit
import FaceOrbCore
import FaceOrbKit
import SwiftUI

/// The menu bar dropdown. Everything the review window and web app can do is here too:
/// import, a one-at-a-time review card, browsing the three piles, picking yourself, cutoffs and privacy.
struct OrbPopover: View {
    enum Tab: String, CaseIterable, Identifiable {
        case home = "Home", review = "Review", photos = "Photos", you = "You", privacy = "Privacy"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .home: "circle.circle"
            case .review: "questionmark.circle"
            case .photos: "photo.on.rectangle"
            case .you: "person.crop.circle"
            case .privacy: "hand.raised"
            }
        }
    }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var windows: AppWindows
    @AppStorage("dropdownTab") private var tab: Tab = .home

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding([.horizontal, .top], 16).padding(.bottom, 10)
            updateBanner
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.rawValue, systemImage: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case .home: HomeTab(go: { tab = $0 })
                case .review: ReviewCardTab(go: { tab = $0 })
                case .photos: PhotosTab()
                case .you: EnrollView(compact: true)
                case .privacy: PrivacySettings(showCutoffs: true)
                }
            }
            .frame(height: 400)
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 420)
    }

    @ViewBuilder private var updateBanner: some View {
        if updater.canUpdate {
            switch updater.state {
            case .idle where updater.updateAvailable:
                banner {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                    Text("Relaunch to update")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Button("Update") { updater.update() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.activity.isBusy)
                        .help(model.activity.isBusy ? "Waiting for the current task to finish." : "Rebuild FaceOrb and reopen it")
                }
            case .updating:
                banner {
                    ProgressView().controlSize(.small)
                    Text("Rebuilding FaceOrb… this can take a minute. It will reopen by itself.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            case .failed(let message):
                banner {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(message).font(.caption).lineLimit(2).truncationMode(.tail)
                                .help(message)
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Button("Show Log") { NSWorkspace.shared.open(updater.logURL) }
                                .controlSize(.small)
                            Button("Try Again") { updater.update() }
                                .controlSize(.small)
                            Button { updater.dismissError() } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .help("Dismiss")
                                .accessibilityLabel("Dismiss update error")
                        }
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Orb(busy: model.activity.isBusy).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let fraction = model.activity.fraction {
                    ProgressView(value: fraction).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if model.activity.isBusy {
                Button("Stop") { model.cancel() }.controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { open(model.isEnrolled ? .bucket(.review) : .people) } label: { Label("Window", systemImage: "macwindow") }
                .disabled(model.lib.photos.isEmpty)
                .help("Open the full review window")
            Button { model.openWebApp() } label: { Label("Browser", systemImage: "safari") }
                .disabled(!model.webAppEnabled)
                .help(model.webAppEnabled ? "Open FaceOrb in your browser (only this Mac can reach it)" : "Turn on the web app in Privacy")
            Button { windows.showPhoneSetup() } label: { Label("Phone", systemImage: "iphone") }
                .help("Configure secure access from your phone")
            Spacer()
            Button { windows.dropdownPinned.toggle() } label: { Image(systemName: windows.dropdownPinned ? "pin.fill" : "pin") }
                .help(windows.dropdownPinned ? "Unpin: close when clicking other apps" : "Keep open while using other apps")
                .accessibilityLabel(windows.dropdownPinned ? "Unpin dropdown" : "Keep dropdown open")
            Button { updater.relaunch() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(updater.state == .updating)
                .help("Relaunch FaceOrb")
                .accessibilityLabel("Relaunch FaceOrb")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit FaceOrb")
        }
        .buttonStyle(.borderless)
    }

    private var headline: String {
        if model.activity.isBusy { return model.activity.label }
        if let e = model.lastError { return e }
        if model.lib.photos.isEmpty { return "Paste an album link or pick a folder to start." }
        if !model.isEnrolled { return "\(model.lib.photos.count) photos scanned. Show FaceOrb who you are." }
        let r = model.count(.review)
        return r > 0 ? "\(r) photos need a quick yes or no." : "All sorted. \(model.count(.mine)) photos of you."
    }

    private func open(_ section: ReviewSection) {
        windows.showReview(section)
    }
}

struct HomeTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var windows: AppWindows
    var go: (OrbPopover.Tab) -> Void
    @State private var link = ""
    /// What "Start over" or "Remove…" is asking to clear: one album, or every album when `source` is nil.
    @State private var clearing: ClearRequest?
    @State private var forgetMeToo = false

    private struct ClearRequest {
        var source: String?
        var title: String
        var photoCount: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.lib.photos.isEmpty {
                HStack(spacing: 8) {
                    CountChip(bucket: .review, count: model.count(.review)) { go(.review) }
                    CountChip(bucket: .mine, count: model.count(.mine)) { go(.photos) }
                    CountChip(bucket: .others, count: model.count(.others)) { go(.photos) }
                }
                if model.isEnrolled && model.count(.mine) > 0 {
                    Button { saveMyPhotos() } label: { Label("Save my photos…", systemImage: "square.and.arrow.down") }
                        .disabled(model.activity.isBusy)
                }
                if !model.isEnrolled {
                    Button { go(.you) } label: { Label("Pick yourself to start sorting", systemImage: "person.crop.circle.badge.questionmark") }
                        .buttonStyle(.borderedProminent)
                }
            }

            if let clearing {
                clearConfirmation(clearing)
            } else {
                addAlbum
            }

            if !model.albumRows.isEmpty || !model.lib.exports.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.albumRows.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Albums").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                                ForEach(model.albumRows) { row in albumRow(row) }
                            }
                        }
                        if !model.lib.exports.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Saved to").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                                ForEach(model.lib.exports, id: \.folder) { record in exportRow(record) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            Spacer(minLength: 0)
            Label("Faces are analysed on this Mac. Nothing is uploaded.", systemImage: "lock.fill")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var addAlbum: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Add an album").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.lib.photos.isEmpty {
                    Button("Start over…") {
                        forgetMeToo = false
                        clearing = ClearRequest(source: nil, title: "all albums", photoCount: model.lib.photos.count)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(model.activity.isBusy)
                    .help("Clear every album so you can add new links or folders from scratch")
                }
            }
            HStack {
            TextField("Album or photo link", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(importLink)
            Button("Import", action: importLink)
                .disabled(link.isEmpty || model.activity.isBusy)
        }
        Button { chooseFolder() } label: { Label("Choose a folder of photos…", systemImage: "folder") }
            .buttonStyle(.link)
            .disabled(model.activity.isBusy)
        }
    }

    /// Inline instead of an alert: alerts and sheets don't attach to the menu bar dropdown.
    private func clearConfirmation(_ request: ClearRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.source == nil ? "Start over with new photos?" : "Remove \(request.title)?",
                  systemImage: "arrow.counterclockwise.circle")
                .font(.callout.weight(.medium))
            Text("Removes \(request.photoCount) photos, their faces and your yes/no decisions\(request.source == nil ? "" : " for this album"). Downloaded copies are deleted; your own folders and saved photos aren't touched.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if request.source == nil {
                Toggle("Also forget my face (pick yourself again)", isOn: $forgetMeToo)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel") { clearing = nil }
                    .keyboardShortcut(.cancelAction)
                Button(request.source == nil ? "Clear Photos" : "Remove", role: .destructive) {
                    model.clearPhotos(sources: request.source.map { [$0] }, keepMe: !forgetMeToo)
                    clearing = nil
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func albumRow(_ row: AppModel.AlbumRow) -> some View {
        let symbol = row.folder != nil ? "folder" : (row.link != nil ? "link" : "photo.stack")
        let trailing = row.folder == nil && row.link != nil ? "arrow.up.forward.square" : "chevron.right"
        let help = row.folder != nil ? "Show in Finder" : (row.link != nil ? "Open in browser" : "Show downloaded copies")
        return PlaceRow(symbol: symbol, title: row.title, detail: row.detail, extra: " · \(row.photoCount) photos",
                        missing: !row.available, trailing: trailing, help: help,
                        action: { model.openAlbum(row) }) {
            if row.folder != nil {
                Button("Show in Finder") { model.openAlbum(row) }
            } else if row.link != nil {
                Button("Open in Browser") { model.openAlbum(row) }
            }
            if row.folder == nil {
                Button("Show Downloaded Copies") { model.revealAlbumCopies(row) }
            }
            Button("Import Again") { model.reimportAlbum(row) }
                .disabled(model.activity.isBusy || (row.folder == nil && row.link == nil))
            if row.folder != nil || row.link != nil {
                Divider()
                Button(row.folder != nil ? "Copy Path" : "Copy Link") { model.copyAlbumLocation(row) }
            }
            Divider()
            Button("Remove from FaceOrb…") {
                forgetMeToo = false
                clearing = ClearRequest(source: row.source, title: row.title, photoCount: row.photoCount)
            }
            .disabled(model.activity.isBusy)
        }
    }

    private func exportRow(_ record: ExportRecord) -> some View {
        let exists = model.exportFolderExists(record)
        let path = (record.folder as NSString).abbreviatingWithTildeInPath
        let date = record.date.formatted(.relative(presentation: .named))
        return PlaceRow(symbol: "folder.fill", title: (record.folder as NSString).lastPathComponent, detail: path,
                        extra: " · \(record.count) photos · \(date)", missing: !exists, trailing: "chevron.right",
                        help: "Show in Finder", action: { model.revealExport(record) }) {
            Button("Show in Finder") { model.revealExport(record) }
            Divider()
            Button("Remove from List") { model.forgetExport(record) }
        }
        .opacity(exists ? 1 : 0.5)
    }

    /// Options live in a sheet on the review window (sheets don't work inside menu bar dropdowns).
    private func saveMyPhotos() {
        windows.showReview(.bucket(.mine))
        model.showExportSheet = true
    }

    private func importLink() {
        guard !link.isEmpty, !model.activity.isBusy else { return }
        model.importLink(link)
        link = ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        panel.message = "FaceOrb reads photos in place. It doesn't copy or change them."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { model.importFolder(url) }
    }
}

/// A full-width, clickable row for a folder, album or saved export, with a hover highlight.
private struct PlaceRow<MenuContent: View>: View {
    var symbol: String
    var title: String
    var detail: String
    var extra: String
    var missing: Bool
    var trailing: String
    var help: String
    var action: () -> Void
    @ViewBuilder var menu: MenuContent
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout).lineLimit(1)
                    secondary
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: trailing).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("\(title), \(missing ? "moved or deleted" : detail)\(extra)")
        .contextMenu { menu }
    }

    private var secondary: Text {
        (missing ? Text("Moved or deleted").foregroundStyle(.orange) : Text(detail).foregroundStyle(.secondary))
            + Text(extra).foregroundStyle(.secondary)
    }
}

/// One photo at a time, biggest-chance-first, with a close-up of the matched face.
struct ReviewCardTab: View {
    @EnvironmentObject var model: AppModel
    var go: (OrbPopover.Tab) -> Void
    @State private var image: NSImage?
    @State private var face: NSImage?

    var body: some View {
        VStack(spacing: 12) {
            if !model.isEnrolled {
                ContentUnavailableView {
                    Label("Who are you?", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Pick yourself first, then FaceOrb will ask about the photos it isn't sure of.")
                } actions: {
                    Button("Pick yourself") { go(.you) }
                }
            } else if let next = model.nextReview {
                let (photo, match) = next
                ZStack(alignment: .topTrailing) {
                    // Fixed-height frame with an aspect-fit photo on a neutral backdrop, so the card never jumps.
                    ZStack {
                        Rectangle().fill(.quaternary)
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit()
                                .accessibilityLabel("Photo to review")
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))

                    // The matched face as an inset circle, with a thin border so it reads on any photo.
                    Group {
                        if let face {
                            Image(nsImage: face).resizable().scaledToFill()
                                .accessibilityLabel("Matched face")
                        } else {
                            ZStack {
                                Rectangle().fill(.quaternary)
                                Image(systemName: "person.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .padding(10)
                    .help("The face FaceOrb matched")
                }
                Text("Is this you? \(Int((max(match.score, 0) * 100).rounded()))% match · \(model.count(.review)) left")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 12) {
                    Button { decide(photo.id, .rejected) } label: { Label("Not me", systemImage: "xmark").frame(maxWidth: .infinity) }
                        .keyboardShortcut("r", modifiers: [])
                    Button { decide(photo.id, .approved) } label: { Label("That's me", systemImage: "checkmark").frame(maxWidth: .infinity) }
                        .keyboardShortcut("a", modifiers: [])
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(.top, 2)
                HStack {
                    Text("A = that's me · R = not me").font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    if let last = model.lastDecided {
                        Button("Undo last") { model.undo(last) }.buttonStyle(.link).keyboardShortcut("u", modifiers: [])
                    }
                }
                .task(id: photo.id) {
                    image = await ThumbnailCache.shared.thumbnail(path: photo.localPath, maxPixel: 900)
                    if let fid = match.bestFaceID, let f = model.face(fid) {
                        face = await ThumbnailCache.shared.face(path: photo.localPath, box: f.box)
                    } else {
                        face = nil
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("All caught up", systemImage: "checkmark.circle")
                } description: {
                    Text("\(model.count(.mine)) photos of you. Nothing needs a decision.")
                } actions: {
                    if let last = model.lastDecided { Button("Undo last") { model.undo(last) } }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func decide(_ id: String, _ verdict: Verdict) {
        model.decide(id, verdict)
        model.lastDecided = id
    }
}

/// The three piles, compact.
struct PhotosTab: View {
    @EnvironmentObject var model: AppModel
    @State private var bucket: Bucket = .mine
    /// Side of one square cell: (420 pt popover - 2 x 12 pt padding - 3 x 8 pt gaps) / 4 columns.
    private static let cell: CGFloat = 93

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $bucket) {
                ForEach([Bucket.mine, .review, .others], id: \.self) { b in Text("\(b.title) \(model.count(b))").tag(b) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            let items = model.photos(in: bucket)
            if items.isEmpty {
                ContentUnavailableView(bucket == .mine ? "No photos of you yet" : "Nothing here", systemImage: bucket.symbol)
            } else {
                ScrollView {
                    // Four equal columns that fill the fixed dropdown width; square cells.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(items, id: \.0.id) { photo, match in
                            PhotoCell(photo: photo, match: match, bucket: bucket, selected: false,
                                      verdict: model.lib.verdicts[photo.id], height: Self.cell)
                                .frame(height: Self.cell)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }
}

struct CountChip: View {
    var bucket: Bucket
    var count: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(count)").font(.title3.weight(.semibold)).monospacedDigit()
                Text(bucket.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(bucket.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

extension Bucket {
    var tint: Color {
        switch self {
        case .mine: .green
        case .review: .orange
        case .others: .gray
        }
    }
    var symbol: String {
        switch self {
        case .mine: "person.crop.circle.badge.checkmark"
        case .review: "questionmark.circle"
        case .others: "person.2"
        }
    }
}

/// The orb: a glassy sphere with a face, whose rim spins while FaceOrb is working.
/// A spinning chrome ball: its reflections turn slowly, faster while FaceOrb is working.
struct Orb: View {
    var busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            ball(turn: reduceMotion ? 0.1 : (seconds / (busy ? 1.5 : 8)).truncatingRemainder(dividingBy: 1))
        }
        .shadow(color: .black.opacity(0.3), radius: busy ? 6 : 3, y: 2)
        .shadow(color: .accentColor.opacity(busy ? 0.5 : 0), radius: 10)
        .animation(.easeInOut(duration: 0.4), value: busy)
        .accessibilityHidden(true)
    }

    private func ball(turn: Double) -> some View {
        let metal: [Color] = [0.96, 0.5, 0.86, 0.32, 0.92, 0.55, 0.96].map { Color(white: $0) }
        return ZStack {
            // Reflections all the way round; turning them makes the ball look like it spins.
            Circle().fill(AngularGradient(colors: metal, center: .center, angle: .degrees(turn * 360)))
            // Blend the reflections together in the middle, so it reads as a ball rather than a knob.
            Circle().fill(RadialGradient(colors: [Color(white: 0.78).opacity(0.95), Color(white: 0.78).opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 16))
            // Shade the edge so it reads as a sphere lit from the top left.
            Circle().fill(RadialGradient(stops: [.init(color: .clear, location: 0),
                                                 .init(color: .black.opacity(0.15), location: 0.6),
                                                 .init(color: .black.opacity(0.55), location: 1)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 30))
            Circle().fill(RadialGradient(colors: [.white.opacity(0.95), .white.opacity(0)],
                                         center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: 11))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .black.opacity(0.35)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
    }
}
