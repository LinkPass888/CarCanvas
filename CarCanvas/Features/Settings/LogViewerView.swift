import SwiftUI

/// Read-only session log. Copy is a plain pasteboard write, which works where
/// the share sheet was unreliable (the export button did nothing on device).
struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var didCopy = false

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
                    HStack(spacing: 12) {
                        Button(L("SETTINGS_LOG_CLEAR")) {
                            CCLog.clear()
                            text = ""
                        }
                        Button(didCopy ? L("SETTINGS_LOG_COPIED") : L("SETTINGS_LOG_COPY")) {
                            let latest = CCLog.snapshot()
                            text = latest
                            UIPasteboard.general.string = latest
                            didCopy = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                didCopy = false
                            }
                        }
                        Button(L("COMMON_CLOSE")) { dismiss() }
                    }
                }
            }
            .onAppear { text = CCLog.snapshot() }
        }
    }
}
