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
    let onConfirm: (CGPoint, CGSize) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @GestureState private var dragOffset = CGSize.zero
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var widthInput: String
    @State private var heightInput: String
    @FocusState private var focusedDimension: Dimension?

    private enum Dimension: Hashable { case width, height }
    private static let ratios = [("16:9", 16, 9), ("9:16", 9, 16), ("4:3", 4, 3),
                                 ("3:4", 3, 4), ("1:1", 1, 1), ("21:9", 21, 9), ("8:3", 8, 3)]

    init(image: CGImage, targetPixelSize: CGSize,
         onConfirm: @escaping (CGPoint, CGSize) async throws -> Void) {
        self.image = image
        self.targetPixelSize = targetPixelSize
        self.onConfirm = onConfirm
        _widthInput = State(initialValue: String(Int(targetPixelSize.width)))
        _heightInput = State(initialValue: String(Int(targetPixelSize.height)))
    }

    private var outputPixelSize: CGSize? {
        guard let width = Int(widthInput), let height = Int(heightInput),
              (1...16_384).contains(width), (1...16_384).contains(height),
              width * height <= 32 * 1024 * 1024 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        TextField(L("CROP_WIDTH"), text: $widthInput)
                            .focused($focusedDimension, equals: .width)
                            .accessibilityLabel(L("CROP_WIDTH"))
                        Text("×").foregroundStyle(.secondary)
                        TextField(L("CROP_HEIGHT"), text: $heightInput)
                            .focused($focusedDimension, equals: .height)
                            .accessibilityLabel(L("CROP_HEIGHT"))
                    }
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)
                    Text(L("CROP_SIZE_HINT")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if outputPixelSize == nil {
                        Text(L("CROP_SIZE_INVALID")).font(.caption).foregroundStyle(.red)
                    }
                    Text(L("CROP_HINT")).font(.footnote).foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    let size = outputPixelSize ?? targetPixelSize
                    let ratio = size.width / size.height
                    let width = max(1, min(proxy.size.width * 0.8, proxy.size.height * 0.8 * ratio))
                    let frame = CGSize(width: width, height: width / ratio)
                    let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
                    let scaled = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    let offset = clampedOffset(scaled: scaled, frame: frame, translation: dragOffset)
                    ZStack {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: scaled.width, height: scaled.height)
                            .offset(x: offset.width, y: offset.height)
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: proxy.size))
                            path.addRect(CGRect(x: (proxy.size.width - frame.width) / 2,
                                                y: (proxy.size.height - frame.height) / 2,
                                                width: frame.width, height: frame.height))
                        }.fill(Color(uiColor: .systemBackground).opacity(0.6), style: FillStyle(eoFill: true))
                        Rectangle().stroke(Color.secondary, lineWidth: 1)
                            .frame(width: frame.width, height: frame.height)
                    }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(DragGesture()
                            .updating($dragOffset) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                let offset = clampedOffset(scaled: scaled, frame: frame, translation: value.translation)
                                center = CGPoint(x: 0.5 - offset.width / scaled.width,
                                                 y: 0.5 - offset.height / scaled.height)
                            }, including: isSaving ? .none : .all)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("CROP_RATIOS")).font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Button(L("CROP_SYSTEM_SIZE")) {
                                focusedDimension = nil
                                widthInput = String(Int(targetPixelSize.width))
                                heightInput = String(Int(targetPixelSize.height))
                            }
                            ForEach(Self.ratios.indices, id: \.self) { index in
                                Button(Self.ratios[index].0) { selectRatio(index) }
                            }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }.frame(height: 44)
                }.disabled(isSaving)
            }
            .padding(20)
            .navigationTitle(L("CROP_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("COMMON_CANCEL")) { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("CROP_USE_PHOTO")) { confirm() }.disabled(isSaving || outputPixelSize == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L("COMMON_OK")) { focusedDimension = nil }
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

    private func selectRatio(_ index: Int) {
        let ratio = Self.ratios[index]
        let size = outputPixelSize ?? targetPixelSize
        let edge = Int(max(size.width, size.height))
        let pixelLimit = Int(sqrt(Double(32 * 1024 * 1024) / Double(ratio.1 * ratio.2)))
        let factor = max(1, min(edge / max(ratio.1, ratio.2), pixelLimit))
        focusedDimension = nil
        widthInput = String(ratio.1 * factor)
        heightInput = String(ratio.2 * factor)
    }

    private func confirm() {
        guard !isSaving, let size = outputPixelSize else { return }
        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let scaled = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let offset = clampedOffset(scaled: scaled, frame: size, translation: .zero)
        let cropCenter = CGPoint(x: 0.5 - offset.width / scaled.width,
                                 y: 0.5 - offset.height / scaled.height)
        focusedDimension = nil
        isSaving = true
        Task {
            do {
                try await onConfirm(cropCenter, size)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
            isSaving = false
        }
    }
}
