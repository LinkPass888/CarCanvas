import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO

/// Original layout: Devices / Wallpaper Preview (with the Dark and Light slots)
/// / Actions / export name, plus the create-local footer.
struct WallpaperView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var history: HistoryStore
    @StateObject private var preview = WallpaperPreviewStore()

    @State private var pickerItem: PhotosPickerItem?
    @State private var createDark = true
    @State private var createLight = true
    @State private var message: String?
    @State private var messageIsError = false
    @State private var isWorking = false
    @State private var hasLoadedOnce = false

    var body: some View {
        Form {

            Section {
                if preview.isSearching {
                    HStack { ProgressView(); Text(L("WALLPAPER_SEARCHING_TITLE")) }
                } else {
                    HStack(spacing: 12) {
                        CPBitmapPreviewView(title: L("WALLPAPER_PREVIEW_DARK"),
                                            image: preview.darkImage)
                        CPBitmapPreviewView(title: L("WALLPAPER_PREVIEW_LIGHT"),
                                            image: preview.lightImage)
                    }
                    if !preview.hasCacheFiles {
                        Text(cacheHint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("WALLPAPER_SECTION_PREVIEW"))
            } footer: {
                Text(previewFooter)
            }

            // Export name comes BEFORE the create button, so it is set first.
            Section(L("WALLPAPER_EXPORT_FILENAME")) {
                TextField(L("WALLPAPER_EXPORT_FILENAME_TITLE"), text: $settings.exportBaseName)
                Text(L("WALLPAPER_EXPORT_FILENAME_FOOTER"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("WALLPAPER_SECTION_ACTIONS")) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(L("WALLPAPER_CHOOSE"), systemImage: "photo.on.rectangle")
                }
                Toggle(L("WALLPAPER_SET_DARK"), isOn: $createDark)
                Toggle(L("WALLPAPER_SET_LIGHT"), isOn: $createLight)

                Button {
                    createLocal()
                } label: {
                    Label(L("WALLPAPER_NEW_CPBITMAP"), systemImage: "plus.circle")
                }
                .disabled(pickerItem == nil || isWorking || (!createDark && !createLight))

                Text(L("WALLPAPER_NEW_CPBITMAP_FOOTER"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("WALLPAPER_TITLE"))
        .alert(messageIsError ? L("COMMON_ERROR") : L("WALLPAPER_CREATE_DONE_TITLE"),
               isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L("COMMON_OK")) { message = nil }
        } message: { Text(message ?? "") }
        .overlay { if isWorking { ProgressView(L("COMMON_PLEASE_WAIT")) } }
        // Load once per launch. `.task` fires again every time the tab is
        // re-selected, which used to wipe the loaded previews and re-run the
        // whole container lookup.
        .task {
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true
            refresh()
        }
        .refreshable { refresh(forceRefresh: true) }
        .onChange(of: pickerItem) { _, _ in loadPickedImage() }
    }

    private var previewFooter: String {
        guard let cacheDirectory = preview.cacheDirectory else {
            return cacheHint
        }
        return LF("WALLPAPER_FOOTER_PREVIEW",
                  preview.wallpaperName ?? L("WALLPAPER_NAME_UNAVAILABLE"),
                  cacheDirectory)
    }

    /// "Connected but no cache" is NOT the same as "no CarPlay device".
    private var cacheHint: String {
        if preview.pairingProbeFailed { return L("WALLPAPER_CACHE_PROBE_FAILED") }
        if preview.pairings > 0 { return L("WALLPAPER_PAIRED_NO_CACHE") }
        return L("WALLPAPER_NO_DEVICES")
    }

    private func refresh(forceRefresh: Bool = false) {
        if forceRefresh { ContainerResolver.invalidateCache() }
        preview.beginSearching()
        Task {
            // Heavy container work off the main actor, then publish on main.
            let loaded = await Task.detached(priority: .userInitiated) {
                WallpaperPreviewStore.loadFromDevice()
            }.value
            await MainActor.run { preview.apply(loaded) }
        }
    }

    /// Shows the picked image in both slots as soon as it is chosen, so the
    /// preview reflects the selection before anything is written.
    private func loadPickedImage() {
        guard let item = pickerItem else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            await MainActor.run { preview.setPickedImage(image) }
        }
    }

    private func createLocal() {
        guard let item = pickerItem else { return }
        isWorking = true
        var appearances: Set<WallpaperTarget.Appearance> = []
        if createDark { appearances.insert(.dark) }
        if createLight { appearances.insert(.light) }

        Task {
            var resultMessage: String
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CCError.renderFailed
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cc-\(UUID().uuidString).img")
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }

                let entry = try await Task.detached(priority: .userInitiated) {
                    try WallpaperService().createLocal(imageURL: tmp, appearances: appearances)
                }.value
                resultMessage = L("WALLPAPER_EXPORT_SUCCESS") + "\n" + entry.baseName
                messageIsError = false
            } catch {
                resultMessage = error.localizedDescription
                messageIsError = true
            }
            await MainActor.run {
                message = resultMessage
                isWorking = false
            }
        }
    }
}
