import SwiftUI
import UIKit
import PhotosUI

enum DockTab: String, CaseIterable, Identifiable {
    case convert
    case finish
    case dot
    case export

    var id: String { rawValue }

    var label: String {
        switch self {
        case .convert: return "変換"
        case .finish: return "仕上げ"
        case .dot: return "1ドット"
        case .export: return "書き出し"
        }
    }
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var frames: [PixelFrame] = []
    @Published var activeIndex: Int = 0
    @Published var preset: PixelPreset = .standard32
    @Published var options: ProcessingOptions = ProcessingOptions.from(.standard32)
    @Published var viewMode: PreviewMode = .result
    @Published var tool: DotTool = .pen
    @Published var penColor: Color = Theme.ink
    @Published var pickColorMode: Bool = false
    @Published var dockTab: DockTab = .convert
    @Published var toast: String?
    @Published var isWorking: Bool = false
    @Published var workNote: String = ""

    private let cutoutService = SubjectCutoutService()
    private var reprocessTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    var currentFrame: PixelFrame? {
        guard frames.indices.contains(activeIndex) else { return nil }
        return frames[activeIndex]
    }

    var canUndo: Bool {
        guard let frame = currentFrame else { return false }
        return !frame.undoStack.isEmpty
    }

    // MARK: - プリセット

    func applyPreset(_ newPreset: PixelPreset) {
        preset = newPreset
        var next = options
        next.targetSize = newPreset.targetSize
        next.maxColors = newPreset.colorCount
        next.fixedPalette = newPreset.fixedPalette
        next.dither = newPreset.defaultDither
        next.outline = newPreset.defaultOutline
        if newPreset == .gb {
            next.hueShift = false
        }
        options = next
    }

    // MARK: - 読み込み

    func load(pickerItems: [PhotosPickerItem]) async {
        guard !pickerItems.isEmpty else { return }
        isWorking = true
        workNote = "写真を読み込んでいます"
        var images: [UIImage] = []
        for item in pickerItems.prefix(8) {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        await buildFrames(from: images)
        isWorking = false
        workNote = ""
        if images.isEmpty {
            showToast("画像を読み込めませんでした")
        }
    }

    func addCameraImage(_ image: UIImage) async {
        isWorking = true
        var images: [UIImage] = [image]
        images.append(contentsOf: frames.map { $0.originalImage })
        await buildFrames(from: Array(images.prefix(8)))
        isWorking = false
        workNote = ""
    }

    private func buildFrames(from images: [UIImage]) async {
        guard !images.isEmpty else {
            frames = []
            activeIndex = 0
            return
        }

        var built: [PixelFrame] = []
        var lockedPalette: [[UInt8]]? = nil

        for (index, image) in images.enumerated() {
            var base = image
            if options.cutoutWithVision && SubjectCutoutService.isAvailable {
                workNote = "被写体を切り抜き中（\(index + 1)/\(images.count)）"
                if let cut = await cutoutService.extractForeground(from: image) {
                    base = cut
                }
            }

            var frameOptions = options
            if index > 0, options.lockPalette, options.fixedPalette == nil {
                frameOptions.fixedPalette = lockedPalette
            }

            workNote = "ドット絵に変換中（\(index + 1)/\(images.count)）"
            let result = await Task.detached(priority: .userInitiated) {
                PixelArtEngine.convert(baseImage: base, options: frameOptions)
            }.value

            guard let result else { continue }

            let frame = PixelFrame(
                originalImage: image,
                baseImage: base,
                name: "dot_\(index + 1)",
                width: result.width,
                height: result.height,
                rgba: result.rgba,
                palette: result.palette
            )
            if index == 0, options.fixedPalette == nil {
                lockedPalette = result.palette
            }
            built.append(frame)
        }

        frames = built
        activeIndex = 0
    }

    // MARK: - 再変換

    func scheduleReprocess() {
        reprocessTask?.cancel()
        let snapshot = frames
        guard !snapshot.isEmpty else { return }
        let currentOptions = options
        reprocessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            if Task.isCancelled { return }
            let rebuilt = await Task.detached(priority: .userInitiated) {
                StudioModel.rebuild(snapshot, options: currentOptions)
            }.value
            if Task.isCancelled { return }
            guard let self else { return }
            self.frames = rebuilt
        }
    }

    nonisolated static func rebuild(_ frames: [PixelFrame], options: ProcessingOptions) -> [PixelFrame] {
        var lockedPalette: [[UInt8]]? = options.fixedPalette
        var updated: [PixelFrame] = []

        for (index, frame) in frames.enumerated() {
            var frameOptions = options
            if index > 0, options.lockPalette, options.fixedPalette == nil {
                frameOptions.fixedPalette = lockedPalette
            }
            guard let result = PixelArtEngine.convert(baseImage: frame.baseImage, options: frameOptions) else { continue }
            var next = frame
            next.width = result.width
            next.height = result.height
            next.rgba = result.rgba
            next.palette = result.palette
            next.undoStack = []
            if index == 0, options.fixedPalette == nil {
                lockedPalette = result.palette
            }
            updated.append(next)
        }
        return updated
    }

    // MARK: - 1ドット修正

    func touchPixel(x: Int, y: Int, start: Bool) {
        guard frames.indices.contains(activeIndex) else { return }
        let index = activeIndex
        let width = frames[index].width
        let height = frames[index].height
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let offset = (y * width + x) * 4

        if pickColorMode {
            let rgba = frames[index].rgba
            guard offset + 3 < rgba.count, rgba[offset + 3] > 0 else {
                pickColorMode = false
                return
            }
            pushUndo(index)
            let target: [UInt8] = [rgba[offset], rgba[offset + 1], rgba[offset + 2]]
            frames[index].rgba = PixelArtEngine.removeColorBySample(
                rgba: rgba,
                width: width,
                height: height,
                target: target,
                tolerance: options.backgroundTolerance
            )
            pickColorMode = false
            return
        }

        if tool == .eyedropper {
            let rgba = frames[index].rgba
            guard offset + 3 < rgba.count, rgba[offset + 3] > 0 else { return }
            penColor = Color(
                red: Double(rgba[offset]) / 255.0,
                green: Double(rgba[offset + 1]) / 255.0,
                blue: Double(rgba[offset + 2]) / 255.0
            )
            return
        }

        if start {
            pushUndo(index)
        }

        if tool == .eraser {
            frames[index].rgba[offset + 3] = 0
        } else {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            if UIColor(penColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                frames[index].rgba[offset] = UInt8(clamping: Int((red * 255).rounded()))
                frames[index].rgba[offset + 1] = UInt8(clamping: Int((green * 255).rounded()))
                frames[index].rgba[offset + 2] = UInt8(clamping: Int((blue * 255).rounded()))
                frames[index].rgba[offset + 3] = 255
            }
        }
    }

    func undo() {
        guard frames.indices.contains(activeIndex) else { return }
        guard let last = frames[activeIndex].undoStack.popLast() else { return }
        frames[activeIndex].rgba = last
    }

    private func pushUndo(_ index: Int) {
        frames[index].undoStack.append(frames[index].rgba)
        if frames[index].undoStack.count > 20 {
            frames[index].undoStack.removeFirst()
        }
    }

    // MARK: - 書き出し

    func exportCurrent() async {
        guard let frame = currentFrame,
              let image = PixelArtEngine.makeUIImage(rgba: frame.rgba, width: frame.width, height: frame.height) else {
            showToast("変換したドット絵がありません")
            return
        }
        let saved = await PhotoSaver.save(image)
        showToast(saved ? "1×透過PNGを保存しました" : "写真への追加を許可してください")
    }

    func exportSheet() async {
        guard frames.count > 1 else {
            showToast("2枚以上で結合できます")
            return
        }
        guard let sheet = PixelArtEngine.mergeSpriteSheet(frames),
              let image = PixelArtEngine.makeUIImage(rgba: sheet.rgba, width: sheet.width, height: sheet.height) else {
            showToast("同じ大きさのフレームだけ結合できます")
            return
        }
        let saved = await PhotoSaver.save(image)
        showToast(saved ? "スプライトシートを保存しました" : "写真への追加を許可してください")
    }

    func exportAll() async {
        guard !frames.isEmpty else {
            showToast("変換したドット絵がありません")
            return
        }
        var savedCount = 0
        for frame in frames {
            guard let image = PixelArtEngine.makeUIImage(rgba: frame.rgba, width: frame.width, height: frame.height) else { continue }
            if await PhotoSaver.save(image) {
                savedCount += 1
            }
        }
        showToast("\(savedCount)/\(frames.count)枚を保存しました")
    }

    // MARK: - 表示補助

    func previewImage(for frame: PixelFrame) -> UIImage? {
        PixelArtEngine.makeUIImage(rgba: frame.rgba, width: frame.width, height: frame.height)
    }

    func thumbImage(at index: Int) -> UIImage? {
        guard frames.indices.contains(index) else { return nil }
        return previewImage(for: frames[index])
    }

    func color(at index: Int, colorIndex: Int) -> Color? {
        guard frames.indices.contains(index) else { return nil }
        let palette = frames[index].palette
        guard palette.indices.contains(colorIndex) else { return nil }
        let triplet = palette[colorIndex]
        return Color(
            red: Double(triplet[0]) / 255.0,
            green: Double(triplet[1]) / 255.0,
            blue: Double(triplet[2]) / 255.0
        )
    }

    func selectColor(triplet: [UInt8]) {
        guard triplet.count >= 3 else { return }
        penColor = Color(
            red: Double(triplet[0]) / 255.0,
            green: Double(triplet[1]) / 255.0,
            blue: Double(triplet[2]) / 255.0
        )
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if Task.isCancelled { return }
            self?.toast = nil
        }
    }
}
