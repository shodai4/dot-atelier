import UIKit
import Foundation

/// ドット絵変換エンジン。Web 版（dot-atelier/js/engine.js）と同じ5段階パイプラインを
/// Swift へ移植したもの。外部通信・機械学習はせず、すべて端末内の計算だけで完結する。
///
/// 1. 背景透過（外周フラッドフィル）
/// 2. エッジ保存平滑化（簡易バイラテラル）
/// 3. エッジ優先ダウンサンプリング（細い主線・瞳を残す）
/// 4. Oklab K-Means++ 減色 ＋ ヒューシフト（任意で4×4ディザ）
/// 5. 孤立点掃除 → L字ダブルピクセル間引き → 1px輪郭線 → 差分バリエーション
enum PixelArtEngine {

    /// 端末の処理負荷を一定に保つため、読み込み時に長辺をここまで縮小する。
    static let maxSourceSide = 512

    // MARK: - 色空間

    struct Lab {
        var l: Double
        var a: Double
        var b: Double
    }

    static func srgbToLinear(_ c: UInt8) -> Double {
        let v = Double(c) / 255.0
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func linearToSrgb(_ value: Double) -> UInt8 {
        let clamped = min(1.0, max(0.0, value))
        let s = clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        return UInt8(clamping: Int((s * 255.0).rounded()))
    }

    static func cubeRoot(_ value: Double) -> Double {
        if value <= 0 { return 0 }
        return pow(value, 1.0 / 3.0)
    }

    static func rgbToOklab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Lab {
        let lr = srgbToLinear(r)
        let lg = srgbToLinear(g)
        let lb = srgbToLinear(b)

        let l = cubeRoot(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cubeRoot(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cubeRoot(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)

        return Lab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    static func oklabToRgb(_ l: Double, _ a: Double, _ b: Double) -> [UInt8] {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_
        let mc = m_ * m_ * m_
        let sc = s_ * s_ * s_

        return [
            linearToSrgb(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
            linearToSrgb(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
            linearToSrgb(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)
        ]
    }

    static func labDistanceSq(_ x: Lab, _ y: Lab) -> Double {
        let dl = x.l - y.l
        let da = x.a - y.a
        let db = x.b - y.b
        return dl * dl + da * da + db * db
    }

    static func rgbDistanceSq(_ r1: Int, _ g1: Int, _ b1: Int, _ r2: Int, _ g2: Int, _ b2: Int) -> Int {
        let dr = r1 - r2
        let dg = g1 - g2
        let db = b1 - b2
        return dr * dr + dg * dg + db * db
    }

    private static let bayer4: [[Double]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5]
    ].map { row in row.map { (Double($0) + 0.5) / 16.0 - 0.5 } }

    // MARK: - 画像の読み込み

    /// UIImage を向き補正・長辺縮小してストレートアルファの RGBA にする。
    static func prepareSource(_ image: UIImage, maxSide: Int = maxSourceSide) -> (rgba: [UInt8], width: Int, height: Int)? {
        let rawWidth = CGFloat(image.cgImage?.width ?? Int(image.size.width))
        let rawHeight = CGFloat(image.cgImage?.height ?? Int(image.size.height))
        let swapped = [UIImage.Orientation.left, .right, .leftMirrored, .rightMirrored].contains(image.imageOrientation)
        let pixelSize = swapped
            ? CGSize(width: max(1, rawHeight), height: max(1, rawWidth))
            : CGSize(width: max(1, rawWidth), height: max(1, rawHeight))
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > 0 else { return nil }
        let scale = min(1.0, CGFloat(maxSide) / longest)
        let width = max(8, Int((pixelSize.width * scale).rounded()))
        let height = max(8, Int((pixelSize.height * scale).rounded()))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let redrawn = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cgImage = redrawn.cgImage else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 乗算済みアルファ → ストレートアルファ
        var i = 0
        while i < buffer.count {
            let alpha = Int(buffer[i + 3])
            if alpha == 0 {
                buffer[i] = 0
                buffer[i + 1] = 0
                buffer[i + 2] = 0
            } else if alpha < 255 {
                buffer[i] = UInt8(clamping: Int(buffer[i]) * 255 / alpha)
                buffer[i + 1] = UInt8(clamping: Int(buffer[i + 1]) * 255 / alpha)
                buffer[i + 2] = UInt8(clamping: Int(buffer[i + 2]) * 255 / alpha)
            }
            i += 4
        }
        return (buffer, width, height)
    }

    // MARK: - 変換本体

    static func convert(
        baseImage: UIImage,
        options: ProcessingOptions
    ) -> (rgba: [UInt8], width: Int, height: Int, palette: [[UInt8]])? {
        guard let source = prepareSource(baseImage) else { return nil }
        return convert(rgba: source.rgba, width: source.width, height: source.height, options: options)
    }

    static func convert(
        rgba sourceRGBA: [UInt8],
        width srcW: Int,
        height srcH: Int,
        options: ProcessingOptions
    ) -> (rgba: [UInt8], width: Int, height: Int, palette: [[UInt8]])? {
        guard srcW > 0, srcH > 0, sourceRGBA.count >= srcW * srcH * 4 else { return nil }

        var work = sourceRGBA
        if options.removeBackground {
            work = removeOuterBackground(rgba: work, width: srcW, height: srcH, tolerance: options.backgroundTolerance)
        }
        if options.smooth {
            work = edgePreservingSmooth(rgba: work, width: srcW, height: srcH)
        }

        let aspect = Double(srcW) / Double(srcH)
        let dstW = aspect >= 1.0
            ? max(8, options.targetSize)
            : max(8, Int((Double(options.targetSize) * aspect).rounded()))
        let dstH = aspect >= 1.0
            ? max(8, Int((Double(options.targetSize) / aspect).rounded()))
            : max(8, options.targetSize)

        var small = edgePriorityDownscale(rgba: work, srcW: srcW, srcH: srcH, dstW: dstW, dstH: dstH)
        if options.seamless {
            small = makeSeamlessTile(rgba: small, width: dstW, height: dstH)
        }

        let quantized = quantizeOklab(
            rgba: small,
            width: dstW,
            height: dstH,
            maxColors: options.maxColors,
            fixedPalette: options.fixedPalette,
            hueShift: options.hueShift,
            dither: options.dither
        )
        small = quantized.rgba

        if options.despeckle {
            small = removeIsolatedPixels(rgba: small, width: dstW, height: dstH)
        }
        if options.dejaggy {
            small = thinJaggyCorners(rgba: small, width: dstW, height: dstH)
        }
        if options.outline != .none {
            small = applyOutline(rgba: small, width: dstW, height: dstH, mode: options.outline)
        }
        if options.variant != .normal {
            small = applyVariant(rgba: small, width: dstW, height: dstH, variant: options.variant, hueAngle: options.hueAngle)
        }

        return (small, dstW, dstH, quantized.palette)
    }

    // MARK: - 1. 背景透過（外周フラッドフィル）

    static func removeOuterBackground(rgba: [UInt8], width: Int, height: Int, tolerance: Int) -> [UInt8] {
        var out = rgba
        let toleranceSq = Double(tolerance * tolerance * 3)
        var visited = [Bool](repeating: false, count: width * height)
        var queue = [Int](repeating: 0, count: width * height)
        var head = 0
        var tail = 0

        let corners = [
            0,
            width - 1,
            (height - 1) * width,
            (height - 1) * width + (width - 1)
        ]
        var backgroundSamples: [(Int, Int, Int)] = []
        for corner in corners {
            let idx = corner * 4
            if out[idx + 3] > 128 {
                backgroundSamples.append((Int(out[idx]), Int(out[idx + 1]), Int(out[idx + 2])))
            }
        }
        if backgroundSamples.isEmpty { return out }

        func isBackground(_ pixel: Int) -> Bool {
            let idx = pixel * 4
            if out[idx + 3] <= 128 { return true }
            let r = Int(out[idx])
            let g = Int(out[idx + 1])
            let b = Int(out[idx + 2])
            for sample in backgroundSamples {
                if Double(rgbDistanceSq(r, g, b, sample.0, sample.1, sample.2)) <= toleranceSq {
                    return true
                }
            }
            return false
        }

        for x in 0..<width {
            let top = x
            let bottom = (height - 1) * width + x
            if !visited[top] && isBackground(top) {
                visited[top] = true
                queue[tail] = top
                tail += 1
            }
            if !visited[bottom] && isBackground(bottom) {
                visited[bottom] = true
                queue[tail] = bottom
                tail += 1
            }
        }
        for y in 0..<height {
            let left = y * width
            let right = y * width + (width - 1)
            if !visited[left] && isBackground(left) {
                visited[left] = true
                queue[tail] = left
                tail += 1
            }
            if !visited[right] && isBackground(right) {
                visited[right] = true
                queue[tail] = right
                tail += 1
            }
        }

        while head < tail {
            let pixel = queue[head]
            head += 1
            out[pixel * 4 + 3] = 0
            let x = pixel % width
            let y = pixel / width
            if x > 0 {
                let next = pixel - 1
                if !visited[next] && isBackground(next) {
                    visited[next] = true
                    queue[tail] = next
                    tail += 1
                }
            }
            if x + 1 < width {
                let next = pixel + 1
                if !visited[next] && isBackground(next) {
                    visited[next] = true
                    queue[tail] = next
                    tail += 1
                }
            }
            if y > 0 {
                let next = pixel - width
                if !visited[next] && isBackground(next) {
                    visited[next] = true
                    queue[tail] = next
                    tail += 1
                }
            }
            if y + 1 < height {
                let next = pixel + width
                if !visited[next] && isBackground(next) {
                    visited[next] = true
                    queue[tail] = next
                    tail += 1
                }
            }
        }
        return out
    }

    /// タップした1色を許容差つきで透過（1ドット修正の「色をタップで透過」）。
    static func removeColorBySample(rgba: [UInt8], width: Int, height: Int, target: [UInt8], tolerance: Int) -> [UInt8] {
        var out = rgba
        let toleranceSq = Double(tolerance * tolerance * 3)
        let tr = Int(target[0])
        let tg = Int(target[1])
        let tb = Int(target[2])
        var i = 0
        while i < width * height {
            let idx = i * 4
            if out[idx + 3] != 0 {
                let d = Double(rgbDistanceSq(Int(out[idx]), Int(out[idx + 1]), Int(out[idx + 2]), tr, tg, tb))
                if d <= toleranceSq {
                    out[idx + 3] = 0
                }
            }
            i += 1
        }
        return out
    }

    // MARK: - 2. エッジ保存平滑化

    static func edgePreservingSmooth(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rgba.count)
        let sigmaColorSq = 38.0 * 38.0 * 3.0
        for y in 0..<height {
            for x in 0..<width {
                let cIdx = (y * width + x) * 4
                if rgba[cIdx + 3] < 128 {
                    out[cIdx + 3] = 0
                    continue
                }
                let cr = Int(rgba[cIdx])
                let cg = Int(rgba[cIdx + 1])
                let cb = Int(rgba[cIdx + 2])
                var sumR = 0.0
                var sumG = 0.0
                var sumB = 0.0
                var sumW = 0.0

                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        if nx < 0 || nx >= width { continue }
                        let nIdx = (ny * width + nx) * 4
                        if rgba[nIdx + 3] < 128 { continue }
                        let nr = Int(rgba[nIdx])
                        let ng = Int(rgba[nIdx + 1])
                        let nb = Int(rgba[nIdx + 2])
                        let distSq = Double(
                            (cr - nr) * (cr - nr) + (cg - ng) * (cg - ng) + (cb - nb) * (cb - nb)
                        )
                        let w = exp(-distSq / sigmaColorSq)
                        sumR += Double(nr) * w
                        sumG += Double(ng) * w
                        sumB += Double(nb) * w
                        sumW += w
                    }
                }

                if sumW > 0 {
                    out[cIdx] = UInt8(clamping: Int((sumR / sumW).rounded()))
                    out[cIdx + 1] = UInt8(clamping: Int((sumG / sumW).rounded()))
                    out[cIdx + 2] = UInt8(clamping: Int((sumB / sumW).rounded()))
                }
                out[cIdx + 3] = 255
            }
        }
        return out
    }

    // MARK: - 3. エッジ優先ダウンサンプリング

    static func edgePriorityDownscale(rgba: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: dstW * dstH * 4)

        var lum = [Double](repeating: 0, count: srcW * srcH)
        for i in 0..<(srcW * srcH) {
            let idx = i * 4
            lum[i] = 0.2126 * Double(rgba[idx]) + 0.7152 * Double(rgba[idx + 1]) + 0.0722 * Double(rgba[idx + 2])
        }

        var edge = [Double](repeating: 0, count: srcW * srcH)
        if srcW > 2 && srcH > 2 {
            for y in 1..<(srcH - 1) {
                for x in 1..<(srcW - 1) {
                    let p = y * srcW + x
                    let gx = abs(lum[p + 1] - lum[p - 1])
                    let gy = abs(lum[p + srcW] - lum[p - srcW])
                    edge[p] = gx + gy
                }
            }
        }

        for dy in 0..<dstH {
            let y0 = (dy * srcH) / dstH
            let y1 = max(y0 + 1, ((dy + 1) * srcH) / dstH)
            for dx in 0..<dstW {
                let x0 = (dx * srcW) / dstW
                let x1 = max(x0 + 1, ((dx + 1) * srcW) / dstW)

                var opaqueCount = 0
                var totalCount = 0
                var bestScore = -1.0
                var bestIdx = -1
                var sumR = 0
                var sumG = 0
                var sumB = 0
                var sumLum = 0.0
                var minLum = Double.infinity
                var darkIdx = -1

                for sy in y0..<y1 {
                    for sx in x0..<x1 {
                        let p = sy * srcW + sx
                        let idx = p * 4
                        totalCount += 1
                        if rgba[idx + 3] >= 128 {
                            opaqueCount += 1
                            sumR += Int(rgba[idx])
                            sumG += Int(rgba[idx + 1])
                            sumB += Int(rgba[idx + 2])
                            sumLum += lum[p]
                            if lum[p] < minLum {
                                minLum = lum[p]
                                darkIdx = idx
                            }
                            let darkBoost = (255.0 - lum[p]) * 0.25
                            let score = edge[p] * 1.4 + darkBoost
                            if score > bestScore {
                                bestScore = score
                                bestIdx = idx
                            }
                        }
                    }
                }

                let outIdx = (dy * dstW + dx) * 4
                if opaqueCount * 2 < totalCount || opaqueCount == 0 {
                    out[outIdx + 3] = 0
                    continue
                }

                let cellMeanLum = sumLum / Double(opaqueCount)
                if darkIdx >= 0 && cellMeanLum - minLum > 42 {
                    out[outIdx] = rgba[darkIdx]
                    out[outIdx + 1] = rgba[darkIdx + 1]
                    out[outIdx + 2] = rgba[darkIdx + 2]
                } else if bestScore > 75 && bestIdx >= 0 {
                    out[outIdx] = rgba[bestIdx]
                    out[outIdx + 1] = rgba[bestIdx + 1]
                    out[outIdx + 2] = rgba[bestIdx + 2]
                } else {
                    out[outIdx] = UInt8(clamping: sumR / opaqueCount)
                    out[outIdx + 1] = UInt8(clamping: sumG / opaqueCount)
                    out[outIdx + 2] = UInt8(clamping: sumB / opaqueCount)
                }
                out[outIdx + 3] = 255
            }
        }
        return out
    }

    // MARK: - 4. Oklab 減色 ＋ ヒューシフト

    static func quantizeOklab(
        rgba: [UInt8],
        width: Int,
        height: Int,
        maxColors: Int,
        fixedPalette: [[UInt8]]?,
        hueShift: Bool,
        dither: DitherMode
    ) -> (rgba: [UInt8], palette: [[UInt8]]) {
        var palette = fixedPalette ?? []

        if palette.isEmpty {
            // サンプルは最大4096点まで（長辺512pxでも端末で一瞬で終わる密度）
            let pixelCount = width * height
            let step = max(1, pixelCount / 4096)
            var samples: [Lab] = []
            samples.reserveCapacity(min(pixelCount, 4096) + 1)
            var i = 0
            while i < pixelCount {
                let idx = i * 4
                if rgba[idx + 3] >= 128 {
                    samples.append(rgbToOklab(rgba[idx], rgba[idx + 1], rgba[idx + 2]))
                }
                i += step
            }
            if samples.isEmpty {
                return (rgba, [])
            }

            let k = min(max(1, maxColors), samples.count)
            var centroids: [Lab] = [samples[0]]

            // K-Means++（決定論的：最遠点を順に追加）
            while centroids.count < k {
                var maxDistance = -1.0
                var farSample = samples[0]
                for sample in samples {
                    var minDistance = Double.infinity
                    for centroid in centroids {
                        let d = labDistanceSq(sample, centroid)
                        if d < minDistance { minDistance = d }
                    }
                    if minDistance > maxDistance {
                        maxDistance = minDistance
                        farSample = sample
                    }
                }
                centroids.append(farSample)
            }

            for _ in 0..<8 {
                var sumL = [Double](repeating: 0, count: k)
                var sumA = [Double](repeating: 0, count: k)
                var sumB = [Double](repeating: 0, count: k)
                var counts = [Int](repeating: 0, count: k)
                for sample in samples {
                    var best = 0
                    var bestDistance = Double.infinity
                    for j in 0..<k {
                        let d = labDistanceSq(sample, centroids[j])
                        if d < bestDistance {
                            bestDistance = d
                            best = j
                        }
                    }
                    sumL[best] += sample.l
                    sumA[best] += sample.a
                    sumB[best] += sample.b
                    counts[best] += 1
                }
                for j in 0..<k where counts[j] > 0 {
                    let n = Double(counts[j])
                    centroids[j] = Lab(l: sumL[j] / n, a: sumA[j] / n, b: sumB[j] / n)
                }
            }

            palette = centroids.map { centroid in
                var a = centroid.a
                var b = centroid.b
                if hueShift {
                    if centroid.l < 0.45 {
                        let t = (0.45 - centroid.l) / 0.45
                        b -= 0.025 * t
                        a += 0.01 * t
                    } else if centroid.l > 0.72 {
                        let t = (centroid.l - 0.72) / 0.28
                        b += 0.028 * t
                    }
                }
                return oklabToRgb(centroid.l, a, b)
            }
        }

        guard !palette.isEmpty else { return (rgba, []) }

        let paletteLab = palette.map { rgbToOklab($0[0], $0[1], $0[2]) }
        var out = rgba

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                if rgba[idx + 3] < 128 {
                    out[idx + 3] = 0
                    continue
                }
                var lab = rgbToOklab(rgba[idx], rgba[idx + 1], rgba[idx + 2])
                if dither == .bayer4 {
                    lab.l += bayer4[y & 3][x & 3] * 0.09
                }
                var best = 0
                var bestDistance = Double.infinity
                for j in 0..<paletteLab.count {
                    let d = labDistanceSq(lab, paletteLab[j])
                    if d < bestDistance {
                        bestDistance = d
                        best = j
                    }
                }
                out[idx] = palette[best][0]
                out[idx + 1] = palette[best][1]
                out[idx + 2] = palette[best][2]
                out[idx + 3] = 255
            }
        }
        return (out, palette)
    }

    // MARK: - 5a. 孤立点掃除

    static func removeIsolatedPixels(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = rgba
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let isOpaque = rgba[idx + 3] >= 128
                var sameCount = 0
                var neighborColors: [(UInt8, UInt8, UInt8)] = []

                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx
                        if nx < 0 || nx >= width { continue }
                        let nIdx = (ny * width + nx) * 4
                        let nOpaque = rgba[nIdx + 3] >= 128
                        if isOpaque && nOpaque {
                            neighborColors.append((rgba[nIdx], rgba[nIdx + 1], rgba[nIdx + 2]))
                            if rgba[nIdx] == rgba[idx] && rgba[nIdx + 1] == rgba[idx + 1] && rgba[nIdx + 2] == rgba[idx + 2] {
                                sameCount += 1
                            }
                        }
                    }
                }

                if isOpaque && neighborColors.isEmpty {
                    out[idx + 3] = 0
                } else if isOpaque && sameCount == 0 && neighborColors.count >= 6 {
                    out[idx] = neighborColors[0].0
                    out[idx + 1] = neighborColors[0].1
                    out[idx + 2] = neighborColors[0].2
                }
            }
        }
        return out
    }

    // MARK: - 5b. L字ダブルピクセル間引き

    static func thinJaggyCorners(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = rgba
        func opaque(_ x: Int, _ y: Int) -> Bool {
            if x < 0 || y < 0 || x >= width || y >= height { return false }
            return rgba[(y * width + x) * 4 + 3] >= 128
        }
        if width < 3 || height < 3 { return out }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                if !opaque(x, y) { continue }
                let u = opaque(x, y - 1)
                let d = opaque(x, y + 1)
                let l = opaque(x - 1, y)
                let r = opaque(x + 1, y)
                let ul = opaque(x - 1, y - 1)
                let ur = opaque(x + 1, y - 1)
                let dl = opaque(x - 1, y + 1)
                let dr = opaque(x + 1, y + 1)

                if u && r && !d && !l && !ur && !dl {
                    out[(y * width + x) * 4 + 3] = 0
                } else if u && l && !d && !r && !ul && !dr {
                    out[(y * width + x) * 4 + 3] = 0
                } else if d && r && !u && !l && !dr && !ul {
                    out[(y * width + x) * 4 + 3] = 0
                } else if d && l && !u && !r && !dl && !ur {
                    out[(y * width + x) * 4 + 3] = 0
                }
            }
        }
        return out
    }

    // MARK: - 5c. 1px 輪郭線

    static func applyOutline(rgba: [UInt8], width: Int, height: Int, mode: OutlineMode) -> [UInt8] {
        if mode == .none { return rgba }
        var out = rgba
        let dirs = [(0, -1), (1, 0), (0, 1), (-1, 0)]

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                if rgba[idx + 3] >= 128 { continue }

                var adjacent = -1
                for dir in dirs {
                    let nx = x + dir.0
                    let ny = y + dir.1
                    if nx < 0 || ny < 0 || nx >= width || ny >= height { continue }
                    let nIdx = (ny * width + nx) * 4
                    if rgba[nIdx + 3] >= 128 {
                        adjacent = nIdx
                        break
                    }
                }
                if adjacent < 0 { continue }

                // すでに隣が暗い線なら二重輪郭にしない
                let adjacentLum = 0.2126 * Double(rgba[adjacent])
                    + 0.7152 * Double(rgba[adjacent + 1])
                    + 0.0722 * Double(rgba[adjacent + 2])
                if adjacentLum < 60 { continue }

                if mode == .black {
                    out[idx] = 20
                    out[idx + 1] = 20
                    out[idx + 2] = 22
                    out[idx + 3] = 255
                } else {
                    let lab = rgbToOklab(rgba[adjacent], rgba[adjacent + 1], rgba[adjacent + 2])
                    let rgb = oklabToRgb(max(0.14, lab.l * 0.45), lab.a * 0.9, lab.b - 0.02)
                    out[idx] = rgb[0]
                    out[idx + 1] = rgb[1]
                    out[idx + 2] = rgb[2]
                    out[idx + 3] = 255
                }
            }
        }
        return out
    }

    // MARK: - シームレスタイル化（左右・上下）

    static func makeSeamlessTile(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = rgba
        let bandX = max(1, Int(Double(width) * 0.18))
        let bandY = max(1, Int(Double(height) * 0.18))

        for y in 0..<height {
            let leftBase = (y * width) * 4
            let rightBase = (y * width + (width - 1)) * 4
            for c in 0..<3 {
                let lv = Double(out[leftBase + c])
                let rv = Double(out[rightBase + c])
                let avg = (lv + rv) / 2.0
                for x in 0..<bandX {
                    let t = Double(x) / Double(bandX)
                    let li = (y * width + x) * 4
                    let ri = (y * width + (width - 1 - x)) * 4
                    out[li + c] = UInt8(clamping: Int((avg + (lv - avg) * t).rounded()))
                    out[ri + c] = UInt8(clamping: Int((avg + (rv - avg) * t).rounded()))
                }
            }
        }

        for x in 0..<width {
            let topBase = x * 4
            let bottomBase = ((height - 1) * width + x) * 4
            for c in 0..<3 {
                let tv = Double(out[topBase + c])
                let bv = Double(out[bottomBase + c])
                let avg = (tv + bv) / 2.0
                for y in 0..<bandY {
                    let t = Double(y) / Double(bandY)
                    let ti = (y * width + x) * 4
                    let bi = ((height - 1 - y) * width + x) * 4
                    out[ti + c] = UInt8(clamping: Int((avg + (tv - avg) * t).rounded()))
                    out[bi + c] = UInt8(clamping: Int((avg + (bv - avg) * t).rounded()))
                }
            }
        }
        return out
    }

    // MARK: - 差分バリエーション

    static func applyVariant(rgba: [UInt8], width: Int, height: Int, variant: VariantMode, hueAngle: Int) -> [UInt8] {
        var out = rgba
        if variant == .normal { return out }

        let rad = Double(hueAngle) * Double.pi / 180.0
        let cosA = cos(rad)
        let sinA = sin(rad)

        for i in 0..<(width * height) {
            let idx = i * 4
            if out[idx + 3] == 0 { continue }
            switch variant {
            case .normal:
                break
            case .flash:
                out[idx] = 255
                out[idx + 1] = 255
                out[idx + 2] = 255
            case .shadow:
                out[idx] = 16
                out[idx + 1] = 16
                out[idx + 2] = 20
                out[idx + 3] = 140
            case .p2:
                let lab = rgbToOklab(out[idx], out[idx + 1], out[idx + 2])
                if lab.l >= 0.22 {
                    let na = lab.a * cosA - lab.b * sinA
                    let nb = lab.a * sinA + lab.b * cosA
                    let rgb = oklabToRgb(lab.l, na, nb)
                    out[idx] = rgb[0]
                    out[idx + 1] = rgb[1]
                    out[idx + 2] = rgb[2]
                }
            }
        }
        return out
    }

    // MARK: - スプライトシート結合

    static func mergeSpriteSheet(_ frames: [PixelFrame]) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let first = frames.first else { return nil }
        let width = first.width
        let height = first.height
        guard frames.allSatisfy({ $0.width == width && $0.height == height }) else { return nil }
        let totalWidth = width * frames.count
        var sheet = [UInt8](repeating: 0, count: totalWidth * height * 4)

        for (index, frame) in frames.enumerated() {
            let offsetX = index * width
            for y in 0..<height {
                for x in 0..<width {
                    let src = (y * width + x) * 4
                    let dst = (y * totalWidth + offsetX + x) * 4
                    sheet[dst] = frame.rgba[src]
                    sheet[dst + 1] = frame.rgba[src + 1]
                    sheet[dst + 2] = frame.rgba[src + 2]
                    sheet[dst + 3] = frame.rgba[src + 3]
                }
            }
        }
        return (sheet, totalWidth, height)
    }

    // MARK: - 画像化

    /// 等倍（1×）の UIImage を作る。保存すると rgba と同じドット数の PNG になる。
    static func makeUIImage(rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }

        var premultiplied = [UInt8](repeating: 0, count: width * height * 4)
        var i = 0
        while i < width * height * 4 {
            let alpha = Int(rgba[i + 3])
            if alpha > 0 {
                premultiplied[i] = UInt8((Int(rgba[i]) * alpha + 127) / 255)
                premultiplied[i + 1] = UInt8((Int(rgba[i + 1]) * alpha + 127) / 255)
                premultiplied[i + 2] = UInt8((Int(rgba[i + 2]) * alpha + 127) / 255)
                premultiplied[i + 3] = UInt8(alpha)
            }
            i += 4
        }

        let data = Data(premultiplied)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}
