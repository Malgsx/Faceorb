import AppKit
import FaceOrbCore
import FaceOrbKit
import SwiftUI

/// "Save my photos": format, size, which photos, naming, and where. Checks space before writing.
struct ExportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions()
    @State private var destination = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())

    var body: some View {
        let items = model.exportPlan(options)
        let needed = ExportPlanner.estimatedBytes(items, options)
        let free = DiskCheck.freeBytes(at: destination)
        let tooFull = free.map { $0 < needed + DiskCheck.safetyMargin } ?? false

        VStack(alignment: .leading, spacing: 0) {
            Text("Save my photos").font(.title2.weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                Picker("Photos", selection: $options.scope) {
                    ForEach(ExportOptions.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Format", selection: $options.format) {
                    ForEach(ExportOptions.Format.allCases, id: \.self) { f in
                        Text(f.title).tag(f).disabled(!ImageExporter.canWrite(f))
                    }
                }
                if options.format.isLossy {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $options.quality, in: 0.5...1)
                            Text("\(Int(options.quality * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Picker("Size", selection: Binding(get: { options.maxPixel ?? 0 }, set: { options.maxPixel = $0 == 0 ? nil : $0 })) {
                    ForEach(ExportOptions.sizeChoices, id: \.0) { label, px in Text(label).tag(px ?? 0) }
                }
                Picker("File names", selection: $options.naming) {
                    ForEach(ExportOptions.Naming.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Save to") {
                    HStack {
                        Text(destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                TextField("In a new folder named", text: $options.subfolder)
                if let first = items.first {
                    LabeledContent("Example", value: first.fileName)
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(items.count) photos, about \(DiskCheck.describe(needed))"
                     + (free.map { " · \(DiskCheck.describe($0)) free on this disk" } ?? ""))
                    .font(.callout).foregroundStyle(.secondary)
                if tooFull {
                    Label("Not enough free space. When a Mac's disk is full, files can't be saved or even deleted properly. Free some space or pick a smaller size/format.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if options.format == .original && options.maxPixel != nil {
                    Text("Resized copies are re-encoded in the original format.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)

            HStack {
                if let last = model.lastExport, !last.files.isEmpty {
                    Button("Delete last saved copies (\(last.files.count))", role: .destructive) { model.deleteLastExport() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save \(items.count) photos") {
                    model.export(options, to: destination)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(items.isEmpty || tooFull || model.activity.isBusy)
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear { options = model.exportOptions }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
