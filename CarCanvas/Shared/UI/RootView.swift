import SwiftUI

/// Original layout: a single scrolling screen with a hero block and four
/// navigation rows. Not a tab bar.
struct RootView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero

                    VStack(spacing: 0) {
                        row(L("ROOT_WALLPAPER"), L("ROOT_WALLPAPER_SUBTITLE"),
                            systemImage: "photo", destination: WallpaperView())
                        divider
                        row(L("ROOT_HISTORY"), L("ROOT_HISTORY_SUBTITLE"),
                            systemImage: "clock", destination: HistoryView())
                        divider
                        row(L("ROOT_CARPLAY_WALLPAPER"), L("ROOT_CARPLAY_WALLPAPER_SUBTITLE"),
                            systemImage: "folder", destination: BrowserView())
                        divider
                        row(L("ROOT_SETTINGS"), L("ROOT_SETTINGS_SUBTITLE"),
                            systemImage: "gearshape", destination: SettingsView())
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("CarCanvas")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: Binding(
            get: { !settings.hasSeenGuide },
            set: { if !$0 { settings.hasSeenGuide = true } }
        )) {
            GuideView()
                .environmentObject(settings)
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            Image("AppIconDisplay")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            Text("CarCanvas").font(.title2.weight(.semibold))
            Text(L("ROOT_HERO_SUBTITLE"))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(L("ROOT_DEVELOPER"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }

    private var divider: some View {
        Divider().padding(.leading, 52)
    }

    private func row<Destination: View>(_ title: String,
                                        _ subtitle: String,
                                        systemImage: String,
                                        destination: Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
