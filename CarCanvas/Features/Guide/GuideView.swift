import SwiftUI

struct GuideView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("GUIDE_HEADER")).font(.headline)
                    StatusBanner()
                }
                ForEach(steps, id: \.title) { step in
                    Section(step.title) { Text(step.body).font(.footnote) }
                }
                Section {
                    Image("CarPlayWallpaperPicker")
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Section { Text(L("GUIDE_FOOTER")).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle(L("GUIDE_TITLE"))
            .toolbar { Button(L("GUIDE_DONE")) { settings.hasSeenGuide = true; dismiss() } }
        }
    }

    private var steps: [(title: String, body: String)] {
        [(L("GUIDE_STEP1_TITLE"), L("GUIDE_STEP1_BODY")),
         (L("GUIDE_STEP2_TITLE"), L("GUIDE_STEP2_BODY")),
         (L("GUIDE_STEP3_TITLE"), L("GUIDE_STEP3_BODY")),
         (L("GUIDE_STEP4_TITLE"), L("GUIDE_STEP4_BODY"))]
    }
}
