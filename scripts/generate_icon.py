#!/usr/bin/env python3
"""アプリアイコン（1024×1024）を生成する。

32×32 のドット絵を NEAREST で 32 倍に引き伸ばし、ドットの粒をそのまま残す。
パレット（絵具皿）を墨色の線で描き、絵具の玉をプリセットカラーで置く。
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"

GRID = 32
SCALE = 1024 // GRID

IVORY = (249, 248, 245, 255)
INK = (26, 26, 27, 255)
CREAM = (241, 238, 231, 255)
RUST = (74, 106, 122, 255)
RED = (200, 62, 48, 255)
YELLOW = (240, 196, 72, 255)
GREEN = (86, 132, 82, 255)
ORANGE = (214, 132, 70, 255)


def main() -> int:
    image = Image.new("RGBA", (GRID, GRID), IVORY)
    draw = ImageDraw.Draw(image)

    # パレット本体（角の丸い木の板）
    draw.rounded_rectangle([3, 6, 29, 27], radius=6, fill=CREAM, outline=INK, width=1)
    # 内側の縁
    draw.rounded_rectangle([5, 8, 27, 25], radius=5, outline=INK, width=1)

    # 親指穴
    draw.ellipse([18, 16, 23, 21], fill=IVORY, outline=INK)

    # 絵具の玉（プリセットの色）
    dabs = [
        (10, 12, RUST),
        (16, 11, RED),
        (22, 13, YELLOW),
        (9, 19, GREEN),
        (14, 21, ORANGE),
    ]
    for x, y, color in dabs:
        draw.rectangle([x - 1, y - 1, x + 1, y + 1], fill=color, outline=INK)

    icon = image.resize((1024, 1024), Image.NEAREST)
    icon.convert("RGB").save(OUT)
    print(f"saved {OUT} ({icon.size[0]}x{icon.size[1]})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
