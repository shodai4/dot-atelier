#!/usr/bin/env python3
"""ドットアトリエのロジック単体テスト。

1) Python ミラー（scripts/dot_engine.py）で色変換・5段階パイプラインの数式と段取りを検証
2) Swift 側のソース・Info.plist・PrivacyInfo・project.yml が同じ設定値で揃っているかを検証

Xcode の無い環境（ubuntu ランナー）でも走る。実際のコンパイルは build ジョブが担う。
"""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import dot_engine as E  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
FAILURES: list[str] = []
CHECKS = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global CHECKS
    CHECKS += 1
    if not condition:
        FAILURES.append(f"{name}: {detail}" if detail else name)
        print(f"FAIL  {name}  {detail}")
    else:
        print(f"ok    {name}")


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


# ---------------------------------------------------------------- 画像づくり

def blank(width: int, height: int, color=(0, 0, 0, 0)):
    return list(color) * (width * height)


def put(buf, width, x, y, color):
    idx = (y * width + x) * 4
    buf[idx:idx + 4] = list(color)


def get(buf, width, x, y):
    idx = (y * width + x) * 4
    return tuple(buf[idx:idx + 4])


def gradient(width: int, height: int):
    buf = []
    for y in range(height):
        for x in range(width):
            buf.extend([min(255, x * 12), min(255, y * 9), 90, 255])
    return buf


# ---------------------------------------------------------------- 色空間

def test_oklab():
    for color in [(255, 255, 255), (0, 0, 0), (200, 30, 40), (74, 106, 122), (17, 200, 90)]:
        lab = E.rgb_to_oklab(*color)
        back = E.oklab_to_rgb(*lab)
        diff = max(abs(a - b) for a, b in zip(color, back))
        check(f"Oklab往復 {color}", diff <= 1, f"戻り値 {tuple(back)} 差 {diff}")

    white = E.rgb_to_oklab(255, 255, 255)
    black = E.rgb_to_oklab(0, 0, 0)
    check("白の明度はほぼ1", abs(white[0] - 1.0) < 0.01, str(white))
    check("黒の明度はほぼ0", abs(black[0]) < 0.01, str(black))
    check("白は無彩色", abs(white[1]) < 0.01 and abs(white[2]) < 0.01, str(white))


def test_palettes():
    check("FCパレットは16色", len(E.FC_PALETTE) == 16)
    check("GBパレットは4色", len(E.GB_PALETTE) == 4)
    check("PICO-8パレットは16色", len(E.PICO8_PALETTE) == 16)
    check("FCに重複なし", len({tuple(c) for c in E.FC_PALETTE}) == 16)
    check("PICO-8に重複なし", len({tuple(c) for c in E.PICO8_PALETTE}) == 16)
    check("GBは明るさ順", E.GB_PALETTE[0][1] < E.GB_PALETTE[-1][1])


def test_quantize_fixed_palette():
    width = height = 16
    src = gradient(width, height)
    out, palette = E.quantize_oklab(src, width, height, 16, fixed_palette=E.FC_PALETTE)
    check("固定パレットはそのまま返る", palette == E.FC_PALETTE, str(palette[:3]))
    used = set()
    for i in range(width * height):
        idx = i * 4
        if out[idx + 3] == 0:
            continue
        used.add((out[idx], out[idx + 1], out[idx + 2]))
    check("出力色はすべて固定パレット内", used <= {tuple(c) for c in E.FC_PALETTE}, str(list(used)[:4]))
    check("固定パレットで複数色が使われる", len(used) > 3, str(len(used)))


def test_quantize_kmeans_deterministic():
    width = height = 16
    src = gradient(width, height)
    out1, pal1 = E.quantize_oklab(src, width, height, 8, None, True, "none")
    out2, pal2 = E.quantize_oklab(src, width, height, 8, None, True, "none")
    check("K-Meansは決定論的", out1 == out2 and pal1 == pal2)
    check("色数は要求以下", len(pal1) <= 8, str(len(pal1)))


def test_dither_changes_result():
    width = height = 16
    src = gradient(width, height)
    plain, _ = E.quantize_oklab(src, width, height, 4, None, False, "none")
    dithered, _ = E.quantize_oklab(src, width, height, 4, None, False, "bayer4")
    check("4×4ディザで結果が変わる", plain != dithered)


# ---------------------------------------------------------------- 前処理

def test_background():
    width = height = 8
    src = blank(width, height, (255, 255, 255, 255))
    for x in range(2, 6):
        for y in range(2, 6):
            if x in (2, 5) or y in (2, 5):
                put(src, width, x, y, (200, 20, 20, 255))
    out = E.remove_outer_background(src, width, height, 22)
    check("外周の白は透過", get(out, width, 0, 0)[3] == 0)
    check("囲まれた内側の白は残る", get(out, width, 3, 3)[3] == 255)
    check("赤い輪は残る", get(out, width, 2, 2)[:3] == (200, 20, 20))


def test_remove_color():
    width, height = 6, 4
    src = blank(width, height, (255, 255, 255, 255))
    put(src, width, 1, 1, (250, 10, 10, 255))
    put(src, width, 4, 2, (10, 10, 250, 255))
    out = E.remove_color_by_sample(src, width, height, [250, 10, 10], 22)
    check("タップ色だけ透過", get(out, width, 1, 1)[3] == 0)
    check("別の色は残る", get(out, width, 4, 2)[3] == 255)
    check("タップ色に近い白は残る", get(out, width, 0, 0)[3] == 255)


def test_downscale():
    src = blank(100, 60, (40, 80, 120, 255))
    out = E.edge_priority_downscale(src, 100, 60, 32, 19)
    check("縦横比維持の縮小サイズ", len(out) == 32 * 19 * 4)
    check("縮小後も不透明", out[3] == 255)

    cell = blank(4, 4, (0, 0, 0, 0))
    put(cell, 4, 0, 0, (255, 0, 0, 255))       # 4pxセルのうち1pxだけ不透明
    for x in (2, 3):
        put(cell, 4, x, 0, (0, 255, 0, 255))   # 4pxセルのうち2px不透明
        put(cell, 4, x, 1, (0, 255, 0, 255))
    small = E.edge_priority_downscale(cell, 4, 4, 2, 2)
    check("半分未満しか不透明でないセルは透過", small[3] == 0)
    check("半分以上不透明なセルは残る", small[(0 * 2 + 1) * 4 + 3] == 255)


def test_seamless():
    width = height = 12
    src = gradient(width, height)
    out = E.make_seamless_tile(src, width, height)
    left_right_equal = all(
        get(out, width, 0, y)[:3] == get(out, width, width - 1, y)[:3] for y in range(height)
    )
    top_bottom_equal = all(
        get(out, width, x, 0)[:3] == get(out, width, x, height - 1)[:3] for x in range(width)
    )
    check("左右端の色が一致（タイル継ぎ目なし）", left_right_equal)
    check("上下端の色が一致（タイル継ぎ目なし）", top_bottom_equal)


# ---------------------------------------------------------------- 仕上げ

def test_despeckle():
    width = height = 7
    src = blank(width, height, (0, 0, 0, 0))
    put(src, width, 3, 3, (30, 30, 30, 255))     # 透明に浮いた1粒
    for x in range(1, 4):
        put(src, width, x, 5, (200, 0, 0, 255))  # 3連は残す
    out = E.remove_isolated_pixels(src, width, height)
    check("透明に浮いた1粒は消える", get(out, width, 3, 3)[3] == 0)
    check("つながった線は残る", get(out, width, 1, 5)[3] == 255)

    noisy = blank(width, height, (255, 255, 255, 255))
    put(noisy, width, 3, 3, (0, 0, 0, 255))      # 周囲と色が浮いた1粒
    replaced = E.remove_isolated_pixels(noisy, width, height)
    check("色だけ浮いた1粒は近傍色に置換", get(replaced, width, 3, 3)[:3] == (255, 255, 255))


def test_dejaggy():
    width = height = 5
    src = blank(width, height, (0, 0, 0, 0))
    put(src, width, 2, 2, (200, 0, 0, 255))
    put(src, width, 2, 1, (200, 0, 0, 255))   # 上
    put(src, width, 3, 2, (200, 0, 0, 255))   # 右
    out = E.thin_jaggy_corners(src, width, height)
    check("L字の角（上+右）は間引かれる", get(out, width, 2, 2)[3] == 0)
    check("腕の部分は残る", get(out, width, 2, 1)[3] == 255 and get(out, width, 3, 2)[3] == 255)


def test_outline():
    width = height = 7
    src = blank(width, height, (0, 0, 0, 0))
    for y in range(2, 5):
        for x in range(2, 5):
            put(src, width, x, y, (200, 120, 60, 255))
    out = E.apply_outline(src, width, height, "black")
    check("外周に1px黒線", get(out, width, 2, 1)[:3] == (20, 20, 22) and get(out, width, 2, 1)[3] == 255)
    check("内部は塗りつぶさない", get(out, width, 3, 3)[:3] == (200, 120, 60))
    check("角の外側は輪郭なし", get(out, width, 1, 1)[3] == 0)

    dark = blank(width, height, (0, 0, 0, 0))
    put(dark, width, 3, 3, (10, 10, 10, 255))
    out_dark = E.apply_outline(dark, width, height, "black")
    check("暗い線の隣は二重輪郭にしない", get(out_dark, width, 3, 4)[3] == 0)

    colored = E.apply_outline(src, width, height, "colortrace")
    check("色トレスは輪郭色が元色ベース", get(colored, width, 2, 1)[3] == 255
          and get(colored, width, 2, 1)[:3] != (20, 20, 22))


def test_variants():
    width, height = 4, 4
    src = blank(width, height, (200, 40, 40, 255))
    put(src, width, 0, 0, (10, 10, 10, 255))

    flash = E.apply_variant(src, width, height, "flash")
    check("白フラッシュは白", get(flash, width, 1, 1)[:3] == (255, 255, 255))

    shadow = E.apply_variant(src, width, height, "shadow")
    check("黒影は半透明の黒", get(shadow, width, 1, 1) == (16, 16, 20, 140))

    p2 = E.apply_variant(src, width, height, "p2")
    check("2P色相で明るい色は回転", get(p2, width, 1, 1)[:3] != (200, 40, 40))
    check("2P色相で暗い輪郭は保護", get(p2, width, 0, 0)[:3] == (10, 10, 10))


def test_sheet():
    frames = []
    for index, color in enumerate([(255, 0, 0), (0, 255, 0), (0, 0, 255)]):
        buf = blank(4, 3, (*color, 255))
        frames.append({"rgba": buf, "width": 4, "height": 3, "index": index})
    sheet = E.merge_sprite_sheet(frames)
    check("シートは横結合", sheet["width"] == 12 and sheet["height"] == 3)
    check("2枚目の先頭画素が正しい", get(sheet["rgba"], 12, 4, 0)[:3] == (0, 255, 0))
    check("3枚目の先頭画素が正しい", get(sheet["rgba"], 12, 8, 0)[:3] == (0, 0, 255))

    broken = frames + [{"rgba": blank(2, 2, (1, 1, 1, 255)), "width": 2, "height": 2, "index": 9}]
    check("大きさが違うフレームは結合しない", E.merge_sprite_sheet(broken) is None)


# ---------------------------------------------------------------- 通し

def circle_image(size=40):
    buf = blank(size, size, (255, 255, 255, 255))
    center = size / 2.0
    for y in range(size):
        for x in range(size):
            if (x - center + 0.5) ** 2 + (y - center + 0.5) ** 2 <= (size * 0.3) ** 2:
                put(buf, size, x, y, (200, 40, 40, 255))
    return buf


def test_convert_pipeline():
    size = 40
    src = circle_image(size)
    result = E.convert(src, size, size, {
        "target_size": 16, "max_colors": 16, "smooth": True, "hue_shift": True,
        "despeckle": True, "dejaggy": True, "outline": "black", "remove_background": True,
    })
    check("出力は指定サイズ", result["width"] == 16 and result["height"] == 16)
    check("角（背景）は透過", get(result["rgba"], 16, 0, 0)[3] == 0)
    check("中心（被写体）は不透明", get(result["rgba"], 16, 8, 8)[3] == 255)
    palette = {tuple(c) for c in result["palette"]}
    used = set()
    for i in range(16 * 16):
        idx = i * 4
        if result["rgba"][idx + 3] == 255:
            used.add(tuple(result["rgba"][idx:idx + 3]))
    check("使われる色は減色パレット＋輪郭色", used <= palette | {(20, 20, 22)}, str(len(used)))
    check("5段階を通して複数色が残る", len(used) >= 2, str(len(used)))


def test_convert_deterministic():
    size = 24
    src = gradient(size, size)
    options = {"target_size": 12, "max_colors": 8, "outline": "colortrace"}
    first = E.convert(src, size, size, options)
    second = E.convert(src, size, size, options)
    check("同じ入力は同じ出力", first == second)


def test_aspect():
    options = {"target_size": 32, "max_colors": 8, "outline": "none"}
    tall = E.convert(blank(60, 100, (120, 90, 60, 255)), 60, 100, options)
    check("縦長は高さが基準", tall["height"] == 32 and tall["width"] == 19, f'{tall["width"]}x{tall["height"]}')
    wide = E.convert(blank(100, 40, (120, 90, 60, 255)), 100, 40, options)
    check("横長は幅が基準", wide["width"] == 32 and wide["height"] == 13, f'{wide["width"]}x{wide["height"]}')


# ---------------------------------------------------------------- Swift 側の整合

def test_swift_sources():
    project = read("project.yml")
    check("Bundle ID が com.shodai4.dotatelier",
          "PRODUCT_BUNDLE_IDENTIFIER: com.shodai4.dotatelier" in project)
    check("deployment target は iOS 17.0", 'iOS: "17.0"' in project)
    check("Team ID が既存アプリと同じ", "DEVELOPMENT_TEAM: 86WNUS2875" in project)

    plist = read("Resources/Info.plist")
    for key in ["NSPhotoLibraryAddUsageDescription", "NSPhotoLibraryUsageDescription",
                "NSCameraUsageDescription", "ITSAppUsesNonExemptEncryption"]:
        check(f"Info.plist に {key}", key in plist)
    check("表示名はドットアトリエ", "<string>ドットアトリエ</string>" in plist)
    check("暗号化は非該当(false)", "<key>ITSAppUsesNonExemptEncryption</key>\n\t<false/>" in plist)

    privacy = read("Resources/PrivacyInfo.xcprivacy")
    check("プライバシー: トラッキングなし", "<key>NSPrivacyTracking</key>\n\t<false/>" in privacy)
    check("プライバシー: 収集データなし", "<key>NSPrivacyCollectedDataTypes</key>\n\t<array/>" in privacy)

    cutout = read("Sources/Services/SubjectCutoutService.swift")
    check("Vision の被写体切り抜きを使用", "VNGenerateForegroundInstanceMaskRequest" in cutout)
    check("iOS 17 の #available ガードがある", "#available(iOS 17.0, *)" in cutout)
    check("元画像と同じ座標系で切り抜く", "croppedToInstancesExtent: false" in cutout)

    engine = read("Sources/Services/PixelArtEngine.swift")
    for name in ["removeOuterBackground", "edgePreservingSmooth", "edgePriorityDownscale",
                 "quantizeOklab", "removeIsolatedPixels", "thinJaggyCorners", "applyOutline",
                 "makeSeamlessTile", "applyVariant", "mergeSpriteSheet", "makeUIImage"]:
        check(f"エンジンに {name}", name in engine)
    for token in ["38.0 * 38.0 * 3.0", "> 42", "> 75", "0.18", "0.025", "0.028", "0.09", "adjacentLum < 60"]:
        check(f"エンジンのしきい値 {token}", token in engine)
    check("等倍出力（scale 1）", "UIImage(cgImage: cgImage, scale: 1, orientation: .up)" in engine)

    models = read("Sources/Models/PixelModels.swift")
    swift_fc = [[int(a), int(b), int(c)] for a, b, c in
                re.findall(r"\[(\d+), (\d+), (\d+)\]", models.split("static let gb")[0])]
    check("Swift のFCパレットがPythonと一致", swift_fc == E.FC_PALETTE, str(swift_fc[:3]))
    swift_gb = [[int(a), int(b), int(c)] for a, b, c in
                re.findall(r"\[(\d+), (\d+), (\d+)\]", models.split("static let gb")[1].split("static let pico8")[0])]
    check("Swift のGBパレットがPythonと一致", swift_gb == E.GB_PALETTE, str(swift_gb))
    swift_pico = [[int(a), int(b), int(c)] for a, b, c in
                  re.findall(r"\[(\d+), (\d+), (\d+)\]", models.split("static let pico8")[1].split("/// PICO-8")[0] if "/// PICO-8" in models else models.split("static let pico8")[1])]
    check("Swift のPICO-8パレットがPythonと一致", swift_pico[:16] == E.PICO8_PALETTE, str(swift_pico[:3]))
    check("プリセットのサイズ/色数", all(s in models for s in [
        "case .rpg48: return 48", "case .icon64: return 64",
        "case .gb: return 4", "case .rpg48: return 24", "case .icon64: return 32", "default: return 16"]))

    model = read("Sources/Views/StudioModel.swift")
    for name in ["exportCurrent", "exportSheet", "exportAll", "touchPixel", "scheduleReprocess", "undo"]:
        check(f"画面側に {name}", name in model)
    check("パレットロック実装", "options.lockPalette" in model)
    check("1ドット修正の取り消しが20手", "undoStack.count > 20" in model)
    control = read("Sources/Views/ControlDock.swift")
    for label in ["1×PNG保存", "シート結合", "全枚保存", "AI被写体抜き", "シームレス", "差分"]:
        check(f"UIに「{label}」", label in control)
    content = read("Sources/Views/ContentView.swift")
    check("最大8枚の一括読み込み", "maxSelectionCount: 8" in content)


def main() -> int:
    test_oklab()
    test_palettes()
    test_quantize_fixed_palette()
    test_quantize_kmeans_deterministic()
    test_dither_changes_result()
    test_background()
    test_remove_color()
    test_downscale()
    test_seamless()
    test_despeckle()
    test_dejaggy()
    test_outline()
    test_variants()
    test_sheet()
    test_convert_pipeline()
    test_convert_deterministic()
    test_aspect()
    test_swift_sources()

    print()
    print(f"{CHECKS - len(FAILURES)} / {CHECKS} 件 PASS")
    if FAILURES:
        print("失敗:")
        for failure in FAILURES:
            print("  -", failure)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
