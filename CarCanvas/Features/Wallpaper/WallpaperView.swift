import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Original layout: three sections — CarPlay Devices, Wallpaper Preview,
/// Actions — plus the export-name row and the clear-data footer.
struct WallpaperView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var history: HistoryStore
    @StateObject private var deviceStore = CarPlayDeviceStore()

    @State private var pickerItem: PhotosPickerItem?
    @State private var destinations: Set<WallpaperTarget.Appearance> = [.dark, .light]
    @State private var cacheFiles: [WallpaperTarget] = []
    @State private var isScanning = false
    @State private var message: String?
    @State private var isWorking = false
    @State private var showClearConfirm = false
    @State private var showDestinationSheet = false

    var body: some View {
        Form {
            devicesSection
            previewSection
            actionsSection
            exportNameSection
            clearSection
        }
        .navigationTitle(L("WALLPAPER_TITLE"))
        .disabled(isWorking)
        .alert(L("COMMON_ERROR"), isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L("COMMON_OK")) { message = nil }
        } message: { Text(message ?? "") }
        .confirmationDialog(L("WALLPAPER_CLEAR_CONFIRM_TITLE"), isPresented: $showClearConfirm) {
            Button(L("WALLPAPER_CLEAR"), role: .destructive) { settings.clearSavedData() }
        } message: { Text(L("WALLPAPER_CLEAR_CONFIRM_MESSAGE")) }
        .sheet(isPresented: $showDestinationSheet) {
            ExportDestinationSheet(entry: nil) { summary in message = summary }
        }
        .overlay { if isWorking { ProgressView(L("COMMON_PLEASE_WAIT")) } }
        .task { refresh() }
        .refreshable { refresh() }
    }

    // MARK: - Sections

    private var devicesSection: some View {
        Section {
            if deviceStore.isSearching {
                HStack { ProgressView(); Text(L("WALLPAPER_SEARCHING_TITLE")) }
            } else if deviceStore.devices.isEmpty {
                Text(L("WALLPAPER_NO_DEVICES")).foregroundStyle(.secondary)
            } else {
                ForEach(deviceStore.devices) { device in
                    Button {
                        deviceStore.selectedDeviceID = device.id
                    } label: {
                        HStack {
                            Text(device.name)
                            Spacer()
                            if deviceStore.selectedDeviceID == device.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(L("WALLPAPER_SECTION_DEVICES"))
        } footer: {
            Text(L("WALLPAPER_FOOTER_DEVICES"))
        }
    }

    private var previewSection: some View {
        Section {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(L("WALLPAPER_CHOOSE"), systemImage: "photo.on.rectangle")
            }
            Picker(L("WALLPAPER_SECTION_PREVIEW"), selection: $destinations) {
                Text(L("WALLPAPER_SET_DARK")).tag(Set<WallpaperTarget.Appearance>([.dark]))
                Text(L("WALLPAPER_SET_LIGHT")).tag(Set<WallpaperTarget.Appearance>([.light]))
                Text(L("WALLPAPER_SET_BOTH")).tag(Set<WallpaperTarget.Appearance>([.dark, .light]))
            }
        } header: {
            Text(L("WALLPAPER_SECTION_PREVIEW"))
        } footer: {
            if isScanning {
                Text(L("WALLPAPER_SEARCHING_TITLE"))
            } else if cacheFiles.isEmpty {
                Text(L("WALLPAPER_CACHE_NOT_FOUND"))
            } else {
                Text(LF("WALLPAPER_FOOTER_PREVIEW",
                        cacheFiles.first?.fileName ?? L("WALLPAPER_NAME_UNAVAILABLE"),
                        cacheFiles.first?.path ?? "—"))
            }
        }
    }

    private var actionsSection: some View {
        Section(L("WALLPAPER_SECTION_ACTIONS")) {
            Button {
                createLocal()
            } label: {
                Label(L("WALLPAPER_CREATE_LOCAL"), systemImage: "square.and.arrow.down")
            }
            .disabled(pickerItem == nil || destinations.isEmpty)

            Button {
                applyAndExport()
            } label: {
                Label(L("WALLPAPER_APPLY_AND_EXPORT"), systemImage: "arrow.down.doc")
            }
            .disabled(cacheFiles.isEmpty || destinations.isEmpty)

            Button {
                exportCurrent()
            } label: {
                Label(L("WALLPAPER_EXPORT_CURRENT"), systemImage: "square.and.arrow.up")
            }

            Text(L("WALLPAPER_CREATE_LOCAL_FOOTER"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var exportNameSection: some View {
        Section(L("WALLPAPER_EXPORT_FILENAME")) {
            TextField(L("WALLPAPER_EXPORT_FILENAME_TITLE"), text: $settings.exportBaseName)
            Text(L("WALLPAPER_EXPORT_FILENAME_FOOTER"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var clearSection: some View {
        Section {
            Button(L("WALLPAPER_CLEAR_SAVED_DATA"), role: .destructive) { showClearConfirm = true }
            Text(L("WALLPAPER_FOOTER_CLEAR"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func refresh() {
        deviceStore.refresh()
        isScanning = true
        Task {
            let files = await Task.detached(priority: .userInitiated) {
                (try? ContainerResolver().resolve().files) ?? []
            }.value
            cacheFiles = files
            isScanning = false
        }
    }

    private func createLocal() {
        guard let item = pickerItem else { return }
        isWorking = true
        let chosen = destinations
        Task {
            var outcome: String
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CCError.renderFailed
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cc-\(UUID().uuidString).img")
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let entry = try await Task.detached(priority: .userInitiated) {
                    try WallpaperService().createLocal(imageURL: tmp, appearances: chosen)
                }.value
                outcome = L("WALLPAPER_EXPORT_SUCCESS") + "\n" + entry.baseName
            } catch {
                outcome = error.localizedDescription
            }
            message = outcome
            isWorking = false
        }
    }

    private func applyAndExport() {
        guard !cacheFiles.isEmpty else { message = L("WALLPAPER_CACHE_NOT_FOUND"); return }
        showDestinationSheet = true
    }

    private func exportCurrent() {
        guard !cacheFiles.isEmpty else { message = L("WALLPAPER_EXPORT_NOTHING"); return }
        isWorking = true
        let files = cacheFiles
        let baseName = settings.exportBaseName
        Task {
            var outcome: String
            do {
                let count: Int = try await Task.detached(priority: .userInitiated) {
                    try WallpaperService().exportExistingCacheFiles(from: files, baseName: baseName)
                }.value
                outcome = count == 0 ? L("WALLPAPER_EXPORT_NOTHING") : L("HISTORY_EXPORT_DONE")
            } catch {
                outcome = L("WALLPAPER_EXPORT_FAILED")
            }
            message = outcome
            isWorking = false
        }
    }
}
