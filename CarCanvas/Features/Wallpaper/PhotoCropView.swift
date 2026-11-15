import SwiftUI
import CoreGraphics

struct PhotoCropRequest: Identifiable {
    let id = UUID()
    let target: WallpaperTarget
    let data: Data
    let preview: CGImage
    let pixelSize: CGSize
    let channelOrder: CPBitmapTemplate.ChannelOrder
}

@MainActor
struct PhotoCropView: View {
    let image: CGImage
    let targetPixelSize: CGSize
    let onConfirm: (CGPoint) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @GestureState private var dragOffset = CGSize.zero
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(L("CROP_HINT")).font(.footnote).foregroundStyle(.secondary)
                GeometryReader { proxy in
                    let ratio = targetPixelSize.width / targetPixelSize.height
                    let width = max(1, min(proxy.size.width, proxy.size.height * ratio))
                    let frame = CGSize(width: width, height: width / ratio)
                    let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
                    let scaled = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    let offset = clampedOffset(scaled: scaled, frame: frame, translation: dragOffset)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: scaled.width, height: scaled.height)
                        .offset(x: offset.width, y: offset.height)
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .background(Color(uiColor: .secondarySystemBackground))
                        .overlay(Rectangle().stroke(Color.secondary, lineWidth: 1))
                        .contentShape(Rectangle())
                        .gesture(DragGesture()
                            .updating($dragOffset) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                let offset = clampedOffset(scaled: scaled, frame: frame, translation: value.translation)
                                center = CGPoint(x: 0.5 - offset.width / scaled.width,
                                                 y: 0.5 - offset.height / scaled.height)
                            }, including: isSaving ? .none : .all)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
            .padding(20)
            .navigationTitle(L("CROP_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("COMMON_CANCEL")) { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("CROP_USE_PHOTO")) { confirm() }.disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .alert(L("COMMON_ERROR"), isPresented: Binding(get: { errorMessage != nil }, set: {
                if !$0 { errorMessage = nil }
            })) {
                Button(L("COMMON_OK")) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func clampedOffset(scaled: CGSize, frame: CGSize, translation: CGSize) -> CGSize {
        let limitX = max(0, (scaled.width - frame.width) / 2)
        let limitY = max(0, (scaled.height - frame.height) / 2)
        return CGSize(width: min(limitX, max(-limitX, (0.5 - center.x) * scaled.width + translation.width)),
                      height: min(limitY, max(-limitY, (0.5 - center.y) * scaled.height + translation.height)))
    }

    private func confirm() {
        guard !isSaving else { return }
        let cropCenter = center
        isSaving = true
        Task {
            do {
                try await onConfirm(cropCenter)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
            isSaving = false
        }
    }
}
