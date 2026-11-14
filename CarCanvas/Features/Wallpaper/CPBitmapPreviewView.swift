import SwiftUI
import CoreGraphics

/// One preview slot. Matches the original screen, which had a Dark image view
/// and a Light image view side by side.
struct CPBitmapPreviewView: View {
    let title: String
    let image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(uiColor: .tertiarySystemFill))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 150)
        }
    }
}
