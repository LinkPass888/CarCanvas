import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct WallpaperView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var history: HistoryStore
    @State private var pickerItem: PhotosPickerItem?
    @State private var createDark = true
    @State private var createLight = true
    @State private var message: String?
    @State private var isWorking = false
    @State private var preview: CGImage?

    var body: some View {
        Form {
            Section { StatusBanner() }

            Section(L("WALLPAPER_SECTION_ACTIONS")) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(L("WALLPAPER_CHOOSE"), systemImage: "photo.on.rectangle")
                }
                Toggle(L("WALLPAPER_SET_DARK"), isOn: $createDark)
                Toggle(L("WALLPAPER_SET_LIGHT"), isOn: $createLight)
                Button {
                    createLocal()
                } label: {
                    Label(L("WALLPAPER_CREATE_LOCAL"), systemImage: "square.and.arrow.down")
                }
                .disabled(pickerItem == nil || isWorking || (!createDark && !createLight))
            }

            Section("CPBitmap preview") {
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Load a cache template to preview channel order and geometry.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Refresh preview") { loadPreview() }
            }

            Section(L("WALLPAPER_EXPORT_FILENAME")) {
                TextField(L("WALLPAPER_EXPORT_FILENAME_TITLE"), text: $settings.exportBaseName)
                Text(L("WALLPAPER_EXPORT_FILENAME_FOOTER"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text(L("WALLPAPER_CREATE_LOCAL_FOOTER"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("WALLPAPER_TITLE"))
        .alert(L("COMMON_ERROR"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L("COMMON_OK")) { message = nil }
        } message: { Text(message ?? "") }
        .overlay { if isWorking { ProgressView(L("COMMON_PLEASE_WAIT")) } }
    }

    private func createLocal() {
        guard let item = pickerItem else { return }
        isWorking = true
        var appearances: Set<WallpaperTarget.Appearance> = []
        if createDark { appearances.insert(.dark) }
        if createLight { appearances.insert(.light) }

        Task.detached(priority: .userInitiated) {
            var resultMessage: String
            do {
                let data = try await item.loadTransferable(type: Data.self)
                guard let data else { throw CCError.renderFailed }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cc-\(UUID().uuidString).img")
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }

                let entry = try WallpaperService().createLocal(imageURL: tmp,
                                                               appearances: appearances)
                resultMessage = L("WALLPAPER_EXPORT_SUCCESS") + "\n" + entry.baseName
            } catch {
                resultMessage = error.localizedDescription
            }
            await MainActor.run {
                message = resultMessage
                isWorking = false
            }
        }
    }

    private func loadPreview() {
        Task.detached(priority: .userInitiated) {
            let image = try? WallpaperService().loadTemplate().preview()
            await MainActor.run { preview = image }
        }
    }
}
