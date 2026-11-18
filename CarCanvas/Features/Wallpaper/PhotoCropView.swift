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
    let onSaveCropSize: (SettingsStore.CropSize?) -> Void
    let onConfirm: (CGPoint, CGSize) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @GestureState private var dragOffset = CGSize.zero
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var widthInput: String
    @State private var heightInput: String
    @State private var usesCustomSize: Bool
    @State private var referenceEdge: Int
    @FocusState private var focusedDimension: Dimension?

    private enum Dimension: Hashable { case width, height }
    private static let ratios = [("16:9", 16, 9), ("9:16", 9, 16), ("4:3", 4, 3),
                                 ("3:4", 3, 4), ("1:1", 1, 1), ("21:9", 21, 9), ("8:3", 8, 3)]

    init(image: CGImage, targetPixelSize: CGSize,
         customCropSize: SettingsStore.CropSize? = SettingsStore.shared.customCropSize,
         onSaveCropSize: @escaping (SettingsStore.CropSize?) -> Void = { SettingsStore.shared.customCropSize = $0 },
         onConfirm: @escaping (CGPoint, CGSize) async throws -> Void) {
        self.image = image
        self.targetPixelSize = targetPixelSize
        self.onSaveCropSize = onSaveCropSize
        self.onConfirm = onConfirm
        let initialWidth = customCropSize?.width ?? Int(targetPixelSize.width)
        let initialHeight = customCropSize?.height ?? Int(targetPixelSize.height)
        _widthInput = State(initialValue: String(initialWidth))
        _heightInput = State(initialValue: String(initialHeight))
        _usesCustomSize = State(initialValue: customCropSize != nil)
        _referenceEdge = State(initialValue: max(1, max(initialWidth, initialHeight)))
    }

    private static func parseDimension(_ text: String) -> Int? {
        let normalized = String(text.trimmingCharacters(in: .whitespacesAndNewlines).map { char -> Character in
            guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1,
                  (0xFF10...0xFF19).contains(scalar.value),
                  let ascii = UnicodeScalar(scalar.value - 0xFF10 + 0x30) else { return char }
            return Character(ascii)
        })
        return Int(normalized)
    }

    private var parsedCropSize: SettingsStore.CropSize? {
        guard let width = Self.parseDimension(widthInput),
              let height = Self.parseDimension(heightInput) else { return nil }
        return SettingsStore.CropSize(width: width, height: height)
    }

    private var outputPixelSize: CGSize? { parsedCropSize?.cgSize }

    private var widthBinding: Binding<String> {
        Binding(
            get: { widthInput },
            set: { newValue in
                guard widthInput != newValue else { return }
                widthInput = newValue
                usesCustomSize = true
                if let size = parsedCropSize { referenceEdge = max(size.width, size.height) }
            }
        )
    }

    private var heightBinding: Binding<String> {
        Binding(
            get: { heightInput },
            set: { newValue in
                guard heightInput != newValue else { return }
                heightInput = newValue
                usesCustomSize = true
                if let size = parsedCropSize { referenceEdge = max(size.width, size.height) }
            }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        TextField(L("CROP_WIDTH"), text: widthBinding)
                            .focused($focusedDimension, equals: .width)
                            .accessibilityLabel(L("CROP_WIDTH"))
                        Text("×").foregroundStyle(.secondary)
                        TextField(L("CROP_HEIGHT"), text: heightBinding)
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L("CROP_HINT")).font(.footnote).foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    let size = outputPixelSize ?? targetPixelSize
                    let maxW = max(1, proxy.size.width * 0.8)
                    let maxH = max(1, proxy.size.height * 0.8)
                    let fitScale = min(maxW / max(1, size.width), maxH / max(1, size.height))
                    let frame = CGSize(width: max(1, size.width * fitScale), height: max(1, size.height * fitScale))
                    let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
                    let scaled = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    let offset = clampedOffset(scaled: scaled, frame: frame, translation: dragOffset)
                    ZStack {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: scaled.width, height: scaled.height)
                            .offset(x: offset.width, y: offset.height)
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
                                let systemWidth = Int(targetPixelSize.width)
                                let systemHeight = Int(targetPixelSize.height)
                                widthInput = String(systemWidth)
                                heightInput = String(systemHeight)
                                usesCustomSize = false
                                referenceEdge = max(1, max(systemWidth, systemHeight))
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
        let edge = max(1, referenceEdge)
        let maxRatioSide = max(ratio.1, ratio.2)
        let pixelLimit = Int(sqrt(Double(SettingsStore.CropSize.maxPixels) / Double(ratio.1 * ratio.2)))
        let sideLimit = SettingsStore.CropSize.maxDimension / maxRatioSide
        let idealFactor = Int((Double(edge) / Double(maxRatioSide)).rounded())
        let factor = max(1, min(idealFactor, min(pixelLimit, sideLimit)))
        focusedDimension = nil
        widthInput = String(ratio.1 * factor)
        heightInput = String(ratio.2 * factor)
        usesCustomSize = true
    }

    private func confirm() {
        guard !isSaving, let cropSize = parsedCropSize else { return }
        let size = cropSize.cgSize
        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let scaled = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let offset = clampedOffset(scaled: scaled, frame: size, translation: .zero)
        let cropCenter = CGPoint(x: 0.5 - offset.width / scaled.width,
                                 y: 0.5 - offset.height / scaled.height)
        let savedSize = usesCustomSize ? cropSize : nil
        focusedDimension = nil
        isSaving = true
        Task {
            do {
                try await onConfirm(cropCenter, size)
                onSaveCropSize(savedSize)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
            isSaving = false
        }
    }
}
