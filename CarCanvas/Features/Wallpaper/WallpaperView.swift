import SwiftUI
import PhotosUI
import CoreGraphics

/// Keep the original two-slot preview, name field and create-local footer.
/// Each slot is now its own picker; mode is implicit in the slot/destination.
struct WallpaperView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var preview = WallpaperPreviewStore()
    @State private var darkPickerItem: PhotosPickerItem?
    @State private var lightPickerItem: PhotosPickerItem?
    @State private var darkPhotoURL: URL?
    @State private var lightPhotoURL: URL?
    @State private var loadingDark = false
    @State private var loadingLight = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var isWorking = false
    @State private var hasLoadedOnce = false
    @State private var previewRevision = 0

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    PhotosPicker(selection: $darkPickerItem, matching: .images) {
                        CPBitmapPreviewView(title: L("WALLPAPER_PREVIEW_DARK"), image: preview.darkImage)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("WALLPAPER_PICK_DARK"))
                    PhotosPicker(selection: $lightPickerItem, matching: .images) {
                        CPBitmapPreviewView(title: L("WALLPAPER_PREVIEW_LIGHT"), image: preview.lightImage)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("WALLPAPER_PICK_LIGHT"))
                }
                .disabled(isWorking)
                Text(L("WALLPAPER_PICK_PAIR_HINT")).font(.caption).foregroundStyle(.secondary)
                if preview.isSearching || loadingDark || loadingLight {
                    HStack { ProgressView(); Text(L("COMMON_PLEASE_WAIT")).font(.caption) }
                } else if !preview.hasCacheFiles {
                    Text(cacheHint).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(L("WALLPAPER_SECTION_PREVIEW"))
            } footer: {
                Text(previewFooter)
            }

            Section(L("WALLPAPER_SECTION_ACTIONS")) {
                HStack {
                    Text(L("WALLPAPER_FILE_NAME"))
                    Spacer()
                    TextField(L("WALLPAPER_FILE_NAME"), text: $settings.exportBaseName)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
                Text(L("WALLPAPER_NEW_CPBITMAP_FOOTER"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button { createLocal() } label: {
                    Label(L("WALLPAPER_NEW_CPBITMAP"), systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(darkPhotoURL == nil || lightPhotoURL == nil || isWorking || loadingDark || loadingLight)
            }
        }
        .navigationTitle(L("ROOT_NEW_WALLPAPER"))
        .alert(messageIsError ? L("COMMON_ERROR") : L("WALLPAPER_CREATE_DONE_TITLE"),
               isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L("COMMON_OK")) { message = nil }
        } message: { Text(message ?? "") }
        .overlay { if isWorking { ProgressView(L("COMMON_PLEASE_WAIT")) } }
        .task {
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true
            await refresh()
        }
        .refreshable { await refresh(forceRefresh: true) }
        .task(id: darkPickerItem) { await loadPickedImage(darkPickerItem, appearance: .dark) }
        .task(id: lightPickerItem) { await loadPickedImage(lightPickerItem, appearance: .light) }
        .onReceive(NotificationCenter.default.publisher(for: .carCanvasCacheDidChange)) { _ in
            Task { await refresh() }
        }
    }

    private var previewFooter: String {
        guard let directory = preview.cacheDirectory else { return cacheHint }
        return LF("WALLPAPER_FOOTER_PREVIEW", preview.wallpaperName ?? L("WALLPAPER_NAME_UNAVAILABLE"), directory)
    }
    private var cacheHint: String {
        if preview.pairingProbeFailed { return L("WALLPAPER_CACHE_PROBE_FAILED") }
        if preview.pairings > 0 { return L("WALLPAPER_PAIRED_NO_CACHE") }
        return L("WALLPAPER_NO_DEVICES")
    }

    @MainActor
    private func refresh(forceRefresh: Bool = false) async {
        previewRevision += 1
        let revision = previewRevision, channelOrder = settings.channelOrder
        preview.beginSearching()
        let loaded = await Task.detached(priority: .userInitiated) {
            WallpaperPreviewStore.loadFromDevice(forceRefresh: forceRefresh, channelOrder: channelOrder)
        }.value
        guard revision == previewRevision else { return }
        preview.apply(loaded)
    }

    @MainActor
    private func loadPickedImage(_ item: PhotosPickerItem?, appearance: WallpaperTarget.Appearance) async {
        guard let item else { return }
        if appearance == .dark { loadingDark = true } else { loadingLight = true }
        defer {
            if (appearance == .dark ? darkPickerItem : lightPickerItem) == item {
                if appearance == .dark { loadingDark = false } else { loadingLight = false }
            }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cc-photo-\(UUID().uuidString).img")
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: temporary) } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CCError.renderFailed }
            try Task.checkCancellation()
            let image = try await Task.detached(priority: .userInitiated) {
                guard let thumbnail = WallpaperService.photoPreview(data: data) else { throw CCError.renderFailed }
                try data.write(to: temporary, options: .atomic)
                return thumbnail
            }.value
            try Task.checkCancellation()
            guard (appearance == .dark ? darkPickerItem : lightPickerItem) == item else { return }
            let previous = appearance == .dark ? darkPhotoURL : lightPhotoURL
            if appearance == .dark { darkPhotoURL = temporary } else { lightPhotoURL = temporary }
            retained = true
            if let previous { try? FileManager.default.removeItem(at: previous) }
            preview.setPickedImage(image, appearance: appearance)
        } catch is CancellationError {
            // A newer pick/view lifetime owns the slot now.
        } catch {
            guard (appearance == .dark ? darkPickerItem : lightPickerItem) == item else { return }
            messageIsError = true
            message = error.localizedDescription
        }
    }

    private func createLocal() {
        guard let darkURL = darkPhotoURL, let lightURL = lightPhotoURL, !isWorking else { return }
        let baseName = settings.exportBaseName, channelOrder = settings.channelOrder
        isWorking = true
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try WallpaperService(channelOrder: channelOrder)
                        .createLocal(darkImageURL: darkURL, lightImageURL: lightURL, baseName: baseName)
                }.value
                message = L("WALLPAPER_ADDED_TO_WALLPAPERS")
                messageIsError = false
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            isWorking = false
        }
    }
}
