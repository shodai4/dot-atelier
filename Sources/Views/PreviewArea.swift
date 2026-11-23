import SwiftUI
import UIKit

@MainActor
struct PreviewArea: View {
    @ObservedObject var model: StudioModel
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.canvas)
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.ink.opacity(0.1), lineWidth: 1)
                content(size: geo.size)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if let frame = model.currentFrame, let image = model.previewImage(for: frame) {
            switch model.viewMode {
            case .result:
                resultView(frame: frame, image: image, size: size)
            case .compare:
                compareView(frame: frame, image: image, size: size)
            case .tile:
                tileView(image: image, size: size)
            }
        } else {
            VStack(spacing: 8) {
                Text("「画像選択」から写真を読み込みます")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.ink.opacity(0.6))
                Text("最大8枚まで一括変換・スプライトシート結合")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.ink.opacity(0.4))
            }
        }
    }

    // MARK: - 通常表示（1ドット修正のタップ対象）

    private func resultView(frame: PixelFrame, image: UIImage, size: CGSize) -> some View {
        let box = CGSize(width: max(40, size.width - 36), height: max(40, size.height - 36))
        let display = fitSize(CGSize(width: CGFloat(max(1, frame.width)), height: CGFloat(max(1, frame.height))), in: box)
        return Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .frame(width: display.width, height: display.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handle(point: value.location, frame: frame, display: display, start: !isDragging)
                        isDragging = true
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }

    private func handle(point: CGPoint, frame: PixelFrame, display: CGSize, start: Bool) {
        guard display.width > 0, display.height > 0 else { return }
        let x = Int(floor(point.x / display.width * CGFloat(frame.width)))
        let y = Int(floor(point.y / display.height * CGFloat(frame.height)))
        guard x >= 0, y >= 0, x < frame.width, y < frame.height else { return }
        model.touchPixel(x: x, y: y, start: start)
    }

    // MARK: - 比較表示

    private func compareView(frame: PixelFrame, image: UIImage, size: CGSize) -> some View {
        let half = CGSize(width: max(40, (size.width - 44) / 2), height: max(40, size.height - 44))
        let display = fitSize(CGSize(width: CGFloat(max(1, frame.width)), height: CGFloat(max(1, frame.height))), in: half)
        return HStack(spacing: 10) {
            VStack(spacing: 6) {
                Image(uiImage: frame.originalImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: display.width, height: display.height)
                Text("元")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.ink.opacity(0.5))
            }
            Rectangle()
                .fill(Theme.accent.opacity(0.45))
                .frame(width: 1, height: display.height + 24)
            VStack(spacing: 6) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: display.width, height: display.height)
                Text("ドット")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.ink.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 3×3 タイル

    private func tileView(image: UIImage, size: CGSize) -> some View {
        let side = max(60, min(size.width - 44, size.height - 36))
        return VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }

    private func fitSize(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let scale = min(box.width / image.width, box.height / image.height)
        return CGSize(width: max(1, image.width * scale), height: max(1, image.height * scale))
    }
}
