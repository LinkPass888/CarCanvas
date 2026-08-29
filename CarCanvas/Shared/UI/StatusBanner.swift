import SwiftUI

/// Always-visible compatibility banner. It makes the fail-closed gate
/// obvious instead of hiding it in a log.
struct StatusBanner: View {
    private var supported: Bool { WQCompatibility.isSupported }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: supported ? "checkmark.shield" : "xmark.shield")
            VStack(alignment: .leading, spacing: 2) {
                Text(supported ? "worse_query backend ready" : "Backend disabled")
                    .font(.footnote.weight(.semibold))
                Text(WQCompatibility.supportSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(supported ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
