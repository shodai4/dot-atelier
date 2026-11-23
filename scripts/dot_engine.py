#!/usr/bin/env python3
"""ドット絵エンジンの Python ミラー（検証用）。

Swift 版 `Sources/Services/PixelArtEngine.swift` と同じ式・同じしきい値で書き、
GitHub Actions の test ジョブ（Xcode の無い ubuntu）でも計算の妥当性を確かめられるようにする。
実際の描画は Swift 側が行い、ここは数式と段取りの自己点検が目的。
"""

from __future__ import annotations

import math

BAYER_4 = [[(v + 0.5) / 16.0 - 0.5 for v in row] for row in [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
]]

FC_PALETTE = [
    [124, 124, 124], [0, 0, 252], [0, 0, 188], [68, 40, 188],
    [148, 0, 132], [168, 0, 32], [168, 16, 0], [136, 20, 0],
    [80, 48, 0], [0, 120, 0], [0, 104, 0], [0, 88, 0],
    [0, 64, 88], [0, 0, 0], [188, 188, 188], [248, 248, 248],
]

GB_PALETTE = [[15, 56, 15], [48, 98, 48], [139, 172, 15], [155, 188, 15]]

PICO8_PALETTE = [
    [0, 0, 0], [29, 43, 83], [126, 37, 83], [0, 135, 81],
    [171, 82, 54], [95, 87, 79], [194, 195, 199], [255, 241, 232],
    [255, 0, 77], [255, 163, 0], [255, 236, 39], [0, 228, 54],
    [41, 173, 255], [131, 118, 156], [255, 119, 168], [255, 204, 170],
]

PRESETS = {
    "standard32": {"size": 32, "colors": 16, "dither": "none", "outline": "black", "palette": None},
    "fc": {"size": 32, "colors": 16, "dither": "none", "outline": "black", "palette": FC_PALETTE},
    "gb": {"size": 32, "colors": 4, "dither": "bayer4", "outline": "colortrace", "palette": GB_PALETTE},
    "pico8": {"size": 32, "colors": 16, "dither": "none", "outline": "black", "palette": PICO8_PALETTE},
    "rpg48": {"size": 48, "colors": 24, "dither": "none", "outline": "colortrace", "palette": None},
    "icon64": {"size": 64, "colors": 32, "dither": "none", "outline": "colortrace", "palette": None},
}


# --- 色空間 ---

def srgb_to_linear(c: int) -> float:
    v = c / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def linear_to_srgb(value: float) -> int:
    clamped = min(1.0, max(0.0, value))
    s = 12.92 * clamped if clamped <= 0.0031308 else 1.055 * (clamped ** (1.0 / 2.4)) - 0.055
    return int(round(s * 255.0))


def rgb_to_oklab(r: int, g: int, b: int):
    lr, lg, lb = srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b)
    l = (0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb) ** (1 / 3)
    m = (0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb) ** (1 / 3)
    s = (0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb) ** (1 / 3)
    return [
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    ]


def oklab_to_rgb(L: float, a: float, b: float):
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    return [
        linear_to_srgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        linear_to_srgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        linear_to_srgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
    ]


def lab_distance_sq(x, y) -> float:
    return (x[0] - y[0]) ** 2 + (x[1] - y[1]) ** 2 + (x[2] - y[2]) ** 2


# --- 1. 背景透過 ---

def remove_outer_background(rgba, width, height, tolerance):
    out = list(rgba)
    tol_sq = tolerance * tolerance * 3
    visited = [False] * (width * height)
    queue = []

    corners = [0, width - 1, (height - 1) * width, (height - 1) * width + (width - 1)]
    samples = []
    for corner in corners:
        idx = corner * 4
        if out[idx + 3] > 128:
            samples.append((out[idx], out[idx + 1], out[idx + 2]))
    if not samples:
        return out

    def is_bg(pixel):
        idx = pixel * 4
        if out[idx + 3] <= 128:
            return True
        for sr, sg, sb in samples:
            d = (out[idx] - sr) ** 2 + (out[idx + 1] - sg) ** 2 + (out[idx + 2] - sb) ** 2
            if d <= tol_sq:
                return True
        return False

    for x in range(width):
        for pixel in (x, (height - 1) * width + x):
            if not visited[pixel] and is_bg(pixel):
                visited[pixel] = True
                queue.append(pixel)
    for y in range(height):
        for pixel in (y * width, y * width + width - 1):
            if not visited[pixel] and is_bg(pixel):
                visited[pixel] = True
                queue.append(pixel)

    head = 0
    while head < len(queue):
        pixel = queue[head]
        head += 1
        out[pixel * 4 + 3] = 0
        x, y = pixel % width, pixel // width
        neighbours = []
        if x > 0:
            neighbours.append(pixel - 1)
        if x + 1 < width:
            neighbours.append(pixel + 1)
        if y > 0:
            neighbours.append(pixel - width)
        if y + 1 < height:
            neighbours.append(pixel + width)
        for nxt in neighbours:
            if not visited[nxt] and is_bg(nxt):
                visited[nxt] = True
                queue.append(nxt)
    return out


def remove_color_by_sample(rgba, width, height, target, tolerance):
    out = list(rgba)
    tol_sq = tolerance * tolerance * 3
    for i in range(width * height):
        idx = i * 4
        if out[idx + 3] == 0:
            continue
        d = (out[idx] - target[0]) ** 2 + (out[idx + 1] - target[1]) ** 2 + (out[idx + 2] - target[2]) ** 2
        if d <= tol_sq:
            out[idx + 3] = 0
    return out


# --- 2. 平滑化 ---

def edge_preserving_smooth(rgba, width, height):
    out = [0] * len(rgba)
    sigma_sq = 38.0 * 38.0 * 3.0
    for y in range(height):
        for x in range(width):
            c = (y * width + x) * 4
            if rgba[c + 3] < 128:
                continue
            cr, cg, cb = rgba[c], rgba[c + 1], rgba[c + 2]
            sum_r = sum_g = sum_b = sum_w = 0.0
            for dy in (-1, 0, 1):
                ny = y + dy
                if ny < 0 or ny >= height:
                    continue
                for dx in (-1, 0, 1):
                    nx = x + dx
                    if nx < 0 or nx >= width:
                        continue
                    n = (ny * width + nx) * 4
                    if rgba[n + 3] < 128:
                        continue
                    nr, ng, nb = rgba[n], rgba[n + 1], rgba[n + 2]
                    dist = (cr - nr) ** 2 + (cg - ng) ** 2 + (cb - nb) ** 2
                    w = math.exp(-dist / sigma_sq)
                    sum_r += nr * w
                    sum_g += ng * w
                    sum_b += nb * w
                    sum_w += w
            if sum_w > 0:
                out[c] = min(255, max(0, int(round(sum_r / sum_w))))
                out[c + 1] = min(255, max(0, int(round(sum_g / sum_w))))
                out[c + 2] = min(255, max(0, int(round(sum_b / sum_w))))
            out[c + 3] = 255
    return out


# --- 3. ダウンサンプリング ---

def edge_priority_downscale(rgba, src_w, src_h, dst_w, dst_h):
    out = [0] * (dst_w * dst_h * 4)
    lum = [0.0] * (src_w * src_h)
    for i in range(src_w * src_h):
        idx = i * 4
        lum[i] = 0.2126 * rgba[idx] + 0.7152 * rgba[idx + 1] + 0.0722 * rgba[idx + 2]
    edge = [0.0] * (src_w * src_h)
    for y in range(1, src_h - 1):
        for x in range(1, src_w - 1):
            p = y * src_w + x
            edge[p] = abs(lum[p + 1] - lum[p - 1]) + abs(lum[p + src_w] - lum[p - src_w])

    for dy in range(dst_h):
        y0 = dy * src_h // dst_h
        y1 = max(y0 + 1, (dy + 1) * src_h // dst_h)
        for dx in range(dst_w):
            x0 = dx * src_w // dst_w
            x1 = max(x0 + 1, (dx + 1) * src_w // dst_w)
            opaque = total = 0
            best_score, best_idx = -1.0, -1
            sum_r = sum_g = sum_b = 0
            sum_lum, min_lum, dark_idx = 0.0, float("inf"), -1
            for sy in range(y0, y1):
                for sx in range(x0, x1):
                    p = sy * src_w + sx
                    idx = p * 4
                    total += 1
                    if rgba[idx + 3] >= 128:
                        opaque += 1
                        sum_r += rgba[idx]
                        sum_g += rgba[idx + 1]
                        sum_b += rgba[idx + 2]
                        sum_lum += lum[p]
                        if lum[p] < min_lum:
                            min_lum = lum[p]
                            dark_idx = idx
                        score = edge[p] * 1.4 + (255.0 - lum[p]) * 0.25
                        if score > best_score:
                            best_score, best_idx = score, idx
            o = (dy * dst_w + dx) * 4
            if opaque * 2 < total or opaque == 0:
                continue
            mean_lum = sum_lum / opaque
            if dark_idx >= 0 and mean_lum - min_lum > 42:
                out[o], out[o + 1], out[o + 2] = rgba[dark_idx], rgba[dark_idx + 1], rgba[dark_idx + 2]
            elif best_score > 75 and best_idx >= 0:
                out[o], out[o + 1], out[o + 2] = rgba[best_idx], rgba[best_idx + 1], rgba[best_idx + 2]
            else:
                out[o] = sum_r // opaque
                out[o + 1] = sum_g // opaque
                out[o + 2] = sum_b // opaque
            out[o + 3] = 255
    return out


# --- 4. 減色 ---

def quantize_oklab(rgba, width, height, max_colors, fixed_palette=None, hue_shift=True, dither="none"):
    palette = [list(c) for c in fixed_palette] if fixed_palette else []
    if not palette:
        step = max(1, (width * height) // 4096)
        samples = []
        for i in range(0, width * height, step):
            idx = i * 4
            if rgba[idx + 3] >= 128:
                samples.append(rgb_to_oklab(rgba[idx], rgba[idx + 1], rgba[idx + 2]))
        if not samples:
            return list(rgba), []
        k = min(max(1, max_colors), len(samples))
        centroids = [list(samples[0])]
        while len(centroids) < k:
            max_d, far = -1.0, samples[0]
            for sample in samples:
                min_d = min(lab_distance_sq(sample, c) for c in centroids)
                if min_d > max_d:
                    max_d, far = min_d, sample
            centroids.append(list(far))
        for _ in range(8):
            sums = [[0.0, 0.0, 0.0, 0] for _ in range(k)]
            for sample in samples:
                best, best_d = 0, float("inf")
                for j, centroid in enumerate(centroids):
                    d = lab_distance_sq(sample, centroid)
                    if d < best_d:
                        best_d, best = d, j
                sums[best][0] += sample[0]
                sums[best][1] += sample[1]
                sums[best][2] += sample[2]
                sums[best][3] += 1
            for j in range(k):
                if sums[j][3] > 0:
                    n = sums[j][3]
                    centroids[j] = [sums[j][0] / n, sums[j][1] / n, sums[j][2] / n]
        palette = []
        for (L, a, b) in centroids:
            if hue_shift:
                if L < 0.45:
                    t = (0.45 - L) / 0.45
                    b -= 0.025 * t
                    a += 0.01 * t
                elif L > 0.72:
                    b += 0.028 * ((L - 0.72) / 0.28)
            palette.append(oklab_to_rgb(L, a, b))
    if not palette:
        return list(rgba), []

    palette_lab = [rgb_to_oklab(*c) for c in palette]
    out = list(rgba)
    for y in range(height):
        for x in range(width):
            idx = (y * width + x) * 4
            if rgba[idx + 3] < 128:
                out[idx + 3] = 0
                continue
            lab = rgb_to_oklab(rgba[idx], rgba[idx + 1], rgba[idx + 2])
            if dither == "bayer4":
                lab[0] += BAYER_4[y & 3][x & 3] * 0.09
            best, best_d = 0, float("inf")
            for j, plab in enumerate(palette_lab):
                d = lab_distance_sq(lab, plab)
                if d < best_d:
                    best_d, best = d, j
            out[idx], out[idx + 1], out[idx + 2] = palette[best]
            out[idx + 3] = 255
    return out, palette


# --- 5. 仕上げ ---

def remove_isolated_pixels(rgba, width, height):
    out = list(rgba)
    for y in range(height):
        for x in range(width):
            idx = (y * width + x) * 4
            is_opaque = rgba[idx + 3] >= 128
            same = 0
            colors = []
            for dy in (-1, 0, 1):
                ny = y + dy
                if ny < 0 or ny >= height:
                    continue
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx = x + dx
                    if nx < 0 or nx >= width:
                        continue
                    n = (ny * width + nx) * 4
                    if is_opaque and rgba[n + 3] >= 128:
                        colors.append((rgba[n], rgba[n + 1], rgba[n + 2]))
                        if rgba[n] == rgba[idx] and rgba[n + 1] == rgba[idx + 1] and rgba[n + 2] == rgba[idx + 2]:
                            same += 1
            if is_opaque and not colors:
                out[idx + 3] = 0
            elif is_opaque and same == 0 and len(colors) >= 6:
                out[idx], out[idx + 1], out[idx + 2] = colors[0]
    return out


def thin_jaggy_corners(rgba, width, height):
    out = list(rgba)

    def op(x, y):
        if x < 0 or y < 0 or x >= width or y >= height:
            return False
        return rgba[(y * width + x) * 4 + 3] >= 128

    for y in range(1, height - 1):
        for x in range(1, width - 1):
            if not op(x, y):
                continue
            u, d, l, r = op(x, y - 1), op(x, y + 1), op(x - 1, y), op(x + 1, y)
            ul, ur, dl, dr = op(x - 1, y - 1), op(x + 1, y - 1), op(x - 1, y + 1), op(x + 1, y + 1)
            if (u and r and not d and not l and not ur and not dl) or \
               (u and l and not d and not r and not ul and not dr) or \
               (d and r and not u and not l and not dr and not ul) or \
               (d and l and not u and not r and not dl and not ur):
                out[(y * width + x) * 4 + 3] = 0
    return out


def apply_outline(rgba, width, height, mode):
    if mode == "none":
        return list(rgba)
    out = list(rgba)
    dirs = [(0, -1), (1, 0), (0, 1), (-1, 0)]
    for y in range(height):
        for x in range(width):
            idx = (y * width + x) * 4
            if rgba[idx + 3] >= 128:
                continue
            adj = -1
            for dx, dy in dirs:
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    n = (ny * width + nx) * 4
                    if rgba[n + 3] >= 128:
                        adj = n
                        break
            if adj < 0:
                continue
            adj_lum = 0.2126 * rgba[adj] + 0.7152 * rgba[adj + 1] + 0.0722 * rgba[adj + 2]
            if adj_lum < 60:
                continue
            if mode == "black":
                out[idx], out[idx + 1], out[idx + 2], out[idx + 3] = 20, 20, 22, 255
            else:
                L, a, b = rgb_to_oklab(rgba[adj], rgba[adj + 1], rgba[adj + 2])
                r, g, bl = oklab_to_rgb(max(0.14, L * 0.45), a * 0.9, b - 0.02)
                out[idx], out[idx + 1], out[idx + 2], out[idx + 3] = r, g, bl, 255
    return out


def make_seamless_tile(rgba, width, height):
    out = list(rgba)
    band_x = max(1, int(width * 0.18))
    band_y = max(1, int(height * 0.18))
    for y in range(height):
        left = (y * width) * 4
        right = (y * width + (width - 1)) * 4
        for c in range(3):
            lv, rv = out[left + c], out[right + c]
            avg = (lv + rv) / 2.0
            for x in range(band_x):
                t = x / band_x
                li = (y * width + x) * 4
                ri = (y * width + (width - 1 - x)) * 4
                out[li + c] = int(round(avg + (lv - avg) * t))
                out[ri + c] = int(round(avg + (rv - avg) * t))
    for x in range(width):
        top = x * 4
        bottom = ((height - 1) * width + x) * 4
        for c in range(3):
            tv, bv = out[top + c], out[bottom + c]
            avg = (tv + bv) / 2.0
            for y in range(band_y):
                t = y / band_y
                ti = (y * width + x) * 4
                bi = ((height - 1 - y) * width + x) * 4
                out[ti + c] = int(round(avg + (tv - avg) * t))
                out[bi + c] = int(round(avg + (bv - avg) * t))
    return out


def apply_variant(rgba, width, height, variant, hue_angle=135):
    out = list(rgba)
    if variant == "normal":
        return out
    rad = math.radians(hue_angle)
    cos_a, sin_a = math.cos(rad), math.sin(rad)
    for i in range(width * height):
        idx = i * 4
        if out[idx + 3] == 0:
            continue
        if variant == "flash":
            out[idx], out[idx + 1], out[idx + 2] = 255, 255, 255
        elif variant == "shadow":
            out[idx], out[idx + 1], out[idx + 2], out[idx + 3] = 16, 16, 20, 140
        elif variant == "p2":
            L, a, b = rgb_to_oklab(out[idx], out[idx + 1], out[idx + 2])
            if L >= 0.22:
                na = a * cos_a - b * sin_a
                nb = a * sin_a + b * cos_a
                out[idx], out[idx + 1], out[idx + 2] = oklab_to_rgb(L, na, nb)
    return out


def merge_sprite_sheet(frames):
    if not frames:
        return None
    width, height = frames[0]["width"], frames[0]["height"]
    if any(f["width"] != width or f["height"] != height for f in frames):
        return None
    total_w = width * len(frames)
    out = [0] * (total_w * height * 4)
    for index, frame in enumerate(frames):
        offset = index * width
        for y in range(height):
            for x in range(width):
                s = (y * width + x) * 4
                d = (y * total_w + offset + x) * 4
                out[d:d + 4] = frame["rgba"][s:s + 4]
    return {"rgba": out, "width": total_w, "height": height}


def convert(src, src_w, src_h, options):
    work = list(src)
    if options.get("remove_background", True):
        work = remove_outer_background(work, src_w, src_h, options.get("tolerance", 22))
    if options.get("smooth", True):
        work = edge_preserving_smooth(work, src_w, src_h)

    target = options.get("target_size", 32)
    aspect = src_w / src_h
    if aspect >= 1:
        dst_w = max(8, target)
        dst_h = max(8, int(round(target / aspect)))
    else:
        dst_w = max(8, int(round(target * aspect)))
        dst_h = max(8, target)

    small = edge_priority_downscale(work, src_w, src_h, dst_w, dst_h)
    if options.get("seamless"):
        small = make_seamless_tile(small, dst_w, dst_h)
    small, palette = quantize_oklab(
        small, dst_w, dst_h,
        options.get("max_colors", 16),
        options.get("fixed_palette"),
        options.get("hue_shift", True),
        options.get("dither", "none"),
    )
    if options.get("despeckle", True):
        small = remove_isolated_pixels(small, dst_w, dst_h)
    if options.get("dejaggy", True):
        small = thin_jaggy_corners(small, dst_w, dst_h)
    if options.get("outline", "black") != "none":
        small = apply_outline(small, dst_w, dst_h, options["outline"])
    if options.get("variant", "normal") != "normal":
        small = apply_variant(small, dst_w, dst_h, options["variant"], options.get("hue_angle", 135))
    return {"rgba": small, "width": dst_w, "height": dst_h, "palette": palette}
