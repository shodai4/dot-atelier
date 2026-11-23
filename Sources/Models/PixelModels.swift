import UIKit

// MARK: - プリセットパレット

enum PaletteLibrary {
    /// ファミコン風 代表16色
    static let fc: [[UInt8]] = [
        [124, 124, 124], [0, 0, 252], [0, 0, 188], [68, 40, 188],
        [148, 0, 132], [168, 0, 32], [168, 16, 0], [136, 20, 0],
        [80, 48, 0], [0, 120, 0], [0, 104, 0], [0, 88, 0],
        [0, 64, 88], [0, 0, 0], [188, 188, 188], [248, 248, 248]
    ]

    /// ゲームボーイ風 4階調
    static let gb: [[UInt8]] = [
        [15, 56, 15],
        [48, 98, 48],
        [139, 172, 15],
        [155, 188, 15]
    ]

    /// PICO-8 標準16色
    static let pico8: [[UInt8]] = [
        [0, 0, 0], [29, 43, 83], [126, 37, 83], [0, 135, 81],
        [171, 82, 54], [95, 87, 79], [194, 195, 199], [255, 241, 232],
        [255, 0, 77], [255, 163, 0], [255, 236, 39], [0, 228, 54],
        [41, 173, 255], [131, 118, 156], [255, 119, 168], [255, 204, 170]
    ]
}

// MARK: - 変換オプション

enum DitherMode: String, CaseIterable, Identifiable {
    case none
    case bayer4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "ディザなし"
        case .bayer4: return "4×4ディザ"
        }
    }
}

enum OutlineMode: String, CaseIterable, Identifiable {
    case none
    case black
    case colortrace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "輪郭なし"
        case .black: return "黒 1px"
        case .colortrace: return "色トレス"
        }
    }
}

enum VariantMode: String, CaseIterable, Identifiable {
    case normal
    case p2
    case flash
    case shadow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "通常"
        case .p2: return "2P色相"
        case .flash: return "白フラッシュ"
        case .shadow: return "黒影"
        }
    }
}

enum PreviewMode: String, CaseIterable, Identifiable {
    case result
    case compare
    case tile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .result: return "ドット"
        case .compare: return "比較"
        case .tile: return "3×3"
        }
    }
}

enum DotTool: String, CaseIterable, Identifiable {
    case pen
    case eraser
    case eyedropper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "ペン"
        case .eraser: return "消しゴム"
        case .eyedropper: return "スポイト"
        }
    }
}

/// Web 版のゲーム機プリセット表と同じ値。
enum PixelPreset: String, CaseIterable, Identifiable {
    case standard32
    case fc
    case gb
    case pico8
    case rpg48
    case icon64

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard32: return "標準 32px"
        case .fc: return "FC風 16色"
        case .gb: return "GB風 4階調"
        case .pico8: return "PICO-8"
        case .rpg48: return "ツクール 48px"
        case .icon64: return "高精細 64px"
        }
    }

    var targetSize: Int {
        switch self {
        case .rpg48: return 48
        case .icon64: return 64
        default: return 32
        }
    }

    var colorCount: Int {
        switch self {
        case .gb: return 4
        case .rpg48: return 24
        case .icon64: return 32
        default: return 16
        }
    }

    var fixedPalette: [[UInt8]]? {
        switch self {
        case .fc: return PaletteLibrary.fc
        case .gb: return PaletteLibrary.gb
        case .pico8: return PaletteLibrary.pico8
        default: return nil
        }
    }

    var defaultDither: DitherMode {
        switch self {
        case .gb: return .bayer4
        default: return .none
        }
    }

    var defaultOutline: OutlineMode {
        switch self {
        case .gb, .rpg48, .icon64: return .colortrace
        default: return .black
        }
    }
}

// MARK: - 変換オプション一式

struct ProcessingOptions: Equatable {
    var targetSize: Int = 32
    var maxColors: Int = 16
    var fixedPalette: [[UInt8]]? = nil
    var dither: DitherMode = .none
    var outline: OutlineMode = .black
    var removeBackground: Bool = true
    var cutoutWithVision: Bool = true
    var backgroundTolerance: Int = 22
    var smooth: Bool = true
    var hueShift: Bool = true
    var despeckle: Bool = true
    var dejaggy: Bool = true
    var variant: VariantMode = .normal
    var hueAngle: Int = 135
    var seamless: Bool = false
    var lockPalette: Bool = true

    static func from(_ preset: PixelPreset) -> ProcessingOptions {
        var options = ProcessingOptions()
        options.targetSize = preset.targetSize
        options.maxColors = preset.colorCount
        options.fixedPalette = preset.fixedPalette
        options.dither = preset.defaultDither
        options.outline = preset.defaultOutline
        if preset == .gb {
            options.hueShift = false
        }
        return options
    }
}

// MARK: - フレーム

struct PixelFrame: Identifiable {
    let id = UUID()
    /// 元写真（比較表示用）
    var originalImage: UIImage
    /// 被写体抜き後の画像（再変換の入力）
    var baseImage: UIImage
    var name: String
    var width: Int
    var height: Int
    var rgba: [UInt8]
    var palette: [[UInt8]]
    var undoStack: [[UInt8]] = []
}
