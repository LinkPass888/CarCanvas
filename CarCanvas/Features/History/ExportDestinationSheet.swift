import SwiftUI

/// Explicit per-destination confirmation. The user picks Dark and/or Light;
/// there is no "apply to everything" and no path text field here.
struct ExportDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: HistoryEntry
    let onFinish: (String) -> Void

    @State private var dark = true
    @State private var light = true
    @State private var confirmed = false
    @State private var targets: [WallpaperTarget] = []
    @State private var error: String?
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { StatusBanner() }
                Section(L("HISTORY_EXPORT_CARPLAY_PICK_TITLE")) {
                    Text(L("HISTORY_EXPORT_CARPLAY_PICK_MESSAGE"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("WALLPAPER_SET_DARK"), isOn: $dark)
                    Toggle(L("WALLPAPER_SET_LIGHT"), isOn: $light)
                }
                Section {
                    Toggle("I confirm overwriting the selected CarPlay cache files on MY OWN device", isOn: $confirmed)
                        .font(.footnote)
                    Button(L("HISTORY_EXPORT_CARPLAY_WRITE")) { perform() }
                        .disabled(!confirmed || (!dark && !light) || result != nil)
                }
                if let result {
                    Section { Text(result).font(.footnote) }
                }
            }
            .navigationTitle(L("HISTORY_EXPORT_CARPLAY"))
            .toolbar { Button(L("COMMON_CANCEL")) { dismiss() } }
            .task { loadTargets() }
            .alert(L("COMMON_ERROR"), isPresented: .constant(error != nil)) {
                Button(L("COMMON_OK")) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func loadTargets() {
        do { targets = try ContainerResolver().resolve().files }
        catch let caught { self.error = caught.localizedDescription }
    }

    private func perform() {
        do {
            let r = try CacheWriter().overwrite(entry: entry, targets: targets, dark: dark, light: light)
            result = LF("HISTORY_EXPORT_CARPLAY_DONE", r.succeeded, r.failed)
        } catch let caught {
            self.error = caught.localizedDescription
        }
    }
}
