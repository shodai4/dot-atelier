import SwiftUI
import PhotosUI
import UIKit

@MainActor
struct ContentView: View {
    @StateObject private var model = StudioModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.ink.opacity(0.12))
            PreviewArea(model: model)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            metaBar
            Divider().overlay(Theme.ink.opacity(0.12))
            ControlDock(model: model)
        }
        .background(Theme.ivory.ignoresSafeArea())
        .overlay(alignment: .top) { toastOverlay }
        .onChange(of: pickerItems) { _, items in
            Task { await model.load(pickerItems: items) }
        }
        .onChange(of: model.options) { _, _ in
            model.scheduleReprocess()
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                Task { await model.addCameraImage(image) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("ドットアトリエ")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Theme.ink)
                Text("端末内完結・AI学習なし・権利完全放棄")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.accent)
            }
            Spacer(minLength: 2)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    headerChip("カメラ")
                }
            }
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 8, matching: .images) {
                headerChip("画像選択")
            }
            Button {
                Task { await model.exportCurrent() }
            } label: {
                headerChip("1×保存", filled: !model.frames.isEmpty)
            }
            .disabled(model.frames.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func headerChip(_ title: String, filled: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .frame(height: 34)
            .padding(.horizontal, 11)
            .background(filled ? Theme.accent : Theme.paper)
            .foregroundColor(filled ? Color.white : Theme.ink)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Theme.ink.opacity(0.14), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - サイズ・パレット・一括サムネイル

    private var metaBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(sizeReadout)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.ink.opacity(0.65))
                Spacer()
                if model.isWorking {
                    Text(model.workNote)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.accent)
                        .lineLimit(1)
                }
                Picker("表示", selection: $model.viewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 168)
            }

            if let frame = model.currentFrame {
                paletteRow(count: frame.palette.count)
            }

            if model.frames.count > 1 {
                batchRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var sizeReadout: String {
        guard let frame = model.currentFrame else { return "未読み込み" }
        return "\(frame.width) × \(frame.height) px (1×)"
    }

    private func paletteRow(count: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(0..<count, id: \.self) { index in
                    if let color = model.color(at: model.activeIndex, colorIndex: index) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Theme.ink.opacity(0.18), lineWidth: 1)
                            )
                            .onTapGesture {
                                if let frame = model.currentFrame, frame.palette.indices.contains(index) {
                                    model.selectColor(triplet: frame.palette[index])
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 26)
    }

    private var batchRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.frames.indices, id: \.self) { index in
                    if let thumb = model.thumbImage(at: index) {
                        Image(uiImage: thumb)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 38, height: 38)
                            .padding(3)
                            .background(Theme.paper)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(index == model.activeIndex ? Theme.accent : Theme.ink.opacity(0.12), lineWidth: index == model.activeIndex ? 2 : 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { model.activeIndex = index }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 48)
    }

    // MARK: - トースト

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.ink.opacity(0.9))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 6)
                .transition(.opacity)
        }
    }
}
