import SwiftUI
import UniformTypeIdentifiers

/// Read-only session log with an opt-in text export.
struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showExporter = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? L("SETTINGS_LOG_EMPTY") : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L("SETTINGS_LOG_TITLE"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("SETTINGS_LOG_REFRESH")) { text = CCLog.snapshot() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button(L("SETTINGS_LOG_CLEAR")) {
                            CCLog.clear()
                            text = ""
                        }
                        Button(L("SETTINGS_LOG_EXPORT")) { prepareExport() }
                        Button(L("GUIDE_DONE")) { dismiss() }
                    }
                }
            }
            .onAppear { text = CCLog.snapshot() }
            .sheet(isPresented: $showExporter) {
                if let exportURL {
                    ActivityExportView(url: exportURL)
                }
            }
        }
    }

    private func prepareExport() {
        let snapshot = CCLog.snapshot()
        let name = "CarCanvas-\(Int(Date().timeIntervalSince1970)).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try snapshot.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            showExporter = true
        } catch {
            CCLog.error("log export failed: \(error.localizedDescription)")
        }
    }
}

/// Wraps UIActivityViewController so the user can share/save the log file.
struct ActivityExportView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
