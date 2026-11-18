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
    @GestureState private var dragTranslation: CGSize?
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
                    let maxW = max(1, proxy.size.width * 0.86)
                    let maxH = max(1, proxy.size.height * 0.86)
                    let fitScale = min(maxW / max(1, size.width), maxH / max(1, size.height))
                    let frame = CGSize(width: max(1, size.width * fitScale), height: max(1, size.height * fitScale))
                    let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
                    let scaled = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    let offset = clampedOffset(scaled: scaled, frame: frame, translation: dragTranslation ?? .zero)
                    let stageColor = Color(uiColor: .secondarySystemBackground)
                    stageColor
                        .overlay {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .frame(width: scaled.width, height: scaled.height)
                                .offset(x: offset.width, y: offset.height)
                        }
                        .overlay {
                            CropFrameOverlay(frameSize: frame, scrimColor: stageColor, isDragging: dragTranslation != nil)
                                .allowsHitTesting(false)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture()
                            .updating($dragTranslation) { value, state, _ in state = value.translation }
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
                            .tint(usesCustomSize ? .secondary : .accentColor)
                            ForEach(Self.ratios.indices, id: \.self) { index in
                                Button(Self.ratios[index].0) { selectRatio(index) }
                                    .tint(isMatchingRatio(index) ? .accentColor : .secondary)
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

    private func isMatchingRatio(_ index: Int) -> Bool {
        guard usesCustomSize, let size = parsedCropSize else { return false }
        let ratio = Self.ratios[index]
        return size.width * ratio.2 == size.height * ratio.1
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

/// High-contrast crop overlay locked to the viewport's own coordinate space so
/// oversized scaled photos never shift the cutout, with dual dark/light strokes
/// that stay legible on pure white, pure black and colorful wallpapers alike.
private struct CropFrameOverlay: View {
    let frameSize: CGSize
    let scrimColor: Color
    let isDragging: Bool

    var body: some View {
        Canvas { context, canvasSize in
            let cropRect = CGRect(x: (canvasSize.width - frameSize.width) / 2,
                                  y: (canvasSize.height - frameSize.height) / 2,
                                  width: frameSize.width,
                                  height: frameSize.height)

            var scrim = Path()
            scrim.addRect(CGRect(origin: .zero, size: canvasSize))
            scrim.addRect(cropRect)
            context.fill(scrim,
                         with: .color(scrimColor.opacity(isDragging ? 0.50 : 0.70)),
                         style: FillStyle(eoFill: true))

            if cropRect.width >= 30, cropRect.height >= 30 {
                var grid = Path()
                for step in 1...2 {
                    let x = cropRect.minX + cropRect.width * CGFloat(step) / 3
                    grid.move(to: CGPoint(x: x, y: cropRect.minY))
                    grid.addLine(to: CGPoint(x: x, y: cropRect.maxY))
                    let y = cropRect.minY + cropRect.height * CGFloat(step) / 3
                    grid.move(to: CGPoint(x: cropRect.minX, y: y))
                    grid.addLine(to: CGPoint(x: cropRect.maxX, y: y))
                }
                context.stroke(grid, with: .color(.black.opacity(isDragging ? 0.45 : 0.28)), lineWidth: 1.5)
                context.stroke(grid, with: .color(.white.opacity(isDragging ? 0.85 : 0.45)), lineWidth: 0.75)
            }

            let outerBorder = Path(cropRect.insetBy(dx: -0.75, dy: -0.75))
            let innerBorder = Path(cropRect)
            context.stroke(outerBorder, with: .color(.black.opacity(0.75)), lineWidth: 1.5)
            context.stroke(innerBorder, with: .color(.white), lineWidth: 1.5)

            let minSide = min(cropRect.width, cropRect.height)
            if minSide >= 16 {
                let arm = min(20, max(7, minSide * 0.25))
                let r = cropRect.insetBy(dx: -0.5, dy: -0.5)
                var corners = Path()
                corners.move(to: CGPoint(x: r.minX, y: r.minY + arm))
                corners.addLine(to: CGPoint(x: r.minX, y: r.minY))
                corners.addLine(to: CGPoint(x: r.minX + arm, y: r.minY))

                corners.move(to: CGPoint(x: r.maxX - arm, y: r.minY))
                corners.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                corners.addLine(to: CGPoint(x: r.maxX, y: r.minY + arm))

                corners.move(to: CGPoint(x: r.minX, y: r.maxY - arm))
                corners.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                corners.addLine(to: CGPoint(x: r.minX + arm, y: r.maxY))

                corners.move(to: CGPoint(x: r.maxX - arm, y: r.maxY))
                corners.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                corners.addLine(to: CGPoint(x: r.maxX, y: r.maxY - arm))

                context.stroke(corners, with: .color(.black.opacity(0.65)),
                               style: StrokeStyle(lineWidth: 5, lineCap: .square, lineJoin: .miter))
                context.stroke(corners, with: .color(.white),
                               style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter))
            }
        }
    }
}
