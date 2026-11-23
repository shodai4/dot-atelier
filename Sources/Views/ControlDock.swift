import SwiftUI
import UIKit

@MainActor
struct ControlDock: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(spacing: 7) {
            tabRow
            ScrollView(.vertical, showsIndicators: false) {
                panel
                    .padding(.bottom, 4)
            }
            .frame(height: 174)
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 4)
        .background(Theme.panel)
    }

    // MARK: - タブ

    private var tabRow: some View {
        HStack(spacing: 6) {
            ForEach(DockTab.allCases) { tab in
                Button {
                    model.dockTab = tab
                } label: {
                    Text(tab.label)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(model.dockTab == tab ? Theme.accent : Theme.paper)
                        .foregroundColor(model.dockTab == tab ? Color.white : Theme.ink)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - パネル

    @ViewBuilder
    private var panel: some View {
        switch model.dockTab {
        case .convert:
            convertPanel
        case .finish:
            finishPanel
        case .dot:
            dotPanel
        case .export:
            exportPanel
        }
    }

    private var convertPanel: some View {
        VStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PixelPreset.allCases) { preset in
                        Button {
                            model.applyPreset(preset)
                        } label: {
                            Text(preset.label)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(height: 30)
                                .padding(.horizontal, 10)
                                .background(model.preset == preset ? Theme.ink : Theme.paper)
                                .foregroundColor(model.preset == preset ? Color.white : Theme.ink)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(Theme.ink.opacity(0.14), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chipToggle("AI被写体抜き", isOn: $model.options.cutoutWithVision)
                    chipToggle("背景自動透過", isOn: $model.options.removeBackground)
                    chipToggle("平滑化", isOn: $model.options.smooth)
                    chipToggle("ヒューシフト", isOn: $model.options.hueShift)
                    chipToggle("孤立点掃除", isOn: $model.options.despeckle)
                    chipToggle("L字間引き", isOn: $model.options.dejaggy)
                    chipToggle("シームレス", isOn: $model.options.seamless)
                    chipToggle("パレットロック", isOn: $model.options.lockPalette)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            sliderRow("サイズ", value: sizeBinding, range: 8...64, step: 8, suffix: "px")
            sliderRow("色数", value: colorBinding, range: 2...32, step: 2, suffix: "色")
            sliderRow("透過許容", value: toleranceBinding, range: 4...80, step: 2, suffix: "")
        }
    }

    private var finishPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("輪郭")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.ink.opacity(0.7))
                    .frame(width: 34, alignment: .leading)
                Picker("輪郭", selection: $model.options.outline) {
                    ForEach(OutlineMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 8) {
                Text("ディザ")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.ink.opacity(0.7))
                    .frame(width: 34, alignment: .leading)
                Picker("ディザ", selection: $model.options.dither) {
                    ForEach(DitherMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 8) {
                Text("差分")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.ink.opacity(0.7))
                    .frame(width: 34, alignment: .leading)
                Picker("差分", selection: $model.options.variant) {
                    ForEach(VariantMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if model.options.variant == .p2 {
                sliderRow("色相角", value: hueBinding, range: 30...330, step: 15, suffix: "°")
            }
        }
    }

    private var dotPanel: some View {
        VStack(spacing: 9) {
            Picker("ツール", selection: $model.tool) {
                ForEach(DotTool.allCases) { tool in
                    Text(tool.label).tag(tool)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                ColorPicker("ペンの色", selection: $model.penColor, supportsOpacity: false)
                    .font(.system(size: 12, weight: .medium))

                Button {
                    model.undo()
                } label: {
                    Text("元に戻す")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(height: 32)
                        .padding(.horizontal, 12)
                        .background(model.canUndo ? Theme.ink : Theme.ink.opacity(0.25))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(!model.canUndo)
            }

            chipToggle("色をタップで透過", isOn: $model.pickColorMode)

            Text("ドットをなぞって描く／消す。スポイトは色を拾う。")
                .font(.system(size: 10))
                .foregroundColor(Theme.ink.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var exportPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton("1×PNG保存") {
                    Task { await model.exportCurrent() }
                }
                actionButton("シート結合") {
                    Task { await model.exportSheet() }
                }
                actionButton("全枚保存") {
                    Task { await model.exportAll() }
                }
            }

            Text(exportNote)
                .font(.system(size: 10))
                .foregroundColor(Theme.ink.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var exportNote: String {
        let count = model.frames.count
        if count == 0 { return "写真を読み込むと書き出せます。" }
        if count == 1 { return "現在1枚。等倍の透過PNGを写真に保存します。" }
        return "\(count)枚を一括変換済み。シート結合は横1列ぶんのPNGになります。"
    }

    // MARK: - 部品

    private func chipToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(height: 29)
                .padding(.horizontal, 10)
                .background(isOn.wrappedValue ? Theme.ink : Theme.paper)
                .foregroundColor(isOn.wrappedValue ? Color.white : Theme.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.ink.opacity(0.14), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Theme.accent)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.ink.opacity(0.7))
                .frame(width: 48, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .tint(Theme.accent)
            Text("\(Int(value.wrappedValue))\(suffix)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.ink.opacity(0.7))
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: - Int バインド

    private var sizeBinding: Binding<Double> {
        Binding(
            get: { Double(model.options.targetSize) },
            set: { model.options.targetSize = Int($0) }
        )
    }

    private var colorBinding: Binding<Double> {
        Binding(
            get: { Double(model.options.maxColors) },
            set: { model.options.maxColors = Int($0) }
        )
    }

    private var toleranceBinding: Binding<Double> {
        Binding(
            get: { Double(model.options.backgroundTolerance) },
            set: { model.options.backgroundTolerance = Int($0) }
        )
    }

    private var hueBinding: Binding<Double> {
        Binding(
            get: { Double(model.options.hueAngle) },
            set: { model.options.hueAngle = Int($0) }
        )
    }
}
